//==========================================================================
//  tb_vib —— G3 颤音检测的【整链】仿真
//
//  opt_feat（rho_raw/rho_dc/rho_ac/ac_env/half_period）→ position_control
//  → vib_en
//
//  判据：
//    频率：half_period ∈ [5,11] 帧 ⇒ 3.8~8.3 Hz（83.3 Hz 帧率）
//    幅度：ac_env > rho_dc/8（摆动 > 12.5%）
//    互斥：trem_en（G5 左右摇）优先
//
//  合成信号：六路 diff 各 = 基值 + 摇动，rho 基值取手在 4 cm 的实测值 9491。
//==========================================================================
`timescale 1ns/1ps

module tb_vib;

localparam integer NCH   = 6;
localparam integer CLKPF = 200;        // 每帧压成 200 个时钟（内部都按帧计数，无影响）

reg clk = 0;
reg rst_n = 0;
always #10 clk = ~clk;

reg              frame_valid = 0;
reg  [NCH*18-1:0] raw_flat = 0;
reg  [15:0]      x_q8   = 16'd1894;
reg              x_valid = 1;

wire signed [23:0] rho_raw, rho_dc, rho_ac, ac_env;
wire [15:0] half_period, feat_fcnt;

opt_feat #(.NCH(NCH)) u_feat (
    .clk         (clk),
    .rst_n       (rst_n),
    .frame_valid (frame_valid),
    .raw_flat    (raw_flat),
    .rho_raw     (rho_raw),
    .rho_dc      (rho_dc),
    .rho_ac      (rho_ac),
    .ac_env      (ac_env),
    .half_period (half_period),
    .frame_cnt   (feat_fcnt)
);

wire signed [15:0] bend;
wire        [7:0]  vel;
wire        [15:0] bend_q14;
wire               trem_en;
wire               vib_en;

position_control u_ctl (
    .clk         (clk),
    .rst_n       (rst_n),
    .frame_valid (frame_valid),
    .x_q8        (x_q8),
    .x_valid     (x_valid),
    .rho_dc      (rho_dc),
    .rho_ac      (rho_ac),
    .ac_env      (ac_env),
    .half_period (half_period),
    .bend        (bend),
    .vel         (vel),
    .bend_q14    (bend_q14),
    .trem_en     (trem_en),
    .vib_en      (vib_en)
);

//----------------------------------------------------------------------
//  一帧：raw_flat 由外部先算好
//----------------------------------------------------------------------
task automatic one_frame;
    begin
        @(posedge clk); frame_valid <= 1'b1;
        @(posedge clk); frame_valid <= 1'b0;
        repeat (CLKPF) @(posedge clk);
    end
endtask

// base_per_ch：每路基值；amp_frac：摇动幅度（占基值比例）；fhz：频率
task automatic run_shake(input real base_per_ch, input real amp_frac,
                         input real fhz, input integer n,
                         output integer hits, output integer tot, output integer warm);
    integer i, c;
    real    ph, v;
    begin
        hits = 0; tot = 0; warm = 0;
        for (i = 0; i < n; i = i + 1) begin
            ph = 2.0 * 3.14159265 * fhz * i / 83.3;
            v  = base_per_ch * (1.0 + amp_frac * $sin(ph));
            for (c = 0; c < NCH; c = c + 1)
                raw_flat[c*18 +: 18] = $rtoi(v);
            one_frame;
            if (i > 120) begin          // 跳过 IIR 稳定过程
                tot = tot + 1;
                if (vib_en) hits = hits + 1;
                if (dbg && tot < 45)
                    $display("      i=%0d rho_dc=%0d rho_ac=%0d ac_env=%0d thr=%0d hp=%0d vib=%0d",
                             i, rho_dc, rho_ac, ac_env, (rho_dc>>>3), half_period, vib_en);
            end
        end
    end
endtask

integer h, t, w;
real    duty;
integer dbg = 0;

initial begin
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    $display("=== G3 颤音检测整链仿真（rho 基值 = 9491 码，即手在 4 cm）===");
    $display("    rho_dc 大约在第 120 帧后稳定，统计只算稳定后的");

    // ---- 1. 手不动 ----
    run_shake(9491.0/6.0, 0.0, 5.0, 400, h, t, w);
    duty = (t > 0) ? h * 100.0 / t : 0.0;
    $display("[1] 静止         vib_en 占比 %0.1f%%（应该 0）", duty);
    if (h != 0) begin $display("    FAIL: 静止不该触发"); errs = errs + 1; end

    // ---- 2. 5 Hz，幅度 20%（上下轻摇，应该触发）----
    run_shake(9491.0/6.0, 0.20, 5.0, 500, h, t, w);
    duty = h * 100.0 / t;
    $display("[2] 5 Hz +/-20%% 占比 %0.1f%%（应该接近 100%%）", duty);
    if (duty < 80.0) begin $display("    FAIL: 5 Hz/20%% 应该触发"); errs = errs + 1; end

    // ---- 3. 5 Hz，幅度只有 5%（太小，不该触发）----
    run_shake(9491.0/6.0, 0.05, 5.0, 400, h, t, w);
    duty = h * 100.0 / t;
    $display("[3] 5 Hz +/-5%%  占比 %0.1f%%（不该触发）", duty);
    if (duty > 5.0) begin $display("    FAIL: 幅度不足不该触发"); errs = errs + 1; end

    // ---- 4. 2 Hz（太慢，不该触发）----
    run_shake(9491.0/6.0, 0.20, 2.0, 500, h, t, w);
    duty = h * 100.0 / t;
    $display("[4] 2 Hz +/-20%% 占比 %0.1f%%（不该触发，低于窗口）", duty);
    if (duty > 10.0) begin $display("    FAIL: 2 Hz 不该触发"); errs = errs + 1; end

    // ---- 5. 12 Hz（太快，超出窗口）----
    run_shake(9491.0/6.0, 0.20, 12.0, 500, h, t, w);
    duty = h * 100.0 / t;
    $display("[5] 12 Hz +/-20%% 占比 %0.1f%%（不该触发，高于窗口）", duty);
    if (duty > 10.0) begin $display("    FAIL: 12 Hz 不该触发"); errs = errs + 1; end

    // ---- 6. 7 Hz 幅度 30%（窗口内，应该触发）----
    run_shake(9491.0/6.0, 0.30, 7.0, 500, h, t, w);
    duty = h * 100.0 / t;
    $display("[6] 7 Hz +/-30%% 占比 %0.1f%%（应该触发）", duty);
    if (duty < 80.0) begin $display("    FAIL: 7 Hz/30%% 应该触发"); errs = errs + 1; end

    $display("==== %0d FAIL ====", errs);
    $finish;
end

integer errs = 0;

endmodule
