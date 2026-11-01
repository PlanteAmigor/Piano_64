//==========================================================================
//  piano64 —— 64 路加法分量钢琴（8 音键 + 移调键 + 2 个功能键）
//
//  按键：
//    · J13 双触点力度键盘 9 组：组 0~7 = 8 个音键，组 8 = 移调键
//    · KEY_AUX[0] (U38/C18) = 音色键，短按循环 钢琴→古筝→唢呐→笛子
//    · KEY_AUX[1] (U37/C19) = 效果器键（暂未接音频，仅状态）
//    · KEY0 (AA13)          = 三模式循环（主页面/测试/教学）
//
//  已删除：J14 六个独立键、两首内置曲谱、指导模式、波形显示
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
    // ── 18 键力度键盘（J13，2026-10-30 接入）────────────────────
    //    两排一前一后配对成 9 组，组 0..7 = 8 音键，组 8 = 切音高
    //    ★ RTL 尚未接入，先声明端口让 cst 能通过综合
    input  wire [8:0] KEY_R1,     // 第 1 排（PCB 上排）D14 D15 A18 A19 D17 C17 C20 F15 F19
    input  wire [8:0] KEY_R2,     // 第 2 排（PCB 下排）F16 E17 F13 F14 E16 D16 E19 D19 D20
    input  wire [1:0] KEY_AUX,    // 上方两个独立键 C18 C19
    input  wire       KEY0,       // 板上 KEY.0 (AA13) → 测试模式开关
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
    inout  wire [3:0]  ddr_dqs_n,

    // ── 32 段常数-Q 频谱（给 HDMI 渲染器用，不在本工程里画）──────────
    //    BANDS 是 clk_sys 域寄存器，两次 bands_tick 之间保持不变；
    //    BANDS_TICK 是 clk_sys 域单拍脉冲（20 ns 宽）。
    //    显示侧 cross-domain 时只需「tick 高电平期间抓一次」即可，
    //    因为数据窗口有几十毫秒那么宽，不存在采样竞态。
    output wire [32*8-1:0] SPEC_BANDS,
    output wire            SPEC_TICK,

    // ── UI 状态总线（给 HDMI 渲染器画状态栏/信息框）─────────────────
    //    [1:0]   ui_mode   0=主页面 1=测试 2=教学
    //    [3:2]   timbre    0=钢琴 1=古筝 2=唢呐 3=笛子
    //    [5:4]   fx        0=NONE 1=REVERB 2=DELAY 3=CHORUS
    //    [15:8]  transpose 有符号半音数（-24..+12）
    //    全部是「按键级」慢变量（去抖后 >10 ms 才变），渲染侧打两拍同步即可。
    output wire [15:0] UI_INFO,

    // ── 「COMPONENT 64」柱图（最近触发声部的 64 根分量柱）─────────────
    //    每根 = 8 位幅度（0..255）。128 个正弦分量两两合并取大值 →
    //    64 根，宽度正好适合 1024 px 的绘图区。
    output wire [64*8-1:0] COMP_AMP
);

    localparam integer NVOICE    = 8;      // ★ 4 → 8：只改这个参数（PH_SHIFT = 8/8 = 1 仍成立）
    localparam integer MIX_SHIFT = 1;

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
    //  板上 KEY.0（AA13）→ 三模式页面循环
    //
    //  赛题「现场验证要求」要一个测试模式：输出 8 路不同频率的纯正弦，
    //  频谱上能数出对应数量的独立谱峰。
    //
    //    每按一次：主页面(0) → 测试(1) → 教学(2) → 主页面(0)
    //    上电默认主页面。音源切换和页面切换是同一个 mode，同步发生。
    //
    //  去抖 20 ms。它不参与演奏计时，不需要 key_dual 那套双触点精度。
    //  板上三个用户键都是「悬空=1、按下=0」，必须开内部上拉。
    //======================================================================
    reg  [1:0] k0_sync;
    always @(posedge clk_sys) k0_sync <= {k0_sync[0], KEY0};

    reg [19:0] k0_cnt;
    reg        k0_stable, k0_stable_d;
    always @(posedge clk_sys) begin
        if (!por_n) begin
            k0_cnt      <= 20'd0;
            k0_stable   <= 1'b1;
            k0_stable_d <= 1'b1;
        end
        else begin
            k0_stable_d <= k0_stable;
            if (k0_sync[1] != k0_stable) begin
                if (k0_cnt == 20'd999_999) begin
                    k0_cnt    <= 20'd0;
                    k0_stable <= k0_sync[1];
                end
                else k0_cnt <= k0_cnt + 20'd1;
            end
            else k0_cnt <= 20'd0;
        end
    end
    wire k0_press = k0_stable_d & ~k0_stable;      // 按下沿（低有效）

    localparam [1:0] MODE_MAIN  = 2'd0,
                     MODE_TEST  = 2'd1,
                     MODE_GUIDE = 2'd2;

    reg [1:0] ui_mode;
    always @(posedge clk_sys) begin
        if (!por_n)        ui_mode <= MODE_MAIN;
        else if (k0_press) ui_mode <= (ui_mode == MODE_GUIDE) ? MODE_MAIN
                                                             : (ui_mode + 2'd1);
    end

    wire test_mode = (ui_mode == MODE_TEST);

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

    // 音色键：上方独立键 KEY_AUX[0]（U38 / C18）
    // ★ 短按松开一次切一种音色：钢琴 → 古筝 → 唢呐 → 笛子
    //   （原「长按切音色 / 短按切模式」已废弃，模式由 KEY0 统一管理）
    wire       timbre_toggle = aux_release[0];

    //======================================================================
    //  音色：0 = 钢琴（白灯）  1 = 古筝（青灯）
    //======================================================================
    //  0 = 钢琴（白灯）  1 = 古筝（青灯）  2 = 唄呐（橙灯）  3 = 笛子（紫灯）
    reg [1:0] timbre_r;

    always @(posedge clk_sys) begin
        if (!engine_rst_n)          timbre_r <= 2'd0;
        else if (timbre_toggle)     timbre_r <= (timbre_r == 2'd3) ? 2'd0 : timbre_r + 2'd1;
    end

    //======================================================================
    //  效果器档位：上方独立键 KEY_AUX[1]（U37 / C19）短按循环
    //    0=NONE 1=REVERB 2=DELAY 3=CHORUS
    //  ★ 目前只有 UI 显示，音频通路还没实现（Step4 之后再做）
    //======================================================================
    reg [1:0] fx_r;

    always @(posedge clk_sys) begin
        if (!engine_rst_n)                       fx_r <= 2'd0;
        else if (aux_release[1])                 fx_r <= (fx_r == 2'd3) ? 2'd0 : fx_r + 2'd1;
    end

    // ★ 古筝判定必须写【== 1】，不能再用 timbre_r[0]
    //   ！3（笛子）的 bit0 也是 1，用 timbre_r[0] 会把笛子当成古筝
    //   （按键映射、移调范围、modal 引擎选择全错）。
    wire is_gz = (timbre_r == 2'd1);
    // ★ 唄呐 / 笛子共用谐波引擎，只是表和音域不同
    wire is_suona = (timbre_r == 2'd2);
    wire is_dizi  = (timbre_r == 2'd3);
    // ★ 谐波类乐器（唄呐或笛子）：共用同一个 add_engine_harm 实例
    wire is_harm  = is_suona | is_dizi;

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
    //   笛子：8 键 67..79，表 67..91 → 0 .. +12（同上）
    wire signed [7:0] tr_min = is_harm  ?  8'sd0  :
                               is_gz    ? -8'sd24 : -8'sd36;
    wire signed [7:0] tr_max = is_harm  ?  8'sd12 :
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
    //   笛子：G4(67) 起，G 大调七声（G A B C D E F# G），8 键全开，移调 0 / +12
    //         音阶步长与钢琴/唄呐完全相同 {0,2,4,5,7,9,11,12}，
    //         只是 note_base 换成 67，所以下面 t_key_step 不用改
    wire [6:0]  t_note_base = is_suona ? 7'd69 :
                              is_dizi  ? 7'd67 :
                              is_gz    ? 7'd62 : 7'd60;   // 唄呐 A4 / 笛子 G4 / 古筝 D4 / 钢琴 C4

    // ★ 4'hF = 无效步长哨兵（该键在本乐器音阶里不存在）
    wire [31:0] t_key_step  = is_gz
        ? {4'd12, 4'hF, 4'd9, 4'd7, 4'hF, 4'd4, 4'd2, 4'd0}   // 古筝 D 宫五声
        : {4'd12, 4'd11, 4'd9, 4'd7, 4'd5, 4'd4, 4'd2, 4'd0}; // 钢琴/唢呐 七声

    // 键 4、键 7 在古筝下不发声（bit3 = 键4，bit6 = 键7）
    wire [7:0]  t_key_en  = is_gz ? 8'b1011_0111 : 8'b1111_1111;  // 唄呐/笛子 8 键全开

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

    // 分量幅度监控（来自「最近一次 note-on 的那个声部」）
    wire [6:0] comp_idx;
    wire [7:0] comp_amp;
    wire       comp_vld;

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
        .timbre     (is_gz),             // ★ modal 引擎：1=古筝 0=钢琴（唄呐/笛子时无效）
        .v_note     (eng_note),
        .v_trig     (eng_trig),
        .v_gate     (eng_gate),
        .v_vel      (v_vel),
        .sample_tick(tick),
        .sample_l   (eng_l),
        .sample_r   (eng_r),
        .v_idle     (v_idle),
        .comp_idx   (comp_idx),
        .comp_amp   (comp_amp),
        .comp_vld   (comp_vld),

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
    //  谐波引擎（唢呐 / 笛子共用，单声部）
    //    · 单声部：任意声部触发都映射到它的 0 号声部，音高用同拍组合 mux
    //    · 表在 DDR，note-on 时 suona_dma 搬十几 KB 到 BSRAM（约 200 us）
    //    · ★ 两个乐器【共用一个实例】：只改 4 个输入
    //        note_lo / note_hi  ：音域（唢呐 69..96 / 笛子 67..91）
    //        inf_base           ：info 表字偏移（0 / 112）
    //        desc_base          ：描述符 app 地址基址（已扣掉 note_lo*16）
    //      省下约 50 块 BSRAM，也省一条 DDR 仲裁。
    //======================================================================
    //  镜像里的段基址（由 tools/make_ddr_image.py 打印）
    localparam integer SUONA_BASE_W = 8769;
    localparam integer DIZI_BASE_W  = 22176;
    localparam integer DESC_OFF_W   = 2;

    // desc_base = ((BASE+DESC_OFF) << 3) - note_lo*16
    //   <<3       ：word = 32 字节 = 8 个 4 字节单位（app_addr 的单位）
    //   note_lo*16：把绝对音号归一到段内序号（每音描述符 64 B = 16 个 app 单位）
    localparam [28:0] SUONA_DESC = ((SUONA_BASE_W + DESC_OFF_W) << 3) - (69 * 16);
    localparam [28:0] DIZI_DESC  = ((DIZI_BASE_W  + DESC_OFF_W) << 3) - (67 * 16);

    localparam [7:0]  SUONA_INF  = 8'd0;     // info 0..111
    localparam [7:0]  DIZI_INF   = 8'd112;   // info 112..211

    wire [6:0]  harm_note_lo  = is_dizi ? 7'd67 : 7'd69;
    wire [6:0]  harm_note_hi  = is_dizi ? 7'd91 : 7'd96;
    wire [7:0]  harm_inf_base = is_dizi ? DIZI_INF : SUONA_INF;
    wire [28:0] harm_desc     = is_dizi ? DIZI_DESC : SUONA_DESC;

    wire signed [15:0] sua_l, sua_r;
    wire [3:0]         sua_v_idle;
    wire [2:0]         sua_app_cmd;
    wire               sua_app_en;
    wire [28:0]        sua_app_addr;

    // ★★ 关键：只有谐波类音色下才允许触发取表 DMA！
    //   之前写成 |v_trig，导致钢琴模式下按一次键，唄呐引擎也会去抢 DDR，
    //   钢琴的取表被挤掉 → 切回钢琴也没声音（实测整机哑掉）。
    wire sua_trig = is_harm && |v_trig;

    // ★★ gate / 力度【不能】走 note_alloc 的声部！
    //    note_alloc 是 8 声部轮转分配，同一个键每次可能落在不同声部；
    //    而唢呐是单声部，用 |v_gate / v_vel[某声部] 会出两个毛病：
    //      · 任一残留声部的 v_gate=1 → 松键也不停（实测第 8 键卡住）
    //      · 力度取错声部         → 轻重反了（实测第 8 键）
    //    钢琴/古筝不受影响：它们每个声部有自己的 v_gate[g]/v_vel[g]，
    //    声部与按键是一一对应的，所以那边一直正常。
    //    唢呐改成直接看【8 个音源键】，与声部分配彻底解耦。
    wire sua_gate = is_harm && (|note_key_state);

    // 按下沿 → 按【键号】锁存力度（不是声部号）
    //   直接复用 note_key_press（= kd_state[7:0] & ~kd_state_d）
    reg  [7:0] sua_vel;
    integer sv;
    always @(posedge clk_sys) begin
        for (sv = 0; sv < 8; sv = sv + 1)
            if (note_key_press[sv]) sua_vel <= note_key_vel[sv*8 +: 8];
    end

    // ★ 音高：组合 mux（必须和 v_trig 同拍有效，引擎在那一拍锁存 sd_note）
    reg  [6:0] sua_note;
    integer si;
    always @(*) begin
        sua_note = harm_note_lo;
        for (si = 0; si < NVOICE; si = si + 1)
            if (v_trig[si]) sua_note = eng_note[si*7 +: 7];
    end


    // ★ 引擎内部多处写死 4 声部（rot[2]、k_nz[2] 等），所以保持 NVOICE=4，
    //   只用 0 号声部：v_trig 只有 bit0 会动，其余声部永不激活。
    //   表缓冲是【共享的一份】，所以多留 3 个空声部不额外占 BSRAM。
    add_engine_harm #(
        .NVOICE    (4),
        .MIX_SHIFT (2),      // 谐波引擎满刻度远高于钢琴，先 ÷4
        .SOFT      (1)
    ) u_harm (
        .clk        (clk_sys),
        .rst_n      (engine_rst_n),
        // ★ 双乐器：音域 / info 段 / 描述符段全部运行时可切
        .note_lo    (harm_note_lo),
        .note_hi    (harm_note_hi),
        .inf_base   (harm_inf_base),
        .desc_base  (harm_desc),
        .v_note     ({21'd0, sua_note}),
        .v_trig     ({3'b000, sua_trig}),
        .v_gate     ({3'b000, sua_gate}),
        .v_vel      ({{24{1'b0}}, sua_vel}),
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

    // ★ 必须打一拍再送进 sat_gain：
    //   直接组合 mux 会把 u_piano/u_mix → u_tx/din 的路径拉长，
    //   实测 SETUP -0.853 ns（CLK_SYS 唯一违例）。
    //   音频流每样点一次，加一拍延迟完全无影响。
    reg signed [15:0] mix_l_r, mix_r_r;
    always @(posedge clk_sys) begin
        mix_l_r <= is_harm ? sua_l : eng_l;
        mix_r_r <= is_harm ? sua_r : eng_r;
    end

    //======================================================================
    //  测试模式音源：8 路纯正弦，【按哪个键响哪个单频】
    //
    //  ★ 为什么要按键驱动、不能 8 路常开：
    //    只用一路真实音频引擎是合成不出「独立谱峰」的：钢琴一个音就有
    //    128 个分量，8 个声部叠起来是 1024 根谱线的谐波森林，频谱仪上
    //    根本数不清。所以测试模式要让每个键只发一个频率。
    //
    //  ★ 为什么会带力度：
    //    kd_state / kd_vel 是 key_dual 双触点算出来的（按得越快力度越大）。
    //    力度直接做每路增益 → 按重点柱就高，松手立刻灭。
    //    评委自己上手按几下就能确认：这是实时硬件合成，不是放录音。
    //======================================================================
    wire signed [15:0] test_snd;
    test_sine8 u_test_sine (
        .clk     (clk_sys),
        .rst_n   (por_n),
        .tick    (tick),
        .key_on  (note_key_state),   // 8 个音键：1 = 按住
        .key_vel (kd_vel[63:0]),     // 8 个音键 × 8 位力度
        .sample  (test_snd)
    );

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
    function signed [31:0] sat_pre;
        input signed [15:0] x;
        input [1:0]         tb;       // 0=钢琴 1=古筝 2=唢呐
        begin
            // ★ 唄呐/笛子只 ×2：实测唄呐引擎输出满力度峰值约 10000，
            //   原来 ×8 送成 80000，软限幅把它压成方波（压缩比 2.5:1），
            //   听感是「嘟嘟」而且削顶后 RMS 更高、听着更响。
            //   ×2 → 20000，在膝点 24000 以下，直通零失真。
            //   笛子 max a 只有 4.48（唄呐 6.83），先同样 ×2，上板听完再调。
            sat_pre = ((tb == 2'd2) || (tb == 2'd3)) ? (x <<< 1) :   // 唄呐/笛子 ×2
                      tb ? (x <<< 4) :       // 古筝 ×16
                           (x <<< 3);        // 钢琴 ×8
        end
    endfunction

    // 膝点 24000，超过后 d = ax-KNEE（钳在 16384），
    //     y = 24000 + d − d²/32768
    // d=16384 时 y = 24000+16384−8192 = 32192（最大值，永不超 32767）
    function signed [15:0] sat_post;
        input signed [31:0] y;        // 已乘过增益的 32 位值
        reg   signed [31:0] ax, d, yy;
        begin
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
            sat_post = y[31] ? -yy[15:0] : yy[15:0];
        end
    endfunction

    // ══════════════════════════════════════════════════════════════
    //  ★★ 软限幅再拆一级（2026-11-01）
    //
    //  加 COMPONENT 64 以后 PnR 重新摆位，`gy_l → out_l_r` 实测
    //  20.021 ns（CLK_SYS 周期 20 ns），SETUP −0.209 ns，占
    //  CLK_SYS 违规的一大半。链是
    //      gy_l → 绝对值 → 膝点比较 → d×d 乘法 → 移位 → 加减 → 钳位 → D
    //  乘法前后塞了太多比较/加减。拆成两级：
    //      ① abs：只做取绝对值 + 保存符号 → ga_l / ga_s
    //      ② lim_post：只做膝点 + d×d + 钳位（输入已是非负数）→ out_l_r
    //  数学上与 sat_post 完全等价（只是再多 1 个样点延迟）。
    // ══════════════════════════════════════════════════════════════
    function [15:0] lim_post;        // 软限幅后级（输入已取绝对值）
        input [31:0] ax;
        reg   [31:0] d, yy;
        begin
            if (ax <= 32'd24000) begin
                yy = ax;                        // 直通区
            end
            else begin
                d = ax - 32'd24000;
                if (d > 32'd16384) d = 32'd16384;
                yy = 32'd24000 + d - ((d * d) >>> 15);
            end
            if (yy > 32'd32767) yy = 32'd32767;
            lim_post = yy[15:0];
        end
    endfunction

    reg [31:0] ga_l, ga_r;           // |gy|
    reg        gs_l, gs_r;           // gy 的符号
    always @(posedge clk_sys) begin
        if (!por_n) begin
            ga_l <= 32'd0;  ga_r <= 32'd0;
            gs_l <= 1'b0;   gs_r <= 1'b0;
        end
        else begin
            ga_l <= gy_l[31] ? (~gy_l + 32'd1) : gy_l;
            ga_r <= gy_r[31] ? (~gy_r + 32'd1) : gy_r;
            gs_l <= gy_l[31];
            gs_r <= gy_r[31];
        end
    end

    wire signed [15:0] sp_l = gs_l ? -$signed({1'b0, lim_post(ga_l)})
                                   :  $signed({1'b0, lim_post(ga_l)});
    wire signed [15:0] sp_r = gs_r ? -$signed({1'b0, lim_post(ga_r)})
                                   :  $signed({1'b0, lim_post(ga_r)});

    // ★★ 原来是单个 sat_gain 函数，从 timbre_r 一路走到输出寄存器：
    //       timbre_r → 增益选择 → 绝对值 → 膝点比较 → d×d 乘法 → 减法 → D
    //    合并 HDMI 后布线变挤，实测 19.989 ns（CLK_SYS 周期 20 ns），
    //    SETUP −0.110 ns，占了 CLK_SYS 违规的 4 个端点。
    //    现在拆成两级：
    //      ① sat_pre  （只选增益倍数，纯移位）→ gy_l / gy_r
    //      ② sat_post （只做软限幅，乘法链在这里）→ out_l_r / out_r_r
    //    两条长链之间的启动寄存器都变了寄存器，乘法链也不再从
    //    高扇出的 timbre_r 出发。数学上完全等价（只是多 1 个样点延迟）。
    reg signed [31:0] gy_l, gy_r;
    always @(posedge clk_sys) begin
        if (!por_n) begin
            gy_l <= 32'sd0;
            gy_r <= 32'sd0;
        end
        else begin
            gy_l <= sat_pre(mix_l_r, timbre_r);
            gy_r <= sat_pre(mix_r_r, timbre_r);
        end
    end

    // ★★ sat_gain 输出必须再打一拍！
    //    组合送进 u_tx 时，路径是
    //        mix_l_r → 增益选择 → 绝对值 → 膝点比较 → d×d 乘法 → 减法
    //                → u_tx 内部移位寄存器 → din
    //    实测阵列后 SETUP −0.239 ns（24.097 ns > 23.858 ns）。
    //    d×d 是 16×16 乘法，综合出来直接顶在后面，而 mix_l_r 又是
    //    音频引擎输出级扇出最大的寄存器，布线很长。
    //    在 sat_gain 后面加一级寄存器，把乘法–比较与 u_tx 切开。
    //    代价：整体延迟多一个样点（20.5 us），完全听不出来。
    reg signed [15:0] out_l_r, out_r_r;
    always @(posedge clk_sys) begin
        // ★ 测试模式下直接输出 8 路正弦，绕过软限幅：
        //   sat_pre 会按音色乘 ×2/×8/×16，而 test_sine8 已经归一化到满幅，
        //   再过一遍增益会直接削顶。
        out_l_r <= test_mode ? test_snd : sp_l;
        out_r_r <= test_mode ? test_snd : sp_r;
    end

    //======================================================================
    //  32 段常数-Q 实时频谱
    //    输入取 out_l_r —— 就是最终送 DAC 的满幅信号，不是中间量
    //    输出直接送到顶层端口，由合并顶层里（clk_p 域）的渲染器消费
    //======================================================================
    spec_cqt u_spec (
        .clk        (clk_sys),
        .rst_n      (por_n),
        .tick       (tick),
        .sample     (out_l_r),
        .bands      (SPEC_BANDS),
        .bands_tick (SPEC_TICK)
    );

    //======================================================================
    //  UI 状态总线 → HDMI 渲染器
    //    ★★ 拼接必须凑成 16 位！原来写成
    //          assign UI_INFO = {transpose, fx_r, timbre_r, ui_mode};
    //       只有 14 位，赋给 16 位端口时左边补 2 个 0，
    //       结果所有字段整体错位 2 位：渲染器读到的音色其实是 fx、
    //       效果器其实是音色、移调只剩 transpose[7:2]。
    //    位图（与 hdmi_ui3_top 的解读一一对应）：
    //        [15:8] transpose  [7:6] 预留  [5:4] fx  [3:2] timbre  [1:0] mode
    //======================================================================
    assign UI_INFO = {transpose, 2'b00, fx_r, timbre_r, ui_mode};

    //======================================================================
    //  COMPONENT 64：把 128 个正弦分量两两合并成 64 根柱
    //
    //  声部按 p = 0..127 顺序扫，每个分量在 s==6 给出一次 (idx, amp)。
    //     idx 偶数 → 暂存到 pmax
    //     idx 奇数 → comp_bar[idx>>1] = max(pmax, amp)   （两根取大值）
    //  这样 64 根柱覆盖全部 128 个分量，又不会因为 128 根太细看不清。
    //
    //  ★ 不在每个样点清零：静音后保留最后一帧的包络，
    //    这样松开键以后图还停在那里，评委能看清谐波形状。
    //  ★ 声部扫满一轮是 1024 拍，用 comp_vld 门控写入即可，
    //    不存在同一个 bar 被两轮混写的问题（一轮内每个 bar 只写一次）。
    //======================================================================
    reg [7:0] comp_bar [0:63];
    reg [7:0] pmax;
    integer   cbi;

    always @(posedge clk_sys) begin
        if (!engine_rst_n) begin
            pmax <= 8'd0;
            for (cbi = 0; cbi < 64; cbi = cbi + 1) comp_bar[cbi] <= 8'd0;
        end
        else if (comp_vld) begin
            if (!comp_idx[0]) pmax <= comp_amp;
            else begin
                comp_bar[comp_idx[6:1]] <= (comp_amp > pmax) ? comp_amp : pmax;
                pmax <= 8'd0;
            end
        end
    end

    genvar cgi;
    generate
        for (cgi = 0; cgi < 64; cgi = cgi + 1) begin : g_comp
            assign COMP_AMP[cgi*8 +: 8] = comp_bar[cgi];
        end
    endgenerate

    //======================================================================
    //  灯带控制信号跨时钟域同步：clk_sys → CLOCK_50
    //
    //  u_led 必须用 CLOCK_50 直连（上板验证过的配置，不走 PLL），
    //  但它的全部控制信号都产生于 clk_sys 域（key_state / timbre /
    //  engine_rst_n）。直接跨域会让 PnR 报出 22 条 hold
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
    reg       led_rst_s0,   led_rst_s1;
    reg [1:0] led_timbre_s0, led_timbre_s1;

    always @(posedge CLOCK_50) begin
        led_key_s0  <= LED_DIAG ? stage_bar : velbar_s1;   // ★ 诊断：加载阶段条形图
        led_rst_s0  <= engine_rst_n;
        led_timbre_s0 <= timbre_r;
        led_key_s1  <= led_key_s0;
        led_rst_s1  <= led_rst_s0;
        led_timbre_s1 <= led_timbre_s0;
    end

    //======================================================================
    //  灯带（布局见 ws2812_keyind；Step4 将整体重写）
    //======================================================================
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
        .mode      (3'd1),          // 指导模式已删 → 固定「自由」显示
        .guide_key (3'd0),
        .guide_key2(3'd0),
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
        .sample_l   (out_l_r),
        .sample_r   (out_r_r),
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
    wire ddr_arb_piano = ld_done && !is_harm;
    wire ddr_arb_suona = ld_done &&  is_harm;

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
