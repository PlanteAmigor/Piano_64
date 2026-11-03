`timescale 1ns/1ps
`default_nettype none

module tb_report_feat;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    reg frame_valid = 0;
    reg signed [23:0] rho_raw = 24'sd0, rho_dc = 24'sd0,
                      rho_ac = 24'sd0, ac_env = 24'sd0;
    reg [15:0] half_period = 16'd0;
    reg [15:0] x_q8 = 16'd0;
    reg [2:0]  hw_err = 3'd0;

    wire [7:0] uchar;
    wire       uvld, ubusy, utxd;

    report_feat u_rep (
        .clk(clk), .rst_n(rst_n), .frame_valid(frame_valid),
        .rho_raw(rho_raw), .rho_dc(rho_dc), .rho_ac(rho_ac),
        .ac_env(ac_env), .half_period(half_period),
        .x_q8(x_q8), .hw_err(hw_err),
        .uart_char(uchar), .uart_valid(uvld), .uart_ready(~ubusy)
    );

    uart_tx #(.CLK_HZ(50_000_000), .BAUD(115_200)) u_tx (
        .clk(clk), .rst_n(rst_n), .dbyte(uchar), .send(uvld),
        .busy(ubusy), .txd(utxd)
    );

    always @(posedge clk) if (uvld && !ubusy) $write("%c", uchar);

    initial begin
        #300 rst_n = 1;
        #200;
        rho_raw = 24'sd393210; rho_dc = 24'sd380000;
        rho_ac  = 24'sd13210;  ac_env = 24'sd1800;
        half_period = 16'd10;
        x_q8 = 16'd1280;
        @(posedge clk); frame_valid <= 1;
        @(posedge clk); frame_valid <= 0;
        #5_000_000;
        $display("\n[timeout done]");
        $finish;
    end
endmodule

`default_nettype wire
