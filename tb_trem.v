//==========================================================================
//  tb_trem —— position_control 的 G5 指颤检测（左右大幅快速摇手）
//
//  判据：x_ac（原始质心 − 慢速 x_dc）的【过零间隔】落在 5~20 帧
//        （帧率 83.3 Hz → 2.1~8.3 Hz），且幅度 > 1.5 cm。
//        单向滑音只产生一次过零 → 不会误触发。
//
//  单位：x_q8 = 256 × cm；帧率 83.3 Hz（仿真里每帧压成 100 个时钟）
//==========================================================================
`timescale 1ns/1ps

module tb_trem;

localparam integer FRAMES_PER_S = 83;
localparam real    CMQ8 = 256.0;

reg         clk = 0;
reg         rst_n = 0;
reg         frame_valid = 0;
reg  [15:0] x_q8 = 16'd1894;
reg         x_valid = 1;
reg  signed [23:0] rho_dc = 24'sd12000;

wire signed [15:0] bend;
wire        [7:0]  vel;
wire        [15:0] bend_q14;
wire               trem_en;

position_control u_dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .frame_valid (frame_valid),
    .x_q8        (x_q8),
    .x_valid     (x_valid),
    .rho_dc      (rho_dc),
    .bend        (bend),
    .vel         (vel),
    .bend_q14    (bend_q14),
    .trem_en     (trem_en)
);

always #10 clk = ~clk;

integer errs = 0;
integer hits;
integer k;

// 送一帧：x 由外部先设好
task automatic one_frame;
    begin
        @(posedge clk); frame_valid <= 1'b1;
        @(posedge clk); frame_valid <= 1'b0;
        repeat (3) @(posedge clk);
    end
endtask

// 静止若干帧，同时统计 trem_en 为 1 的帧数
task automatic run_static(input integer n, output integer h);
    integer i;
    begin
        h = 0;
        for (i = 0; i < n; i = i + 1) begin
            one_frame;
            if (trem_en) h = h + 1;
        end
    end
endtask

// 摇手若干帧（freq Hz，amp cm），统计最后 1/3 时间里 trem_en=1 的比例
task automatic run_shake(input real fhz, input real amp_cm, input integer n,
                         output integer h, output integer tot);
    integer i;
    real    ph;
    begin
        h = 0; tot = 0;
        for (i = 0; i < n; i = i + 1) begin
            ph = 2.0 * 3.14159265 * fhz * (i * 1.0) / (FRAMES_PER_S * 1.0);
            x_q8 = 16'd1894 + $rtoi(amp_cm * CMQ8 * $sin(ph));
            one_frame;
            if (i > n/3) begin
                tot = tot + 1;
                if (trem_en) h = h + 1;
            end
        end
    end
endtask

real    duty;
integer hh, tt;

initial begin
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    $display("=== G5 指颤检测（帧率约 83 Hz）===");

    // ---- 1. 手不动 ----
    x_q8 = 16'd1894;
    run_static(120, hh);
    $display("[1] 静止          trem_en=1 的帧数 %0d / 120", hh);
    if (hh != 0) begin $display("    FAIL: 静止不该触发"); errs = errs + 1; end

    // ---- 2. 慢速单向滑动 1000 → 3000（约 0.8 s）----
    begin : slide
        integer i;
        hh = 0;
        for (i = 0; i < 70; i = i + 1) begin
            x_q8 = 16'd1000 + i * 16'd28;
            one_frame;
            if (trem_en) hh = hh + 1;
        end
    end
    $display("[2] 慢速单向滑动   trem_en=1 的帧数 %0d / 70", hh);
    if (hh != 0) begin $display("    FAIL: 滑音不该触发"); errs = errs + 1; end

    // ---- 3. 6 Hz ±3 cm（指颤）----
    run_shake(6.0, 3.0, 180, hh, tt);
    duty = hh * 100.0 / tt;
    $display("[3] 6 Hz +/-3cm    占比 %0.1f%%（应接近 100%%）", duty);
    if (duty < 90.0) begin $display("    FAIL: 6 Hz 摇手应该触发"); errs = errs + 1; end

    // ---- 4. 摇完停下来：允许一小段尾（约 25 帧 ≈ 0.3 s），后半段必须为 0 ----
    begin : stopchk
        integer i, tail, late;
        tail = 0; late = 0; i = 0;
        for (i = 0; i < 120; i = i + 1) begin
            one_frame;
            if (trem_en) begin
                tail = tail + 1;
                if (i >= 60) late = late + 1;
            end
        end
        $display("[4] 摇完停住      尾巴 %0d 帧（≤30 可用），后半段 %0d 帧", tail, late);
        if (tail > 30) begin $display("    FAIL: 退出太慢"); errs = errs + 1; end
        if (late != 0) begin $display("    FAIL: 后半段应完全退出"); errs = errs + 1; end
    end

    // ---- 5. 2.5 Hz ±3 cm（慢摇，仍在窗口内）----
    run_shake(2.5, 3.0, 240, hh, tt);
    duty = hh * 100.0 / tt;
    $display("[5] 2.5 Hz +/-3cm   占比 %0.1f%%（应触发）", duty);
    if (duty < 80.0) begin $display("    FAIL: 2.5 Hz 应该触发"); errs = errs + 1; end

    // ---- 6. 6 Hz 但只 ±0.8 cm（幅度不够，等同噪声）----
    run_shake(6.0, 0.8, 180, hh, tt);
    duty = hh * 100.0 / tt;
    $display("[6] 6 Hz +/-0.8cm   占比 %0.1f%%（不该触发）", duty);
    if (duty > 5.0) begin $display("    FAIL: 幅度不足不该触发"); errs = errs + 1; end

    // ---- 7. 12 Hz 快速抖动（超出窗口上限）----
    run_shake(12.0, 3.0, 180, hh, tt);
    duty = hh * 100.0 / tt;
    $display("[7] 12 Hz +/-3cm    占比 %0.1f%%（不该触发，超出窗口）", duty);
    if (duty > 5.0) begin $display("    FAIL: 12 Hz 不该触发"); errs = errs + 1; end

    $display("==== %0d FAIL ====", errs);
    $finish;
end

endmodule
