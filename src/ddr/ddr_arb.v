//==========================================================================
//  ddr_arb.v —— DDR 用户口 4 路仲裁器（clk_x1 / 100 MHz 域）
//
//  背景
//  -----------------------------------------------------------------------
//  原设计是裸的 ld_done 二选一（加载器 / 参数表 / 谐波表），因为三者
//  在时间上天然互斥。加上效果器后变成 4 个客户，其中效果器是"持续型"
//  客户，必须显式仲裁，否则会出现：
//    · 两路同时发命令 → 地址/命令错乱
//    · 写数据通道被两路同时驱动 → 写坏参数表（钢琴音色崩）
//
//  事务（transaction）的定义 —— 全部依据 Gowin DDR3 IP 的实际时序：
//  -----------------------------------------------------------------------
//    读：  app_en & app_rdy 握手成功   →  等 app_rd_data_valid 到来
//          （★ app_rd_data_valid 是"每个 256 位字一个脉冲"，
//            见 ddr_param_dma.v 的 S_WAIT；现有设计完全串行，
//            全局只有一个 outstanding 读 → 读数据不需要 owner tag）
//    写：  app_en & app_rdy 握手成功   +   app_wdf_wren & wr_data_rdy 握手成功
//          （★ app_wdf_end = app_wdf_wren，一次写只发 1 拍 256 位，
//            IP 内部自动拆成 8 个 32-bit beat，见 sd_ddr_loader.v:391）
//
//  仲裁策略
//  -----------------------------------------------------------------------
//  轮询（ARB_TYPE_ROUND_ROBIN=1）+ 事务级保持（ARB_BLOCK/ARB_BLOCK_ACK=1）
//    · 轮询 → 天然无饿死，不需要额外老化计数器
//    · 事务级保持 → grant 一旦给出，保持到该客户 ack 为止，
//      不会出现"命令是 A 的、写数据是 B 的"
//
//  ★ 已处理的两个陷阱（第一版写错的地方，记在这里防回归）
//  -----------------------------------------------------------------------
//   ① 声明顺序：is_wr 必须在 wdf_want 之前声明，否则被当成隐式 1 位线网
//   ② ack 后一拍的重复发令竞态：arbiter.v 在 ack 当拍就会释放 grant，
//      而客户要下一拍才撤销 m_req（寄存器输出）→ 中间有一拍
//      cmd_acc 已清零、m_req 仍为高 → 会被再授一次权、重复发命令。
//      解决办法：内部请求 req_gen 用 m_ack 与 ack_d 屏蔽两拍。
//
//  ⚠️ 对上游客户（master）的强制约束
//  -----------------------------------------------------------------------
//    1. 有事务时拉高 m_req，并【保持到 m_ack 返回】，之后撤销
//    2. m_ack 返回前不得改变 m_cmd / m_addr / m_wdf_data
//    3. 写事务必须先给出 m_wdf_vld，否则靠超时保护强行结束
//    违反 1/2 会造成地址错乱（不是"性能下降"，是"数据损坏"）。
//
//  超时保护
//  -----------------------------------------------------------------------
//  某个客户拿到 grant 后 TIMEOUT 拍（默认 4096 约 41us @100MHz）还不 ack，
//  强制结束该事务并置 m_abort，避免整个 DDR 通道被卡死。
//
//  版权
//  -----------------------------------------------------------------------
//  底层仲裁判决使用 alexforencich/verilog-axi 的 arbiter.v（MIT），
//  见 src/ddr/arbiter.v 与 src/ddr/priority_encoder.v。
//==========================================================================
`default_nettype none

module ddr_arb #(
    parameter integer N          = 4,      // 客户数
    parameter integer TIMEOUT    = 4096,   // 事务超时拍数
    //  0 = 客户直接给 DDR 地址（本工程 ddr_param_dma / suona_dma /
    //      sd_ddr_loader 送出的 app_addr 已经是 <<3 之后的，必须用 0）
    //  3 = 客户给 29 位「256 位字序号」，由本模块左移 3 成 DDR 地址
    parameter integer ADDR_SHIFT = 0
)(
    input  wire             clk,        // clk_x1 = 100 MHz
    input  wire             rst_n,

    // ── 各客户请求口 ────────────────────────────────────────────────
    input  wire [N-1:0]     m_req,      // 有事务，保持到 m_ack
    input  wire [N*3-1:0]   m_cmd,      // 3'b001=读  3'b000=写
    input  wire [N*29-1:0]  m_addr,     // 256 位字序号（内部左移 3 成 DDR 地址）
                                        // 与 ddr_param_dma.v 的 base_addr[28:0] 同语义
    input  wire [N*256-1:0] m_wdf_data, // 写数据
    input  wire [N-1:0]     m_wdf_vld,  // 写数据已就绪
    output wire [N-1:0]     m_gnt,      // 当前授权（独热）
    output reg  [N-1:0]     m_ack,      // 事务完成（单拍脉冲）
    output reg  [N-1:0]     m_abort,    // 超时强杀（单拍脉冲，诊断用）

    // ── DDR 用户口（clk_x1 域）────────────────────────────────────────
    output wire [2:0]       app_cmd,
    output wire             app_en,
    output wire [28:0]      app_addr,
    output wire [255:0]     app_wdf_data,
    output wire             app_wdf_wren,
    output wire             app_wdf_end,
    output wire [31:0]      app_wdf_mask,
    output wire             app_burst,
    input  wire             app_rdy,
    input  wire             wr_data_rdy,
    input  wire             app_rd_data_valid,
    input  wire [255:0]     app_rd_data
);

    //  地址移位：由 ADDR_SHIFT 参数控制（见文件头说明）
    //  1 个 256 位字 = 32 字节 = 8 个 32-bit 字 → 左移 3

    //======================================================================
    //  1. 逐客户判定读写（★ 必须先声明：否则 wdf_want 会用到隐式 1 位线网）
    //======================================================================
    wire [N-1:0] is_wr;
    genvar gi;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : g_iswr
            assign is_wr[gi] = (m_cmd[gi*3 +: 3] == 3'b000);
        end
    endgenerate

    //======================================================================
    //  2. 内部请求：屏蔽 ack 及其后一拍，防止重复发令
    //======================================================================
    reg  [N-1:0] ack_d;                       // m_ack 延迟一拍
    wire [N-1:0] req_gen = m_req & ~(m_ack | ack_d);

    always @(posedge clk) begin
        if (!rst_n) ack_d <= {N{1'b0}};
        else        ack_d <= m_ack;
    end

    //======================================================================
    //  3. 事务子状态
    //======================================================================
    reg  [N-1:0] cmd_acc;      // 命令已握手
    reg  [N-1:0] wdf_acc;      // 写数据已握手
    reg  [N-1:0] rd_seen;      // 读数据已返回

    wire [N-1:0] cmd_want = req_gen & ~cmd_acc;                      // 还欠一条命令
    wire [N-1:0] wdf_want = req_gen & ~wdf_acc & m_wdf_vld & is_wr;  // 还欠一拍写数据

    //======================================================================
    //  4. 底层仲裁：轮询 + 事务级保持
    //======================================================================
    wire [N-1:0] arb_gnt;

    arbiter #(
        .PORTS                (N),
        .ARB_TYPE_ROUND_ROBIN (1),   // 轮询：天然无饿死
        .ARB_BLOCK            (1),   // 授权后保持
        .ARB_BLOCK_ACK        (1),   // 保持到 acknowledge
        .ARB_LSB_HIGH_PRIORITY(1)
    ) u_arb (
        .clk         (clk),
        .rst         (~rst_n),           // ★ arbiter.v 的 rst 是高有效
        .request     (req_gen),
        //  ★★ 关键：ARB_BLOCK_ACK=1 时仲裁器【只认 acknowledge】才释放 grant，
        //     超时强杀也必须回一个 acknowledge，否则授权永久挂住 →
        //     整个 DDR 通道彻底卡死（第一版就死在这里）。
        .acknowledge (m_ack | m_abort),
        .grant       (arb_gnt),
        .grant_valid (),
        .grant_encoded ()
    );

    assign m_gnt = arb_gnt;

    //======================================================================
    //  5. 命令 / 写数据 的发出与 mux
    //======================================================================
    wire [N-1:0] cmd_send = cmd_want & arb_gnt;
    wire [N-1:0] wdf_send = wdf_want & arb_gnt;

    //  ★ 地址约定：见 ADDR_SHIFT 参数说明
    //     ADDR_SHIFT=3 时 m_addr 是 29 位的「256 位字序号」，左移 3 得到 DDR
    //     地址单位（32-bit 字）。256MB 空间 = 2^26 个 32 字节字，左移 3 后
    //     正好占满 29 位，不会溢出。
    wire [28:0] sel_addr = mux_n29(m_addr, arb_gnt);

    assign app_en       = |cmd_send;
    assign app_cmd      = mux_n3   (m_cmd,      arb_gnt);
    assign app_addr     = sel_addr << ADDR_SHIFT;
    assign app_wdf_data = mux_n256(m_wdf_data,  arb_gnt);
    assign app_wdf_wren = |wdf_send;
    assign app_wdf_end  = app_wdf_wren;      // 与加载器一致：一次写只发 1 拍
    assign app_wdf_mask = 32'd0;             // 全写
    assign app_burst    = 1'b0;              // 固定突发（与现有设计一致）

    //  独热码 → 数据（grant 保证独热，按位或即可）
    function [2:0] mux_n3; input [N*3-1:0] d; input [N-1:0] s;
        integer k; reg [2:0] r;
        begin r = 3'd0; for (k=0;k<N;k=k+1) if (s[k]) r = r | d[k*3 +: 3]; mux_n3 = r; end
    endfunction
    function [28:0] mux_n29; input [N*29-1:0] d; input [N-1:0] s;
        integer k; reg [28:0] r;
        begin r = 29'd0; for (k=0;k<N;k=k+1) if (s[k]) r = r | d[k*29 +: 29]; mux_n29 = r; end
    endfunction
    function [255:0] mux_n256; input [N*256-1:0] d; input [N-1:0] s;
        integer k; reg [255:0] r;
        begin r = 256'd0; for (k=0;k<N;k=k+1) if (s[k]) r = r | d[k*256 +: 256]; mux_n256 = r; end
    endfunction

    //======================================================================
    //  6. 事务完成判定
    //======================================================================
    wire cmd_hs = app_en       && app_rdy;        // 命令被接受
    wire wdf_hs = app_wdf_wren && wr_data_rdy;    // 写数据被接受
    wire rd_hs  = app_rd_data_valid;              // 读数据返回（全局唯一）

    //  ★ 读数据只记到"正在做读事务"的客户头上，防止写事务被误标
    wire [N-1:0] rd_upd = rd_hs ? (arb_gnt & ~is_wr) : {N{1'b0}};

    wire [N-1:0] cmd_acc_n = cmd_acc | (cmd_hs ? arb_gnt : {N{1'b0}});
    wire [N-1:0] wdf_acc_n = wdf_acc | (wdf_hs ? arb_gnt : {N{1'b0}});
    wire [N-1:0] rd_seen_n = rd_seen | rd_upd;

    wire [N-1:0] done_rd = cmd_acc_n & rd_seen_n;   // 读：命令 + 数据都齐
    wire [N-1:0] done_wr = cmd_acc_n & wdf_acc_n;   // 写：命令 + 数据都齐

    //  ★★ 必须逐客户选择完成条件。
    //     写成 `is_wr ? done_wr : done_rd` 是错的：is_wr 是 N 位向量，
    //     作为三目条件时会被看成一个整体（非零即真），只要有任何一个
    //     客户在读、另一个在写，is_wr != 0，所有人都会去等 done_wr，
    //     于是所有读事务都永远完不成 → 只能等超时。
    wire [N-1:0] txn_done = (done_wr & is_wr) | (done_rd & ~is_wr);

    //======================================================================
    //  7. 超时保护
    //======================================================================
    //  用隐式截断而不是 TIMEOUT[15:0] 位选，综合器兼容性更好
    localparam [15:0] TMO_MAX = TIMEOUT;

    reg  [15:0]  tmo_cnt;
    reg  [N-1:0] gnt_d;

    wire grant_changed = (arb_gnt != gnt_d);
    wire tmo_hit       = (tmo_cnt >= TMO_MAX);

    //  ★★ 授权刚切换的那一拍 tmo_cnt 还是上一个客户的旧值（寄存器要下一拍
    //     才清零），如果直接拿 tmo_hit 去杀新客户，就会把刚拿到的授权误杀，
    //     进而连锁误杀（实测：一个卡死客户会拖死其余全部客户）。
    wire tmo_valid = tmo_hit && !grant_changed;

    //  用 m_abort 自屏蔽 → 保证 abort 是干净的单拍脉冲
    wire [N-1:0] abort_now = (tmo_valid ? arb_gnt : {N{1'b0}}) & ~m_abort;

    always @(posedge clk) begin
        if (!rst_n) begin
            tmo_cnt <= 16'd0;
            gnt_d   <= {N{1'b0}};
        end
        else begin
            gnt_d <= arb_gnt;
            if (grant_changed || (arb_gnt == {N{1'b0}})) tmo_cnt <= 16'd0;
            else if (!tmo_hit)                           tmo_cnt <= tmo_cnt + 16'd1;
        end
    end

    //======================================================================
    //  8. 状态更新
    //======================================================================
    wire [N-1:0] fin = txn_done | abort_now;

    always @(posedge clk) begin
        if (!rst_n) begin
            cmd_acc <= {N{1'b0}};
            wdf_acc <= {N{1'b0}};
            rd_seen <= {N{1'b0}};
            m_ack   <= {N{1'b0}};
            m_abort <= {N{1'b0}};
        end
        else begin
            m_ack   <= txn_done;
            m_abort <= abort_now;
            cmd_acc <= cmd_acc_n & ~fin;
            wdf_acc <= wdf_acc_n & ~fin;
            rd_seen <= rd_seen_n & ~fin;
        end
    end

    //======================================================================
    //  9. 仿真断言（综合时被 translate_off 屏蔽）
    //======================================================================
    // synopsys translate_off
    always @(posedge clk) begin
        if (rst_n) begin
            if (((arb_gnt & (arb_gnt - {{(N-1){1'b0}},1'b1})) != {N{1'b0}}) &&
                (arb_gnt != {N{1'b0}}))
                $display("[DDR_ARB] ERROR @%0t: grant 不是独热码 %b", $time, arb_gnt);
            if (app_en && (arb_gnt == {N{1'b0}}))
                $display("[DDR_ARB] ERROR @%0t: app_en 有效但没有 grant", $time);
            if (app_wdf_wren && ((arb_gnt & is_wr) == {N{1'b0}}))
                $display("[DDR_ARB] ERROR @%0t: 读事务却发了写数据", $time);
        end
    end
    // synopsys translate_on

endmodule

`default_nettype wire
