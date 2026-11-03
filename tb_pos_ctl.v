//==========================================================================
//  tb_pos_ctl —— position_control 单元测试
//  验证：x 质心 → 弯音（音分 + Q2.14 音高比）、rho → 力度
//==========================================================================
`timescale 1ns/1ps

module tb_pos_ctl;

reg         clk = 0;
reg         rst_n = 0;
reg         frame_valid = 0;
reg  [15:0] x_q8 = 16'd1894;
reg         x_valid = 0;
reg  signed [23:0] rho_dc = 24'sd2000;

wire signed [15:0] bend;
wire        [7:0]  vel;
wire        [15:0] bend_q14;

position_control u_dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .frame_valid (frame_valid),
    .x_q8        (x_q8),
    .x_valid     (x_valid),
    .rho_dc      (rho_dc),
    .bend        (bend),
    .vel         (vel),
    .bend_q14    (bend_q14)
);

always #10 clk = ~clk;      // 50 MHz

// 一帧 = 12 ms（83.3 Hz），仿真时压缩成 200 个时钟便于观察
task automatic frame(input [15:0] xv, input signed [23:0] rv, input xok);
    integer i;
    begin
        x_q8    = xv;
        rho_dc  = rv;
        x_valid = xok;
        for (i = 0; i < 200; i = i + 1) begin
            @(posedge clk);
            frame_valid <= 1'b1;
            @(posedge clk);
            frame_valid <= 1'b0;
        end
    end
endtask

integer errs = 0;
real    ratio_expect;

initial begin
    $dumpfile("/mnt/project/InstruementSound/.tmp/tb_pos_ctl.vcd");
    $dumpvars(0, tb_pos_ctl);

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // ---- 1. 手在正中 7.40 cm，rho 很大 ----
    frame(16'd1894, 24'sd24000, 1'b1);
    $display("[1] x=7.40cm  bend=%0d  bend_q14=%0d  vel=%0d", bend, bend_q14, vel);
    if (bend > 5 || bend < -5) begin
        $display("    FAIL: 正中应该 bend≈0"); errs = errs + 1;
    end

    // ---- 2. 手在 10 cm ----
    frame(16'd2560, 24'sd24000, 1'b1);
    ratio_expect = 2.0 ** (351.0/1200.0) * 16384.0;
    $display("[2] x=10.0cm bend=%0d  bend_q14=%0d (期望 %0.0f)  vel=%0d",
             bend, bend_q14, ratio_expect, vel);
    if (bend < 300 || bend > 400) begin
        $display("    FAIL: 应该约 +351 音分"); errs = errs + 1;
    end

    // ---- 3. 手在 2.2 cm（左端）----
    frame(16'd563, 24'sd24000, 1'b1);
    $display("[3] x=2.2cm  bend=%0d  bend_q14=%0d  vel=%0d", bend, bend_q14, vel);
    if (bend > -600 || bend < -700) begin
        $display("    FAIL: 应该约 -700 音分"); errs = errs + 1;
    end

    // ---- 4. 手拿开（rho 低于门限）----
    frame(16'd1894, 24'sd2000, 1'b0);
    $display("[4] 手拿开   bend=%0d  vel=%0d", bend, vel);
    if (vel > 4) begin
        $display("    FAIL: 手拿开 vel 应该≈0"); errs = errs + 1;
    end

    // ---- 5. 近距离 rho 很大，看力度是否饱和 ----
    frame(16'd1894, 24'sd24000, 1'b1);
    $display("[5] rho=24000 vel=%0d（应接近 255）", vel);
    if (vel < 240) begin
        $display("    FAIL: 力度应该饱和"); errs = errs + 1;
    end

    // ---- 6. 中距离 rho=11000（≈4cm）----
    frame(16'd1894, 24'sd11000, 1'b1);
    $display("[6] rho=11000 vel=%0d（≈4cm，期望 100~130）", vel);
    if (vel < 90 || vel > 140) begin
        $display("    FAIL: 力度区间不对"); errs = errs + 1;
    end

    // ---- 7. 稀疏有效帧：每 4 帧才 1 帧 x_valid（现场就是这个情况）----
    //      旧写法只在有效帧滤波 → 收敛慢 4~8 倍 → 看起来完全没反应
    begin
        integer i;
        x_q8   = 16'd2560;
        rho_dc = 24'sd24000;
        for (i = 0; i < 200; i = i + 1) begin
            @(posedge clk);
            frame_valid <= 1'b1;
            x_valid     <= ((i % 4) == 0);   // 25% 有效
            @(posedge clk);
            frame_valid <= 1'b0;
            x_valid     <= ((i % 4) == 1);
        end
    end
    $display("[7] 稀疏有效帧(25%%) x=10cm bend=%0d（期望 ≈+351）", bend);
    if (bend < 300 || bend > 400) begin
        $display("    FAIL: 稀疏有效帧下弯音没跟上去"); errs = errs + 1;
    end

    if (errs == 0) $display("\n==== ALL PASS ====");
    else           $display("\n==== %0d FAIL ====", errs);
    $finish;
end

endmodule
