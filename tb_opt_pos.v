`timescale 1ns/1ps
`default_nettype none

module tb_opt_pos;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg frame_valid = 0;
    reg [107:0] raw = 108'd0;
    wire [15:0] x_q8;
    wire [23:0] sum_pos;
    wire        x_valid;
    wire [15:0] x_frame;

    opt_pos u_dut(
        .clk(clk), .rst_n(rst_n), .frame_valid(frame_valid),
        .raw_flat(raw), .x_q8(x_q8), .sum_pos(sum_pos),
        .x_valid(x_valid), .x_frame(x_frame)
    );

    integer err = 0;

    task frame(input integer d0, d1, d2, d3, d4, d5);
        begin
            raw = { 6'sd0, d5[17:0], d4[17:0], d3[17:0],
                    d2[17:0], d1[17:0], d0[17:0] };
            @(posedge clk); frame_valid <= 1;
            @(posedge clk); frame_valid <= 0;
            repeat (40) @(posedge clk);
        end
    endtask

    task chk(input [8*24-1:0] name, input integer expect_q8);
        begin
            if (x_q8 !== expect_q8[15:0]) begin
                $display("FAIL %0s: x_q8=%0d (%.2f cm)  期望 %0d (%.2f cm)",
                         name, x_q8, x_q8/256.0, expect_q8, expect_q8/256.0);
                err = err + 1;
            end else begin
                $display("ok   %0s: %.3f cm  sum=%0d", name, x_q8/256.0, sum_pos);
            end
        end
    endtask

    initial begin
        #300 rst_n = 1;
        #200;
        // 只亮 CH3（x=10cm）
        frame(0, 0, 0, 10000, 0, 0);       chk("only CH4(10cm)", 2560);
        // 只亮 CH1（x=0）
        frame(10000, 0, 0, 0, 0, 0);       chk("only CH1(0cm)",  0);
        // CH2+CH3 相等 → (2.5+5)/2 = 3.75 cm
        frame(0, 5000, 5000, 0, 0, 0);     chk("CH2=CH3",        960);
        // 六路全等 → 均值 (0+2.5+5+10+12.5+15)/6 = 7.5 cm
        frame(5000,5000,5000,5000,5000,5000); chk("all equal",     1920);
        // 负值应被当 0
        frame(-5000, 0, 0, 10000, 0, -8000);  chk("neg->0",       2560);
        // 分母太小 → invalid
        frame(10, 10, 10, 10, 10, 10);
        if (x_valid !== 1'b0) begin $display("FAIL: 小分母应 x_valid=0"); err=err+1; end
        else $display("ok   small den -> x_valid=0");
        $display("\n错误数 = %0d  %0s", err, err==0 ? "PASS" : "FAIL");
        $finish;
    end
endmodule

`default_nettype wire
