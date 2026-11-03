//==========================================================================
//  report_feat —— 五路特征 → 串口十进制（115200-8N1）
//
//  每帧一行：
//      +0393210,+0388000,+0005210,+0000180,+000010\r\n
//       rho_raw   rho_dc    rho_ac    ac_env    half_period
//
//  每列固定 7 字符 = 符号 + 6 位数字（前导零保留，宽度固定便于对齐/解析）。
//  half_period 单位是「帧」（83.3 Hz），10 帧 = 8.3 Hz，5 帧 = 16.7 Hz。
//
//  Python: [int(x) for x in line.split(',')]
//
//  ── 握手 ────────────────────────────────────────────────────────
//    uart_tx 的 busy 是下一拍才拉高，必须 T_IDLE→T_SEND→T_WAIT 三态，
//    byte_done 用 uart_ready（不是 !uart_ready）。
//==========================================================================
`default_nettype none

module report_feat (
    input  wire              clk,
    input  wire              rst_n,

    input  wire              frame_valid,
    input  wire signed [23:0] rho_raw,
    input  wire signed [23:0] rho_dc,
    input  wire signed [23:0] rho_ac,
    input  wire signed [23:0] ac_env,
    input  wire [15:0]        half_period,
    input  wire [15:0]        x_q8,          // 质心横向位置，1 LSB = 1/256 cm
    input  wire signed [15:0] bend,         // 音分 ±200
    input  wire [7:0]         vel,          // 力度 0..255
    input  wire [2:0]         hw_err,        // AD7606 错误码，心跳里带出来

    output wire [7:0]        uart_char,
    output wire              uart_valid,
    input  wire              uart_ready
);

    localparam integer NV = 8;
    localparam integer NDIG = 6;

    function [19:0] pow10d(input [2:0] i);
        case (i)
            3'd0:    pow10d = 20'd100000;
            3'd1:    pow10d = 20'd10000;
            3'd2:    pow10d = 20'd1000;
            3'd3:    pow10d = 20'd100;
            3'd4:    pow10d = 20'd10;
            default: pow10d = 20'd1;
        endcase
    endfunction

    localparam R_IDLE = 3'd0,
               R_CH   = 3'd1,
               R_SIGN = 3'd2,
               R_DIG  = 3'd3,
               R_EMIT = 3'd4,
               R_SEP  = 3'd5,
               R_CR   = 3'd6,
               R_LF   = 3'd7;

    // ★ 心跳：1 秒没收到一帧就发 "!<hw_err>\r\n"。
    //   没有它，一旦 ADC 不出帧，串口一声不响，分不清是串口坏还是没采到。
    localparam integer HB_DIV = 50_000_000;
    localparam [2:0] H_IDLE = 3'd0, H_BANG = 3'd1, H_NUM = 3'd2,
                     H_CR   = 3'd3, H_LF   = 3'd4;

    reg [25:0] idle_cnt;
    reg        hb_req;
    reg [2:0]  hst;
    reg [2:0]  err_lat;

    reg [2:0] st;
    reg [2:0] chi;
    reg [2:0] dgi;
    reg [19:0] cur;
    reg [3:0] dg;
    reg       neg;

    reg signed [23:0] v [0:NV-1];
    integer j;

    wire signed [23:0] vcur = v[chi];
    wire signed [23:0] vabs = (vcur < 24'sd0) ? (-vcur) : vcur;

    //----------------------------------------------------------------------
    // 输出握手
    //----------------------------------------------------------------------
    reg [7:0] put_byte;
    reg       put_vld;
    reg [1:0] tst;

    assign uart_char  = put_byte;
    assign uart_valid = put_vld && (tst == 2'd1);

    wire busy_now  = !uart_ready;
    wire byte_done = (tst == 2'd2) && uart_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            tst <= 2'd0;
        end else begin
            case (tst)
            2'd0: if (put_vld)  tst <= 2'd1;
            2'd1: if (busy_now) tst <= 2'd2;
            2'd2: if (!busy_now) tst <= 2'd0;
            default: tst <= 2'd0;
            endcase
        end
    end

    //----------------------------------------------------------------------
    // 本拍要发什么
    //----------------------------------------------------------------------
    always @(*) begin
        put_byte = 8'h00;
        put_vld  = 1'b0;
        case (st)
            R_SIGN: begin put_byte = neg ? 8'h2D : 8'h2B; put_vld = 1'b1; end
            R_EMIT: begin put_byte = 8'h30 + {4'd0, dg};  put_vld = 1'b1; end
            R_SEP:  begin put_byte = 8'h2C; put_vld = (chi != NV - 1);    end
            R_CR:   begin put_byte = 8'h0D; put_vld = 1'b1; end
            R_LF:   begin put_byte = 8'h0A; put_vld = 1'b1; end
            default: ;
        endcase
        // 心跳（与普通行互斥：只在 st==R_IDLE 时才进心跳）
        if (hst == H_BANG)     begin put_byte = 8'h21;                 put_vld = 1'b1; end
        else if (hst == H_NUM) begin put_byte = 8'h30 + err_lat;       put_vld = 1'b1; end
        else if (hst == H_CR)  begin put_byte = 8'h0D;                 put_vld = 1'b1; end
        else if (hst == H_LF)  begin put_byte = 8'h0A;                 put_vld = 1'b1; end
    end

    //----------------------------------------------------------------------
    // 主状态机
    //----------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            st  <= R_IDLE;
            chi <= 3'd0;
            dgi <= 3'd0;
            cur <= 20'd0;
            dg  <= 4'd0;
            neg <= 1'b0;
            idle_cnt <= 26'd0;
            hb_req   <= 1'b0;
            hst      <= H_IDLE;
            err_lat  <= 3'd0;
            for (j = 0; j < NV; j = j + 1) v[j] <= 24'sd0;
        end else begin
            // ---- 心跳计时 ----
            if (frame_valid) begin
                idle_cnt <= 26'd0;
                hb_req   <= 1'b0;
            end else if (idle_cnt >= HB_DIV) begin
                idle_cnt <= 26'd0;
                hb_req   <= 1'b1;
            end else begin
                idle_cnt <= idle_cnt + 26'd1;
            end

            // ---- 心跳小状态机（只发 !<err>\r\n，四拍）----
            case (hst)
            H_IDLE: if (hb_req && st == R_IDLE) begin
                        err_lat <= hw_err;
                        hb_req  <= 1'b0;
                        hst     <= H_BANG;
                    end
            H_BANG: if (byte_done) hst <= H_NUM;
            H_NUM:  if (byte_done) hst <= H_CR;
            H_CR:   if (byte_done) hst <= H_LF;
            H_LF:   if (byte_done) hst <= H_IDLE;
            default: hst <= H_IDLE;
            endcase

            case (st)
            R_IDLE: begin
                if (frame_valid && hst == H_IDLE) begin
                    v[0] <= rho_raw;
                    v[1] <= rho_dc;
                    v[2] <= rho_ac;
                    v[3] <= ac_env;
                    v[4] <= $signed({8'd0, half_period});
                    v[5] <= $signed({8'd0, x_q8});
                    v[6] <= bend;
                    v[7] <= $signed({16'd0, vel});
                    chi  <= 3'd0;
                    st   <= R_CH;
                end
            end

            R_CH: begin
                neg <= (vcur < 24'sd0);
                cur <= vabs[19:0];
                dgi <= 3'd0;
                dg  <= 4'd0;
                st  <= R_SIGN;
            end

            R_SIGN: if (byte_done) st <= R_DIG;

            R_DIG: begin
                if (cur >= pow10d(dgi)) begin
                    cur <= cur - pow10d(dgi);
                    dg  <= dg + 4'd1;
                end else begin
                    st <= R_EMIT;
                end
            end

            R_EMIT: if (byte_done) begin
                dg <= 4'd0;
                if (dgi == NDIG - 1) begin
                    st <= R_SEP;
                end else begin
                    dgi <= dgi + 3'd1;
                    st  <= R_DIG;
                end
            end

            R_SEP: begin
                if (chi == NV - 1)      st <= R_CR;
                else if (byte_done) begin chi <= chi + 3'd1; st <= R_CH; end
            end

            R_CR: if (byte_done) st <= R_LF;
            R_LF: if (byte_done) st <= R_IDLE;

            default: st <= R_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
