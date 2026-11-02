//==========================================================================
//  tb_fx_delay.v —— 逐样点导出 RTL 输出，交给 Python 定点模型比对
//
//  激励：n=0 处一个单位脉冲
//  长度：40000 样点（> 左延迟 16384，能覆盖首次回声 + 若干次反馈）
//  导出：每行 "n out_l out_r"
//
//  验证：tools/fx_delay_check.py 用与 RTL 完全相同的定点算法重算，逐样点 bit-exact
//==========================================================================
`timescale 1ns/1ps

module tb_fx_delay;

    reg clk = 1'b0;
    always #10 clk = ~clk;              // 50 MHz

    reg rst_n = 1'b0;
    reg tick  = 1'b0;
    reg signed [15:0] in_l = 16'sd0, in_r = 16'sd0;
    wire signed [15:0] out_l, out_r;

    fx_delay #(
        .AL     (14),
        .AR     (14),
        .DLEN_L (16384),
        .DLEN_R (12207),
        .FB_Q8  (97),
        .GD_Q8  (128),
        .GW_Q8  (141)
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
        for (mi = 0; mi < 16384; mi = mi + 1) begin
            dut.mem_l[mi] = 16'd0;
            dut.mem_r[mi] = 16'd0;
        end
    end

    task step_tick;
        begin
            @(negedge clk); tick = 1'b1;
            @(negedge clk); tick = 1'b0;
            repeat (10) @(negedge clk);
        end
    endtask

    initial begin
        fh = $fopen("fx_delay_out.txt", "w");
        if (fh == 0) begin
            $display("ERROR: 无法创建 fx_delay_out.txt");
            $finish;
        end

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        for (n = 0; n < 40000; n = n + 1) begin
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
        $display("已导出 fx_delay_out.txt（40000 样点）");
        $finish;
    end

endmodule
