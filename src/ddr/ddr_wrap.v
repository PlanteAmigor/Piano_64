//==========================================================================
//  ddr_wrap —— DDR3 1GiB 封装（第 1 步：只做初始化，验证资源与时序）
//
//  来自 ddr_bringup（已上板验证 `DDR3 TEST OKAY!`）：
//    · IP：DDR3_Memory_Interface_Top（256 位，DQ_WIDTH=32，DDR3-800）
//    · PLL：50 MHz → 400 MHz（memory_clk），IP 内部 /4 出 clk_x1 = 100 MHz
//
//  ★ 用户接口（cmd/addr/wr_data/rd_data）跑在 clk_x1 = 100 MHz 域，
//    而系统主时钟是 50 MHz —— 跨时钟域在第 2 步处理。
//    本步先把 IP 挂上去，确认：
//      1) IOLOGIC 97/285 加进来后还够（键盘占 20 个普通 IO）
//      2) 400 MHz / 100 MHz 时钟域时序能收敛
//      3) BSRAM 再加 16 块后不超过 340
//
//  实现方式：命令口全部拉静态（不发任何读写），只观察 init_calib_complete。
//  这样综合出来的资源和最终形态基本一致，风险提前暴露。
//==========================================================================
`default_nettype none

module ddr_wrap (
    input  wire        clk,          // 50 MHz 系统时钟
    input  wire        rst_n,        // 同步于 clk

    output wire        init_done,    // DDR 校准完成（clk_x1 域直通）
    output wire        clk_x1,       // 100 MHz 用户时钟（IP 产生）
    output wire        pll_locked,   // ★ 诊断：DDR PLL 是否锁定

    // ── DDR3 MC 用户接口（全部同步于 clk_x1）────────────────────
    input  wire [2:0]   app_cmd,
    input  wire         app_en,
    input  wire [28:0]  app_addr,
    input  wire [255:0] app_wdf_data,
    input  wire         app_wdf_wren,
    input  wire         app_wdf_end,
    input  wire [31:0]  app_wdf_mask,
    input  wire         app_burst,
    output wire         app_rdy,
    output wire         wr_data_rdy,
    output wire         app_rd_data_valid,
    output wire [255:0] app_rd_data,

    // ── DDR3 物理引脚 ───────────────────────────────────────────
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

    localparam integer ADDR_W = 29;

    // ── PLL：50 MHz → 400 MHz ────────────────────────────────────
    wire memory_clk;
    wire pll_lock;
    wire pll_stop;
    // ★ clk_x1 已在端口列表里声明为 output（100 MHz 用户时钟），
    //   这里绝不能再 `wire clk_x1;` —— 会触发
    //   WARN (EX3628) Redeclaration of ANSI port 'clk_x1' is not allowed

    Gowin_PLL_DDR u_pll (
        .lock    (pll_lock),
        .clkout0 (),
        .clkout1 (),
        .clkout2 (memory_clk),
        .clkin   (clk),
        .init_clk(clk),
        .reset   (~rst_n),
        .enclk0  (1'b1),
        .enclk1  (1'b1),
        .enclk2  (pll_stop)
    );

    // ── 用户接口（第 1 步：静态，不发命令）──────────────────────
    wire              calib_raw;

    DDR3_Memory_Interface_Top u_ddr3 (
        .memory_clk         (memory_clk),
        .pll_stop           (pll_stop),
        .clk                (clk),
        .rst_n              (rst_n),

        .cmd_ready          (app_rdy),
        .cmd                (app_cmd),
        .cmd_en             (app_en),
        .addr               (app_addr),

        .wr_data_rdy        (wr_data_rdy),
        .wr_data            (app_wdf_data),
        .wr_data_en         (app_wdf_wren),
        .wr_data_end        (app_wdf_end),
        .wr_data_mask       (app_wdf_mask),

        .rd_data            (app_rd_data),
        .rd_data_valid      (app_rd_data_valid),
        .rd_data_end        (),

        .sr_req             (1'b0),
        .ref_req            (1'b0),
        .sr_ack             (),
        .ref_ack            (),

        .init_calib_complete(calib_raw),
        .clk_out            (clk_x1),
        .pll_lock           (pll_lock),
        .burst              (app_burst),
        .ddr_rst            (),

        .O_ddr_addr         (ddr_addr),
        .O_ddr_ba           (ddr_bank),
        .O_ddr_cs_n         (ddr_cs),
        .O_ddr_ras_n        (ddr_ras),
        .O_ddr_cas_n        (ddr_cas),
        .O_ddr_we_n         (ddr_we),
        .O_ddr_clk          (ddr_ck),
        .O_ddr_clk_n        (ddr_ck_n),
        .O_ddr_cke          (ddr_cke),
        .O_ddr_odt          (ddr_odt),
        .O_ddr_reset_n      (ddr_reset_n),
        .O_ddr_dqm          (ddr_dm),
        .IO_ddr_dq          (ddr_dq),
        .IO_ddr_dqs         (ddr_dqs),
        .IO_ddr_dqs_n       (ddr_dqs_n)
    );

    // ── 校准完成：直接以 clk_x1 域输出 ─────────────────────────
    //  ★ 消费者是 sd_ddr_loader，它就跑在 clk_x1 域，同域不需要同步器。
    //    （以前这里打到 clk(50MHz) 是因为没有消费者，纯观察；现在直接透传，
    //      避免多一级延迟让 loader 早于 DDR 就绪。）
    assign init_done  = calib_raw;
    assign pll_locked = pll_lock;      // 诊断用

endmodule

`default_nettype wire
