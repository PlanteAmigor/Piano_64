//==========================================================================
//  tb_harm_hw —— 唢呐引擎端到端仿真（DDR 取表 → BSRAM → 合成 → 输出）
//
//  目的：把硬件实际会算出的 sample 序列 dump 出来，与
//        out/suona/合成/AB_前后_M071_B4.wav 对比，
//        判断「嘟嘟声」是 RTL 算错还是数据流问题。
//
//  跑法（工程根目录）：
//    iverilog -g2012 -DSIM_INIT -o ../.tmp/simpd/tb_harm_hw.vvp -s tb_harm_hw \
//        src/add_engine_harm.v src/harm_buf.v src/suona_dma.v src/mix_sum.v \
//        sim/tb_harm_hw.v
//    vvp ../.tmp/simpd/tb_harm_hw.vvp
//==========================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_harm_hw;

    localparam integer NSMP = 147000;   // 约 3.01 s

    reg clk    = 1'b0;
    reg clk100 = 1'b0;
    always #10   clk    = ~clk;          // 50 MHz
    always #5.0  clk100 = ~clk100;       // 100 MHz

    reg rst_n    = 1'b0;
    reg rst100_n = 1'b0;

    //------------------------------------------------ DDR 模型
    reg [255:0] MEM [0:32767];
    initial $readmemh("../.tmp/simpd/p64_full.hex", MEM);

    reg         m_busy  = 1'b0;
    reg [4:0]   m_cnt   = 5'd0;
    reg [28:0]  m_addr  = 29'd0;
    reg         m_valid = 1'b0;
    reg [255:0] m_data  = 256'd0;

    wire [2:0]   app_cmd;
    wire         app_en;
    wire [28:0]  app_addr;
    wire         app_rdy = ~m_busy;
    wire         app_rd_data_valid = m_valid;
    wire [255:0] app_rd_data = m_data;

    always @(posedge clk100) begin
        m_valid <= 1'b0;
        if (app_en && app_rdy) begin
            m_busy <= 1'b1;
            m_addr <= app_addr;
            m_cnt  <= 5'd0;
        end
        else if (m_busy) begin
            m_cnt <= m_cnt + 5'd1;
            if (m_cnt == 5'd5) begin
                m_data  <= MEM[m_addr[16:3]];   // app_addr 是字节地址
                m_valid <= 1'b1;
                m_busy  <= 1'b0;
            end
        end
    end

    //------------------------------------------------ DUT
    reg  [3:0]  v_trig = 4'd0;
    reg  [27:0] v_note;
    wire signed [15:0] sample_l, sample_r;
    wire [3:0]  v_idle;
    reg  [31:0] v_vel;

    initial begin
        v_note = {4{7'd71}};
        v_vel  = {4{8'd200}};
    end

    add_engine_harm #(
        .NVOICE    (4),
        .NOTE_LO   (69),
        .NOTE_HI   (96),
        .TIMBRE    (3),
        .MIX_SHIFT (2),
        .SOFT      (1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .v_note(v_note), .v_trig(v_trig), .v_gate(4'hF), .v_vel(v_vel),
        .sample_tick(1'b0),
        .sample_l(sample_l), .sample_r(sample_r),
        .v_idle(v_idle),
        .clk100(clk100), .rst100_n(rst100_n),
        .app_cmd(app_cmd), .app_en(app_en), .app_addr(app_addr),
        .app_rdy(app_rdy),
        .app_rd_data_valid(app_rd_data_valid),
        .app_rd_data(app_rd_data)
    );

    //------------------------------------------------ 激励
    initial begin
        rst_n = 1'b0; rst100_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1; rst100_n = 1'b1;
        repeat (10) @(negedge clk);
        v_trig[0] = 1'b1;
        @(negedge clk);
        v_trig[0] = 1'b0;
    end

    //------------------------------------------------ 诊断
    integer dbg_t;
    initial begin
        for (dbg_t = 0; dbg_t < 8; dbg_t = dbg_t + 1) begin
            #50000;
            $display("t=%0d act=%b pend=%b quiet=%b busy=%b st=%0d seg=%0d sdst=%0d done_p=%b dma_done=%b",
                     dbg_t, dut.v_act[0], dut.sd_pend, dut.quiet, dut.sd_busy,
                     dut.st, dut.u_sdma.seg, dut.u_sdma.st, dut.dma_done_p, dut.done_tog_w);
        end
    end

    //------------------------------------------------ 每样点 dump
    integer f, k;

    initial begin
        f = $fopen("harm_hw_dump.txt", "w");
        k = 0;
    end

    always @(posedge clk) begin
        if (rst_n && dut.cnt == 10'd0) begin
            if (k < NSMP) begin
                $fwrite(f, "%0d\n", $signed(dut.smp));
                k = k + 1;
                // 进度（每 2000 样点 ≈ 0.041 s 一次；整个 3 s 仿真约 15~20 min）
                if (k % 2000 == 0)
                    $display("  ... %0d / %0d 样点 (%.2f s)", k, NSMP, k/48828.125);
            end
            else if (k == NSMP) begin
                $fclose(f);
                $display("DUMP done: %0d samples", NSMP);
                $finish;
                k = k + 1;
            end
        end
    end

endmodule

`default_nettype wire
