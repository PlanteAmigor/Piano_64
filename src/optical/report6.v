//==========================================================================
//  report6 —— 六路差值 → 串口十进制 ASCII（115200-8N1）
//
//  用途：上板「看数」。位置模型还没标定，先用这个确认
//        「灯亮不亮、光回不回来、六路读数对不对」。
//
//  输出格式（每轮 12 ms 一行）：
//      +00314,+00265,+00221,+00177,+00133,+00090\r\n
//      └ch1──┘ └ch2──┘ …                    └ch6──┘
//    每路固定 6 字符 = 符号 + 5 位数字，单位 mV。
//    Python: [int(x) for x in line.split(',')]
//
//  ⚠️ 5 位十进制够用：码值最大 65535 → 10002 mV。
//  ⚠️ 前导零保留（"+00314"），每路宽度固定，肉眼对齐、解析也不会错位。
//
//  ── 握手（这里最容易错）────────────────────────────────────────────
//    uart_tx 的 busy 是【下一拍】才拉高的。所以不能用 uart_ready 直接推进
//    状态机，否则同一拍会连发两次（report4 第一版踩过，仿真才发现）。
//    正确做法：out_b/out_pend 一对寄存器
//        out_go（= 需要发 && !out_pend）→ out_b 更新、out_pend 置 1
//        out_pend && uart_ready            → out_pend 清 0
//        FSM 只在 out_go 那一拍推进
//    uart_tx 在 out_pend 为 1 的那一拍采到 send，因此一个字节只会发一次。
//==========================================================================
`default_nettype none

module report6 #(
    parameter integer NCH = 6
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              frame_valid,   // 一轮六路更新完（单拍）
    input  wire [NCH*18-1:0] flt_flat,      // 18 位有符号码值

    // ---- 到 uart_tx ----
    output wire [7:0]        uart_char,
    output wire              uart_valid,
    input  wire              uart_ready      // 接 !busy
);

    //======================================================================
    // 码值 → mV：  mV = code * 5000 / 32768 = (code * 5000) >>> 15
    // （±5 V 量程，1 LSB = 152.6 µV）
    //======================================================================
    function signed [15:0] to_mv(input signed [17:0] code);
        reg signed [31:0] t;
        begin
            t     = code * 32'sd5000;
            to_mv = t[30:15];                 // >>> 15，结果 ±10002 放得下
        end
    endfunction

    function [15:0] pow10(input [2:0] i);
        case (i)
            3'd0:    pow10 = 16'd10000;
            3'd1:    pow10 = 16'd1000;
            3'd2:    pow10 = 16'd100;
            3'd3:    pow10 = 16'd10;
            default: pow10 = 16'd1;
        endcase
    endfunction

    //======================================================================
    // 状态
    //======================================================================
    localparam R_IDLE = 4'd0,
               R_HDR  = 4'd1,
               R_CH   = 4'd2,
               R_SIGN = 4'd3,
               R_DIG  = 4'd4,
               R_EMIT = 4'd5,
               R_SEP  = 4'd6,
               R_CR   = 4'd7,
               R_LF   = 4'd8;

    // 表头 "# ir diff mV\r\n" —— 上电打一次，确认波特率/链路
    //  ⚠️ 用八进制 \015\012 而不是 \r\n：iverilog 不认 \r，会当成字母 'r'
    localparam [8*14-1:0] HDR_STR = "# ir diff mV\015\012";
    localparam integer    HDR_LEN = 14;

    reg [3:0]         st;
    reg [3:0]         hi;         // 表头字符索引
    reg [2:0]         chi;        // 0..NCH-1
    reg [2:0]         dgi;        // 0..4 → 10000..1
    reg [15:0]        cur;        // 正在拆的绝对值
    reg [3:0]         dg;         // 当前位的数字 0..9
    reg               neg;
    reg               hdr_done;

    reg signed [15:0] mv [0:NCH-1];
    integer j;

    //======================================================================
    // 输出握手（字节级）
    //
    //  uart_tx 的行为：busy=0 时看到 send 才在【下一拍】拉高 busy，然后连发 10 位。
    //  所以不能只看 ready —— 必须「看到 busy 起来 → 再等 busy 落下去」才算一个字节发完。
    //
    //      T_IDLE : 有字节要发 → T_SEND
    //      T_SEND : uart_valid=1（uart_tx 这一拍采到 send）→ 等 busy 起来 → T_WAIT
    //      T_WAIT : uart_valid=0，等 busy 落低 → byte_done（单拍）→ T_IDLE
    //======================================================================
    localparam T_IDLE = 2'd0, T_SEND = 2'd1, T_WAIT = 2'd2;

    reg [7:0] put_byte;
    reg       put_vld;
    reg [1:0] tst;

    assign uart_char  = put_byte;
    assign uart_valid = put_vld && (tst == T_SEND);

    //  ★ byte_done 用 uart_ready（= !busy）：在 T_WAIT 里等 busy【落低】才算发完。
    //    写成 !uart_ready 就变成「忙的时候算完」→ 状态机飞跑、一个字节都发不出去。
    wire busy_now  = !uart_ready;
    wire byte_done = (tst == T_WAIT) && uart_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            tst <= T_IDLE;
        end else begin
            case (tst)
            T_IDLE: if (put_vld)  tst <= T_SEND;
            T_SEND: if (busy_now) tst <= T_WAIT;
            T_WAIT: if (!busy_now) tst <= T_IDLE;
            default: tst <= T_IDLE;
            endcase
        end
    end

    //======================================================================
    // 本拍要发什么
    //======================================================================
    always @(*) begin
        put_byte = 8'h00;
        put_vld  = 1'b0;
        case (st)
            R_HDR:  begin put_byte = HDR_STR[(HDR_LEN-1-hi)*8 +: 8]; put_vld = 1'b1;  end
            R_SIGN: begin put_byte = neg ? 8'h2D : 8'h2B;            put_vld = 1'b1;  end
            R_EMIT: begin put_byte = 8'h30 + {4'd0, dg};             put_vld = 1'b1;  end
            R_SEP:  begin put_byte = 8'h2C; put_vld = (chi != NCH[2:0] - 3'd1);        end
            R_CR:   begin put_byte = 8'h0D; put_vld = 1'b1;  end
            R_LF:   begin put_byte = 8'h0A; put_vld = 1'b1;  end
            default: ;
        endcase
    end

    //======================================================================
    // 主状态机
    //======================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            st       <= R_IDLE;
            hi       <= 4'd0;
            chi      <= 3'd0;
            dgi      <= 3'd0;
            cur      <= 16'd0;
            dg       <= 4'd0;
            neg      <= 1'b0;
            hdr_done <= 1'b0;
            for (j = 0; j < NCH; j = j + 1) mv[j] <= 16'sd0;
        end else begin
            case (st)
            //----------------------------------------------------------
            R_IDLE: begin
                if (frame_valid) begin
                    for (j = 0; j < NCH; j = j + 1)
                        mv[j] <= to_mv($signed(flt_flat[18*j +: 18]));
                    if (!hdr_done) begin
                        hi <= 4'd0;
                        st <= R_HDR;
                    end else begin
                        chi <= 3'd0;
                        st  <= R_CH;
                    end
                end
            end

            //---------------- 表头（只发一次）--------------------------
            R_HDR: if (byte_done) begin
                if (hi == HDR_LEN - 1) begin
                    hdr_done <= 1'b1;
                    chi      <= 3'd0;
                    st       <= R_CH;
                end else begin
                    hi <= hi + 4'd1;
                end
            end

            //---------------- 取下一个通道 -----------------------------
            R_CH: begin
                neg <= (mv[chi] < 16'sd0);
                cur <= (mv[chi] < 16'sd0) ? (-mv[chi]) : mv[chi];
                dgi <= 3'd0;
                dg  <= 4'd0;
                st  <= R_SIGN;
            end

            //---------------- 符号位 -----------------------------------
            R_SIGN: if (byte_done) st <= R_DIG;

            //---------------- 逐位提取（反复减 10^dgi）-----------------
            R_DIG: begin
                if (cur >= pow10(dgi)) begin
                    cur <= cur - pow10(dgi);
                    dg  <= dg + 4'd1;
                end else begin
                    st <= R_EMIT;
                end
            end

            //---------------- 发出这一位 -------------------------------
            R_EMIT: if (byte_done) begin
                dg <= 4'd0;
                if (dgi == 3'd4) begin
                    st <= R_SEP;
                end else begin
                    dgi <= dgi + 3'd1;
                    st  <= R_DIG;
                end
            end

            //---------------- 分隔 / 行尾 ------------------------------
            R_SEP: begin
                if (chi == NCH[2:0] - 3'd1) begin
                    st <= R_CR;              // 最后一个通道：不发逗号
                end else if (byte_done) begin
                    chi <= chi + 3'd1;
                    st  <= R_CH;
                end
            end

            R_CR: if (byte_done) st <= R_LF;
            R_LF: if (byte_done) st <= R_IDLE;

            default: st <= R_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
