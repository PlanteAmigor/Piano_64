//==========================================================================
//  piano64 —— 64 路加法分量钢琴（8 音键 + 移调键 + 2 个功能键）
//
//  按键：
//    · J13 双触点力度键盘 9 组：组 0~7 = 8 个音键，组 8 = 移调键
//    · KEY_AUX[0] (U38/C18) = 音色键：短按循环 钢琴→古筝→唢呐→笛子
//                             长按 1 s 循环效果器 NONE→REVERB→DELAY→CHORUS
//    · KEY_AUX[1] (U37/C19) = 三模式切换（主页面 / 测试 / 教学）
//    · KEY0 (AA13)          = 板载键，与 U37 等效（也能切三模式）
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
    output wire [64*8-1:0] COMP_AMP,

    // ── 李萨如（相位图）取样口 ──────────────────────────────────
    //    SCOPE_SMP 每样点更新一次，在两次 SCOPE_TOG 翻转之间保持稳定
    //    （1024 个 clk_sys 周期 = 20.5 us）；渲染侧用 clk_p 打两拍同步
    //    SCOPE_TOG、靠翻转沿抓一次数据，不存在多位撕裂。
    output wire signed [15:0] SCOPE_SMP,
    output wire               SCOPE_TOG,

    // ── note-on 触发（给相位图做单次捕获用）──────────────────────
    //    任意声部被触发就翻转一次；渲染侧打两拍检测翻转沿。
    //    用翻转而不是脉冲：clk_sys 的单拍脉冲只有 20 ns，
    //    跨到 75 MHz 域有概率被整个漏掉。
    output reg                SCOPE_TRG
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

    // ui_mode 的具体更新放到下面 KEY_AUX 扫描之后（要用 aux_release[1]）
    reg [1:0] ui_mode;

    //======================================================================
    //  ★ 演奏键盘改为【单触点】扫描（2026-11-01 需求变更）
    //
    //    1) 只认第 1 排（KEY_R1）触发音符。第 2 排（KEY_R2）不参与演奏，
    //       只保留 R2[8] 一个键做「移调 -12」。
    //    2) 力度改由外部输入控制（以后接 UART/ADC），现在暂时固定 128
    //       = 最大 254 的一半。接外部输入时只改 vel_ext 一处。
    //    3) 第 9 组拆成两个物理按键：
    //         KEY_R1[8] 短按 → 移调 +12（升）
    //         KEY_R2[8] 短按 → 移调 -12（降）
    //
    //    原来的 key_dual 用双触点 Δt 测力度，现在有 ROW2 就不用它了。
    //    代价：单触点失去双触点对「脏开关假高电平」的防护（Jack Ganssle
    //    实测过坏开关松手时会先"稳定高电平 81 ms"再"稳定低 42 ms"，
    //    任何基于稳定时间的去抖都会被骗，于是同一个音触发两次）。
    //    下面的 40 ms 重触发屏蔽窗口是最低成本的兜底。
    //======================================================================
    wire [8:0] r1_state, r1_press, r1_release;
    wire [8:0] r2_state, r2_press, r2_release;

    key_scan #(
        .N        (9),
        .DEBOUNCE (DEBOUNCE),
        .IMMEDIATE(1)
    ) u_keys_r1 (
        .clk         (clk_sys),
        .rst_n       (engine_rst_n),
        .key_in      (KEY_R1),
        .key_state   (r1_state),
        .key_press   (r1_press),
        .key_release (r1_release)
    );

    key_scan #(
        .N        (9),
        .DEBOUNCE (DEBOUNCE),
        .IMMEDIATE(1)
    ) u_keys_r2 (
        .clk         (clk_sys),
        .rst_n       (engine_rst_n),
        .key_in      (KEY_R2),
        .key_state   (r2_state),
        .key_press   (r2_press),
        .key_release (r2_release)
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

    // ── 力度：暂时固定 128，以后接外部输入只改这一行 ────────────────
    wire [7:0] vel_ext = 8'd128;

    // ── 40 ms 重触发屏蔽：note-off 后这段时间内同一键的 press 忽略 ──
    localparam [20:0] RETRIG_T = 21'd2_000_000;    // 40 ms @50 MHz

    reg [7:0]  rt_mask;
    reg [20:0] rt_tmr;

    always @(posedge clk_sys) begin
        if (!engine_rst_n) begin
            rt_mask <= 8'd0;
            rt_tmr  <= 21'd0;
        end
        else if (|r1_release[7:0]) begin
            rt_mask <= rt_mask | r1_release[7:0];
            rt_tmr  <= RETRIG_T;
        end
        else if (rt_tmr != 21'd0) begin
            rt_tmr <= rt_tmr - 21'd1;
        end
        else begin
            rt_mask <= 8'd0;
        end
    end

    // 音源：第 1 排前 8 个键（C4..C5 一个八度）
    // ★ 第 9 键是【纯功能键】——不在 7:0 里，本来就不会发声
    wire [7:0]  note_key_state = r1_state[7:0];
    wire [7:0]  note_key_press = r1_press[7:0] & ~rt_mask;
    wire [63:0] note_key_vel   = {8{vel_ext}};

    //======================================================================
    //  三模式切换：U37（KEY_AUX[1] / C19）短按；板上 KEY0（AA13）也保留
    //
    //    每按一次：主页面(0) → 测试(1) → 教学(2) → 主页面(0)
    //    上电默认主页面。音源切换和页面切换是同一个 mode，同步发生。
    //
    //  测试模式是赛题「现场验证要求」：输出 8 路不同频率的纯正弦，
    //  频谱上能数出对应数量的独立谱峰。
    //======================================================================
    wire mode_switch = k0_press | aux_release[1];

    always @(posedge clk_sys) begin
        if (!por_n)           ui_mode <= MODE_MAIN;
        else if (mode_switch) ui_mode <= (ui_mode == MODE_GUIDE) ? MODE_MAIN
                                                                 : (ui_mode + 2'd1);
    end

    wire test_mode = (ui_mode == MODE_TEST);

    //======================================================================
    //  音色/效果器键：上方独立键 KEY_AUX[0]（U38 / C18）
    //
    //          短按（松开时、没按满 1 s）→ 切音色 钢琴→古筝→唢呐→笛子
    //          长按（按满 1 s 那一拍）    → 切效果器 NONE→REVERB→DELAY→CHORUS
    //
    //  ★★ 长按后不能再触发短按（2026-11-01 修的 bug）
    //    原来写成松手时就把 lp_fired 清 0：
    //        else begin lp_cnt <= 0; lp_fired <= 1'b0; end
    //    但 key_scan 的 key_release 脉冲比 key_state 下降沿【晚一拍】，
    //    等脉冲到来时 lp_fired 已经被清掉 → 长按松开又当成短按切了音色。
    //    现在改成：
    //        · 松手时只清 lp_cnt，lp_fired 一直保持到下一次按下
    //        · 按下沿（!aux_d）才把 lp_fired 清 0 重新开始判定
    //======================================================================
    localparam [25:0] LP_MAX = 26'd49_999_999;      // 1 s @50 MHz

    reg  [25:0] lp_cnt;
    reg         lp_fired;                           // 本次按键已判定为长按
    reg         aux0_d;

    always @(posedge clk_sys) aux0_d <= aux_state[0];

    always @(posedge clk_sys) begin
        if (!engine_rst_n) begin
            lp_cnt   <= 26'd0;
            lp_fired <= 1'b0;
        end
        else if (!aux_state[0]) begin               // 松开：只清计数
            lp_cnt   <= 26'd0;
        end
        else if (!aux0_d) begin                     // 按下沿：重新开始
            lp_cnt   <= 26'd0;
            lp_fired <= 1'b0;
        end
        else if (lp_cnt != LP_MAX) begin
            lp_cnt   <= lp_cnt + 26'd1;
        end
        else begin
            lp_fired <= 1'b1;                       // 按满 1 s
        end
    end

    wire timbre_toggle = aux_release[0] && !lp_fired;          // 短按松开
    wire fx_toggle     = (lp_cnt == LP_MAX) && !lp_fired;      // 按满 1 s 那一拍

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
    //  效果器档位：0=NONE 1=REVERB 2=DELAY 3=CHORUS（U38 长按循环）
    //  ★ 目前只有 UI 显示 + 灯带指示，音频通路还没实现
    //======================================================================
    reg [1:0] fx_r;

    always @(posedge clk_sys) begin
        if (!engine_rst_n)                       fx_r <= 2'd0;
        else if (fx_toggle)                      fx_r <= (fx_r == 2'd3) ? 2'd0 : fx_r + 2'd1;
    end

    //======================================================================
    //  李萨如余辉档位：0..3（KEY_R2[0] 短按循环）
    //    不同乐器需要的余辉完全不同：唢呐/笛子波形严格周期，余辉可以长；
    //    钢琴/古筝非谐性使相图缓慢形变，余辉一长就叠成一团。
    //    L1 余辉 250ms   L2 余辉 125ms   L3 余辉 62ms   L4 余辉 36ms
    //    （亮度模型是"最近性"：每次扫过直接写满 15，再逐帧衰减，
    //      所以拖尾整体亮度均匀，只有新旧之分）
    //  ★ KEY_R2[0] 空着不用（演奏只认 R1），正好当功能键。
    //======================================================================
    reg [1:0] agl_sel;

    always @(posedge clk_sys) begin
        if (!engine_rst_n)              agl_sel <= 2'd0;
        else if (r2_press[0])           agl_sel <= (agl_sel == 2'd3) ? 2'd0
                                                         : agl_sel + 2'd1;
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
    //  ★ 移调（第 9 组拆成两个物理按键）
    //     KEY_R1[8] 短按 → 整体 +1 八度（+12）
    //     KEY_R2[8] 短按 → 整体 -1 八度（-12）
    //     到音域边界停住、不循环；切换音色清零回 0。
    //     ★ 不再用力度大小判方向 —— 两个独立按键，方向天然确定。
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

    wire tr_up_fire   = engine_rst_n && r1_press[8];
    wire tr_down_fire = engine_rst_n && r2_press[8];

    always @(posedge clk_sys) begin
        if (!engine_rst_n) begin
            transpose <= 8'sd0;
        end
        else if (timbre_toggle) begin
            // 切换音色 → 清零（音域不同，旧档位可能已越界）
            transpose <= 8'sd0;
        end
        else if (tr_up_fire) begin
            // 到上限就停住，不回绕
            transpose <= (transpose + TR_STEP > tr_max)
                       ? tr_max : transpose + TR_STEP;
        end
        else if (tr_down_fire) begin
            // 到下限就停住，不回绕
            transpose <= (transpose - TR_STEP < tr_min)
                       ? tr_min : transpose - TR_STEP;
        end
    end

    //======================================================================
    //  移调指示灯：动作后亮 300 ms（红 = 降 -12，蓝 = 升 +12）
    //    tr_up_fire / tr_down_fire 都是 key_scan 的单拍 press 脉冲。
    //======================================================================
    wire tr_fire = tr_up_fire | tr_down_fire;
    wire tr_down = tr_down_fire;

    localparam [23:0] TR_LED_T = 24'd14_999_999;   // 300 ms @50 MHz

    reg        tr_led_on;
    reg        tr_led_neg;
    reg [23:0] tr_led_tmr;

    always @(posedge clk_sys) begin
        if (!engine_rst_n) begin
            tr_led_on  <= 1'b0;
            tr_led_neg <= 1'b0;
            tr_led_tmr <= 24'd0;
        end
        else if (tr_fire) begin
            tr_led_on  <= 1'b1;
            tr_led_neg <= tr_down;
            tr_led_tmr <= TR_LED_T;
        end
        else if (tr_led_on) begin
            if (tr_led_tmr != 24'd0) tr_led_tmr <= tr_led_tmr - 24'd1;
            else                     tr_led_on  <= 1'b0;
        end
    end

    //======================================================================
    //  复音分配：8 键 → 8 声部（C4..C5 一个八度）
    //======================================================================
    wire [NVOICE*7-1:0] k_note;
    wire [NVOICE-1:0]   v_trig, v_gate, v_idle;
    wire [NVOICE*8-1:0] v_vel;

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

    // 谐波引擎的同名监控（唢呐/笛子）
    wire [6:0] harm_idx;
    wire [7:0] harm_amp;
    wire       harm_vld;

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
    //   直接复用 note_key_press（= r1_press[7:0]，已含重触发屏蔽）
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
        .part_idx   (harm_idx),
        .part_amp   (harm_amp),
        .part_vld   (harm_vld),

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
    //    力度直接做每路增益 → 按重点柱就高，松手立刻灭。
    //    ★ 现在力度固定 128（单触点），所以 8 路柱高一致；
    //      以后接外部力度输入后就会恢复动态。
    //    评委自己上手按几下就能确认：这是实时硬件合成，不是放录音。
    //======================================================================
    wire signed [15:0] test_snd;
    test_sine8 u_test_sine (
        .clk     (clk_sys),
        .rst_n   (por_n),
        .tick    (tick),
        .key_on  (note_key_state),   // 8 个音键：1 = 按住
        .key_vel (note_key_vel),     // 8 个音键 × 8 位力度（目前固定 128）
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
    //        [15:8] transpose  [7:6] agl  [5:4] fx  [3:2] timbre  [1:0] mode
    //======================================================================
    assign UI_INFO = {transpose, agl_sel, fx_r, timbre_r, ui_mode};

    //======================================================================
    //  COMPONENT 64：把 128 个正弦分量两两合并成 64 根柱
    //
    //  数据源按音色二选一（和音源 mux 用同一个 is_harm）：
    //      钢琴/古筝 → add_engine8       的 part_idx/part_amp（128 分量）
    //      唢呐/笛子 → add_engine_harm   的 part_idx/part_amp（谐波表）
    //
    //  显示策略（2026-11-01 改，原版是「瞬时值 + 冻结」，会闪一下就没了）：
    //    ① note-on 时【清空全部 64 根】——立即重画，快奏不糊
    //       声部扫完 128 分量只要 1 个样点周期 = 20.5 us，
    //       60 fps 的一帧是 16.7 ms，所以视觉上是瞬间完成
    //    ② 峰值保持：新值 > 当前值就立即上升（0 延迟）
    //    ③ 回落：每 ~94 个样点全部降 1 级 → 255 级约 0.49 s 落满
    //
    //  快奏时每次按键图瞬间换成新音的包络（不会把上一个音的残留糊上来）；
    //  按住不松时峰值持续刷新、柱子稳定；松手后 0.5 s 平滑落光。
    //======================================================================
    localparam integer FS_HZ          = 48828;       // 音频样点率
    localparam integer COMP_FALL_MS   = 500;         // 回落时间
    // 每降 1 级间隔的样点数：0.5 s / 255 级 ≈ 94 个样点
    localparam integer COMP_FALL_STEP = (FS_HZ / 1000) * COMP_FALL_MS / 255;

    // 音色二选一
    wire [6:0] src_idx = is_harm ? harm_idx : comp_idx;
    wire [7:0] src_amp = is_harm ? harm_amp : comp_amp;
    wire       src_vld = is_harm ? harm_vld : comp_vld;

    //======================================================================
    //  ★★ 必须打一拍再进 comp_bar（2026-11-01）
    //
    //  数据源是「8 个声部 → last_v 选一个」→ 再按音色二选一，组合链是
    //      last_v → 8:1 mux（7 位）→ 2:1 mux → comp_idx[6:1] → 64 路写译码
    //  64 路译码本身已经不短，前面再串两级 mux，实测
    //      u_piano/last_v_1_s1/Q → comp_bar[61]/CE = 20.13 ns（SETUP −0.130）
    //  在 last_v 选择之后加一级寄存器，把 mux 与译码分开。
    //  单拍脉冲 src_vld 与 idx/amp 同拍寄存，配对关系不变。
    //======================================================================
    reg [6:0] s_idx_r;
    reg [7:0] s_amp_r;
    reg       s_vld_r;

    always @(posedge clk_sys) begin
        s_idx_r <= src_idx;
        s_amp_r <= src_amp;
        s_vld_r <= src_vld;
    end

    // 任意一个声部被触发 → 立即清空重画
    wire comp_clr = (|eng_trig) | sua_trig;

    reg [7:0] comp_bar [0:63];
    reg [7:0] pmax;
    reg [6:0] fdiv;
    reg [7:0] mx;
    integer   cbi;

    always @(posedge clk_sys) begin
        if (!engine_rst_n) begin
            pmax <= 8'd0;
            fdiv <= 7'd0;
            for (cbi = 0; cbi < 64; cbi = cbi + 1) comp_bar[cbi] <= 8'd0;
        end
        else begin
            // ── ③ 回落：每 COMP_FALL_STEP 个样点全部降 1 级 ────────
            //    先写，下面峰值更新的优先级更高（同拍冲突时峰值赢）
            if (tick) begin
                if (fdiv >= COMP_FALL_STEP[6:0] - 7'd1) begin
                    fdiv <= 7'd0;
                    for (cbi = 0; cbi < 64; cbi = cbi + 1)
                        if (comp_bar[cbi] != 8'd0)
                            comp_bar[cbi] <= comp_bar[cbi] - 8'd1;
                end
                else fdiv <= fdiv + 7'd1;
            end

            // ── ① note-on 清空 ──────────────────────────────────
            if (comp_clr)
                for (cbi = 0; cbi < 64; cbi = cbi + 1) comp_bar[cbi] <= 8'd0;

            // ── ② 峰值保持（放最后 → 同拍冲突时它赢）──────────────
            if (s_vld_r) begin
                if (!s_idx_r[0]) pmax <= s_amp_r;
                else begin
                    mx = (s_amp_r > pmax) ? s_amp_r : pmax;
                    if (mx > comp_bar[s_idx_r[6:1]])
                        comp_bar[s_idx_r[6:1]] <= mx;
                    pmax <= 8'd0;
                end
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
    //  李萨如（相位图）取样
    //    取最终送 DAC 的 out_l_r（已含软限幅），每样点锁一次 + 翻转标志。
    //    不能用 L/R 做 XY：本工程是单声道，左右完全一样 → 会画成一条直线。
    //======================================================================
    reg signed [15:0] scope_smp;
    reg               scope_tog;

    always @(posedge clk_sys) begin
        if (!por_n) begin
            scope_smp <= 16'sd0;
            scope_tog <= 1'b0;
        end
        else if (tick) begin
            scope_smp <= out_l_r;
            scope_tog <= ~scope_tog;
        end
    end

    assign SCOPE_SMP = scope_smp;
    assign SCOPE_TOG = scope_tog;

    // note-on 触发：comp_clr 就是「任意声部被触发」的单拍脉冲
    always @(posedge clk_sys) begin
        if (!por_n)         SCOPE_TRG <= 1'b0;
        else if (comp_clr)  SCOPE_TRG <= ~SCOPE_TRG;
    end

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
    reg [7:0]  led_kst_s0,  led_kst_s1;     // 8 键按住状态
    reg [63:0] led_kvel_s0, led_kvel_s1;    // 8 键力度
    reg [1:0]  led_tmb_s0,  led_tmb_s1;     // 音色
    reg [1:0]  led_fx_s0,   led_fx_s1;      // 效果器档位
    reg        led_trl_s0,  led_trl_s1;     // 移调闪光有效
    reg        led_trn_s0,  led_trn_s1;     // 移调方向（1=降）
    reg        led_rst_s0,  led_rst_s1;     // 复位

    always @(posedge CLOCK_50) begin
        led_kst_s0  <= note_key_state;
        led_kvel_s0 <= note_key_vel;
        led_tmb_s0  <= timbre_r;
        led_fx_s0   <= fx_r;
        led_trl_s0  <= tr_led_on;
        led_trn_s0  <= tr_led_neg;
        led_rst_s0  <= engine_rst_n;

        led_kst_s1  <= led_kst_s0;
        led_kvel_s1 <= led_kvel_s0;
        led_tmb_s1  <= led_tmb_s0;
        led_fx_s1   <= led_fx_s0;
        led_trl_s1  <= led_trl_s0;
        led_trn_s1  <= led_trn_s0;
        led_rst_s1  <= led_rst_s0;
    end

    //======================================================================
    //  灯带（布局见 ws2812_keyind.v 文件头）
    //======================================================================
    ws2812_keyind #(
        .N_LED (20),
        .DIAG  (0)
    ) u_led (
        // ★★ 灯带时钟用【CLOCK_50 直连】，和验证正常的 led_align 工程完全一致
        //    （PLL 输出 clk_sys 虽然频率相同，但相位/抖动不同，怀疑是卡死的原因）
        //    所有输入都经过上面的两拍同步，不再直接跨域
        .clk      (CLOCK_50),
        .rst_n    (led_rst_s1),
        .key_on   (led_kst_s1),
        .key_vel  (led_kvel_s1),
        .timbre   (led_tmb_s1),
        .fx       (led_fx_s1),
        .tr_led   (led_trl_s1),
        .tr_neg   (led_trn_s1),
        .dout     (DOUT)
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
    wire [3:0]  ld_stage;          // 加载阶段（clk_x1 域，仅用于串口报告）

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
