//==========================================================================
//  param_dma —— 把"当前音"的 128 个分量从源表搬进声部 cache
//
//  总架构文档里的「按需 DMA，触发时机：note-on」这一段。
//
//  一次搬运：128 分量 × 12 字节 = 1536 字节，耗时 129 拍 = 2.58 µs @50MHz。
//  8 个音同时 note-on 串行搬 = 20.6 µs，远小于钢琴起音可辨阈值（~5 ms）。
//
//  ── 时序（流水 1 拍/分量）────────────────────────────────────────
//      cnt=0    发 src_addr = {note_off, 0}
//      cnt=1    发 {note_off,1} ‖ 写 cache[0]（数据 = cnt=0 那拍读出的）
//      ...
//      cnt=127  发 {note_off,127} ‖ 写 cache[126]
//      cnt=128                        ‖ 写 cache[127] → done
//
//  源表是同步读（地址打一拍），所以"发地址"和"写上一份数据"可以同拍进行，
//  不需要额外的等待状态。
//==========================================================================
`default_nettype none

module param_dma #(
    parameter integer NPART = 128
)(
    input  wire         clk,
    input  wire         rst_n,

    // ── 控制 ────────────────────────────────────────────────────
    input  wire         start,          // 一个时钟宽的启动脉冲
    input  wire [6:0]   note_off,       // 该音在源表内的偏移（0..87）
    output reg          busy,
    output reg          done,           // 完成时一拍的脉冲

    // ── 源表读口（同步读，1 拍延迟）──────────────────────────────
    output reg  [13:0]  src_addr,
    input  wire [31:0]  src_d0,
    input  wire [31:0]  src_d1,
    input  wire [31:0]  src_d2,

    // ── 目标 cache 写口 ─────────────────────────────────────────
    output reg          we,
    output reg  [6:0]   waddr,
    output reg  [95:0]  wdata
);

    localparam [1:0] ST_IDLE = 2'd0,
                     ST_RUN  = 2'd1;

    // ★ 位宽：cnt 要能表示 128（NPART），所以 8 位而非 7 位
    reg [1:0] st;
    reg [7:0] cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            st       <= ST_IDLE;
            cnt      <= 8'd0;
            busy     <= 1'b0;
            done     <= 1'b0;
            we       <= 1'b0;
            waddr    <= 7'd0;
            wdata    <= 96'd0;
            src_addr <= 14'd0;
        end
        else begin
            we   <= 1'b0;
            done <= 1'b0;

            case (st)

                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        st  <= ST_RUN;
                        cnt <= 8'd0;
                        busy <= 1'b1;
                    end
                end

                ST_RUN: begin
                    // ★★ 时序修正（2026-10-31）：ROM 是【地址非阻塞赋值 + 同步读】，
                    //    实际需要 2 拍：
                    //      cnt=k   拍：src_addr <= {note_off,k}（下一拍才生效）
                    //      cnt=k+1 拍：ROM 采样到 {note_off,k}
                    //      cnt=k+2 拍：ROM 输出 m[note_off,k] ← 这时才能写
                    //    之前按 1 拍设计，结果写进去的全是复位前地址 0 的数据
                    //    （仿真里所有声部都装成 note 21 的数据就是这个原因）。
                    //
                    //    所以：cnt 走 0..129，地址在 cnt<128 时发，
                    //          数据在 cnt>=2 时写（写到 cnt-2 槽位）。
                    if (cnt < 8'd130) begin
                        if (cnt < NPART[7:0])
                            src_addr <= { note_off, cnt[6:0] };

                        if (cnt >= 8'd2) begin
                            we    <= 1'b1;
                            waddr <= (cnt - 8'd2);      // 128-2=126, 129-2=127 ✓
                            wdata <= { src_d2, src_d1, src_d0 };
                        end
                        cnt <= cnt + 8'd1;
                    end
                    else begin
                        st   <= ST_IDLE;
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
