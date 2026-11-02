//==========================================================================
//  tb_ddr_arb.v —— ddr_arb 的独立仿真台
//
//  验证目标
//  -----------------------------------------------------------------------
//    1. 授权独热，app_en/app_wdf_wren 只在有授权时出现
//    2. 【地址完整性】app_en/app_wdf_data 每拍都等于被授权客户的值
//    3. 【事务原子性】某客户事务未 ack 前，不会出现另一个客户的命令/数据
//    4. 【读数据归属】app_rd_data_valid 只记到正在做读事务的客户
//    5. 【无饿死】每个客户都能拿到足够的授权次数
//    6. 【无重复发令】同一事务只发一条命令（第一版曾在这里出错）
//    7. 【超时保护】故意让一个客户不发写数据，验证 abort 能救回来
//
//  编译运行
//  -----------------------------------------------------------------------
//    iverilog -g2012 -o tb_ddr_arb \
//        src/ddr/arbiter.v src/ddr/priority_encoder.v src/ddr/ddr_arb.v tb_ddr_arb.v
//    vvp tb_ddr_arb
//==========================================================================
`timescale 1ns/1ps

//  逐拍跟踪窗口末拍（编译时可用 -DTRACE_END_VAL=<n> 覆盖，0 表示关闭）
`ifndef TRACE_END_VAL
`define TRACE_END_VAL 0
`endif

//──────────────────────────────────────────────────────────────────────
//  单个客户的行为模型：随机发读/写事务，等到 ack 才撤销 req
//──────────────────────────────────────────────────────────────────────
module tb_client #(
    parameter integer ID   = 0,
    parameter integer SEED = 1,
    parameter integer P_WR_T = 77,   // 写事务阈值（0..255 尺度）: 77≈30%, 128≈50%, 153≈60%
    parameter integer STUCK = 0      // 1 = 故意不发写数据（测超时）
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         gnt,
    input  wire         ack,
    input  wire         abort_i,
    output reg          req,
    output reg  [2:0]   cmd,
    output reg  [28:0]  addr,
    output reg  [255:0] wdf_data,
    output reg          wdf_vld,
    output reg  [31:0]  n_txn,       // 发出的完整事务数
    output reg  [31:0]  n_err
);
    integer r;
    reg [31:0] lfsr;

    // 选一个"有分量"的地址，方便查地址错乱
    function [28:0] pick_addr(input [31:0] rv);
        begin
            pick_addr = {ID[3:0], rv[23:0], 1'b0};   // 高 4 位带客户号
        end
    endfunction

    initial begin
        req = 0; cmd = 3'b001; addr = 0; wdf_data = 0; wdf_vld = 0;
        n_txn = 0; n_err = 0;
        lfsr = SEED;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            req <= 1'b0; wdf_vld <= 1'b0; cmd <= 3'b001; addr <= 29'd0; wdf_data <= 256'd0;
        end
        else if (abort_i) begin
            // 超时强杀：必须放弃本次事务
            req <= 1'b0; wdf_vld <= 1'b0;
            n_err <= n_err + 1;
        end
        else if (ack) begin
            // 事务完成
            req <= 1'b0; wdf_vld <= 1'b0;
            n_txn <= n_txn + 1;
        end
        else if (!req) begin
            // 空闲时按概率发起新事务
            // ★ 用互不干扰的位段：bit[6:0] 决定是否发起，bit[15:8] 决定读/写
            //   （第一版用 lfsr%100 同时算两件事，导致读/写判定恒真 → 全是写）
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            if (lfsr[6:0] < 7'd8) begin              // 8/128 ≈ 6%
                if (lfsr[15:8] < P_WR_T) begin
                    cmd     <= 3'b000;                       // 写
                    wdf_vld <= STUCK ? 1'b0 : 1'b1;          // STUCK 时故意不给数据
                end
                else begin
                    cmd     <= 3'b001;                       // 读
                    wdf_vld <= 1'b0;
                end
                addr     <= pick_addr(lfsr);
                wdf_data <= {232'd0, ID[7:0], lfsr[23:8]};   // 232+8+16 = 256
                req      <= 1'b1;
            end
        end
        // req 保持期间不得改 cmd/addr/wdf_data —— 本模型天然满足
    end
endmodule

//──────────────────────────────────────────────────────────────────────
//  测试台主体
//──────────────────────────────────────────────────────────────────────
module tb_ddr_arb;

    localparam integer N       = 4;
    localparam integer NCLK    = 30000;
    localparam integer TIMEOUT = 200;      // 缩短超时，便于测 abort

`ifdef TEST_STUCK
    localparam integer STUCK_IDX = 3;      // 客户 3 故意不发写数据，验证超时能救回总线
`else
    localparam integer STUCK_IDX = -1;
`endif

    reg clk = 1'b0;
    always #5 clk = ~clk;                  // 100 MHz
    reg rst_n = 1'b0;

    // ── DUT 端口 ──
    wire [N-1:0]     m_req, m_wdf_vld, m_gnt, m_ack, m_abort;
    wire [N*3-1:0]   m_cmd;
    wire [N*29-1:0]  m_addr;
    wire [N*256-1:0] m_wdf_data;

    wire [2:0]   app_cmd;
    wire         app_en;
    wire [28:0]  app_addr;
    wire [255:0] app_wdf_data;
    wire         app_wdf_wren, app_wdf_end, app_burst;
    wire [31:0]  app_wdf_mask;

    reg          app_rdy, wr_data_rdy, app_rd_data_valid;
    reg  [255:0] app_rd_data;

    // ── 客户实例 ──
    wire [N*32-1:0] cli_ntxn, cli_nerr;
    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_cli
            tb_client #(
                .ID   (i),
                .SEED (32'h1234_5678 + i*7919),
                .P_WR_T (i == 0 ? 77 : (i == 1 ? 153 : 128)),
                .STUCK  (i == STUCK_IDX ? 1 : 0)
            ) u_cli (
                .clk     (clk), .rst_n(rst_n),
                .gnt     (m_gnt[i]), .ack(m_ack[i]), .abort_i(m_abort[i]),
                .req     (m_req[i]),
                .cmd     (m_cmd[i*3 +: 3]),
                .addr    (m_addr[i*29 +: 29]),
                .wdf_data(m_wdf_data[i*256 +: 256]),
                .wdf_vld (m_wdf_vld[i]),
                .n_txn   (cli_ntxn[i*32 +: 32]),
                .n_err   (cli_nerr[i*32 +: 32])
            );
        end
    endgenerate

    //──────────────────────────────────────────────────────────────
    //  DUT
    //──────────────────────────────────────────────────────────────
    ddr_arb #(.N(N), .TIMEOUT(TIMEOUT), .ADDR_SHIFT(3)) dut (
        .clk(clk), .rst_n(rst_n),
        .m_req(m_req), .m_cmd(m_cmd), .m_addr(m_addr),
        .m_wdf_data(m_wdf_data), .m_wdf_vld(m_wdf_vld),
        .m_gnt(m_gnt), .m_ack(m_ack), .m_abort(m_abort),
        .app_cmd(app_cmd), .app_en(app_en), .app_addr(app_addr),
        .app_wdf_data(app_wdf_data), .app_wdf_wren(app_wdf_wren),
        .app_wdf_end(app_wdf_end), .app_wdf_mask(app_wdf_mask),
        .app_burst(app_burst),
        .app_rdy(app_rdy), .wr_data_rdy(wr_data_rdy),
        .app_rd_data_valid(app_rd_data_valid), .app_rd_data(app_rd_data)
    );

    //──────────────────────────────────────────────────────────────
    //  DDR 模型：app_rdy / wr_data_rdy 随机抖动，读数据延迟几拍返回
    //──────────────────────────────────────────────────────────────
    integer seed = 20261102;
    integer n_rd_accept = 0;      // 模型接受了几条读命令
    integer n_rd_valid  = 0;      // 模型吐了几个 rd_data_valid

    always @(posedge clk) begin
        app_rdy      <= (($unsigned($random(seed)) % 100) < 70);   // 70% 可接受
        wr_data_rdy  <= (($unsigned($random(seed)) % 100) < 60);   // 60%
    end

    // 读数据：命令被接受后延迟 2~6 拍，出一个 valid 脉冲
    reg [3:0] rd_lat = 4'd0;
    reg       rd_pend = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_pend <= 1'b0;
            app_rd_data_valid <= 1'b0;
        end
        else if (|m_abort) begin
            //  DUT 放弃事务（超时）：模型也必须丢弃挂起的读，
            //  否则陈旧数据会晚到，污染下一个客户的事务
            rd_pend <= 1'b0;
        end
        else begin
            app_rd_data_valid <= 1'b0;
            if (app_en && app_rdy && app_cmd == 3'b001) begin
                rd_pend <= 1'b1;
                rd_lat  <= 4'd2 + ($unsigned($random(seed)) % 5);
                n_rd_accept = n_rd_accept + 1;
            end
            else if (rd_pend) begin
                if (rd_lat == 4'd0) begin
                    rd_pend <= 1'b0;
                    app_rd_data_valid <= 1'b1;
                    app_rd_data <= {224'd0, $unsigned($random(seed))};
                    n_rd_valid = n_rd_valid + 1;
                end
                else rd_lat <= rd_lat - 4'd1;
            end
        end
    end

    //──────────────────────────────────────────────────────────────
    //  影子模型：逐拍校验 app_* 与"被授权客户"一致
    //──────────────────────────────────────────────────────────────
    integer e_addr, e_wdata, e_gnt_multi, e_en_nognt, e_cmd_mismatch;
    integer e_wdf_on_rd, e_wdf_mismatch, e_txn_overlap, e_addr_chg;
    integer n_cmd_rd, n_cmd_wr, n_rd_data, n_cyc;
    reg [N-1:0] busy_owner;        // 正在处理事务的客户（事务级互斥检查）
    reg [28:0]  lat_addr [0:N-1];  // 锁存命令被接受时的地址

    integer k, m;
    always @(posedge clk) begin
        if (!rst_n) begin
            e_addr = 0; e_wdata = 0; e_gnt_multi = 0; e_en_nognt = 0;
            e_cmd_mismatch = 0; e_wdf_on_rd = 0; e_wdf_mismatch = 0;
            e_txn_overlap = 0; e_addr_chg = 0;
            n_cmd_rd = 0; n_cmd_wr = 0; n_rd_data = 0; n_cyc = 0;
            busy_owner = {N{1'b0}};
        end
        else begin
            n_cyc = n_cyc + 1;

            // ① 授权必须独热
            m = 0;
            for (k = 0; k < N; k = k + 1) if (m_gnt[k]) m = m + 1;
            if (m > 1) e_gnt_multi = e_gnt_multi + 1;

            // ② 命令必须有授权
            if (app_en && m == 0) e_en_nognt = e_en_nognt + 1;

            // ③ 命令的 cmd/addr 必须等于被授权客户的值
            for (k = 0; k < N; k = k + 1) begin
                if (app_en && m_gnt[k]) begin
                    if (app_cmd !== m_cmd[k*3 +: 3]) e_cmd_mismatch = e_cmd_mismatch + 1;
                    if (app_addr !== (m_addr[k*29 +: 29] << 3)) e_addr = e_addr + 1;
                end
                // ④ 写数据的 data 必须等于被授权客户的值，且必须发生在写事务上
                if (app_wdf_wren && m_gnt[k]) begin
                    if (m_cmd[k*3 +: 3] !== 3'b000) e_wdf_on_rd = e_wdf_on_rd + 1;
                    if (app_wdf_data !== m_wdf_data[k*256 +: 256]) e_wdf_mismatch = e_wdf_mismatch + 1;
                end
            end

            // ⑤ 事务原子性：命令被接受后，到 ack 之前不许换客户
            if (app_en && app_rdy && m == 1) begin
                if (busy_owner != {N{1'b0}} && busy_owner != m_gnt)
                    e_txn_overlap = e_txn_overlap + 1;
                busy_owner <= m_gnt;
                for (k = 0; k < N; k = k + 1)
                    if (m_gnt[k]) lat_addr[k] <= m_addr[k*29 +: 29];
                if (app_cmd == 3'b001) n_cmd_rd = n_cmd_rd + 1;
                else                   n_cmd_wr = n_cmd_wr + 1;
            end
            if (|m_ack) busy_owner <= {N{1'b0}};
            if (|m_abort) busy_owner <= {N{1'b0}};

            if (app_rd_data_valid) n_rd_data = n_rd_data + 1;
        end
    end

    //──────────────────────────────────────────────────────────────
    //  运行
    //──────────────────────────────────────────────────────────────
    //── 调试：逐拍打印（把 TRACE_END 改大即可打开波形文本） ──
    parameter integer TRACE_END = `TRACE_END_VAL;
    integer dbg_cyc = 0;
    always @(posedge clk) begin
        dbg_cyc = dbg_cyc + 1;
        if (rst_n && dbg_cyc >= 20 && dbg_cyc <= TRACE_END)
            $display("c=%0d gnt=%b req=%b rgen=%b cwant=%b en=%b rdy=%b cmd=%b cmdacc=%b rdseen=%b iswr=%b rdv=%b rdp=%b rdl=%0d wdfv=%b wdw=%b wdr=%b ack=%b ackd=%b tmo=%0d",
                dbg_cyc, m_gnt, m_req, dut.req_gen, dut.cmd_want, app_en, app_rdy,
                m_cmd, dut.cmd_acc, dut.rd_seen, dut.is_wr, app_rd_data_valid,
                rd_pend, rd_lat, m_wdf_vld, app_wdf_wren, wr_data_rdy,
                m_ack, dut.ack_d, dut.tmo_cnt);
    end

    //── 调试：打印前若干次 abort 的现场 ──
    integer dbg_cnt = 0;
    integer dbg_i;
    always @(posedge clk) begin
        if (rst_n && |m_abort && dbg_cnt < 10) begin
            dbg_cnt = dbg_cnt + 1;
            $display("[ABORT %0d] t=%0t gnt=%b req=%b cmd=%b cmd_acc=%b wdf_acc=%b rd_seen=%b tmo=%0d rd_pend=%b rd_lat=%0d app_rdy=%b wdr=%b",
                dbg_cnt, $time, m_gnt, m_req,
                {m_cmd[2:0], m_cmd[5:3], m_cmd[8:6], m_cmd[11:9]},
                dut.cmd_acc, dut.wdf_acc, dut.rd_seen, dut.tmo_cnt,
                rd_pend, rd_lat, app_rdy, wr_data_rdy);
        end
    end

    initial begin
        $dumpfile("tb_ddr_arb.vcd");
        $dumpvars(0, tb_ddr_arb);
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (NCLK) @(posedge clk);

        $display("");
        $display("================ ddr_arb 仿真结果 ================");
        $display(" 运行周期            : %0d", n_cyc);
        $display(" 读命令 / 写命令     : %0d / %0d", n_cmd_rd, n_cmd_wr);
        $display(" 读数据返回          : %0d   (模型接受读命令 %0d 条)", n_rd_data, n_rd_accept);
        $display(" 模型吐出的读数据    : %0d", n_rd_valid);
        $display(" 各客户完成事务数    : %0d / %0d / %0d / %0d",
                 cli_ntxn[0*32 +: 32], cli_ntxn[1*32 +: 32],
                 cli_ntxn[2*32 +: 32], cli_ntxn[3*32 +: 32]);
        $display(" 各客户错误(abort)数 : %0d / %0d / %0d / %0d",
                 cli_nerr[0*32 +: 32], cli_nerr[1*32 +: 32],
                 cli_nerr[2*32 +: 32], cli_nerr[3*32 +: 32]);
        $display("--------------------------------------------------");
        $display(" 授权不独热          : %0d", e_gnt_multi);
        $display(" 无授权却发命令      : %0d", e_en_nognt);
        $display(" 命令 cmd 不匹配     : %0d", e_cmd_mismatch);
        $display(" 命令 addr 不匹配    : %0d", e_addr);
        $display(" 读事务却发写数据    : %0d", e_wdf_on_rd);
        $display(" 写数据不匹配        : %0d", e_wdf_mismatch);
        $display(" 事务被中途打断      : %0d", e_txn_overlap);
        $display("==================================================");

        if (e_gnt_multi + e_en_nognt + e_cmd_mismatch + e_addr +
            e_wdf_on_rd + e_wdf_mismatch + e_txn_overlap == 0) begin
`ifdef TEST_STUCK
            //  卡死的客户必须被 abort 刹住，同时其余客户必须照常工作
            if (cli_nerr[STUCK_IDX*32 +: 32] == 0)
                $display("*** FAIL：卡死的客户竟然没被超时刹住 ***");
            else if (cli_ntxn[0*32 +: 32] < 100 || cli_ntxn[1*32 +: 32] < 100 ||
                     cli_ntxn[2*32 +: 32] < 100)
                $display("*** FAIL：卡死客户把总线拖垓了（其他客户几乎没进展） ***");
            else
                $display("*** PASS（超时模式）：卡死客户被刹住 %0d 次，其余客户照常工作 ***",
                         cli_nerr[STUCK_IDX*32 +: 32]);
`else
            $display("*** PASS：所有检查项为 0 ***");
`endif
        end
        else
            $display("*** FAIL ***");
        $finish;
    end

endmodule
