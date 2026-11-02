//==========================================================================
//  fx_chorus —— 立体声合唱（CHORUS）
//
//  ★ LFO 正弦用【工程里已验证的 add_sine_lut】(1024 点 BSRAM ROM)
//  -----------------------------------------------------------------------
//  最初自己写了个「65 项 case + 嵌套函数 + 从连续赋值里调用」的正弦，
//  仿真能过、与 Python 模型 bit-exact，但**上板后笛子的音高随机乱跳 + 滋滋**，
//  而软件模型完全干净。时序余量也修到 +4.8% 了，问题依旧。
//  症状「真机上随机跳、模型上平滑」说明 LFO 输出在硬件上是垃圾值 ——
//  这个自制的正弦是整个设计里唯一没在其它模块用过的构造。
//  改用 add_engine8 里一直在用的 add_sine_lut（1024 点、10 位插值），
//  插值误差 ~1e-6，比原来的 64 点方案好 256 倍。
//
//  延迟线读数插值（Q8 frac）
//  -----------------------------------------------------------------------
//  延迟量连续变化，只取整数延迟会有阶梯 → 拉链噪声。
//
//  每拍最多 1 个乘法，绝不串联
//  -----------------------------------------------------------------------
//  时序报告实测：全设计最差路径曾在
//      u_fx_chorus/ph_*_s0/Q  → u_fx_chorus/dint_l_*_s0/D
//      u_fx_chorus/mx_*_s0/Q  → u_fx_chorus/out_l_*_s0/D
//  即「正弦表 → 乘法 → 地址」和「混音 → 软限幅 d*d」。现在正弦走 BSRAM
//  同步读（天生打一拍），软限幅换成无乘法的硬钳位。
//
//  参数（fs = 48828.125 Hz）
//  -----------------------------------------------------------------------
//      base 12.0 ms → 585.9375 样本 → Q8 = 150000
//      音分 = 1200*log2(1 + 2*pi*D*f)，D=深度[秒]，f=LFO[Hz]
//      LFO_STEP = f * 2^32 / fs      0.6Hz → 52777   0.15Hz → 13194
//      延迟范围 = base ± depth 必须 < ABUF
//
//==========================================================================
`default_nettype none

module fx_chorus #(
    parameter integer ABUF     = 1024,      // 延迟线深度（必须是 2 的幂）
    parameter integer BASE_Q8  = 150000,    // 基延迟 12.0ms，Q8 样本
    parameter integer DEPTH_Q8 = 25000,     // 调制深度 2.0ms = 97.66 样本
    parameter integer LFO_STEP = 52777,     // LFO 频率 0.6Hz
    parameter integer GD_Q8    = 149,       // 干声 0.582
    parameter integer GW_Q8    = 149        // 湿声 0.582
)(
    input  wire               clk,          // clk_sys = 50 MHz
    input  wire               rst_n,
    input  wire               tick,         // 每音频采样一个脉冲（1024 周期）
    input  wire               enable,       // 1 = 应用合唱；0 = 旁通
    input  wire signed [15:0] in_l,
    input  wire signed [15:0] in_r,
    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r
);

    localparam integer AW = 10;                      // log2(ABUF)
    localparam [31:0]  PH_QUARTER = 32'h4000_0000;   // 90°

    //======================================================================
    //  1. LFO 正弦：复用工程里已验证的 1024 点 ROM
    //     dout = { sin(i+1), sin(i) }，i = phase[31:22]，插值系数 = phase[21:12]
    //     同步读 → 设定地址后下一拍数据有效
    //======================================================================
    reg  [9:0]  sin_addr;
    wire [31:0] sin_dout;

    add_sine_lut #(.AW(10), .DEPTH(1024)) u_lfo_sin (
        .clk  (clk),
        .addr (sin_addr),
        .dout (sin_dout)
    );

    wire signed [15:0] sin_s0 = sin_dout[15:0];    // sin(i)
    wire signed [15:0] sin_s1 = sin_dout[31:16];   // sin(i+1)

    //  ★★ ROM 同步读是【两拍】的：X 拍设地址 → X+1 地址进寄存器 →
    //     X+1 拍沿上才读 → X+2 数据才有效。按组合时序（X+1）去取会把
    //     上一采样的右相位当成左相位，即两路正弦直接搞反
    //     （实测内部信号：RTL sv_l=32721 sv_r=1719，模型正好相反）。
    //     所以地址在 st1（左）、st2（右）分别施加，数据在 st3、st4 取；
    //     并且插值系数必须分开存，不能共用一个寄存器。
    reg  [9:0]        lfo_fr_l, lfo_fr_r;
    reg  [3:0]        st;

    //  同一份乘法，按状态选左/右的插值系数
    wire [9:0]        fr_sel = (st == 4'd4) ? lfo_fr_r : lfo_fr_l;
    wire signed [17:0] lfo_ds = $signed(sin_s1) - $signed(sin_s0);
    wire signed [27:0] lfo_p  = lfo_ds * $signed({1'b0, fr_sel});
    wire signed [17:0] lfo_v  = $signed(sin_s0) + (lfo_p >>> 10);

    //======================================================================
    //  2. 延迟量（Q8 样本）
    //======================================================================
    reg [AW-1:0] wr;              // 写指针 = 当前采样序号 mod 1024
    reg [31:0]   ph_cur;          // 本样点的 LFO 相位（st1 锁存）
    reg [31:0]   ph;              // LFO 相位累加器

    wire [31:0] ph_r = ph_cur + PH_QUARTER;   // 右声道相位（差 90°）

    reg signed [17:0] sv_l, sv_r;

    reg [9:0] dint_l, dint_r;     // 整数延迟
    reg [7:0] frac_l, frac_r;     // 小数延迟

    //  25000 * 32767 = 8.19e8（32 位有符号足够）
    wire signed [31:0] dq8_l = BASE_Q8 + ((DEPTH_Q8 * sv_l) >>> 15);
    wire signed [31:0] dq8_r = BASE_Q8 + ((DEPTH_Q8 * sv_r) >>> 15);

    //  a = x[n - D_int]，b = x[n - D_int - 1]
    wire [AW-1:0] ada_l = wr - dint_l[AW-1:0];
    wire [AW-1:0] adb_l = ada_l - 1'b1;
    wire [AW-1:0] ada_r = wr - dint_r[AW-1:0];
    wire [AW-1:0] adb_r = ada_r - 1'b1;

    //======================================================================
    //  3. 两条环形延迟线（各 1 个 BSRAM）
    //     读地址组合形式：地址不打卡、只有数据打卡 → 只 1 拍延迟。
    //     写与读地址永不相同（dint >= BASE-DEPTH = 415），SDP 安全。
    //======================================================================
    reg [15:0] mem_l [0:ABUF-1];
    reg [15:0] mem_r [0:ABUF-1];

    //  ★ rd_sel_b 必须由 st 组合译码，不能打拍（寄存的话赋值那拍不生效）
    wire          rd_sel_b = (st == 4'd7);   // st6 施加地址 a，st7 施加地址 b
    wire [AW-1:0] ra_l = rd_sel_b ? adb_l : ada_l;
    wire [AW-1:0] ra_r = rd_sel_b ? adb_r : ada_r;

    reg          we;
    reg [AW-1:0] wa;
    reg [15:0]   wd_l, wd_r;
    reg [15:0]   rd_l, rd_r;

    always @(posedge clk) begin
        if (we) begin
            mem_l[wa] <= wd_l;
            mem_r[wa] <= wd_r;
        end
        rd_l <= mem_l[ra_l];
        rd_r <= mem_r[ra_r];
    end

    //======================================================================
    //  4. 每采样 11 拍的时序机（一个采样有 1024 拍，非常宽裕）
    //
    //       st0  等 tick
    //       st1  写当前样本，锁存干声和本样点相位，ph 前进；施加左相位地址
    //       st2  施加右相位地址
    //       st3  取左正弦（ROM 两拍延迟，到这里才有效）
    //       st4  取右正弦；由左正弦算 dint_l/frac_l
    //       st5  由右正弦算 dint_r/frac_r
    //       st6  施加读地址 a（两路 dint 必须都已就绪）
    //       st7  抓 a；施加读地址 b
    //       st8  抓 b
    //       st9  线性插值 → wet
    //       st10 干湿混合 + 钳位 → 输出，写指针前进
    //
    //  ★ st6 这个「只施加地址」的拍不能省：dint_r 在 st5 才锁存，
    //    若 st5 就施加地址 a，右声道会用到旧 dint_r（曾经读到刚写入的
    //    mem_r[0]，bit-exact 校验当场抓到 out_r 在 n=0 错一个值）。
    //======================================================================
    reg signed [16:0] a_l, a_r;
    reg signed [16:0] b_l, b_r;
    reg signed [16:0] wet_l, wet_r;
    reg signed [15:0] dry_l, dry_r;

    //  线性插值：out = a + (b-a)*frac/256
    wire signed [16:0] da_l = b_l - a_l;
    wire signed [16:0] da_r = b_r - a_r;
    wire signed [24:0] pa_l = da_l * $signed({1'b0, frac_l});
    wire signed [24:0] pa_r = da_r * $signed({1'b0, frac_r});
    wire signed [16:0] ip_l = a_l + (pa_l >>> 8);
    wire signed [16:0] ip_r = a_r + (pa_r >>> 8);

    //  干湿混合（Q8）
    wire signed [31:0] mx_l = ($signed(dry_l) * GD_Q8 + wet_l * GW_Q8) >>> 8;
    wire signed [31:0] mx_r = ($signed(dry_r) * GD_Q8 + wet_r * GW_Q8) >>> 8;

    //  硬钳位（无乘法，只作兜底；引擎峰值 25886 下永不触发）
    function signed [15:0] clamp16;
        input signed [31:0] x;
        begin
            if (x > 32'sd32767)       clamp16 = 16'sd32767;
            else if (x < -32'sd32768) clamp16 = -16'sd32768;
            else                      clamp16 = x[15:0];
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            st       <= 4'd0;
            wr       <= {AW{1'b0}};
            ph       <= 32'd0;
            ph_cur   <= 32'd0;
            sin_addr <= 10'd0;
            lfo_fr_l <= 10'd0;
            lfo_fr_r <= 10'd0;
            we       <= 1'b0;
            wa       <= {AW{1'b0}};
            wd_l     <= 16'd0;      wd_r   <= 16'd0;
            sv_l     <= 18'sd0;     sv_r   <= 18'sd0;
            dint_l   <= 10'd0;      dint_r <= 10'd0;
            frac_l   <= 8'd0;       frac_r <= 8'd0;
            a_l      <= 17'sd0;     a_r    <= 17'sd0;
            b_l      <= 17'sd0;     b_r    <= 17'sd0;
            wet_l    <= 17'sd0;     wet_r  <= 17'sd0;
            dry_l    <= 16'sd0;     dry_r  <= 16'sd0;
            out_l    <= 16'sd0;     out_r  <= 16'sd0;
        end
        else begin
            case (st)
                //──────────────────────────────────────────────
                4'd0: if (tick) st <= 4'd1;

                //──────────────────────────────────────────────
                4'd1: begin
                    //  写当前样本（★ 旁通时也照常写，保证切入无缝）
                    we       <= 1'b1;
                    wa       <= wr;
                    wd_l     <= in_l;
                    wd_r     <= in_r;
                    dry_l    <= in_l;
                    dry_r    <= in_r;
                    //  锁存本样点相位，左右两路正弦都用它
                    ph_cur   <= ph;
                    ph       <= ph + LFO_STEP[31:0];
                    //  LFO 第一步：施加左相位地址
                    sin_addr <= ph[31:22];
                    lfo_fr_l <= ph[21:12];
                    st       <= 4'd2;
                end

                //──────────────────────────────────────────────
                4'd2: begin
                    we       <= 1'b0;
                    //  LFO 第二步：施加右相位地址
                    sin_addr <= ph_r[31:22];
                    lfo_fr_r <= ph_r[21:12];
                    st       <= 4'd3;
                end

                //──────────────────────────────────────────────
                4'd3: begin
                    sv_l <= lfo_v;                 // 左正弦
                    st   <= 4'd4;
                end

                //──────────────────────────────────────────────
                4'd4: begin
                    sv_r   <= lfo_v;               // 右正弦
                    dint_l <= dq8_l[17:8];
                    frac_l <= dq8_l[7:0];
                    st     <= 4'd5;
                end

                //──────────────────────────────────────────────
                4'd5: begin
                    dint_r <= dq8_r[17:8];
                    frac_r <= dq8_r[7:0];
                    st     <= 4'd6;
                end

                //──────────────────────────────────────────────
                4'd6: st <= 4'd7;      // 施加读地址 a（两路 dint 均已就绪）

                //──────────────────────────────────────────────
                4'd7: begin
                    a_l <= $signed(rd_l);          // rd_l = mem[地址 a]
                    a_r <= $signed(rd_r);
                    st  <= 4'd8;
                end

                //──────────────────────────────────────────────
                4'd8: begin
                    b_l <= $signed(rd_l);          // rd_l = mem[地址 b]
                    b_r <= $signed(rd_r);
                    st  <= 4'd9;
                end

                //──────────────────────────────────────────────
                4'd9: begin
                    wet_l <= ip_l;
                    wet_r <= ip_r;
                    st    <= 4'd10;
                end

                //──────────────────────────────────────────────
                4'd10: begin
                    out_l <= enable ? clamp16(mx_l) : dry_l;
                    out_r <= enable ? clamp16(mx_r) : dry_r;
                    wr    <= wr + 1'b1;
                    st    <= 4'd0;
                end

                default: st <= 4'd0;
            endcase
        end
    end

endmodule

`default_nettype wire
