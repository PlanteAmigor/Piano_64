//==========================================================================
//  tb_art —— G7 顿音 / G8 急停 检测
//
//  判据（position_control 里）：
//    dv = (rho_raw[n] − rho_raw[n−2]) / 2     每帧
//    dv_up = dv > +700，dv_dn = dv < −700      （码/帧）
//    先相反方向有过大变化（6 帧内）→ 顿音 art_pulse
//    只有单纯快速下降            → 急停 stop_pulse
//
//  实测标定：ρ 每 cm 变化量
//    1→2 cm  7696 码/cm   ← 近距离极敏感
//    2→4 cm  5616 码/cm
//    4→10cm   373 码/cm
//  所以近距离（音量最大时）信号最大，反而最容易触发。
//==========================================================================
`timescale 1ns/1ps

module tb_art;

reg clk = 0;
reg rst_n = 0;
always #10 clk = ~clk;

reg frame_valid = 0;
reg [15:0] x_q8 = 16'd1894;
reg x_valid = 1;
reg signed [23:0] rho_raw = 24'sd9491;
reg signed [23:0] rho_dc  = 24'sd9491;
reg signed [23:0] rho_ac  = 24'sd0;

wire signed [15:0] bend;
wire        [7:0]  vel;
wire        [15:0] bend_q14;
wire trem_en, vib_en, art_pulse, stop_hold, hand_on;

position_control u_dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .frame_valid (frame_valid),
    .x_q8        (x_q8),
    .x_valid     (x_valid),
    .rho_dc      (rho_dc),
    .rho_raw     (rho_raw),
    .rho_ac      (rho_ac),
    .ac_env      (24'sd0),
    .half_period (16'd0),
    .bend        (bend),
    .vel         (vel),
    .bend_q14    (bend_q14),
    .trem_en     (trem_en),
    .vib_en      (vib_en),
    .art_pulse   (art_pulse),
    .stop_hold   (stop_hold),
    .hand_on     (hand_on)
);

integer errs = 0;
integer n_art, n_stop;

task automatic one_frame;
    begin
        @(posedge clk); frame_valid <= 1'b1;
        @(posedge clk); frame_valid <= 1'b0;
        if (art_pulse)  n_art  = n_art  + 1;
        if (stop_hold)  n_stop = n_stop + 1;
        repeat (3) @(posedge clk);
    end
endtask

// 线性爬升/下降 n 帧
task automatic ramp_to(input integer from, input integer to_v, input integer n);
    integer i;
    begin
        for (i = 1; i <= n; i = i + 1) begin
            rho_raw = from + (to_v - from) * i / n;
            one_frame;
        end
    end
endtask

integer i;

initial begin
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
    $display("=== G7 顿音 / G8 急停 检测（阈值 ±700 码/帧）===");

    // ---- 1. 静止 ----
    n_art = 0; n_stop = 0;
    rho_raw = 24'sd9491;
    for (i = 0; i < 60; i = i + 1) one_frame;
    $display("[1] 静止            art=%0d stop=%0d（都应 0）", n_art, n_stop);
    if (n_art != 0 || n_stop != 0) begin $display("    FAIL"); errs = errs + 1; end

    // ---- 2. 慢速上升 2 cm（40 帧）——滑音，不该触发 ----
    n_art = 0; n_stop = 0;
    ramp_to(9491, 9491+11232, 40);
    $display("[2] 慢速上移 2cm    art=%0d stop=%0d（都应 0）", n_art, n_stop);
    if (n_art != 0 || n_stop != 0) begin $display("    FAIL: 滑音不该触发"); errs = errs + 1; end

    // ---- 3. 快速下压 3 帧再快速抬起 3 帧（顿音）----
    n_art = 0; n_stop = 0;
    ramp_to(20723, 28420, 3);      // 2 cm → 1 cm，3 帧
    ramp_to(28420, 20723, 3);      // 回来
    for (i = 0; i < 12; i = i + 1) one_frame;
    $display("[3] 快速压+抬(3帧)  art=%0d stop=%0d（art 应 1）", n_art, n_stop);
    if (n_art < 1) begin $display("    FAIL: 应该触发顿音"); errs = errs + 1; end

    // ---- 4. 只有快速抬手（急停）----
    //      判据现在是【相对量】rho_ac < −0.3125·rho_dc，不再看单帧斜率
    n_art = 0; n_stop = 0;
    rho_raw = 24'sd20723; rho_dc = 24'sd20723; rho_ac = 24'sd0;
    for (i = 0; i < 20; i = i + 1) one_frame;   // 稳定
    n_art = 0; n_stop = 0;
    // 手抽走：rho_raw 跌到 8675，慢基线还在 20723
    rho_raw = 24'sd8675; rho_ac = 24'sd8675 - 24'sd20723;
    for (i = 0; i < 12; i = i + 1) one_frame;
    $display("[4] 手抽走(2→6cm)   art=%0d stop=%0d（stop 应 1）", n_art, n_stop);
    if (n_stop < 1) begin $display("    FAIL: 应该触发急停"); errs = errs + 1; end
    if (n_art > 1)  begin $display("    FAIL: 不该同时报顿音"); errs = errs + 1; end
    // 基线跟上后 rho_ac 回 0，应重新武装
    rho_dc = 24'sd8675; rho_ac = 24'sd0;
    for (i = 0; i < 12; i = i + 1) one_frame;

    // ---- 5. 远距离（8 cm，灵敏度低 20 倍）也要能触发 ----
    n_art = 0; n_stop = 0;
    rho_raw = 24'sd7935;
    for (i = 0; i < 20; i = i + 1) one_frame;
    n_art = 0; n_stop = 0;
    ramp_to(7935, 13100, 3);       // 8 cm → 5 cm，3 帧
    ramp_to(13100, 7935, 3);
    for (i = 0; i < 12; i = i + 1) one_frame;
    $display("[5] 远距压+抬(8cm)  art=%0d stop=%0d（art 应 1）", n_art, n_stop);
    if (n_art < 1) begin $display("    FAIL: 远距离也应该能触发"); errs = errs + 1; end

    // ---- 6. 噪声 ±120 码 —— 不该触发 ----
    n_art = 0; n_stop = 0;
    rho_raw = 24'sd9491;
    for (i = 0; i < 300; i = i + 1) begin
        rho_raw = 24'sd9491 + (($random % 240));
        one_frame;
    end
    $display("[6] 噪声 +/-120     art=%0d stop=%0d（应接近 0）", n_art, n_stop);
    if (n_art > 2 || n_stop > 2) begin $display("    FAIL: 噪声不该触发"); errs = errs + 1; end

    // ---- 7. 5 Hz 上下轻摇（幅度 30%）—— G3 颤音，不该触发顿音/急停 ----
    //      30% 时 rho_ac 最低 −2847，阈值 −2966（0.3125×9491）→ 打不到
    n_art = 0; n_stop = 0;
    begin : vibchk
        integer k;
        real    ph, v;
        for (k = 0; k < 200; k = k + 1) begin
            ph = 2.0 * 3.14159265 * 5.0 * k / 83.3;
            v  = 9491.0 * (1.0 + 0.30 * $sin(ph));
            rho_raw = $rtoi(v);
            rho_dc  = 24'sd9491;
            rho_ac  = rho_raw - 24'sd9491;
            one_frame;
        end
    end
    $display("[7] 5 Hz 轻摇(30%%)  art=%0d stop=%0d（都应 0）", n_art, n_stop);
    if (n_art > 1 || n_stop > 1) begin
        $display("    FAIL: 颤音不该被当成顿音/急停"); errs = errs + 1;
    end

    // ---- 8. 手在不在（"有手才响"的判据，必须用即时 rho_raw）----
    n_art = 0; n_stop = 0;
    rho_raw = 24'sd9491; rho_dc = 24'sd9491; rho_ac = 24'sd0;
    for (i = 0; i < 6; i = i + 1) one_frame;
    $display("[8a] 手在(4cm)      hand_on=%0d（应 1）", hand_on);
    if (hand_on !== 1'b1) begin $display("    FAIL"); errs = errs + 1; end

    // 手抽走：rho_raw 掉到无手电平，注意 rho_dc 仍是慢基线（故意不跟着改）
    rho_raw = 24'sd2068; rho_ac = 24'sd2068 - 24'sd9491;
    for (i = 0; i < 5; i = i + 1) one_frame;
    $display("[8b] 手抽走        hand_on=%0d（应在 3 帧内变 0）", hand_on);
    if (hand_on !== 1'b0) begin $display("    FAIL: 手走了 hand_on 应该掉下来"); errs = errs + 1; end

    // 手回来
    rho_raw = 24'sd9491; rho_ac = 24'sd0;
    for (i = 0; i < 3; i = i + 1) one_frame;
    $display("[8c] 手回来        hand_on=%0d（应 1）", hand_on);
    if (hand_on !== 1'b1) begin $display("    FAIL: 手回来应该立刻恢复"); errs = errs + 1; end

    // 单帧毛刺不该让声音断：rho_raw 只掉 1 帧
    begin : glitch
        integer k;
        for (k = 0; k < 10; k = k + 1) begin
            rho_raw = (k == 4) ? 24'sd2068 : 24'sd9491;
            one_frame;
        end
    end
    $display("[8d] 单帧毛刺      hand_on=%0d（应仍 1，3 帧去抖）", hand_on);
    if (hand_on !== 1'b1) begin $display("    FAIL: 单帧毛刺不该断音"); errs = errs + 1; end

    $display("==== %0d FAIL ====", errs);
    $finish;
end

endmodule
