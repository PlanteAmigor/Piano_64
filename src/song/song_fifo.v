//==========================================================================
//  song_fifo —— 字节 FIFO（First Word Fall Through），给帧解析器做缓冲
//
//  为什么必须有这个：
//    bt_frame_rx（来自队友 UART 方案）在 valid=1 期间【完全不接收字节】——
//    它要等上层 consume 后才回 state=0 重新找 A5 5A。
//    在 UART 115200 下每字节 87 µs，上层处理 32 个事件（约 8 µs）来得及；
//    但 SD 卡是 640 ns/字节，同样 8 µs 内会来 13 个字节 → 全部丢失 →
//    258 字节的 DATA 帧被吞掉，只有后面的帧能靠重新同步 A5 5A 侥幸解析。
//
//  本 FIFO 的消费侧逻辑：
//      rd_en = !empty && !frame_valid
//    即在解析器忙碌期间【不弹出】，字节安全留在 FIFO 里。
//
//  深度 512 字节：SD 640 ns/字节下可吸收 328 µs 的处理延迟，
//  而处理一帧 32 个事件只需约 8 µs，余量 40 倍。
//  小文件（<512 B）可以整包缓存。
//
//  用寄存器实现（512×8 = 4096 FF），不占 BSRAM。
//==========================================================================
`default_nettype none

module song_fifo #(
    parameter integer AW = 9                    // 深度 = 2^AW = 512
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire [7:0]   wr_data,
    input  wire         wr_en,

    output wire [7:0]   rd_data,                // 组合读：rdptr 指向的字
    input  wire         rd_en,

    output wire         empty,
    output wire         full,
    output wire [AW:0]  level,
    output reg          overflow                // 曾发生写入被丢弃（诊断用）
);

    reg [7:0]    mem [0:(1<<AW)-1];
    reg [AW-1:0] wptr, rptr;
    reg [AW:0]   cnt;

    assign empty   = (cnt == {(AW+1){1'b0}});
    assign full    = (cnt == ({(AW+1){1'b0}} | (1 << AW)));
    assign level   = cnt;
    assign rd_data = mem[rptr];

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always @(posedge clk) begin
        if (!rst_n) begin
            wptr     <= {AW{1'b0}};
            rptr     <= {AW{1'b0}};
            cnt      <= {(AW+1){1'b0}};
            overflow <= 1'b0;
        end
        else begin
            if (wr_en && full) overflow <= 1'b1;

            if (do_wr) mem[wptr] <= wr_data;

            case ({do_wr, do_rd})
            2'b10: begin
                wptr <= wptr + 1'b1;
                cnt  <= cnt + 1'b1;
            end
            2'b01: begin
                rptr <= rptr + 1'b1;
                cnt  <= cnt - 1'b1;
            end
            2'b11: begin
                wptr <= wptr + 1'b1;
                rptr <= rptr + 1'b1;
            end
            default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
