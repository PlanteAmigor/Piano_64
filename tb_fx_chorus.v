//==========================================================================
//  tb_fx_chorus.v —— 逐样点导出 RTL 输出，交给 Python 定点模型比对
//
//  激励：n=0 处一个单位脉冲，其余全 0，跑 1400 个样点（> 2×最大延迟 756）
//  导出：每行 "n out_l out_r"
//
//  验证思路（见 tools/fx_chorus_check.py）：
//    Python 用与 RTL 完全相同的定点算法重算一遍，逐样点要求 bit-exact。
//    这样任何一处位宽/符号/时序搞错都会立刻暴露，而不是"听起来差不多"。
//==========================================================================
`timescale 1ns/1ps

module tb_fx_chorus;

    reg clk = 1'b0;
    always #10 clk = ~clk;              // 50 MHz

    reg rst_n = 1'b0;
    reg tick  = 1'b0;
    reg signed [15:0] in_l = 16'sd0, in_r = 16'sd0;
    wire signed [15:0] out_l, out_r;

    fx_chorus #(
        .ABUF     (1024),
        .BASE_Q8  (150000),
        .DEPTH_Q8 (25000),
        .LFO_STEP (52777),
        .GD_Q8    (149),
        .GW_Q8    (149)
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

    integer n, fh;

    //  仿真专用的内存初始化：iverilog 里未初始化的 reg 数组是 X，
    //  而 Gowin BSRAM 上电后是 0。这里清 0 让仿真与硬件一致。
    //  （纯仿真语句，综合时整段被忽略）
    integer mi;
    initial begin
        for (mi = 0; mi < 1024; mi = mi + 1) begin
            dut.mem_l[mi] = 16'd0;
            dut.mem_r[mi] = 16'd0;
        end
    end

    //  一个样点：tick 拉高一拍，再等状态机跑完（st0..st5，留足余量）
    task step_tick;
        begin
            @(negedge clk); tick = 1'b1;
            @(negedge clk); tick = 1'b0;
            repeat (12) @(negedge clk);
        end
    endtask

    initial begin
        fh = $fopen("fx_chorus_out.txt", "w");
        if (fh == 0) begin
            $display("ERROR: 无法创建 fx_chorus_out.txt");
            $finish;
        end

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        for (n = 0; n < 1400; n = n + 1) begin
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

        //  第二份：内部信号，用于定位 RTL 与模型的差异
        $fclose(fh);
        fh = $fopen("fx_chorus_dbg.txt", "w");
        n = 0;
        repeat (5) @(negedge clk);
        rst_n = 1'b0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        for (n = 0; n < 1400; n = n + 1) begin
            if (n == 0) begin in_l = 16'sd32767; in_r = 16'sd32767; end
            else begin in_l = 16'sd0; in_r = 16'sd0; end
            step_tick;
            $fdisplay(fh, "%0d %0d %0d %0d %0d %0d %0d",
                      n, dut.sv_l, dut.sv_r, dut.dint_l, dut.frac_l,
                      dut.dint_r, dut.frac_r);
        end

        $fclose(fh);
        $display("已导出 fx_chorus_out.txt（1400 样点）");
        $finish;
    end

endmodule
