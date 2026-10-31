//==========================================================================
//  tb_sd_ddr_loader —— 离线验证 sd_ddr_loader 的 DDR 写入/读回校验
//
//  组成：
//    · sd_ddr_loader（被测）
//    · sd_stub_p64.v 里的假 sd_file_list_reader（吐 P64.BIN 字节流）
//    · 本文件里的行为级 DDR3 MC 模型（256 位，cmd/wr_data/rd_data 三通道）
//
//  断言：
//    · load_ok == 1
//    · nbytes == 文件大小
//    · nwords == 文件大小/32
//    · 结束时把 DDR 模型内存 dump 成 ddr_dump.bin，主机侧与 P64.BIN 逐字节比对
//
//  跑法：
//    iverilog -g2012 -o sim_loader \
//        sim/tb_sd_ddr_loader.v sim/sd_stub_p64.v \
//        src/sd_ddr_loader.v src/sd/sd_async_fifo.v src/sd/uart_tx.v
//    vvp sim_loader
//==========================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_sd_ddr_loader;

    //------------------------------------------------ 时钟 / 复位
    reg clk50  = 1'b0;
    reg clk100 = 1'b0;
    reg arst_n = 1'b0;

    always #10.0 clk50  = ~clk50;      // 50 MHz
    always #5.0  clk100 = ~clk100;     // 100 MHz

    //------------------------------------------------ DUT 接口
    wire        sd_clk;
    wire        sd_cmd;
    wire        sd_dat0 = 1'b1;
    wire        uart_txd;

    wire [2:0]   app_cmd;
    wire         app_en;
    wire [28:0]  app_addr;
    wire [255:0] app_wdf_data;
    wire         app_wdf_wren;
    wire         app_wdf_end;
    wire [31:0]  app_wdf_mask;
    wire         app_burst;
    wire         app_rdy;
    wire         wr_data_rdy;
    wire         app_rd_data_valid;
    wire [255:0] app_rd_data;

    wire         load_done, load_ok;
    wire [3:0]   stage;
    wire [31:0]  nbytes, nwords, err_ov;
    wire [11:0]  nfiles, file_no;

    reg calib_done = 1'b0;

    sd_ddr_loader #(
        .CLK50_HZ  (50_000_000),
        .CLK100_HZ (100_000_000),
        .BOOT_MS   (1)                 // 仿真里缩短上电等待
    ) dut (
        .clk50       (clk50),
        .clk100      (clk100),
        .arst_n      (arst_n),
        .calib_done  (calib_done),
        .dbg_pll     (1'b1),
        .dbg_por_n   (1'b1),
        .dbg_reset_n (1'b1),
        .sd_clk      (sd_clk),
        .sd_cmd      (sd_cmd),
        .sd_dat0     (sd_dat0),
        .app_cmd        (app_cmd),
        .app_en         (app_en),
        .app_addr       (app_addr),
        .app_wdf_data   (app_wdf_data),
        .app_wdf_wren   (app_wdf_wren),
        .app_wdf_end    (app_wdf_end),
        .app_wdf_mask   (app_wdf_mask),
        .app_burst      (app_burst),
        .app_rdy        (app_rdy),
        .wr_data_rdy    (wr_data_rdy),
        .app_rd_data_valid (app_rd_data_valid),
        .app_rd_data    (app_rd_data),
        .load_done   (load_done),
        .load_ok     (load_ok),
        .stage       (stage),
        .nbytes      (nbytes),
        .nwords      (nwords),
        .err_ov      (err_ov),
        .nfiles      (nfiles),
        .file_no     (file_no),
        .uart_txd    (uart_txd)
    );

    //====================================================================
    //  行为级 DDR3 MC 模型（256 位数据宽度）
    //====================================================================
    localparam integer DMEM = 65536;
    reg [255:0] MEM [0:DMEM-1];

    reg [28:0] wa_hold = 29'd0;
    reg        whold_v = 1'b0;
    wire       wr_cmd_now = app_en && (app_cmd == 3'b000);

    reg [28:0] rq [0:31];        // 待响应的读地址
    reg [5:0]  rq_w = 6'd0, rq_r = 6'd0;

    reg [5:0]  wqdcnt = 6'd0;
    reg [7:0]  rd_lat = 8'd0;
    reg [28:0] rd_cur;
    reg        rd_have = 1'b0;
    reg        rvalid_r = 1'b0;
    reg [255:0] rdata_r;

    assign app_rdy     = 1'b1;      // 命令永远能接
    assign wr_data_rdy = 1'b1;      // 写数据永远能接
    assign app_rd_data_valid = rvalid_r;
    assign app_rd_data       = rdata_r;

    integer wi;
    initial for (wi = 0; wi < DMEM; wi = wi + 1) MEM[wi] = 256'd0;

    always @(posedge clk100) begin
        rvalid_r <= 1'b0;

        // 写通道：loader 可能【同拍】发命令和写数据，也可能先命令后数据。
        //  ★ 曾经用 wr_q 数组配对，同拍时数组里还是 x → MEM[x] 写入被丢，
        //    仿真里 DATA 全成了垃圾（板上其实是对的）。
        if (wr_cmd_now) begin
            wa_hold <= app_addr;
            whold_v <= 1'b1;
        end
        if (app_wdf_wren) begin
            MEM[ wr_cmd_now ? app_addr : wa_hold ] <= app_wdf_data;
            if (wqdcnt < 6'd3)
                $display("[W%0d] addr=%0d data=%h", wqdcnt, wr_cmd_now ? app_addr : wa_hold, app_wdf_data);
            wqdcnt <= wqdcnt + 6'd1;
            whold_v <= 1'b0;
        end
        // 读命令入队
        if (app_en && app_cmd == 3'b001) begin
            rq[rq_w[4:0]] <= app_addr;
            rq_w <= rq_w + 6'd1;
        end

        // 读响应：固定 8 拍延迟
        if (!rd_have) begin
            if (rq_r != rq_w) begin
                rd_cur  <= rq[rq_r[4:0]];
                rq_r    <= rq_r + 6'd1;
                rd_have <= 1'b1;
                rd_lat  <= 8'd8;
            end
        end
        else if (rd_lat != 8'd0) begin
            rd_lat <= rd_lat - 8'd1;
        end
        else begin
            rdata_r  <= MEM[rd_cur];
            rvalid_r <= 1'b1;
            rd_have  <= 1'b0;
        end
    end

    //====================================================================
    //  主流程
    //====================================================================
    integer fdump;
    integer k;
    integer errors = 0;

    initial begin
        $dumpfile("tb_loader.vcd");
        $dumpvars(0, tb_sd_ddr_loader);

        #100;
        arst_n = 1'b1;
        #1000;
        calib_done = 1'b1;             // 假装 DDR 校准完成

        // 等加载结束
        wait (load_done === 1'b1);
        #2000;

        $display("=================================================");
        $display(" NF=%0d  FN=%0d", nfiles, file_no);
        $display(" BY=%0d  WD=%0d  OV=%0d", nbytes, nwords, err_ov);
        $display(" load_ok=%0d  stage=%0d", load_ok, stage);
        $display(" rcnt=%0d hdr_total=%0d hdr_chk=%h chk_v=%h",
                 dut.rcnt, dut.hdr_total, dut.hdr_chk, dut.chk_v);
        $display("=================================================");

        // dump 前 nwords 个 256 位字
        fdump = $fopen("ddr_dump.bin", "wb");
        for (k = 0; k < nwords; k = k + 1) begin
            $fwrite(fdump, "%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c",
                MEM[8*k][7:0],   MEM[8*k][15:8],  MEM[8*k][23:16], MEM[8*k][31:24],
                MEM[8*k][39:32], MEM[8*k][47:40], MEM[8*k][55:48], MEM[8*k][63:56],
                MEM[8*k][71:64], MEM[8*k][79:72], MEM[8*k][87:80], MEM[8*k][95:88],
                MEM[8*k][103:96],MEM[8*k][111:104],MEM[8*k][119:112],MEM[8*k][127:120],
                MEM[8*k][135:128],MEM[8*k][143:136],MEM[8*k][151:144],MEM[8*k][159:152],
                MEM[8*k][167:160],MEM[8*k][175:168],MEM[8*k][183:176],MEM[8*k][191:184],
                MEM[8*k][199:192],MEM[8*k][207:200],MEM[8*k][215:208],MEM[8*k][223:216],
                MEM[8*k][231:224],MEM[8*k][239:232],MEM[8*k][247:240],MEM[8*k][255:248]);
        end
        $fclose(fdump);

        if (load_ok !== 1'b1) begin
            $display("*** 失败: load_ok != 1 ***");
            errors = errors + 1;
        end

        if (errors == 0) $display("=== TB PASS ===");
        else             $display("=== TB FAIL (%0d) ===", errors);

        $finish;
    end

    // 超时保护
    initial begin
        #200_000_000;
        $display("*** TIMEOUT ***  stage=%0d nbytes=%0d nwords=%0d", stage, nbytes, nwords);
        $finish;
    end

    //------------------------------------------------ 调试探针
    reg [3:0] st_prev = 4'hF;
    reg [3:0] pst_prev = 4'hF;
    reg [31:0] nb_prev = 32'hFFFFFFFF;
    always @(posedge clk100) begin
        if (dut.st !== st_prev) begin
            $display("[%0t] 100M st=%0d -> %0d (end_cnt=%0d found_q=%0d rempty=%0d)",
                     $time, st_prev, dut.st, dut.end_cnt, dut.found_q, dut.u_fifo.rempty);
            st_prev = dut.st;
        end
        if (nbytes !== nb_prev) begin
            if (nbytes < 32'd5 || (nbytes % 32'd1000) == 0)
                $display("[%0t] nbytes=%0d", $time, nbytes);
            nb_prev = nbytes;
        end
    end

endmodule

`default_nettype wire
