//==========================================================================
//  piano64_top —— 音频引擎 + HDMI 32 段频谱，单比特流合并顶层
//
//  为什么需要这个文件
//    主音频工程（add_top）和 HDMI 工程（hdmi_ui_top / hdmi_spec_top）原来
//    是【两个独立码流】，一次只能烧一个。要把频谱显示出来就必须合到
//    一个比特流里 —— 本文件就是那个合并点：
//
//        piano64_top
//          ├── u_audio : add_top        音频引擎 / DDR / SD / I2S（clk_sys 域）
//          └── u_hdmi  : hdmi_spec_top  720p 渲染 + DVI（clk_p 75 MHz 域）
//
//    两者唯一的连接是 SPEC_BANDS/SPEC_TICK（一束 256 位慢变数据），
//    跨域方式见 hdmi_spec_top 里的注释（抓 tick 高电平，data 有几十 ms 静止窗口）。
//
//  引脚：完全等于 piano64.cst 的全部引脚 + TMDS 四对差分
//        （V22/AB13/AA13 三个与 HDMI 工程同名同脚，无双驱冲突）
//==========================================================================
`default_nettype none

module piano64_top #(
    parameter integer STARTUP  = 2_500_000,
    parameter integer DEBOUNCE = 1_000_000
)(
    // ── 与 add_top 完全一致的板级引脚 ──────────────────────────────
    input  wire       CLOCK_50,
    input  wire       RESET_n,
    input  wire [6:0] KEY,
    input  wire [8:0] KEY_R1,
    input  wire [8:0] KEY_R2,
    input  wire [1:0] KEY_AUX,
    input  wire       KEY0,

    output wire       AUD_BCK,
    output wire       AUD_LRCK,
    output wire       AUD_DIN,
    output wire       DOUT,

    output wire       SD_CLK,
    inout  wire       SD_CMD,
    input  wire       SD_DAT0,

    output wire       UART_TX,

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

    // ── HDMI TMDS（差分对按「P,N 两个球」写在 cst 里）──────────────
    output wire       tmds_clk_n_0,
    output wire       tmds_clk_p_0,
    output wire [2:0] tmds_d_n_0,
    output wire [2:0] tmds_d_p_0
);

    // ── 频谱总线（clk_sys 域）────────────────────────────────────────
    wire [32*8-1:0] spec_bands;
    wire            spec_tick;

    // ══════════════════════════════════════════════════════════════
    //  音频引擎
    // ══════════════════════════════════════════════════════════════
    add_top #(
        .STARTUP  (STARTUP),
        .DEBOUNCE (DEBOUNCE)
    ) u_audio (
        .CLOCK_50   (CLOCK_50),
        .RESET_n    (RESET_n),
        .KEY        (KEY),
        .KEY_R1     (KEY_R1),
        .KEY_R2     (KEY_R2),
        .KEY_AUX    (KEY_AUX),
        .KEY0       (KEY0),
        .AUD_BCK    (AUD_BCK),
        .AUD_LRCK   (AUD_LRCK),
        .AUD_DIN    (AUD_DIN),
        .DOUT       (DOUT),
        .SD_CLK     (SD_CLK),
        .SD_CMD     (SD_CMD),
        .SD_DAT0    (SD_DAT0),
        .UART_TX    (UART_TX),
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
        .ddr_dqs_n  (ddr_dqs_n),
        .SPEC_BANDS (spec_bands),
        .SPEC_TICK  (spec_tick)
    );

    // ══════════════════════════════════════════════════════════════
    //  HDMI 32 段频谱显示（自带 720p PLL，独立 clk_p 域）
    //
    //  ★ 用 RESET_n 直接复位：hdmi_spec_top 内部已有「PLL 锁定后才放开」
    //    的 4 拍上电计数器（por），不需要外层再加同步器。
    // ══════════════════════════════════════════════════════════════
    hdmi_spec_top u_hdmi (
        .clk          (CLOCK_50),
        .resetn       (RESET_n),
        .BANDS        (spec_bands),
        .BANDS_TICK   (spec_tick),
        .tmds_clk_n_0 (tmds_clk_n_0),
        .tmds_clk_p_0 (tmds_clk_p_0),
        .tmds_d_n_0   (tmds_d_n_0),
        .tmds_d_p_0   (tmds_d_p_0)
    );

endmodule

`default_nettype wire
