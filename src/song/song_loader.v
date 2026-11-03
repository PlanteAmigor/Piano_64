//==========================================================================
//  song_loader —— 把 v3 帧流（来自 SD 卡）装填成事件表
//
//  数据来源可以是：
//    · SD 卡上的 SONGxx.BIN（本模块当前用途）
//    · 蓝牙 BT36 的 UART 字节流（同一份字节流，接法一样）
//  两者格式【逐字节相同】，所以本模块对来源无感。
//
//  协议 v3（与队友 Android App / FPGA 完全一致）：
//    A5 5A 03 | type | seq | len:LE16 | payload | crc16:LE16
//      type=1 BEGIN  payload 8 字节: count:u16 duration_ms:u32 timbre:u8 flags:u8
//      type=2 DATA   payload       : offset:u16 + N 个 8 字节事件
//      type=3 END    payload 2 字节: count:u16
//    事件 8 字节: start_ms:u32 | note:u8 | dur_ms:u16 | vel:u8
//
//  本模块只做「装填 + 校验」，不做调度。调度由 bt_song_player 负责。
//  验收标准：song_valid=1 且 err_code=0 后，事件 RAM 里是排好序的事件表。
//
//  ★ 与 ref/bt36_v3 的 bt_midi_top.v 的差异：
//    - 删掉 UART 收发、ACK 回传、命令帧（PLAY/STOP/QUERY）处理
//    - 删掉"上传事务"的重复帧缓存（SD 是单次顺序读，不会重传）
//    - 保留全部字段校验，错误码含义与队友一致
//    - MAX_EVENTS 默认 2048（2048×64bit = 128 Kbit ≈ 8 块 BSRAM）
//
//  来源：ref/bt36_v3/fpga_bt_v3/src/bt/bt_midi_top.v（队友 v1.1.0）
//==========================================================================
`default_nettype none

module song_loader #(
    parameter integer CLK_HZ     = 50_000_000,
    parameter integer MAX_EVENTS = 2048,
    parameter integer TIMEOUT_MS = 2000
)(
    input  wire         clk,
    input  wire         rst_n,

    // ── 字节流输入（clk50 域，接 bt_frame_rx 的同款握手）──
    input  wire [7:0]   byte_data,
    input  wire         byte_valid,
    input  wire         byte_error,      // SD 无错误信号，接 0 即可

    // ── 事件 RAM 写口（1W1R，外部例化）──
    //    ★ wptr 是内部计数器，waddr_q 是延迟一拍的实际写地址，
    //      两者必须分开：ram_we 也打一拍，若直接用递増后的 wptr 会写到下一个位置。
    output wire [10:0]  ram_waddr,       // 0 .. MAX_EVENTS-1
    output reg          ram_we,
    output reg  [63:0]  ram_wdata,

    // ── 结果 / 状态 ──
    output reg          song_valid,      // 1 = 曲谱已完整提交
    output reg  [15:0]  song_count,      // 事件数
    output reg  [31:0]  song_duration,   // 总时长 ms
    output reg          song_multi,
    output reg  [1:0]   song_timbre,     // 0钢琴 1古筝 2唢呐 3笛子
    output reg  [7:0]   err_code,        // 0=OK，含义见文件末尾
    output reg          busy,            // 正在装填
    output wire         frame_hit,
    output wire         stream_idle
);

    //======================================================================
    //  1. 字节 FIFO + 挂起寄存器
    //
    //  ★ 必须缓冲：bt_frame_rx 在 valid=1 期间完全不收字节（等上层 consume）。
    //    UART 115200 下 87 µs/字节来得及，但 SD 是 640 ns/字节，
    //    处理 32 个事件要 8 µs，正好吞掉 13 个字节 → 258 字节的 DATA 帧丢失。
    //
    //  握手：只有当【没有挂起字节】且【解析器此刻能收】时才从 FIFO 弹出。
    //        吞吐 1 字节 / 2 拍，远快于 SD 的 1 字节 / 32 拍。
    //======================================================================
    wire [7:0] fifo_dout;
    wire       fifo_empty, fifo_full, fifo_ovf;

    song_fifo #(.AW (9)) u_fb (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_data  (byte_data),
        .wr_en    (byte_valid),
        .rd_data  (fifo_dout),
        .rd_en    (fifo_ren),
        .empty    (fifo_empty),
        .full     (fifo_full),
        .level    (),
        .overflow (fifo_ovf)
    );

    reg        pend;                 // FIFO 已弹出一个字节，正等解析器接收
    reg [7:0]  pend_data;
    wire       acc  = !frame_valid;  // 解析器本拍能否接收字节
    wire       fifo_ren = !fifo_empty && !pend && acc;

    always @(posedge clk) begin
        if (!rst_n) begin
            pend      <= 1'b0;
            pend_data <= 8'd0;
        end
        else begin
            if (pend && acc) pend <= 1'b0;          // 本拍被解析器接收
            if (fifo_ren) begin
                pend      <= 1'b1;                  // 下一拍送给解析器
                pend_data <= fifo_dout;
            end
        end
    end

    //======================================================================
    //  2. 帧解析（复用队友模块，只接字节流，不关心来源是 SD 还是 UART）
    //======================================================================
    reg  [8:0]  payload_addr;
    wire [7:0]  payload_data, frame_error, frame_type, frame_seq;
    wire [15:0] frame_length, frame_crc;
    wire        frame_valid;
    wire        frame_idle;
    reg         consume;

    assign frame_hit = frame_valid;
    assign stream_idle = fifo_empty && !pend && frame_idle && st == S_IDLE;

    bt_frame_rx #(
        .CLK_HZ     (CLK_HZ),
        .TIMEOUT_MS (TIMEOUT_MS)
    ) u_frame (
        .clk         (clk),
        .rst_n       (rst_n),
        .byte_data   (pend_data),
        .byte_valid  (pend),
        .byte_error  (1'b0),
        .consume     (consume),
        .payload_addr(payload_addr),
        .payload_data(payload_data),
        .valid       (frame_valid),
        .error_code  (frame_error),
        .frame_type  (frame_type),
        .seq         (frame_seq),
        .length      (frame_length),
        .frame_crc   (frame_crc)
        ,.idle       (frame_idle)
    );

    //======================================================================
    //  3. 事务状态机
    //      IDLE → HEADER（读 payload 前 8 字节）→ DISPATCH
    //           → COPY（逐字节拼事件）→ CHECK（校验+写 RAM）→ NEXT_EVENT
    //           → DONE（consume）→ RELEASE（等 valid 落下）→ IDLE
    //======================================================================
    localparam [2:0] S_IDLE      = 3'd0,
                     S_HEADER    = 3'd1,
                     S_DISPATCH  = 3'd2,
                     S_COPY      = 3'd3,
                     S_CHECK     = 3'd4,
                     S_NEXT_EVT  = 3'd5,
                     S_DONE      = 3'd6,
                     S_RELEASE   = 3'd7;

    reg [2:0]  st;
    reg [63:0] header;          // BEGIN 的 8 字节 payload
    reg [63:0] event_word;      // 正在拼的事件
    reg [3:0]  header_index;
    reg [3:0]  header_bytes;
    reg [3:0]  byte_index;
    reg [5:0]  event_index;     // 本帧内第几个事件
    reg [5:0]  frame_events;    // 本帧事件数
    reg [31:0] previous_start;  // 上一个事件的 start_ms（查排序）
    reg  [15:0] wptr;            // Count includes 2048; address alone is 11 bits.
    reg  [10:0] waddr_q;         // 实际写地址（延迟一拍）
    assign ram_waddr = waddr_q;
    reg        uploading;       // BEGIN 已收到，正在等 DATA
    reg        allow_drop;      // BEGIN.flags[0]，允许超额丢音

    wire [31:0] ev_start    = event_word[31:0];
    wire [7:0]  ev_note     = song_multi ? {1'b0,event_word[38:32]} : event_word[39:32];
    wire [1:0] ev_timbre = song_multi ? {event_word[39],event_word[63]} : song_timbre;
    wire [15:0] ev_duration = song_multi ? {1'b0,event_word[54:40]} : event_word[55:40];
    wire [7:0]  ev_velocity = song_multi ? {1'b0,event_word[62:56]} : event_word[63:56];
    wire [32:0] ev_end      = {1'b0, ev_start} + {17'd0, ev_duration};

    // 音域随音色（与队友 BoardProtocol.kt / bt_midi_top.v 一致）
    wire [7:0]  note_lo = (ev_timbre == 2'd0) ? 8'd21 :
                          (ev_timbre == 2'd1) ? 8'd38 :
                          (ev_timbre == 2'd2) ? 8'd69 : 8'd67;
    wire [7:0]  note_hi = (ev_timbre == 2'd0) ? 8'd108 :
                          (ev_timbre == 2'd1) ? 8'd86 :
                          (ev_timbre == 2'd2) ? 8'd96 : 8'd91;

    //======================================================================
    //  4. 并发声部检查
    //     每来一个事件，看能不能塞进 8 个声部之一（结束时间 <= 新事件开始）
    //     allow_drop=0 时超了直接报错，避免用户以为播了其实丢了音
    //======================================================================
    reg [31:0] end_ms [0:7];
    integer    chosen, k;
    always @(*) begin
        chosen = -1;
        for (k = 7; k >= 0; k = k - 1)
            if ((song_multi ? (ev_timbre<2 ? k<7 : k==7) : (song_timbre<2 || k==0)) && end_ms[k]<=ev_start)
                chosen = k;
    end

    //======================================================================
    //  5. 主状态机
    //======================================================================
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            st             <= S_IDLE;
            consume        <= 1'b0;
            payload_addr   <= 9'd0;
            header         <= 64'd0;
            event_word     <= 64'd0;
            header_index   <= 4'd0;
            header_bytes   <= 4'd0;
            byte_index     <= 4'd0;
            event_index    <= 6'd0;
            frame_events   <= 6'd0;
            previous_start <= 32'd0;
            uploading      <= 1'b0;
            allow_drop     <= 1'b0;
            ram_we         <= 1'b0;
            wptr           <= 11'd0;
            waddr_q        <= 11'd0;
            ram_wdata      <= 64'd0;
            song_valid     <= 1'b0;
            song_count     <= 16'd0;
            song_duration  <= 32'd0;
            song_timbre    <= 2'd0; song_multi<=0;
            err_code       <= 8'd0;
            busy           <= 1'b0;
            for (i = 0; i < 8; i = i + 1) end_ms[i] <= 32'd0;
        end
        else begin
            ram_we <= 1'b0;

            case (st)
            // ── 一个新帧就绪 ───────────────────────────────────────
            S_IDLE: if (frame_valid) begin
                header       <= 64'd0;
                header_index <= 4'd0;
                payload_addr <= 9'd0;
                header_bytes <= (frame_length > 16'd8) ? 4'd8 : frame_length[3:0];
                if (frame_error != 8'd0) begin
                    err_code <= frame_error;
                    uploading <= 1'b0;
                    song_valid <= 1'b0;
                    st       <= S_DONE;
                end
                else if (frame_length == 16'd0) begin
                    st <= S_DISPATCH;                     // 无 payload 的帧
                end
                else begin
                    st <= S_HEADER;
                end
            end

            // ── 读 payload 前 8 字节到 header ──────────────────────
            S_HEADER: begin
                header[header_index*8 +: 8] <= payload_data;
                if (header_index + 4'd1 >= header_bytes) st <= S_DISPATCH;
                else begin
                    header_index <= header_index + 4'd1;
                    payload_addr <= payload_addr + 9'd1;
                end
            end

            // ── 按帧类型分派 ──────────────────────────────────────
            S_DISPATCH: begin
                case (frame_type)
                // BEGIN
                8'h01: begin
                    if (frame_length != 16'd8)                       err_code <= 8'd2;
                    else if (header[15:0] == 16'd0 ||
                             header[15:0] > MAX_EVENTS)              err_code <= 8'd4;
                    else if (header[47:16] == 32'd0 ||
                             header[47:16] > 32'd86_400_000 ||
                             header[55:48] > 8'd3 ||
                             (header[63:56] & 8'h7e) != 0)                   err_code <= 8'd5;
                    else begin
                        song_valid     <= 1'b0;                  // 新曲谱开始，旧的作废
                        uploading      <= 1'b1;
                        song_count     <= header[15:0];
                        song_duration  <= header[47:16];
                        song_timbre    <= header[49:48];
                        song_multi     <= header[63];
                        allow_drop     <= header[56];
                        previous_start <= 32'd0;
                        wptr           <= 11'd0;                 // ★ 写指针必须归零
                        err_code       <= 8'd0;
                        for (i = 0; i < 8; i = i + 1) end_ms[i] <= 32'd0;
                    end
                    st <= S_DONE;
                end

                // DATA
                8'h02: begin
                    // ★ 每个分支显式设 st（非阻塞赋值读回旧值，不能用 if(st!=S_COPY)）
                    if (!uploading) begin
                        err_code <= 8'd3;
                        st       <= S_DONE;
                    end
                    else if (frame_length < 16'd10 || frame_length > 16'd258 ||
                             ((frame_length - 16'd2) & 16'd7) != 16'd0) begin
                        err_code <= 8'd2;
                        st       <= S_DONE;
                    end
                    else if (header[15:0] != wptr) begin
                        // offset 必须等于已写入的事件数（wptr 就是计数器）
                        err_code <= 8'd7;
                        st       <= S_DONE;
                    end
                    else if (wptr + ((frame_length - 16'd2) >> 3) > song_count ||
                             wptr + ((frame_length - 16'd2) >> 3) > MAX_EVENTS) begin
                        err_code <= 8'd4;
                        uploading <= 1'b0;
                        st <= S_DONE;
                    end
                    else begin
                        frame_events <= (frame_length - 16'd2) >> 3;
                        event_index  <= 6'd0;
                        byte_index   <= 4'd0;
                        event_word   <= 64'd0;
                        payload_addr <= 9'd2;                    // 跳过 offset
                        st           <= S_COPY;
                    end
                end

                // END
                8'h03: begin
                    if (frame_length != 16'd2)                               err_code <= 8'd2;
                    else if (!uploading ||
                             header[15:0] != song_count || wptr != song_count) begin
                        err_code <= 8'd3;
                        uploading <= 1'b0;
                        song_valid <= 1'b0;
                    end
                    else begin
                        uploading  <= 1'b0;
                        song_valid <= 1'b1;                      // ★ 这一刻曲谱才算可用
                        err_code   <= 8'd0;
                    end
                    st <= S_DONE;
                end

                // 命令帧（PLAY/STOP/QUERY）：SD 场景用不到，忽略
                8'h10, 8'h11, 8'h12: st <= S_DONE;

                default: begin
                    err_code <= 8'd11;
                    st       <= S_DONE;
                end
                endcase
            end

            // ── 逐字节拼一个 8 字节事件 ───────────────────────────
            S_COPY: begin
                event_word[byte_index*8 +: 8] <= payload_data;
                if (payload_addr < 9'd257) payload_addr <= payload_addr + 9'd1;
                if (byte_index == 4'd7) st <= S_CHECK;
                else                    byte_index <= byte_index + 4'd1;
            end

            // ── 校验 + 写 RAM ────────────────────────────────────
            S_CHECK: begin
                if (ev_note < note_lo || ev_note > note_hi ||
                    ev_duration == 16'd0 ||
                    ev_velocity == 8'd0 || ev_velocity > 8'd127 ||
                    ev_end > {1'b0, song_duration} ||
                    (wptr != 11'd0 && ev_start < previous_start)) begin
                    err_code  <= 8'd5;
                    uploading <= 1'b0;
                    st        <= S_DONE;
                end
                else if (chosen < 0 && (!allow_drop || song_multi)) begin
                    err_code  <= 8'd9;                       // 超出声部容量
                    uploading <= 1'b0;
                    st        <= S_DONE;
                end
                else begin
                    ram_we         <= 1'b1;
                    waddr_q        <= wptr[10:0];
                    wptr           <= wptr + 16'd1;
                    ram_wdata      <= event_word;
                    previous_start <= ev_start;
                    if (chosen >= 0) end_ms[chosen] <= ev_end[31:0];
                    st <= S_NEXT_EVT;
                end
            end

            // ── 本帧还有事件就继续 ────────────────────────────────
            S_NEXT_EVT: begin
                if (event_index + 6'd1 >= frame_events) st <= S_DONE;
                else begin
                    event_index <= event_index + 6'd1;
                    byte_index  <= 4'd0;
                    event_word  <= 64'd0;
                    st          <= S_COPY;
                end
            end

            // ── 放行本帧，等解析器把 valid 落下 ────────────────────
            S_DONE: begin
                consume <= 1'b1;
                st      <= S_RELEASE;
            end

            S_RELEASE: begin
                consume <= 1'b0;
                if (!frame_valid) st <= S_IDLE;
            end

            default: st <= S_IDLE;
            endcase

            busy <= (st != S_IDLE) || frame_valid;
            // A file is one transaction. Preserve its first diagnostic until
            // the receiver resets us for the next file, even if END follows.
            if (err_code != 0) begin
                err_code <= err_code;
                uploading <= 0;
                song_valid <= 0;
                ram_we <= 0;
            end
            // A transport error invalidates the complete upload, including
            // frames still buffered after the fault. Reset before retrying.
            if (byte_error || fifo_ovf) begin
                uploading <= 1'b0;
                song_valid <= 1'b0;
                err_code <= 8'd8;
                ram_we <= 1'b0;
            end
        end
    end

endmodule

//==========================================================================
//  err_code 含义（与队友 BoardProtocol.kt 一致，便于对照 App 提示）
//    0  成功
//    1  CRC 校验失败
//    2  帧长度错误
//    3  曲谱未提交或数量不完整
//    4  事件数量超出容量 / BEGIN 字段越界
//    5  音符音域、排序、时长或力度无效
//    7  事件偏移不连续
//    8  帧接收超时
//    9  超过音色声部容量
//    10 协议版本不兼容
//    11 不支持的帧类型
//==========================================================================
`default_nettype wire
