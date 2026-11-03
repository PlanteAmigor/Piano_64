// Scope sample processing stays at 50 MHz; only finished coordinates cross
// into the 148.5 MHz pixel domain. Each coordinate pair is held until the
// next audio sample, far longer than the three-flop toggle synchronizer.
`default_nettype none
module ui_scope_points(input wire clk,input wire rst_n,input wire [1:0] flt_sel,
    input wire signed [15:0] SCOPE_SMP,input wire SCOPE_TOG,input wire SCOPE_TRG,
    output reg [7:0] px_pt,py_pt,output reg point_toggle);
    reg scope_t0, scope_t1, scope_t2;
    reg trg_t0,   trg_t1,   trg_t2;

    always @(posedge clk) begin
        if (!rst_n) begin
            scope_t0 <= 1'b0; scope_t1 <= 1'b0; scope_t2 <= 1'b0;
            trg_t0   <= 1'b0; trg_t1   <= 1'b0; trg_t2   <= 1'b0;
        end
        else begin
            scope_t0 <= SCOPE_TOG;
            scope_t1 <= scope_t0;
            scope_t2 <= scope_t1;
            trg_t0   <= SCOPE_TRG;
            trg_t1   <= trg_t0;
            trg_t2   <= trg_t1;
        end
    end
    wire plot   = scope_t1 ^ scope_t2;      // 单拍：新样点
    wire noteon = trg_t1   ^ trg_t2;        // 单拍：新的 note-on

    // ── 样点延迟线（相位图 y 轴取 Δ=24 样点前的自身）──────────────
    //    不能用 L/R 做 XY —— 本工程是单声道，左右完全一样 → 一条直线。
    //
    //    ★ 必须注意：综合器会把「移位 + 只有末端被读 + 读出直接进寄存器」
    //      识别成 SRL/RAM，如果这条链上还有复位逻辑，就会报
    //         ERROR (PA2122) Not support WRITE_MODE = 2'b10
    //      所以延迟链不带复位，初值用 initial 给（FPGA 上电即 0）。
    (* syn_ramstyle = "registers" *)
    // ── 直流阻断（一阶高通，≈ 15 Hz）────────────────────────────
    //   ★ 修「笛子图形从右下到左上漂移」：相图 x=s[n]、y=s[n-Δ]，
    //     信号带缓慢直流 D 时两个轴【同时】偏移 D，图形就沿 x=y
    //     对角线平移，余辉又把沿途位置叠起来 → "一坨"。
    //     x/y 用同一个滤波器，椭圆形状不变。
    //   截止 ≈ fs·(1/512)/(2π) ≈ 15 Hz，最低音 262 Hz 完全不受影响。
    //   差分式：y[n] = x[n] - x[n-1] + y[n-1]·(1 - 2^-9)
    //
    //   ★★ 必须给初值！feedback 结构里只要有一个 X，就会永久锁在 X
    //      （dc_fb = X，dc_o = X，下一拍还是 X）→ smp_q 全 X →
    //      pk 变 X → (pk != 0) 为 X → 永远不打点 → 整块图形全黑。
    //      FPGA 上电 FF 是 0 所以硬件不会复现，只有仿真会。
    reg signed [15:0] dc_x1, dc_y1;
    initial begin
        dc_x1 = 16'sd0;
        dc_y1 = 16'sd0;
    end

    wire signed [17:0] dc_x  = $signed({{2{SCOPE_SMP[15]}}, SCOPE_SMP});
    wire signed [17:0] dc_xd = $signed({{2{dc_x1[15]}}, dc_x1});
    wire signed [17:0] dc_yd = $signed({{2{dc_y1[15]}}, dc_y1});
    wire signed [17:0] dc_d  = dc_x - dc_xd;
    wire signed [17:0] dc_fb = dc_yd - (dc_yd >>> 9);
    wire signed [17:0] dc_s  = dc_d + dc_fb;
    wire signed [17:0] dc_o  = (dc_s >  18'sd32767) ?  18'sd32767 :
                               (dc_s < -18'sd32768) ? -18'sd32768 : dc_s;

    // ── 显示用低通（两级一阶串联，12 dB/oct）──────────────────────
    //   针对「线条不像唢呐那样细」：
    //     笛子有气流噪声（宽带）→ 每个样点被推偏一点 → 线条变宽
    //     钢琴/古筝高次谐波丰富 → 相邻样点跳变大 → 描出的带更宽
    //   低通削掉这些高频抖动，线条立刻变细、图形更简洁。
    //   ★ 只滤显示，音频通路完全不动。
    //   截止（fs=48828）：k=2 → ≈1.9 kHz；k=3 → ≈970 Hz；k=0 → 直通
    //   y[n] = y[n-1] + (x[n] - y[n-1]) / 2^k   （k=0 时 y=x，等效不滤）
    //   ★★ 必须每级单独打一拍。写成一条组合链
    //      （dc 限幅 → 减 → 动态移位 → 加 → 再一级 → 加）是 15 ns 级，
    //      在 clk_pix 上拖出 149 个 setup 违例，而且连带把 CLK_SYS /
    //      sysclk 的布点一起拖坏（Fmax 从 78 掉到 67）。
    //      plot 只占 1/1536 拍，加几级流水毫无代价。
    wire [3:0]    lp_k  = (flt_sel == 2'd0) ? 4'd0 :
                          (flt_sel == 2'd1) ? 4'd2 : 4'd3;

    reg signed [15:0] dcr;          // 第 0 拍：直流阻断输出
    reg signed [15:0] lp1, lp2;     // 第 1 / 2 拍：两级低通
    reg               f1, f2, f3;   // 流水有效标志

    // ★★ 差分必须用 17 位！信号是 ±24000，两点之差可达 48000，
    //    16 位有符号（±32767）装不下 → 溢出反号 → 滤波器朝反方向走 →
    //    波形变成圆角方波。仿真踩过一次。
    wire signed [16:0] lp_d1 = $signed({dcr[15], dcr}) - $signed({lp1[15], lp1});
    wire signed [16:0] lp_v1 = $signed({lp1[15], lp1}) + (lp_d1 >>> lp_k);
    wire signed [16:0] lp_d2 = $signed({lp1[15], lp1}) - $signed({lp2[15], lp2});
    wire signed [16:0] lp_v2 = $signed({lp2[15], lp2}) + (lp_d2 >>> lp_k);

    initial begin
        dcr = 16'sd0; lp1 = 16'sd0; lp2 = 16'sd0;
        f1  = 1'b0;   f2  = 1'b0;   f3  = 1'b0;
    end

    reg signed [16*25-1:0] dly;
    initial dly = {(16*25){1'b0}};

    always @(posedge clk) begin
        f1 <= plot;
        f2 <= f1;
        f3 <= f2;

        if (plot) begin
            dc_x1 <= SCOPE_SMP;
            dc_y1 <= dc_o[15:0];
            dcr   <= dc_o[15:0];
        end
        // 第 1 级低通
        if (f1) lp1 <= lp_v1[15:0];
        // 第 2 级低通
        if (f2) lp2 <= lp_v2[15:0];
        // 第 3 拍：送进延迟线
        if (f3) dly <= {dly[16*24-1:0], lp2};
    end
    wire signed [15:0] smp_q = dly[15:0];            // 当前样点
    wire signed [15:0] smp_d = dly[16*24 +: 16];     // 24 个样点之前

    // ── AGC 峰值跟随 ────────────────────────────────────────────
    //    AGC_DEC = 4：满幅 32768 每样点降 4 → 8192 样点 ≈ 168 ms
    //    比最低音周期（3.8 ms）慢得多，不会把椭圆本身画歪；
    //    又比一个音的衰减快得多，所以半径能一直保持恒定。
    localparam [15:0] AGC_DEC = 16'd4;

    reg [15:0] ax,ay,peak_xy;
    always @(posedge clk)begin
        if(!rst_n)begin ax<=0;ay<=0;peak_xy<=0;end
        else begin
            ax<=smp_q[15] ? (~smp_q+16'd1):smp_q;
            ay<=smp_d[15] ? (~smp_d+16'd1):smp_d;
            peak_xy<=ax>ay?ax:ay;
        end
    end

    reg [15:0] pk;
    always @(posedge clk) begin
        if (!rst_n)       pk <= 16'd0;
        else if (noteon)  pk <= 16'd0;          // 新音：重新起峰
        else if (plot) begin
            if (peak_xy >= pk)     pk <= peak_xy;
            else if (pk > AGC_DEC) pk <= pk - AGC_DEC;
            else                   pk <= 16'd0;
        end
    end

    // ── 增益 = 2^-sh × Cq ───────────────────────────────────────
    //    sh 把峰值挪到 8 位范围（峰 >> sh 落在 128..255），
    //    Cq 再把剩下的 1~2 倍误差补平，于是峰值恒等于 ≈104（半窗）。
    //    ★ 只用移位会得到一个 2 倍的锯齿：pk 每衰减一半，图就从"满"
    //      跳回"半"，形成 ~90 Hz 的呼吸感。Cq 就是为了消掉它。
    //
    //    Cq = round(96 × 256 / p8)，按 p8 的高 5 位查表（32 项）
    //    ★ 目标 96（不是 104）：留出 8 px 边距，图形不贴框边，
    //      也避免 AGC 量化误差导致轻微削顶。
    function [7:0] agc_gain;
        input [4:0] i;
        begin
            case (i)
            5'd16:   agc_gain = 8'd186;
            5'd17:   agc_gain = 8'd176;
            5'd18:   agc_gain = 8'd166;
            5'd19:   agc_gain = 8'd158;
            5'd20:   agc_gain = 8'd150;
            5'd21:   agc_gain = 8'd143;
            5'd22:   agc_gain = 8'd137;
            5'd23:   agc_gain = 8'd131;
            5'd24:   agc_gain = 8'd125;
            5'd25:   agc_gain = 8'd120;
            5'd26:   agc_gain = 8'd116;
            5'd27:   agc_gain = 8'd112;
            5'd28:   agc_gain = 8'd108;
            5'd29:   agc_gain = 8'd104;
            5'd30:   agc_gain = 8'd101;
            5'd31:   agc_gain = 8'd98;
            default: agc_gain = 8'd192;   // p8 < 128：小信号，给最大增益
            endcase
        end
    endfunction

    reg [3:0] pk_k;
    always @(*) begin
        if      (pk[15]) pk_k = 4'd15;
        else if (pk[14]) pk_k = 4'd14;
        else if (pk[13]) pk_k = 4'd13;
        else if (pk[12]) pk_k = 4'd12;
        else if (pk[11]) pk_k = 4'd11;
        else if (pk[10]) pk_k = 4'd10;
        else if (pk[9])  pk_k = 4'd9;
        else if (pk[8])  pk_k = 4'd8;
        else if (pk[7])  pk_k = 4'd7;
        else if (pk[6])  pk_k = 4'd6;
        else if (pk[5])  pk_k = 4'd5;
        else if (pk[4])  pk_k = 4'd4;
        else if (pk[3])  pk_k = 4'd3;
        else if (pk[2])  pk_k = 4'd2;
        else if (pk[1])  pk_k = 4'd1;
        else             pk_k = 4'd0;
    end

    // ── AGC 计算：拆成 5 级流水 ──────────────────────────────────
    //
    //   ★ 一条组合链写下来是 15.2 ns（要求 13.33 ns @75 MHz），
    //     在 clk_pix 上产生 17 个 setup 违例。所以拆成 5 级：
    //        pl1  |x|、|y|、符号、峰值 MSB 位置
    //        pl2  移位量 + 增益查表
    //        pl3  归一化到 8 位
    //        pl4  乘增益 + 限幅 + 符号 → 位图坐标
    //        pl5  送位图打点
    //     每级只在各自那拍更新，总延迟 5 拍 ≈ 67 ns，
    //     对 48.8 kHz 的样点率完全无影响。

    reg pl1, pl2, pl3, pl4, pl5;
    always @(posedge clk) begin
        if (!rst_n) begin
            pl1 <= 1'b0; pl2 <= 1'b0; pl3 <= 1'b0; pl4 <= 1'b0; pl5 <= 1'b0;
        end
        else begin
            pl1 <= liss_plot;
            pl2 <= pl1;  pl3 <= pl2;  pl4 <= pl3;  pl5 <= pl4;
        end
    end

    // 1 级
    reg [15:0] ux_r, uy_r;
    reg        nx_r, ny_r;
    reg [3:0]  pk_k_r;
    always @(posedge clk) begin
        if (pl1) begin
            ux_r   <= ax;
            uy_r   <= ay;
            nx_r   <= smp_q[15];
            ny_r   <= smp_d[15];
            pk_k_r <= pk_k;
        end
    end

    // 2 级
    wire [3:0]  sh_c = (pk_k_r > 4'd7) ? (pk_k_r - 4'd7) : 4'd0;
    wire [15:0] p8_c = pk >> sh_c;              // 128..255（pk>=128 时）
    reg  [3:0]  sh_r;
    reg  [7:0]  g_r;
    always @(posedge clk) begin
        if (pl2) begin
            sh_r <= sh_c;
            g_r  <= agc_gain(p8_c[7:3]);
        end
    end

    // 3 级
    reg [7:0] vx_r, vy_r;
    always @(posedge clk) begin
        if (pl3) begin
            vx_r <= ux_r >> sh_r;
            vy_r <= uy_r >> sh_r;
        end
    end

    // 4 级：乘增益 + 限幅 + 回符号
    //   ★ 8×8 乘法必须先把操作数扩展到 16 位，否则 Verilog 按操作数最大
    //     位宽（8 位）算，结果直接截断。
    wire [15:0] mx_c = ({8'd0, vx_r} * {8'd0, g_r}) >> 8;
    wire [15:0] my_c = ({8'd0, vy_r} * {8'd0, g_r}) >> 8;
    wire [7:0]  cx_c = (mx_c[7:0] > 8'd96) ? 8'd96 : mx_c[7:0];
    wire [7:0]  cy_c = (my_c[7:0] > 8'd96) ? 8'd96 : my_c[7:0];
    wire [7:0]  pxc  = nx_r ? (8'd128 - cx_c) : (8'd128 + cx_c);
    wire [7:0]  pyc  = ny_r ? (8'd128 - cy_c) : (8'd128 + cy_c);

    // ── 触发后静默 10 ms，等 AGC 收敛 ───────────────────────────
    //    note-on 那一拍 pk 被清 0，紧接着的第一个样点往往接近过零（很小），
    //    于是增益被放到最大 → 后面几个样点直接钳到 ±96 → 画出一坨垃圾。
    //    等 10 ms（500 个样点）pk 已经跟住包络，再开始画就干净了。
    //    ★ 不再有"捕获 200 ms 后冻结"—— 帧存靠荧光衰减持续刷新。
    localparam [15:0] SETTLE_LEN = 16'd500;     // 10 ms @ 48828 Hz

    reg [15:0] settle_cnt;
    reg        settle_ok;
    always @(posedge clk) begin
        if (!rst_n) begin
            settle_cnt <= 16'd0;
            settle_ok  <= 1'b1;                  // 上电不阻塞
        end
        else if (noteon) begin
            settle_cnt <= 16'd0;
            settle_ok  <= 1'b0;
        end
        else if (!settle_ok && plot) begin
            if (settle_cnt >= SETTLE_LEN) settle_ok <= 1'b1;
            else                          settle_cnt <= settle_cnt + 16'd1;
        end
    end

    // pk==0（刚复位/刚触发）时增益未建立，这一拍不打点，避免画出边界角点
    // 不把已经衰减到量化噪声的尾部重新放大成满屏轨迹。
    wire liss_plot = plot && settle_ok && (pk >= 16'd128);

    // 第 5 级：坐标送位图

    always @(posedge clk) begin
        if (!rst_n) begin
            px_pt   <= 8'd128;
            py_pt   <= 8'd128;point_toggle<=0;
        end
        else if (pl5) begin
            px_pt   <= pxc;
            py_pt   <= pyc;point_toggle<=~point_toggle;
        end
    end

endmodule
`default_nettype wire
