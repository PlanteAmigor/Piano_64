//==========================================================================
//  tb_engine4 —— 4 声部同时发声
//
//  4 个声部都弹 MIDI 67、同一时刻触发 → 每个谐波的贡献完全一样，
//  内部 acc 必然正好是单声部的 4 倍。取 MIX_SHIFT=2（输出 /4），
//  结果应与「单声部 + MIX_SHIFT=0」逐点一致 —— 任何一点对不上，
//  都说明 4 声部的调度/累加有问题。
//
//  顺便验证时序：4 声部 × K=62 = 248 谐波 + 24 前置 + 6 排空 = 278 拍 < 1024。
//==========================================================================
`timescale 1ns/1ps

module tb_eng_v3;

    localparam integer NVOICE = 4;
    localparam integer NPC    = 3000;

    reg clk = 1'b0, rst_n = 1'b0;
    always #10 clk = ~clk;

    reg [NVOICE*7-1:0] v_note;
    reg [NVOICE-1:0]   v_trig = {NVOICE{1'b0}};
    reg [NVOICE-1:0]   v_gate = {NVOICE{1'b0}};
    wire signed [15:0] sl, sr;
    wire [NVOICE-1:0]  vidle;

    reg [9:0] tcnt = 10'd0;
    always @(posedge clk) tcnt <= (tcnt == 10'd1023) ? 10'd0 : tcnt + 10'd1;
    wire tick = (tcnt == 10'd1000);

    add_engine_harm #(
        .NVOICE(NVOICE), .NOTE_LO(67), .NOTE_HI(91),
        .TIMBRE(2), .MIX_SHIFT(2), .SOFT(0)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .v_note(v_note), .v_trig(v_trig), .v_gate(v_gate),
        .sample_tick(tick),
        .sample_l(sl), .sample_r(sr), .v_idle(vidle)
    );

    integer fd, n = 0;
    initial fd = $fopen("eng_v3.txt", "w");
    always @(posedge clk) begin
        if (rst_n && tick) begin
            $fwrite(fd, "%0d\n", sl);
            n = n + 1;
        end
    end

    // 记录每个样点调度用了多少拍（验证时序预算）
    reg [9:0] max_use = 10'd0;
    reg [9:0] t_start = 10'd0;
    reg       running = 1'b0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.cnt == 10'd0) begin
                if (running && (tcnt_now - t_start) > max_use) max_use <= tcnt_now - t_start;
                running <= 1'b0;
            end
            if (dut.st != 2'd0 && !running) begin
                running  <= 1'b1;
                t_start  <= tcnt_now;
            end
            if (dut.st == 2'd0 && running) begin
                if ((tcnt_now - t_start) > max_use) max_use <= tcnt_now - t_start;
                running <= 1'b0;
            end
        end
    end
    reg [9:0] tcnt_now = 10'd0;
    always @(posedge clk) tcnt_now <= tcnt;

    initial begin
        v_note = {7'd85, 7'd79, 7'd72, 7'd67};
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);
        v_trig = 4'b1000;
        repeat (3) @(posedge clk);
        v_trig = {NVOICE{1'b0}};

        wait (n >= NPC);
        repeat (20) @(posedge clk);
        $fclose(fd);
        $display("### 4 声部：采样点 %0d，单样点最多用了 %0d 拍（预算 1024）", n, max_use);
        $finish;
    end

endmodule
