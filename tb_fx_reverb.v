//==========================================================================
//  tb_fx_reverb.v —— 逐样点导出 RTL 输出，交给 Python 定点模型比对
//
//  激励：n=0 处一个单位脉冲
//  长度：60000 样点（反馈 0.88、最短梳状 1236 → RT60 约 1.4 s ≈ 68000 样点，
//        6 万样点足够覆盖可听范围内的尾巴）
//  导出：每行 "n out_l out_r"
//
//  验证：tools/fx_reverb_check.py 用与 RTL 完全相同的定点算法重算
//==========================================================================
`timescale 1ns/1ps

module tb_fx_reverb;

    reg clk = 1'b0;
    always #10 clk = ~clk;              // 50 MHz

    reg rst_n = 1'b0;
    reg tick  = 1'b0;
    reg signed [15:0] in_l = 16'sd0, in_r = 16'sd0;
    wire signed [15:0] out_l, out_r;

    fx_reverb #(
        .FB_Q8  (225),
        .GD_Q8  (128),
        .GW_Q8  (140)
    ) dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .tick   (tick),
        .enable (1'b1),
        .in_l   (in_l),
        .in_r   (in_r),
        .out_l  (out_l),
        .out_r  (out_r)
    );

    integer n, fh, mi;

    //  仿真专用内存初始化（Gowin BSRAM 上电为 0，iverilog 给 X）
    initial begin
        for (mi = 0; mi < 12288; mi = mi + 1) dut.cmem[mi] = 16'd0;
        for (mi = 0; mi < 1792; mi = mi + 1) begin
            dut.amem_l[mi] = 16'd0;
            dut.amem_r[mi] = 16'd0;
        end
    end

    task step_tick;
        begin
            @(negedge clk); tick = 1'b1;
            @(negedge clk); tick = 1'b0;
            // 本模块一个样点最多用 ~42 拍，留 60 拍余量
            repeat (60) @(negedge clk);
        end
    endtask

    initial begin
        fh = $fopen("fx_reverb_out.txt", "w");
        if (fh == 0) begin
            $display("ERROR: 无法创建 fx_reverb_out.txt");
            $finish;
        end

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        for (n = 0; n < 60000; n = n + 1) begin
            if (n == 0) begin
                in_l = 16'sd32767;
                in_r = 16'sd32767;
            end
            else begin
                in_l = 16'sd0;
                in_r = 16'sd0;
            end
            step_tick;
            $fdisplay(fh, "%0d %0d %0d", n, out_l, out_r);
        end

        $fclose(fh);
        $display("已导出 fx_reverb_out.txt（60000 样点）");
        $finish;
    end

endmodule
