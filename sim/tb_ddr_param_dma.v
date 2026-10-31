//==========================================================================
//  tb_ddr_param_dma —— 验证 ddr_param_dma 从 DDR 取表正确
//
//  做法：
//    1. 由 P64.BIN 生成 p64_v2.hex（每行 64 个十六进制字符 = 一个 256 位字）
//    2. TB 用 $readmemh 装进 256 位存储器，模拟 DDR3
//    3. 让 ddr_param_dma 取某个音（默认 note 60）的 64 个 beat
//    4. 把 param_cache 的 128 个分量导出到 cache_dump.txt
//    5. 主机侧用 Python 与 P64.BIN 逐分量比对
//
//  跑法：
//    iverilog -g2012 -DSIM_INIT -o sim_pdma tb_ddr_param_dma.v \
//        ../src/ddr_param_dma.v ../src/param_cache.v
//    vvp sim_pdma
//==========================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_ddr_param_dma;

    localparam integer NOTE       = 60;
    localparam integer NOTE_LO    = 21;
    localparam integer BASE_WORD  = 1;                    // piano_base_word
    localparam integer WORDS_NOTE = 64;

    localparam [28:0] NOTE_BASE = BASE_WORD + (NOTE - NOTE_LO) * WORDS_NOTE;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5.0 clk = ~clk;                              // 100 MHz

    //------------------------------------------------ DDR 模型
    reg [255:0] MEM [0:16383];

    reg  [28:0] rq [0:7];
    reg  [3:0]  rq_w = 4'd0, rq_r = 4'd0;
    reg  [7:0]  lat  = 8'd0;
    reg  [28:0] cur;
    reg         have = 1'b0;
    reg         rvalid = 1'b0;
    reg [255:0] rdata;

    //------------------------------------------------ DUT
    reg         start_tog = 1'b0;
    wire        done_tog;
    wire        busy;
    wire        we;
    wire [6:0]  waddr;
    wire [95:0] wdata;
    wire [2:0]  app_cmd;
    wire        app_en;
    wire [28:0] app_addr;
    wire        app_rdy = 1'b1;
    wire        app_rd_data_valid = rvalid;
    wire [255:0] app_rd_data = rdata;

    ddr_param_dma #(
        .WORDS_PER_NOTE (WORDS_NOTE),
        .ADDR_SHIFT     (3)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start_tog(start_tog), .base_addr(NOTE_BASE[28:0]),
        .done_tog(done_tog), .busy(busy),
        .we(we), .waddr(waddr), .wdata(wdata),
        .app_cmd(app_cmd), .app_en(app_en), .app_addr(app_addr),
        .app_rdy(app_rdy),
        .app_rd_data_valid(app_rd_data_valid), .app_rd_data(app_rd_data)
    );

    wire [31:0] c_d0, c_d1, c_d2;

    param_cache #(.NPART(128)) u_cache (
        .wclk(clk), .rclk(clk),
        .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(7'd0), .d0(c_d0), .d1(c_d1), .d2(c_d2)
    );

    //------------------------------------------------ DDR 响应
    always @(posedge clk) begin
        rvalid <= 1'b0;
        if (app_en && app_cmd == 3'b001) begin
            rq[rq_w[2:0]] <= app_addr;
            rq_w <= rq_w + 4'd1;
        end
        if (!have) begin
            if (rq_r != rq_w) begin
                cur  <= rq[rq_r[2:0]];
                rq_r <= rq_r + 4'd1;
                have <= 1'b1;
                lat  <= 8'd6;
            end
        end
        else if (lat != 8'd0) lat <= lat - 8'd1;
        else begin
            rdata  <= MEM[cur >> 3];
            rvalid <= 1'b1;
            have   <= 1'b0;
        end
    end

    //------------------------------------------------ 主流程
    integer fd, k;

    initial begin
        $readmemh("p64_v2.hex", MEM);
        #100;
        rst_n = 1'b1;
        #200;
        start_tog = 1'b1;                 // 翻转 = 启动
        wait (done_tog === 1'b1);
        #200;

        $display("busy=%0d done_tog=%0d", busy, done_tog);

        fd = $fopen("cache_dump.txt", "w");
        for (k = 0; k < 128; k = k + 1)
            $fwrite(fd, "%08x %08x %08x\n",
                    u_cache.mem[k][31:0], u_cache.mem[k][63:32], u_cache.mem[k][95:64]);
        $fclose(fd);

        // 自检：与 DDR 存储器直接对照
        begin
            integer err;
            reg [95:0] exp;
            err = 0;
            for (k = 0; k < 128; k = k + 1) begin
                exp = (k % 2 == 0)
                      ? MEM[NOTE_BASE + (k/2)][95:0]
                      : MEM[NOTE_BASE + (k/2)][223:128];
                if (u_cache.mem[k] !== exp) begin
                    if (err < 4)
                        $display("  MISMATCH k=%0d got=%h exp=%h", k, u_cache.mem[k], exp);
                    err = err + 1;
                end
            end
            if (err == 0) $display("=== TB PASS (128/128 分量一致) ===");
            else          $display("=== TB FAIL (%0d/128 分量错) ===", err);
        end
        $finish;
    end

    initial begin
        #2_000_000;
        $display("*** TIMEOUT *** st=%0d w=%0d", dut.st, dut.w);
        $finish;
    end

endmodule

`default_nettype wire
