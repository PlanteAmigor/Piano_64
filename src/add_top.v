//==========================================================================
//  piano64 —— 64 路加法分量钢琴，【只有按键发声模式】
//
//  与原工程（piano_twinkle_dac）完全一致的硬件：
//    · 按键：KEY[0..5]=do re mi fa sol la  KEY[7]=升八度 KEY[8]=降八度
//            KEY[6] 原为模式键，本工程只有一种模式 → 空闲不用
//    · 灯带：20 颗，只有 7 颗按键指示灯（按下亮、松开灭），其余全黑
//            第 5~11 颗（索引 4~10）：KEY[0]→索引10 … KEY[6]→索引4
//
//  去掉的：自动演奏、指导模式、音色切换、八度切换、常亮状态灯
//  分量数：每音 64 路（赛题拓展 1「单音加法分量 ≥32 路」）
//==========================================================================
`default_nettype none

module add_top #(
    parameter integer STARTUP  = 2_500_000,    // 上电静音 50 ms
    // ★ 消隐窗从 8 ms 加长到 20 ms：便宜的轻触开关抖动可达 10~20 ms，
    //   8 ms 挡不住会多出几次 key_press → 重触发 → 听感是"哒哒"噪音
    parameter integer DEBOUNCE = 1_000_000     // 按键消隐窗 20 ms
)(
    input  wire       CLOCK_50,   // 50 MHz 晶振 V22（先进 PLL）
    input  wire       RESET_n,
    input  wire [6:0] KEY,        // [0..5]=do re mi fa sol la  [6]=模式键，悬空=1 按下=0
    // ── 18 键力度键盘（J13，2026-10-30 接入）────────────────────
    //    两排一前一后配对成 9 组，组 0..7 = 8 音键，组 8 = 切音高
    //    ★ RTL 尚未接入，先声明端口让 cst 能通过综合
    input  wire [8:0] KEY_R1,     // 第 1 排（PCB 上排）D14 D15 A18 A19 D17 C17 C20 F15 F19
    input  wire [8:0] KEY_R2,     // 第 2 排（PCB 下排）F16 E17 F13 F14 E16 D16 E19 D19 D20
    input  wire [1:0] KEY_AUX,    // 上方两个独立键 C18 C19
    output wire       AUD_BCK,
    output wire       AUD_LRCK,
    output wire       AUD_DIN,
    output wire       DOUT,       // WS2812

    // ── TF 卡（1-bit SD 模式，上电把 P64.BIN 灌进 DDR3）──────────
    output wire       SD_CLK,
    inout  wire       SD_CMD,
    input  wire       SD_DAT0,

    // ── 调试串口（115200 8N1，报告加载结果）────────────────────
    output wire       UART_TX,

    // ── DDR3 1 GiB（板载焊死，走专用 IOLOGIC 引脚，与 J13 无任何关系）──
    output wire [14:0] ddr_addr,
    output wire [2:0]  ddr_bank,
    output wire        ddr_cs,
    output wire        ddr_ras,
    output wire        ddr_cas,
    output wire        ddr_we,
    output wire        ddr_ck,
    output wire        ddr_ck_n,
    output wire        ddr_cke,
    output wire        ddr_odt,
    output wire        ddr_reset_n,
    output wire [3:0]  ddr_dm,
    inout  wire [31:0] ddr_dq,
    inout  wire [3:0]  ddr_dqs,
    inout  wire [3:0]  ddr_dqs_n
);

    // ★ 20 个键的原始电平（0=按下）。RTL 接入前先保留引用，避免综合优化掉端口。
    wire [19:0] key_pad_raw = {KEY_AUX, KEY_R2, KEY_R1};
    /* verilator lint_off UNUSED */
    wire        _unused_keys = ^key_pad_raw;
    /* verilator lint_on UNUSED */

    localparam integer NVOICE    = 8;      // ★ 4 → 8：只改这个参数（PH_SHIFT = 8/8 = 1 仍成立）
    localparam integer MIX_SHIFT = 1;
    localparam [2:0]   M_FREE    = 3'd2;       // 只有这一种模式

    //======================================================================
    //  时钟：50 MHz → PLL → 全局时钟网（频率不变，只为降时钟偏斜）
    //======================================================================
    wire clk_sys, pll_lock;

    pll50 u_pll (
        .clk_in (CLOCK_50),
        .clk_out(clk_sys),
        .lock   (pll_lock)
    );

    //======================================================================
    //  复位 + 上电静音
    //======================================================================
    reg [21:0] por_cnt = 22'd0;
    always @(posedge clk_sys)
        if (por_cnt != STARTUP[21:0] - 22'd1) por_cnt <= por_cnt + 22'd1;

    wire por_n       = (por_cnt == STARTUP[21:0] - 22'd1);
    wire engine_rst_n = por_n & RESET_n & pll_lock;

    //======================================================================
    //  按键扫描（9 个引脚全接，功能见文件头）
    //======================================================================
    wire [6:0] key_state, key_press, key_release;

    key_scan #(
        .N        (7),
        .DEBOUNCE (DEBOUNCE),
        .IMMEDIATE(1)
    ) u_keys (
        .clk         (clk_sys),
        .rst_n       (engine_rst_n),
        .key_in      (KEY),
        .key_state   (key_state),
        .key_press   (key_press),
        .key_release (key_release)
    );

    //======================================================================
    //  ★ 18 键双触点力度键盘（J13）
    //    KEY_R1 = 前触点（先闭合）  KEY_R2 = 后触点（后闭合）
    //    Δt 越小 = 力度越大；两触点都闭合才确认按下，都断开才确认抬起
    //    详细机理见 src/key_dual.v 文件头
    //======================================================================
    wire [8:0]  kd_state;
    wire [71:0] kd_vel;              // 9 键 × 8 位

    key_dual #(
        .N        (9),
        .T_CONFIRM(2_500_000),       // 50 ms：等第二个触点（超时=没压到底=轻按）
        .T_RELEASE(3_000_000)        // 60 ms：两触点都断开后确认抬起
    ) u_keys_dual (
        .clk       (clk_sys),
        .rst_n     (engine_rst_n),
        .key_f     (KEY_R1),
        .key_b     (KEY_R2),
        .key_state (kd_state),
        .key_vel   (kd_vel)
    );

    wire [1:0] aux_state, aux_press, aux_release;

    key_scan #(
        .N        (2),
        .DEBOUNCE (DEBOUNCE),
        .IMMEDIATE(1)
    ) u_keys_aux (
        .clk         (clk_sys),
        .rst_n       (engine_rst_n),
        .key_in      (KEY_AUX),
        .key_state   (aux_state),
        .key_press   (aux_press),
        .key_release (aux_release)
    );

    // 音源：前 8 个键（C4..C5 一个八度）
    // ★ 第 9 键是【纯功能键】——不在 7:0 里，本来就不会发声，不用额外屏蔽
    wire        shift_on = kd_state[8];     // 仅用于诊断显示

    wire [7:0]  note_key_state = kd_state[7:0];

    reg  [7:0]  kd_state_d;
    always @(posedge clk_sys) kd_state_d <= kd_state[7:0];
    wire [7:0]  note_key_press = kd_state[7:0] & ~kd_state_d;
    wire [63:0] note_key_vel   = kd_vel[63:0];

    // 模式/音色键：改用上方独立键 KEY_AUX[0]（旧 P14 不再使用）
    wire       mode_key_hit = aux_state[0];
    wire       mode_key_rel = aux_release[0];

    //======================================================================
    //  模式：1=按键发声  2=指导·小星星  3=指导·欢乐颂
    //======================================================================
    localparam [1:0] MD_FREE  = 2'd1,
                     MD_TWIN  = 2'd2,
                     MD_ODE   = 2'd3;

    reg [1:0] mode;

    //======================================================================
    //  KEY[6] 长短按区分
    //    短按（松开时、且没按满 1 s）→ 切模式 1/2/3
    //    长按（按满 1 s）          → 切音色 钢琴/古筝
    //======================================================================
    localparam integer LP_LIMIT = 50_000_000;       // 1 s @50MHz
    localparam [25:0]  LP_MAX   = LP_LIMIT - 1;

    reg [25:0] lp_cnt;
    reg        lp_fired;                            // 本次按键已判定为长按

    always @(posedge clk_sys) begin
        if (!engine_rst_n) begin
            lp_cnt   <= 26'd0;
            lp_fired <= 1'b0;
        end
        else if (mode_key_hit) begin                // 按住
            if (lp_cnt != LP_MAX) lp_cnt <= lp_cnt + 26'd1;
            else                  lp_fired <= 1'b1;
        end
        else begin                                  // 松开
            lp_cnt   <= 26'd0;
            lp_fired <= 1'b0;
        end
    end

    wire timbre_toggle = (lp_cnt == LP_MAX) && !lp_fired;   // 按满 1 s 那一拍
    wire mode_toggle   = mode_key_rel && !lp_fired;         // 短按松开

    always @(posedge clk_sys) begin
        if (!engine_rst_n)          mode <= MD_FREE;
        else if (mode_toggle)       mode <= (mode == MD_ODE) ? MD_FREE : mode + 2'd1;
    end

    //======================================================================
    //  音色：0 = 钢琴（白灯）  1 = 古筝（青灯）
    //======================================================================
    //  0 = 钢琴（白灯）  1 = 古筝（青灯）  2 = 唢呐（橙灯）
    reg [1:0] timbre_r;

    always @(posedge clk_sys) begin
        if (!engine_rst_n)          timbre_r <= 2'd0;
        else if (timbre_toggle)     timbre_r <= (timbre_r == 2'd2) ? 2'd0 : timbre_r + 2'd1;
    end

    // ★ 当前音色是否古筝（与 add_engine8 的 .timbre(timbre_r[0]) 同一判据）
    //   按键映射、移调范围都按它选
    wire is_gz = timbre_r[0];

    //======================================================================
    //  ★ 移调（第 9 键 = 纯功能键，单手一个键完成）
    //     轻击第 9 键（只有前触点闭合，力度小）→ 整体 +1 八度
    //     重击第 9 键（前后触点都闭合，力度大）→ 整体 -1 八度
    //     ★ 方向直接取 key_dual 已经算好的第 9 键力度 kd_vel[71:64]，
    //       与演奏用力完全同一套判定，不新加门限：
    //         轻击走 FALLBACK → vel = 48
    //         重击 → vel_from(Δt) 落在 2..254 的高段
    //       以 128 为界（正好是 vel_from 里 Δt≈15 ms 的位置）。
    //     到音域边界停住、不循环；切换音色清零回 0。
    //======================================================================
    localparam signed [7:0] TR_STEP = 8'sd12;

    // 8 个键音高范围由各乐器自己的映射决定：
    //   钢琴：60..72 (C4..C5)，表 21..108 → -36 .. +36（7 档）
    //   古筝：62..74 (D4..D5)，表 38..86  → -24 .. +12（4 档）
    //   唢呐：8 键 69..81，表 69..96 → 0 .. +12（只有 2 档）
    wire signed [7:0] tr_min = is_suona ?  8'sd0  :
                               is_gz    ? -8'sd24 : -8'sd36;
    wire signed [7:0] tr_max = is_suona ?  8'sd12 :
                               is_gz    ?  8'sd12 :  8'sd36;

    reg signed [7:0] transpose;

    reg        kd9_d, tr_armed, tr_hold;
    reg [21:0] tr_tmr;

    // 60 ms @50MHz：等 key_dual 把第 9 键的力度确定下来（其 T_CONFIRM = 50 ms）
    localparam [21:0] TR_WAIT = 22'd3_000_000;

    always @(posedge clk_sys) begin
        if (!engine_rst_n) begin
            transpose <= 8'sd0;
            kd9_d     <= 1'b0;
            tr_armed  <= 1'b0;
            tr_hold   <= 1'b0;
            tr_tmr    <= 22'd0;
        end
        else begin
            kd9_d <= kd_state[8];

            // 切换音色 → 清零（音域不同，旧档位可能已越界）
            if (timbre_toggle)
                transpose <= 8'sd0;

            // 第 9 键松开 → 允许下一次移调
            if (!kd_state[8])
                tr_hold <= 1'b0;

            // 第 9 键新按下沿
            if (kd_state[8] && !kd9_d && !tr_armed && !tr_hold) begin
                tr_armed <= 1'b1;
                tr_tmr   <= TR_WAIT;
            end
            else if (tr_armed) begin
                if (tr_tmr != 22'd0) begin
                    tr_tmr <= tr_tmr - 22'd1;
                end
                else begin
                    // 力度已确定：大 = 重击 → -12；小 = 轻击 → +12
                    tr_armed <= 1'b0;
                    tr_hold  <= 1'b1;
                    if (kd_vel[71:64] >= 8'd128) begin
                        // 到下限就停住，不回绕
                        transpose <= (transpose - TR_STEP < tr_min)
                                   ? tr_min : transpose - TR_STEP;
                    end
                    else begin
                        // 到上限就停住，不回绕
                        transpose <= (transpose + TR_STEP > tr_max)
                                   ? tr_max : transpose + TR_STEP;
                    end
                end
            end
        end
    end

    //======================================================================
    //  曲谱表（MIDI 音号，范围正好是 C4~B4，对应 7 个键）
    //    小星星 42 音  欢乐颂 30 音
    //======================================================================
    reg [6:0] g_twinkle [0:41];
    reg [6:0] g_ode     [0:29];

    initial begin
        g_twinkle[ 0]=7'd60; g_twinkle[ 1]=7'd60; g_twinkle[ 2]=7'd67; g_twinkle[ 3]=7'd67;
        g_twinkle[ 4]=7'd69; g_twinkle[ 5]=7'd69; g_twinkle[ 6]=7'd67;
        g_twinkle[ 7]=7'd65; g_twinkle[ 8]=7'd65; g_twinkle[ 9]=7'd64; g_twinkle[10]=7'd64;
        g_twinkle[11]=7'd62; g_twinkle[12]=7'd62; g_twinkle[13]=7'd60;
        g_twinkle[14]=7'd67; g_twinkle[15]=7'd67; g_twinkle[16]=7'd65; g_twinkle[17]=7'd65;
        g_twinkle[18]=7'd64; g_twinkle[19]=7'd64; g_twinkle[20]=7'd62;
        g_twinkle[21]=7'd67; g_twinkle[22]=7'd67; g_twinkle[23]=7'd65; g_twinkle[24]=7'd65;
        g_twinkle[25]=7'd64; g_twinkle[26]=7'd64; g_twinkle[27]=7'd62;
        g_twinkle[28]=7'd60; g_twinkle[29]=7'd60; g_twinkle[30]=7'd67; g_twinkle[31]=7'd67;
        g_twinkle[32]=7'd69; g_twinkle[33]=7'd69; g_twinkle[34]=7'd67;
        g_twinkle[35]=7'd65; g_twinkle[36]=7'd65; g_twinkle[37]=7'd64; g_twinkle[38]=7'd64;
        g_twinkle[39]=7'd62; g_twinkle[40]=7'd62; g_twinkle[41]=7'd60;

        g_ode[ 0]=7'd64; g_ode[ 1]=7'd64; g_ode[ 2]=7'd65; g_ode[ 3]=7'd67;
        g_ode[ 4]=7'd67; g_ode[ 5]=7'd65; g_ode[ 6]=7'd64; g_ode[ 7]=7'd62;
        g_ode[ 8]=7'd60; g_ode[ 9]=7'd60; g_ode[10]=7'd62; g_ode[11]=7'd64;
        g_ode[12]=7'd64; g_ode[13]=7'd62; g_ode[14]=7'd62;
        g_ode[15]=7'd64; g_ode[16]=7'd64; g_ode[17]=7'd65; g_ode[18]=7'd67;
        g_ode[19]=7'd67; g_ode[20]=7'd65; g_ode[21]=7'd64; g_ode[22]=7'd62;
        g_ode[23]=7'd60; g_ode[24]=7'd60; g_ode[25]=7'd62; g_ode[26]=7'd64;
        g_ode[27]=7'd62; g_ode[28]=7'd60; g_ode[29]=7'd60;
    end

    //======================================================================
    //  指导：按对当前音才前进，灯带指出"当前该按"和"再下一个"
    //======================================================================
    reg [5:0] guide_step;

    wire       use_ode       = (mode == MD_ODE);
    wire       in_guide      = (mode != MD_FREE);
    wire [5:0] guide_len     = use_ode ? 6'd30 : 6'd42;
    wire [5:0] guide_step_p  = guide_step + 6'd1;
    wire [5:0] guide_step_nx = (guide_step_p >= guide_len) ? 6'd0 : guide_step_p;

    wire [6:0] guide_note  = use_ode ? g_ode[guide_step]     : g_twinkle[guide_step];
    wire [6:0] guide_note2 = use_ode ? g_ode[guide_step_nx]  : g_twinkle[guide_step_nx];

    // MIDI 音号 → 键序号（C4 D4 E4 F4 G4 A4 B4 = 60 62 64 65 67 69 71）
    function [2:0] note2key;
        input [6:0] n;
        begin
            case (n)
                7'd60:   note2key = 3'd0;   // do
                7'd62:   note2key = 3'd1;   // re
                7'd64:   note2key = 3'd2;   // mi
                7'd65:   note2key = 3'd3;   // fa
                7'd67:   note2key = 3'd4;   // sol
                7'd69:   note2key = 3'd5;   // la
                7'd71:   note2key = 3'd6;   // si
                default: note2key = 3'd0;
            endcase
        end
    endfunction

    wire [2:0] guide_key  = note2key(guide_note);    // 当前该按（亮）
    wire [2:0] guide_key2 = note2key(guide_note2);   // 再下一个音（暗预告）

    // ★ 必须用"模式发生变化"判断，不能用"进入指导态"：
    //   模式2→3 都是指导态，用进入态判断会导致 step 不归零（原工程踩过）
    reg [1:0] mode_d;
    always @(posedge clk_sys) mode_d <= mode;
    wire enter_guide = in_guide && (mode != mode_d);

    always @(posedge clk_sys) begin
        if (!engine_rst_n)                    guide_step <= 6'd0;
        else if (enter_guide)                 guide_step <= 6'd0;
        else if (in_guide && note_key_press[guide_key])
            guide_step <= guide_step_nx;
    end

    //======================================================================
    //  复音分配：8 键 → 8 声部（C4..C5 一个八度）
    //======================================================================
    wire [NVOICE*7-1:0] k_note;
    wire [NVOICE-1:0]   v_trig, v_gate, v_idle;
    wire [NVOICE*8-1:0] v_vel;

    // ★★ 诊断：记录最近一次 note-on 的力度，并转成条形图（3 位 → 0..7 颗灯）
    //    vel 254 → 7 颗全亮；vel 128 → 4 颗；vel 32 → 1 颗；vel 2 → 0 颗
    //    按一下键就能看出实际力度落在哪一档
    reg [7:0] dbg_vel;
    integer   di;
    always @(posedge clk_sys) begin
        for (di = 0; di < NVOICE; di = di + 1)
            if (v_trig[di]) dbg_vel <= v_vel[di*8 +: 8];
    end
    wire [7:0] vel_bar = (8'd1 << dbg_vel[7:5]) - 8'd1;

    //======================================================================
    //  ★ 每个乐器独立的按键映射（键名位置固定，但音高与可用键不同）
    //
    //     键号：  1    2    3    4     5    6    7    8
    //     键名： do   re   mi   fa    sol  la   si   do'
    //
    //     钢琴（C 大调七声）：
    //       step   0    2    4    5     7    9    11   12   → C4 D4 E4 F4 G4 A4 B4 C5
    //       enable 8 键全开
    //
    //     古筝（D 宫五声，宫商角徵羽）：
    //       step   0    2    4    F     7    9    F    12   → D4 E4 F#4 -- A4 B4 -- D5
    //       enable 键 4(fa)、键 7(si) 屏蔽 —— 五声音阶里没有这两个音
    //       所以古筝实际发声键 = 1,2,3,5,6,8（6 个）
    //======================================================================
    //   唢呐：A4(69) 起，七声，8 键全开，移调 0 / +12
    //         （音域只有 28 半音，五声会一档移调都做不了）
    wire [6:0]  t_note_base = is_suona ? 7'd69 :
                              is_gz    ? 7'd62 : 7'd60;   // 唢呐 A4 / 古筝 D4 / 钢琴 C4

    // ★ 4'hF = 无效步长哨兵（该键在本乐器音阶里不存在）
    wire [31:0] t_key_step  = is_gz
        ? {4'd12, 4'hF, 4'd9, 4'd7, 4'hF, 4'd4, 4'd2, 4'd0}   // 古筝 D 宫五声
        : {4'd12, 4'd11, 4'd9, 4'd7, 4'd5, 4'd4, 4'd2, 4'd0}; // 钢琴/唢呐 七声

    // 键 4、键 7 在古筝下不发声（bit3 = 键4，bit6 = 键7）
    wire [7:0]  t_key_en  = is_gz ? 8'b1011_0111 : 8'b1111_1111;  // 唢呐 8 键全开

    note_alloc #(
        .NKEY     (8),
        .NVOICE   (NVOICE)
    ) u_alloc (
        .clk      (clk_sys),
        .rst_n    (engine_rst_n),

        .key_state(note_key_state),
        .key_enable(t_key_en),
        .note_base (t_note_base),
        .key_step  (t_key_step),
        .key_vel  (note_key_vel),
        .transpose(transpose),
        .v_idle   (v_idle),
        .v_note   (k_note),
        .v_trig   (v_trig),
        .v_gate   (v_gate),
        .v_vel    (v_vel)
    );

    //======================================================================
    //  ★★ 上电自检：每 2 s 自动弹一次 C4（响 0.5 s），完全不依赖键盘
    //     目的：一次定位故障到底在「引擎/音频链路」还是「键盘接线」
    //       · 听得见周期性 C4  → 引擎和 I2S 正常，问题在键盘
    //       · 完全听不见        → 引擎或音频链路出问题
    //     调试完把它改回 0
    //======================================================================
    localparam integer AUTO_TEST = 0;

    localparam [26:0] AT_PERIOD = 27'd99_999_999;   // 2 s @50MHz
    localparam [26:0] AT_TRIG   = 27'd24_999_999;   // 0.5 s 处触发
    localparam [26:0] AT_OFF    = 27'd74_999_999;   // 1.5 s 处松键（响 1 s）

    reg [26:0] aut_t;
    always @(posedge clk_sys) begin
        if (!engine_rst_n)                 aut_t <= 27'd0;
        else if (aut_t == AT_PERIOD)       aut_t <= 27'd0;
        else                               aut_t <= aut_t + 27'd1;
    end

    wire aut_trig = AUTO_TEST && (aut_t == AT_TRIG);
    wire aut_gate = AUTO_TEST && (aut_t >= AT_TRIG) && (aut_t < AT_OFF);
    wire aut_any  = aut_trig || aut_gate;

    wire [NVOICE*7-1:0] eng_note = aut_any ? {NVOICE{7'd60}} : k_note;
    wire [NVOICE-1:0]   eng_trig = aut_trig ? {{(NVOICE-1){1'b0}}, 1'b1} : v_trig;
    wire [NVOICE-1:0]   eng_gate = aut_gate ? {{(NVOICE-1){1'b0}}, 1'b1} : v_gate;

    //======================================================================
    //  加法合成引擎：128 分量/声部，8 声部共用一份参数 ROM
    //    ★ 与旧版（64 分量 × 16 级流水线）的区别见 src/add_voice8.v 文件头
    //      实测：关键路径 15.1 ns → 9.3 ns，共用 ROM 让 pROM 92 块 → 29 块
    //======================================================================
    //  音色选择（改这一个常量即可切换，参数表需同步放进工程根目录）
    //    0 = 钢琴：88 音 × 128 分量 = 11264 深 → add_param0/1/2.hex
    //    1 = 古筝：49 音 × 128 分量 =  6272 深 → gz_param0/1/2.hex
    localparam integer TIMBRE_SEL  = 0;
    localparam integer T_ROM_AW    = (TIMBRE_SEL == 1) ? 13 : 14;
    localparam integer T_ROM_DEPTH = (TIMBRE_SEL == 1) ? 6272 : 11264;
    localparam integer T_NOTE_LO   = (TIMBRE_SEL == 1) ? 38 : 21;
    localparam integer T_NOTE_HI   = (TIMBRE_SEL == 1) ? 86 : 108;

    wire               tick;
    wire signed [15:0] eng_l, eng_r;

    add_engine8 #(
        .NVOICE   (NVOICE),
        .NPART    (128),
        .ROM_AW   (T_ROM_AW),
        .ROM_DEPTH(T_ROM_DEPTH),
        .NOTE_LO  (T_NOTE_LO),
        .NOTE_HI  (T_NOTE_HI),
        .ATK      (0),
        .MIX_SHIFT(MIX_SHIFT),
        // ── 参数源改为 DDR3（第 3 步）──────────────────────────────
        //   取值必须与 tools/make_ddr_image.py 生成的文件头一致：
        //     piano_base = 1，gz_base = 5633，每音 64 个 256 位字
        .USE_DDR    (1),
        .PIANO_BASE (1),
        .GZ_BASE    (5633),
        .WORDS_NOTE (64),
        .ADDR_SHIFT (3)
    ) u_piano (
        .clk        (clk_sys),
        .rst_n      (engine_rst_n),
        .timbre     (timbre_r[0]),       // ★ modal 引擎：0=钢琴 1=古筝（唢呐时无效）
        .v_note     (eng_note),
        .v_trig     (eng_trig),
        .v_gate     (eng_gate),
        .v_vel      (v_vel),
        .sample_tick(tick),
        .sample_l   (eng_l),
        .sample_r   (eng_r),
        .v_idle     (v_idle),

        // DDR 取表口（clk_x1 域）
        .clk100              (ddr_clk_x1),
        .rst100_n            (ddr_init_done),
        .app_cmd             (eng_app_cmd),
        .app_en              (eng_app_en),
        .app_addr            (eng_app_addr),
        .app_rdy             (ddr_app_rdy),
        .app_rd_data_valid   (ddr_rd_valid),
        .app_rd_data         (ddr_rd_data)
    );

    //======================================================================
    //  唢呐引擎（单声部谐波合成，表按音从 DDR 预取）
    //    · 单声部：任意声部触发都映射到它的 0 号声部，音高用同拍组合 mux
    //    · 表在 DDR，note-on 时 suona_dma 搬 21 KB 到 BSRAM（约 200 us）
    //======================================================================
    wire signed [15:0] sua_l, sua_r;
    wire [3:0]         sua_v_idle;
    wire [2:0]         sua_app_cmd;
    wire               sua_app_en;
    wire [28:0]        sua_app_addr;

    wire sua_trig = |v_trig;
    wire sua_gate = |v_gate;

    reg  [6:0] sua_note;
    integer si;
    always @(*) begin
        sua_note = 7'd69;
        for (si = 0; si < NVOICE; si = si + 1)
            if (v_trig[si]) sua_note = eng_note[si*7 +: 7];
    end

    // ★ 引擎内部多处写死 4 声部（rot[2]、k_nz[2] 等），所以保持 NVOICE=4，
    //   只用 0 号声部：v_trig 只有 bit0 会动，其余声部永不激活。
    //   表缓冲是【共享的一份】，所以多留 3 个空声部不额外占 BSRAM。
    add_engine_harm #(
        .NVOICE    (4),
        .NOTE_LO   (69),        // 唢呐表 A4..C7
        .NOTE_HI   (96),
        .TIMBRE    (3),
        .MIX_SHIFT (0),
        .SOFT      (1)
    ) u_harm (
        .clk        (clk_sys),
        .rst_n      (engine_rst_n),
        .v_note     ({21'd0, sua_note}),
        .v_trig     ({3'b000, sua_trig}),
        .v_gate     ({3'b000, sua_gate}),
        .v_vel      ({{24{1'b0}}, v_vel[7:0]}),
        .sample_tick(tick),
        .sample_l   (sua_l),
        .sample_r   (sua_r),
        .v_idle     (sua_v_idle),

        .clk100              (ddr_clk_x1),
        .rst100_n            (ddr_init_done),
        .app_cmd             (sua_app_cmd),
        .app_en              (sua_app_en),
        .app_addr            (sua_app_addr),
        .app_rdy             (ddr_app_rdy),
        .app_rd_data_valid   (ddr_rd_valid),
        .app_rd_data         (ddr_rd_data)
    );

    wire is_suona = (timbre_r == 2'd2);

    // ★ 必须打一拍再送进 sat_gain：
    //   直接组合 mux 会把 u_piano/u_mix → u_tx/din 的路径拉长，
    //   实测 SETUP -0.853 ns（CLK_SYS 唯一违例）。
    //   音频流每样点一次，加一拍延迟完全无影响。
    reg signed [15:0] mix_l_r, mix_r_r;
    always @(posedge clk_sys) begin
        mix_l_r <= is_suona ? sua_l : eng_l;
        mix_r_r <= is_suona ? sua_r : eng_r;
    end

    //======================================================================
    //  输出增益 ×8
    //
    //  实测（修完 add_voice8 两个 bug 后，用浮点模型扫全音域 + iverilog 复算）：
    //      sample_l（引擎输出，已含 MIX_SHIFT=1 的 ÷2）单音峰值
    //        钢琴 最大 817（MIDI 38）/ 中位 615     古筝 最大 324 / 中位 198
    //      4 声部实测峰值（38/60/72/84） = 1766，0 个削顶样点
    //
    //  sat_gain 取 2 的幂，按【最坏同相】4 声部定：
    //      单声部 raw 峰值 V = 817×2 = 1634
    //      最坏同相：Σ=4V=6536 → mix_sum 的 >>1 → 3268 → ×8 = 26144 = −2.0 dBFS ✓
    //      实测典型 4 声部：1766×8 = 14128 = −7.3 dBFS
    //      单音：817×8 = 6536 = −14.0 dBFS
    //
    //  ★ 原来 ×4：最坏同相只有 13072 = −8.0 dBFS，白白浪费 8 dB 动态范围；
    //    ×16 会到 +4.1 dBFS 削顶，所以 ×8 是能取的最大 2 的幂。
    //  ★ 更早的 ×8 + 旧表会削顶，是因为旧表峰值更高且当时 sat_gain 前面
    //    没有 mix_sum 的 ÷2；现在两处定标重新算过，×8 是安全的。
    //======================================================================
    //======================================================================
    //  输出增益 + ★软限幅（治"多音破音"）
    //    钢琴 ×8 ：单音峰值约 5240 → 原样通过（响度不变）
    //    古筝 ×16：同理
    //    8 个音同时响：峰值约 40000 > 32767 → 硬钳位会削顶破音，
    //                  改成二次肩软压缩，平滑压到 ~32192，不削顶
    //
    //    膝点 24000，超过后 d = ax-KNEE（钳在 16384），
    //        y = 24000 + d − d²/32768
    //    d=16384 时 y = 24000+16384−8192 = 32192（最大值，永不超 32767）
    //======================================================================
    function signed [15:0] sat_gain;
        input signed [15:0] x;
        input [1:0]         tb;       // 0=钢琴 1=古筝 2=唢呐
        reg   signed [31:0] y, ax, d, yy;
        begin
            y = (tb == 2'd2) ? (x <<< 3) :      // 唢呐
                tb          ? (x <<< 4) :       // 古筝 ×16
                              (x <<< 3);        // 钢琴 ×8
            ax = (y < 0) ? -y : y;
            if (ax <= 32'sd24000) begin
                yy = ax;                        // 直通区
            end
            else begin
                d = ax - 32'sd24000;
                if (d > 32'sd16384) d = 32'sd16384;
                yy = 32'sd24000 + d - ((d * d) >>> 15);
            end
            if (yy > 32'sd32767) yy = 32'sd32767;
            sat_gain = y[31] ? -yy[15:0] : yy[15:0];
        end
    endfunction

    //======================================================================
    //  灯带控制信号跨时钟域同步：clk_sys → CLOCK_50
    //
    //  u_led 必须用 CLOCK_50 直连（上板验证过的配置，不走 PLL），
    //  但它的全部控制信号都产生于 clk_sys 域（mode / key_state /
    //  guide_key / engine_rst_n）。直接跨域会让 PnR 报出 22 条 hold
    //  违例（−0.726 ns）：CLK_SYS 与 CLOCK_50 虽然同为 50 MHz，却分布在
    //  不同时钟树分支（PBR1/2 与 PBR2/3），实测偏斜约 0.7 ns，数据会跑赢
    //  捕获时钟。
    //
    //  这些信号全部是「按键级」慢变量（去抖后 >10 ms 才变一次），
    //  打两拍同步即可，对视觉效果无任何影响。
    //  时序约束侧对应 piano64.sdc 里的
    //      set_false_path -from [get_clocks CLK_SYS] -to [get_clocks CLOCK_50]
    //  （标准 CDC 处理：同步器隔离后不再对跨域路径做时序检查）
    //======================================================================
    reg [2:0] led_mode_s0,  led_mode_s1;
    reg [7:0] led_key_s0,   led_key_s1;
    // ★★ 配对诊断：同步 KEY_R1 / KEY_R2 的原始电平
    //    灯带只点亮【两个触点都闭合】的位置。
    //      · 按下一个键，对应灯亮 → 配对正确
    //      · 按下去灯不亮      → 配对错误（对应的两个开关不在同一个琴键上）
    reg [7:0] rawk1_s0, rawk1_s1, rawk2_s0, rawk2_s1;
    reg [7:0] velbar_s0, velbar_s1;

    // ★★★ SD→DDR 加载阶段诊断（2026-10-31）
    //   ld_stage 产生在 clk_x1(100 MHz) 域，阶段变化是「毫秒级慢变量」，
    //   打到 CLOCK_50 域只需两拍同步。
    //   灯带亮【几颗】= 加载器走到第几步（0 = 还在横幅/等校准）：
    //      1 颗 = S_READ  （正在收字节写 DDR）
    //      2 颗 = S_FLUSH （收尾）
    //      3 颗 = S_V_RD  （DDR 读回校验）
    //      4 颗 = S_REPORT
    //      5 颗 = S_SEND  （正在吐串口）
    //      6 颗 = S_STAY  （全部结束，结果看串口）
    //   ⚠ 这期间按键灯不显示力度，是临时诊断配置，定位完就改回来。
    localparam integer LED_DIAG = 1;
    wire [3:0] ld_stage;          // 加载器阶段（clk_x1 域，声明前置给灯带用）
    reg [3:0] ld_stage_s0, ld_stage_s1;
    wire [7:0] stage_bar = (ld_stage_s1 >= 4'd7) ? 8'h7F
                         : (ld_stage_s1 == 4'd0) ? 8'h00
                         : ((8'd1 << ld_stage_s1[2:0]) - 8'd1);

    always @(posedge CLOCK_50) begin
        rawk1_s0 <= KEY_R1[7:0];
        rawk2_s0 <= KEY_R2[7:0];
        velbar_s0 <= vel_bar;
        ld_stage_s0 <= ld_stage;
        rawk1_s1 <= rawk1_s0;
        rawk2_s1 <= rawk2_s0;
        velbar_s1 <= velbar_s0;
        ld_stage_s1 <= ld_stage_s0;
    end

    wire [7:0] pair_ok = ~(rawk1_s1 & rawk2_s1);   // 低电平 = 闭合
    reg [2:0] led_gk_s0,    led_gk_s1;
    reg [2:0] led_gk2_s0,   led_gk2_s1;
    reg       led_rst_s0,   led_rst_s1;
    reg [1:0] led_timbre_s0, led_timbre_s1;

    always @(posedge CLOCK_50) begin
        led_mode_s0 <= {1'b0, mode};
        led_key_s0  <= LED_DIAG ? stage_bar : velbar_s1;   // ★ 诊断：加载阶段条形图
        led_gk_s0   <= guide_key;
        led_gk2_s0  <= guide_key2;
        led_rst_s0  <= engine_rst_n;
        led_timbre_s0 <= timbre_r;
        led_mode_s1 <= led_mode_s0;
        led_key_s1  <= led_key_s0;
        led_gk_s1   <= led_gk_s0;
        led_gk2_s1  <= led_gk2_s0;
        led_rst_s1  <= led_rst_s0;
        led_timbre_s1 <= led_timbre_s0;
    end

    //======================================================================
    //  灯带（布局与原工程一致）
    //======================================================================
    // ★★★ 灯带前 6 颗（索引 0~5）是坏灯（实测：第 6 颗往后完全正常）
    //     所以所有指示灯整体后移到索引 6 开始，前 6 颗永远发 0（保持黑）
    //       索引 5~10   = 6 个按键灯（KEY[5]→5 … KEY[0]→10）第 6~11 颗
    //       索引 11     = 乐器灯（白 = 钢琴）        第 12 颗
    //       索引 12     = 模式灯（红/绿/蓝）          第 13 颗
    ws2812_keyind #(
        .N_LED       (20),
        .LED_BASE    (13),          // KEY[0] → 索引 13（KEY[7] → 索引 6）
        .NKEY        (8),
        .BRIGHT_SHIFT(2),
        .TIMBRE_LED  (14),          // 乐器灯：索引 14
        .MODE_LED    (15),          // 模式灯：索引 15
        .DOT_EN      (0),
        .DIAG        (0)
    ) u_led (
        // ★★ 灯带时钟用【CLOCK_50 直连】，和验证正常的 led_align 工程完全一致
        //    （PLL 输出 clk_sys 虽然频率相同，但相位/抖动不同，怀疑是卡死的原因）
        //    所有输入都经过上面的两拍同步，不再直接跨域
        .clk       (CLOCK_50),
        .rst_n     (led_rst_s1),
        .key_state (led_key_s1),
        .mode      (led_mode_s1),
        .guide_key (led_gk_s1),
        .guide_key2(led_gk2_s1),
        .timbre    (led_timbre_s1),  // 白=钢琴 青=古筝（经两拍同步）
        .oct       (3'sd0),         // 本工程无八度，八度条已删
        .dout      (DOUT)
    );

    //======================================================================
    //  I2S
    //======================================================================
    pcm5102a_tx #(.DIV(16), .SLOTS(64)) u_tx (
        .clk        (clk_sys),
        .rst_n      (por_n),
        .sample_l   (sat_gain(mix_l_r, timbre_r)),
        .sample_r   (sat_gain(mix_r_r, timbre_r)),
        .sample_tick(tick),
        .bck        (AUD_BCK),
        .lrck       (AUD_LRCK),
        .din        (AUD_DIN)
    );

    //======================================================================
    //  DDR3 1 GiB —— 第 2 步：SD 卡 P64.BIN → DDR3（含读回校验）
    //    用户接口在 clk_x1(100MHz) 域；sd_ddr_loader 也整块跑在 clk_x1，
    //    所以 SD 读字节 / 拼 256 位字 / 写 DDR / 读回校验 全程同域，无 CDC。
    //======================================================================
    wire        ddr_init_done;
    wire        ddr_pll_locked;
    wire        ddr_clk_x1;
    wire [2:0]  ddr_app_cmd;
    wire        ddr_app_en;
    wire [28:0] ddr_app_addr;
    wire [255:0] ddr_app_wdf_data;
    wire        ddr_app_wdf_wren;
    wire        ddr_app_wdf_end;
    wire [31:0] ddr_app_wdf_mask;
    wire        ddr_app_burst;
    wire        ddr_app_rdy;
    wire        ddr_wr_data_rdy;
    wire        ddr_rd_valid;
    wire [255:0] ddr_rd_data;

    ddr_wrap u_ddr (
        .clk        (CLOCK_50),
        .rst_n      (por_n & RESET_n),
        .init_done  (ddr_init_done),
        .clk_x1     (ddr_clk_x1),
        .pll_locked (ddr_pll_locked),

        .app_cmd        (ddr_app_cmd),
        .app_en         (ddr_app_en),
        .app_addr       (ddr_app_addr),
        .app_wdf_data   (ddr_app_wdf_data),
        .app_wdf_wren   (ddr_app_wdf_wren),
        .app_wdf_end    (ddr_app_wdf_end),
        .app_wdf_mask   (ddr_app_wdf_mask),
        .app_burst      (ddr_app_burst),
        .app_rdy        (ddr_app_rdy),
        .wr_data_rdy    (ddr_wr_data_rdy),
        .app_rd_data_valid (ddr_rd_valid),
        .app_rd_data    (ddr_rd_data),

        .ddr_addr   (ddr_addr),
        .ddr_bank   (ddr_bank),
        .ddr_cs     (ddr_cs),
        .ddr_ras    (ddr_ras),
        .ddr_cas    (ddr_cas),
        .ddr_we     (ddr_we),
        .ddr_ck     (ddr_ck),
        .ddr_ck_n   (ddr_ck_n),
        .ddr_cke    (ddr_cke),
        .ddr_odt    (ddr_odt),
        .ddr_reset_n(ddr_reset_n),
        .ddr_dm     (ddr_dm),
        .ddr_dq     (ddr_dq),
        .ddr_dqs    (ddr_dqs),
        .ddr_dqs_n  (ddr_dqs_n)
    );

    //----------------------------------------------------------------------
    //  SD → DDR 加载器（clk_x1 = 100 MHz 域）
    //----------------------------------------------------------------------
    wire        ld_done, ld_ok;
    wire [31:0] ld_nbytes, ld_nwords, ld_ov;
    wire [11:0] ld_nfiles, ld_fileno;

    // 加载器独占的 DDR 口（写通道 + 命令通道）
    wire [2:0]   ld_app_cmd;
    wire         ld_app_en;
    wire [28:0]  ld_app_addr;
    wire [255:0] ld_app_wdf_data;
    wire         ld_app_wdf_wren;
    wire         ld_app_wdf_end;
    wire [31:0]  ld_app_wdf_mask;

    // 引擎（add_engine8）的 DDR 口：只有读通道
    wire [2:0]   eng_app_cmd;
    wire         eng_app_en;
    wire [28:0]  eng_app_addr;

    sd_ddr_loader #(
        .CLK50_HZ (50_000_000),
        .CLK100_HZ(100_000_000),
        .BOOT_MS  (300)
    ) u_ld (
        // ★ 双时钟：SD/FAT 栈跑 50 MHz（组合乘法在 100 MHz 下 −6.2 ns 违例），
        //   拼字/写 DDR/读回校验跑 clk_x1（DDR MC 用户域），中间 sd_async_fifo
        .clk50       (CLOCK_50),
        .clk100      (ddr_clk_x1),
        .arst_n      (por_n & RESET_n),
        .calib_done  (ddr_init_done),
        .dbg_pll     (ddr_pll_locked),
        .dbg_por_n   (por_n),
        .dbg_reset_n (RESET_n),

        .sd_clk      (SD_CLK),
        .sd_cmd      (SD_CMD),
        .sd_dat0     (SD_DAT0),

        .app_cmd        (ld_app_cmd),
        .app_en         (ld_app_en),
        .app_addr       (ld_app_addr),
        .app_wdf_data   (ld_app_wdf_data),
        .app_wdf_wren   (ld_app_wdf_wren),
        .app_wdf_end    (ld_app_wdf_end),
        .app_wdf_mask   (ld_app_wdf_mask),
        .app_burst      (),
        .app_rdy        (ddr_app_rdy),
        .wr_data_rdy    (ddr_wr_data_rdy),
        .app_rd_data_valid (ddr_rd_valid),
        .app_rd_data    (ddr_rd_data),

        .load_done   (ld_done),
        .load_ok     (ld_ok),
        .stage       (ld_stage),
        .nbytes      (ld_nbytes),
        .nwords      (ld_nwords),
        .err_ov      (ld_ov),
        .nfiles      (ld_nfiles),
        .file_no     (ld_fileno),

        .uart_txd    (UART_TX)
    );

    //======================================================================
    //  DDR 用户口仲裁
    //    加载器只在开机时跑一次，跑完就永久空闲；引擎的取表 DMA 只在
    //    note-on 时短时占用。所以直接用 ld_done 二选一即可，无需真仲裁器。
    //    写数据通道只有加载器使用，直接接过去（引擎只读）。
    //======================================================================
    // 三路互斥：加载期间给 loader；加载后按音色给钢琴(含古筝)或唢呐
    wire ddr_arb_piano = ld_done && !is_suona;
    wire ddr_arb_suona = ld_done &&  is_suona;

    assign ddr_app_cmd      = ddr_arb_suona ? sua_app_cmd  :
                              ddr_arb_piano ? eng_app_cmd  : ld_app_cmd;
    assign ddr_app_en       = ddr_arb_suona ? sua_app_en   :
                              ddr_arb_piano ? eng_app_en   : ld_app_en;
    assign ddr_app_addr     = ddr_arb_suona ? sua_app_addr :
                              ddr_arb_piano ? eng_app_addr : ld_app_addr;
    assign ddr_app_wdf_data = ld_app_wdf_data;
    assign ddr_app_wdf_wren = ld_app_wdf_wren;
    assign ddr_app_wdf_end  = ld_app_wdf_end;
    assign ddr_app_wdf_mask = ld_app_wdf_mask;
    assign ddr_app_burst    = 1'b0;

endmodule

`default_nettype wire
