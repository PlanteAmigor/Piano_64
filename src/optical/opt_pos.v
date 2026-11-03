//==========================================================================
//  opt_pos —— 六路差分 → 横向位置 x（加权质心）
//
//  x = Σ (x_i · d_i) / Σ d_i ，只累加 d_i > 0 的部分（负值当 0）
//
//  x_i 的物理位置（F407 标定点）：0, 2.5, 5, 10, 12.5, 15 cm
//  ⚠️ 中间 5→10 cm 有 5 cm 大间隔，权重必须按真实坐标，不能等距
//
//  ── 为什么先不用 30 点双线性 ────────────────────────────────────
//    质心只需要 6 乘 + 1 除，能立刻验证「手左右移动 → x 单调」。
//    标定表可以随后替换这里的换算，接口不变。
//
//  ── 定点 ────────────────────────────────────────────────────────
//    X_Q8 = 256 → 1 LSB = 1/256 cm ≈ 39 µm，量程 0..3840 (0..15.00 cm)
//    分子 Σ(Xi_Q8 · di) 最大 3840×65535×6 ≈ 1.5e9 → 31 位
//    分母 Σdi 最大 393210 → 19 位
//    除法用 32 拍逐位长除，帧率 83 Hz 下完全够（600k 拍/帧）
//==========================================================================
`default_nettype none

module opt_pos #(
    parameter integer NCH = 6
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              frame_valid,
    input  wire [NCH*18-1:0] raw_flat,     // 逐帧原始 diff

    output reg  [15:0]       x_q8,         // 0..3840
    output reg  [23:0]       sum_pos,      // Σ max(di,0)，给 ρ 用（比带符号求和更抗噪）
    output reg               x_valid,      // 分母足够大 → 位置可信
    output reg  [15:0]       x_frame
);

    //----------------------------------------------------------------------
    // 权重：Xi × 256   0, 2.5, 5, 10, 12.5, 15 cm
    //----------------------------------------------------------------------
    function [11:0] wx(input [2:0] i);
        case (i)
            3'd0:    wx = 12'd0;      // 0    cm
            3'd1:    wx = 12'd640;    // 2.5  cm
            3'd2:    wx = 12'd1280;   // 5    cm
            3'd3:    wx = 12'd2560;   // 10   cm
            3'd4:    wx = 12'd3200;   // 12.5 cm
            default: wx = 12'd3840;   // 15   cm
        endcase
    endfunction

    //----------------------------------------------------------------------
    // 正部 + 加权累加
    //----------------------------------------------------------------------
    wire signed [23:0] d0 = $signed(raw_flat[18*0 +: 18]);
    wire signed [23:0] d1 = $signed(raw_flat[18*1 +: 18]);
    wire signed [23:0] d2 = $signed(raw_flat[18*2 +: 18]);
    wire signed [23:0] d3 = $signed(raw_flat[18*3 +: 18]);
    wire signed [23:0] d4 = $signed(raw_flat[18*4 +: 18]);
    wire signed [23:0] d5 = $signed(raw_flat[18*5 +: 18]);

    wire [23:0] p0 = (d0 > 24'sd0) ? d0[23:0] : 24'd0;
    wire [23:0] p1 = (d1 > 24'sd0) ? d1[23:0] : 24'd0;
    wire [23:0] p2 = (d2 > 24'sd0) ? d2[23:0] : 24'd0;
    wire [23:0] p3 = (d3 > 24'sd0) ? d3[23:0] : 24'd0;
    wire [23:0] p4 = (d4 > 24'sd0) ? d4[23:0] : 24'd0;
    wire [23:0] p5 = (d5 > 24'sd0) ? d5[23:0] : 24'd0;

    wire [23:0] den_w = p0 + p1 + p2 + p3 + p4 + p5;

    // 乘加：p 最大 262143（18 位有符号正部），w 最大 3840 → 单积 ≤ 1.0e9 → 32 位
    wire [31:0] t0 = wx(3'd0) * p0[17:0];
    wire [31:0] t1 = wx(3'd1) * p1[17:0];
    wire [31:0] t2 = wx(3'd2) * p2[17:0];
    wire [31:0] t3 = wx(3'd3) * p3[17:0];
    wire [31:0] t4 = wx(3'd4) * p4[17:0];
    wire [31:0] t5 = wx(3'd5) * p5[17:0];
    wire [33:0] num_w = {2'b00, t0} + {2'b00, t1} + {2'b00, t2}
                      + {2'b00, t3} + {2'b00, t4} + {2'b00, t5};

    // 分母小于这个值认为「没有手」，位置不可信
    //  ★ 基线（无手）实测 Σ ≈ 2000~2200 码，所以门限必须明显高于它，
    //    否则噪声会让 x 在 0 和「六路均值 7.5 cm」之间乱跳。
    // ★ 分母门限。手拿开时 den ≈ 2068（实测），手在 7~10 cm 时 den ≈ 7630。
    //   原来取 6000 → 只剩 25% 余量，手稍偏/角度一变就掉到门限以下，
    //   x_valid 变 0 → x_hold 冻结 → 弯音完全不动（而力度门限是 4000，所以音量正常）。
    //   改成 4500（基线 2068 的 2.2 倍，够防噪）。
    localparam [23:0] DEN_MIN = 24'd4500;

    //----------------------------------------------------------------------
    // 逐位长除：num / den → quo
    //----------------------------------------------------------------------
    reg        busy;
    reg [5:0]  k;
    reg [33:0] num_r;
    reg [23:0] den_r;
    reg [23:0] rem;
    reg [33:0] quo;

    wire [24:0] rem_sh = {rem, num_r[33]};        // 左移一位并带进被除数高位
    wire        ge     = (rem_sh >= {1'b0, den_r});
    wire [24:0] rem_nx = ge ? (rem_sh - {1'b0, den_r}) : rem_sh;
    wire [33:0] quo_n  = {quo[32:0], ge};

    always @(posedge clk) begin
        if (!rst_n) begin
            busy     <= 1'b0;
            k        <= 6'd0;
            num_r    <= 34'd0;
            den_r    <= 24'd0;
            rem      <= 24'd0;
            quo      <= 34'd0;
            x_q8     <= 16'd0;
            sum_pos  <= 24'd0;
            x_valid  <= 1'b0;
            x_frame  <= 16'd0;
        end else begin
            if (frame_valid && !busy) begin
                num_r   <= num_w;
                den_r   <= den_w;
                rem     <= 24'd0;
                quo     <= 34'd0;
                k       <= 6'd0;
                sum_pos <= den_w;
                x_valid <= (den_w >= DEN_MIN);
                busy    <= 1'b1;
            end else if (busy) begin
                // 左移、比较、减法；商位并到低位
                rem   <= rem_nx[23:0];
                num_r <= {num_r[32:0], 1'b0};
                quo   <= quo_n;
                if (k == 6'd33) begin
                    busy    <= 1'b0;
                    x_q8    <= (den_r >= DEN_MIN) ? quo_n[15:0] : 16'd0;
                    x_frame <= x_frame + 16'd1;
                end else begin
                    k <= k + 6'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
