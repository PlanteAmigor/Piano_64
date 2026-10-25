//==========================================================================
//  tb_engine_harm —— 4 声部全流水引擎的基准测试
//
//  只让声部 0 弹 MIDI 67，其余静音，输出与 add_voice_harm（已验证 34 dB）
//  的结果逐样点对比 —— 两套 RTL 用不同的表格式和完全不同的调度，
//  能对上就说明流水引擎的寻址/流水/定标全对。
//==========================================================================
`timescale 1ns/1ps

module tb_engine_harm;

    localparam integer NVOICE = 4;
    localparam integer NPC    = 3000;

    reg clk = 1'b0, rst_n = 1'b0;
    always #10 clk = ~clk;

    reg [NVOICE*7-1:0] v_note;
    reg [NVOICE-1:0]   v_trig = {NVOICE{1'b0}};
    reg [NVOICE-1:0]   v_gate = {NVOICE{1'b0}};
    wire signed [15:0] sl, sr;
    wire [NVOICE-1:0]  vidle;

    // 帧计数：与引擎内部 cnt 同时复位、同周期 → 天然对齐
    reg [9:0] tcnt = 10'd0;
    always @(posedge clk) tcnt <= (tcnt == 10'd1023) ? 10'd0 : tcnt + 10'd1;
    wire tick = (tcnt == 10'd1000);          // 引擎 1 声部约 74 拍就完了，取 1000 稳

    add_engine_harm #(
        .NVOICE(NVOICE), .NOTE_LO(67), .NOTE_HI(91),
        .TIMBRE(2), .MIX_SHIFT(0), .SOFT(0)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .v_note(v_note), .v_trig(v_trig), .v_gate(v_gate),
        .sample_tick(tick),
        .sample_l(sl), .sample_r(sr), .v_idle(vidle)
    );

    integer fd, n = 0;
    initial fd = $fopen("engine_sim_out.txt", "w");
    always @(posedge clk) begin
        if (rst_n && tick) begin
            $fwrite(fd, "%0d\n", sl);
            n = n + 1;
        end
    end

    integer cyc = 0;
    always @(posedge clk) if (rst_n) cyc <= cyc + 1;

    initial begin
        v_note = {NVOICE*7{1'b0}};
        v_note[6:0] = 7'd67;                 // 只有声部 0 用
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);
        v_trig[0] = 1'b1;
        repeat (3) @(posedge clk);
        v_trig[0] = 1'b0;

        wait (n >= NPC);
        repeat (20) @(posedge clk);
        $fclose(fd);
        $display("### 采样点 %0d，周期 %0d", n, cyc);
        $display("### v_idle=%b", vidle);
        $finish;
    end

endmodule
