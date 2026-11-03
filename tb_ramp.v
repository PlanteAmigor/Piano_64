//==========================================================================
//  tb_ramp —— 证明 add_voice8 的 ramp 在 vel_gain=255 时 8 位回绕
//
//  旧写法：if (ramp < vel_gain) ramp <= ramp + 8'd2;
//          ramp=254、vel_gain=255 → 254+2 = 256 → 截断成 0
//          → 又 +2/+2 爬回 254 → 在 0↔254 间锯齿，周期 128 样点
//          → 48828/128 = 381 Hz 锯齿噪声。
//  只在手指贴近光敏管、opt_vel 饱和到 255 时出现；
//  唢呐/笛子走 add_engine_harm，没有 ramp，所以没这个现象。
//==========================================================================
`timescale 1ns/1ps

module tb_ramp;

localparam integer FS = 48828;

integer errs = 0;

//--------------------------------------------------------------------
task automatic run_case(input integer vel_gain, input integer mode,
                        output integer wraps, output integer minv,
                        output integer maxv);
    integer n;
    reg [7:0] ramp;
    reg [8:0] nx;
    begin
        ramp = 8'd0;
        wraps = 0;
        minv = 999; maxv = 0;
        for (n = 0; n < 2000; n = n + 1) begin
            nx = {1'b0, ramp} + 9'd2;
            if (mode == 0) begin
                // ---- 旧写法（8 位加法）----
                if (ramp < vel_gain[7:0]) begin
                    if (nx[8]) wraps = wraps + 1;      // 跨过 255 的次数
                    ramp = nx[7:0];
                end
                else if (ramp > vel_gain[7:0]) ramp = ramp - 8'd1;
            end
            else begin
                // ---- 新写法（9 位中间量 + 夹到目标）----
                if (ramp < vel_gain[7:0])
                    ramp = (nx >= {1'b0, vel_gain[7:0]}) ? vel_gain[7:0] : nx[7:0];
                else if (ramp > vel_gain[7:0]) ramp = ramp - 8'd1;
            end
            if (n > 400) begin
                if (ramp < minv) minv = ramp;
                if (ramp > maxv) maxv = ramp;
            end
        end
    end
endtask

integer w_old, w_new, mn, mx;
real    freq_old;

initial begin
    $display("=== add_voice8 ramp 收敛测试（vel_gain=255，跑 2000 个样点）===");

    run_case(255, 0, w_old, mn, mx);
    freq_old = w_old * 1.0 * FS / 2000.0;
    $display("  旧写法：回绕 %0d 次，稳态范围 %0d..%0d，锯齿频率约 %0.0f Hz",
             w_old, mn, mx, freq_old);
    if (w_old == 0) begin
        $display("      FAIL: 没复现出回绕"); errs = errs + 1;
    end
    if (mn > 50) begin
        $display("      FAIL: 应该掉到很低的值"); errs = errs + 1;
    end

    run_case(255, 1, w_new, mn, mx);
    $display("  新写法：回绕 %0d 次，稳态范围 %0d..%0d", w_new, mn, mx);
    if (w_new != 0) begin $display("      FAIL: 新写法不该回绕"); errs = errs + 1; end
    if (mn != 255)  begin $display("      FAIL: 应该稳定在 255"); errs = errs + 1; end

    // 顺便验证其他力度值仍然收敛正确
    run_case(200, 1, w_new, mn, mx);
    $display("  vel_gain=200：稳态范围 %0d..%0d（应为 200..200）", mn, mx);
    if (mn != 200 || mx != 200) begin $display("      FAIL: 没收敛到 200"); errs = errs + 1; end

    run_case(120, 1, w_new, mn, mx);
    $display("  vel_gain=120：稳态范围 %0d..%0d（应为 120..120）", mn, mx);
    if (mn != 120 || mx != 120) begin $display("      FAIL: 没收敛到 120"); errs = errs + 1; end

    $display("==== %0d FAIL ====", errs);
    $finish;
end

endmodule
