//==========================================================================
//  uart_tx —— 8N1 串口发送器（可复用）
//
//  接口是【显式握手】的，这是关键：
//      send 拉高一拍 → busy 拉高（表示已接手）→ 发完 10 位后 busy 落低
//  调用方必须：发 send 后等 busy 变 1，再等 busy 变 0，才能发下一个字节。
//
//  ★ 为什么要强调：uart_probe 第一版就是"发 send 的下一拍就取下一个字符"，
//    但发送器要再一拍才把 busy 拉高，于是调用方那拍又取了一次 →
//    每个字节省略一个（发出 T N - A T O…）。这个 bug 只有仿真能发现。
//
//  帧格式：起始位(0) + 8 位数据(LSB 先) + 停止位(1)，共 10 位
//  sh = {停止位, d[7:0], 起始位}，从 sh[0] 开始往外吐
//==========================================================================
`default_nettype none

module uart_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] dbyte,
    input  wire       send,
    output reg        busy,
    output reg        txd
);
    localparam integer DIV = CLK_HZ / BAUD;      // 50e6/115200 = 434

    reg [15:0] bcnt;
    reg [3:0]  bbit;
    reg [9:0]  sh;

    always @(posedge clk) begin
        if (!rst_n) begin
            bcnt <= 16'd0;
            bbit <= 4'd0;
            sh   <= 10'h3FF;
            busy <= 1'b0;
            txd  <= 1'b1;
        end
        else if (!busy) begin
            txd <= 1'b1;
            if (send) begin
                sh   <= {1'b1, dbyte, 1'b0};
                busy <= 1'b1;
                bcnt <= 16'd0;
                bbit <= 4'd0;
            end
        end
        else begin
            if (bcnt == DIV - 1) begin
                bcnt <= 16'd0;
                txd  <= sh[0];
                sh   <= {1'b1, sh[9:1]};
                if (bbit == 4'd9) begin
                    busy <= 1'b0;
                    txd  <= 1'b1;
                end
                else
                    bbit <= bbit + 4'd1;
            end
            else
                bcnt <= bcnt + 16'd1;
        end
    end

endmodule

`default_nettype wire
