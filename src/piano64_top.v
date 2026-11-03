//==========================================================================
//  piano64_top —— 音频引擎 + HDMI 三页面 UI，单比特流合并顶层
//
//  为什么需要这个文件
//    主音频工程（add_top）和 HDMI 工程原来是【两个独立码流】，一次只能
//    烧一个。要把画面显示出来就必须合到一个比特流里 —— 本文件就是那个
//    合并点：
//
//        piano64_top
//          ├── u_audio : add_top        音频引擎 / DDR / SD / I2S（clk_sys 域）
//          └── u_hdmi  : hdmi_ui3_top   1080p 三页面渲染 + DVI（clk_p 148.5 MHz 域）
//
//    两者唯一的连接是 SPEC_BANDS（256 位慢变数据）与 UI_INFO（16 位慢变量），
//    跨域方式见 hdmi_ui3_top 里的注释（慢变量直接打拍，数据窗口几十 ms）。
//
//  引脚：完全等于 piano64.cst 的全部引脚 + TMDS 四对差分
//        （V22/AA13 两个与 HDMI 工程同名同脚，无双驱冲突）
//==========================================================================
`default_nettype none

module piano64_top #(
    parameter integer STARTUP  = 2_500_000,
    parameter integer DEBOUNCE = 1_000_000
)(
    // ── 与 add_top 完全一致的板级引脚 ──────────────────────────────
    input  wire       CLOCK_50,
    input  wire       RESET_n,
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
    inout  wire       SD_DAT0,
    input wire BT_RX,output wire BT_TX,

    output wire       UART_TX,

    // ── 六路光敏前端（TDM 发射 + AD7606 双串行）──────────────────
    output wire [5:0] IR_EMIT,
    output wire       ADC_CSN,
    output wire       ADC_SCLK,
    output wire       ADC_RST,
    output wire       ADC_CONVST,
    input  wire       ADC_BUSY,
    input  wire       ADC_DOUTA,
    input  wire       ADC_DOUTB,

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
    wire [18:0]     ui_info;
    wire [383:0] song_ui;
    wire [1023:0] song_roll;
    wire song_ui_toggle, song_ui_ack;
    wire [64*8-1:0] comp_amp;
    wire signed [15:0] scope_smp;
    wire scope_clk;
    wire               scope_tog;
    wire               scope_trg;

    // ══════════════════════════════════════════════════════════════
    //  音频引擎
    // ══════════════════════════════════════════════════════════════
    add_top #(
        .STARTUP  (STARTUP),
        .DEBOUNCE (DEBOUNCE)
    ) u_audio (
        .CLOCK_50   (CLOCK_50),
        .RESET_n    (RESET_n),
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
        .BT_RX(BT_RX),.BT_TX(BT_TX),
        .IR_EMIT    (IR_EMIT),
        .ADC_CSN    (ADC_CSN),
        .ADC_SCLK   (ADC_SCLK),
        .ADC_RST    (ADC_RST),
        .ADC_CONVST (ADC_CONVST),
        .ADC_BUSY   (ADC_BUSY),
        .ADC_DOUTA  (ADC_DOUTA),
        .ADC_DOUTB  (ADC_DOUTB),
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
        .SPEC_TICK  (spec_tick),
        .UI_INFO    (ui_info),
        .SONG_UI(song_ui),.SONG_ROLL(song_roll),.SONG_UI_TOGGLE(song_ui_toggle),.SONG_UI_ACK(song_ui_ack),
        .COMP_AMP   (comp_amp),
        .SCOPE_CLK(scope_clk),
        .SCOPE_SMP  (scope_smp),
        .SCOPE_TOG  (scope_tog),
        .SCOPE_TRG  (scope_trg)
    );

    // ══════════════════════════════════════════════════════════════
    //  HDMI 三页面 UI（自带 1080p PLL，独立 clk_p 域）
    //
    //  ★ 用 RESET_n 直接复位：hdmi_ui3_top 内部已有「PLL 锁定后才放开」
    //    的 4 拍上电计数器（por），不需要外层再加同步器。
    // ══════════════════════════════════════════════════════════════
    hdmi_ui3_top u_hdmi (
        .clk          (CLOCK_50),
        .resetn       (RESET_n),
        .BANDS        (spec_bands),
        .BANDS_TICK   (spec_tick),
        .UI_INFO      (ui_info),
        .SONG_UI(song_ui),.SONG_ROLL(song_roll),.SONG_UI_TOGGLE(song_ui_toggle),.SONG_UI_ACK(song_ui_ack),
        .COMP_AMP     (comp_amp),
        .CLK_SCOPE(scope_clk),
        .SCOPE_SMP    (scope_smp),
        .SCOPE_TOG    (scope_tog),
        .SCOPE_TRG    (scope_trg),
        .tmds_clk_n_0 (tmds_clk_n_0),
        .tmds_clk_p_0 (tmds_clk_p_0),
        .tmds_d_n_0   (tmds_d_n_0),
        .tmds_d_p_0   (tmds_d_p_0)
    );

endmodule

`default_nettype wire
