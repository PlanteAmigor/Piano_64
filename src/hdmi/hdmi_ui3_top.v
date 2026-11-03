//==========================================================================
//  hdmi_ui3_top —— 1280×720@60 三页面渲染器（主页面 / 测试 / 教学）
//
//  与旧的 hdmi_spec_top 的区别
//    旧版只画一个 32 段频谱；本文件一次做完三个页面，由 KEY0 循环切换，
//    切页时做 24 ms 黑场淡出淡入（12 ms 出 + 12 ms 入）。
//
//  三个页面
//    page 0 主页面  状态栏 + 32 段频谱 + 64 分量高度(占位) + 李萨如(占位) + 信息框
//    page 1 测试    满幅 32 段频谱（8 路纯正弦，频谱上能数出 8 个独立峰）
//    page 2 教学    选歌 / 自动演奏 / 跟弹判定与倒计时
//
//  为什么不用帧缓冲
//    逐像素组合计算。75 MHz 像素时钟 → 每像素 13.3 ns。
//
//  三级流水（全部在 clk_p 域）
//    t0  px/py 有效 → 算行列/柱选
//    t1  登记行列 → 组合查「这一列这一行是哪个字符」→ 得字模地址
//        登记柱高换算后的像素高
//    t2  字模 BSRAM 读出 → 取位；柱子比较；画框/画线
//    t3  rgb 登记输出；de/hs/vs 同步延 3 拍（与数据严格对齐）
//
//  文字系统
//    统一字符网格：16 px 行高、8 px 列宽，起点 (8,8)
//        行号  ln  = (py-8)>>4     0..44
//        列号  col = (px-8)>>3     0..159
//        字形行    = (py-8)&15
//        字形列    = (px-8)&7
//    全屏只有一个字模 ROM，任何页面任何位置都用同一套硬件。
//    字符串用 32 字符定宽的参数常量存（右补空格），
//        s[(31-i)*8 +: 8]  取第 i 个字符
//    再经 a2i() 换成 ui_font_asc.hex 的 ROM 索引。
//
//  ★ 字符索引必须与 tools/gen_ui_font.py 的 ASC 字符串完全一致：
//      0-9 数字 / 10-35 A-Z / 36 空格 / 37 '.' / 38 ':' / 39 '/' / 40 '%'
//      41 '+' / 42 '-' / 43 'x' / 44 '(' / 45 ')' / 46 '[' / 47 ']'
//      48 '<' / 49 '>' / 50 '=' / 51 '#' / 52 '*' / 53 ',' / 54 '!'
//
//  柱子几何（两页共用同一套，只有基准线和高度系数不同）
//    列距 32（2 的幂，纯位移）、柱宽 24、起点 x=16
//    32×32 = 1024 px，正好占满左侧 1024 px 宽的区域
//==========================================================================
`default_nettype none

module hdmi_ui3_top (
    input  wire clk,                        // 50 MHz 晶振
    input  wire resetn,                     // 低有效

    // ── 来自 spec_cqt（clk_sys 域）──────────────────────────────────
    input  wire [32*8-1:0] BANDS,           // 32 × 8 位柱高
    input  wire            BANDS_TICK,      // 保留端口（采样不做门控，见下）

    // ── 来自 add_top 的状态总线（clk_sys 域，慢变量）─────────────────
    //    [1:0] ui_mode  [3:2] timbre  [6:4] fx  [18:11] transpose
    input  wire [18:0]     UI_INFO,
    input wire [255:0] SONG_UI,
    input wire SONG_UI_TOGGLE,
    output reg SONG_UI_ACK,

    // ── COMPONENT 64：最近触发声部的 64 根分量柱高度 ────────────────
    input  wire [64*8-1:0] COMP_AMP,

    // ── 李萨如（相位图）取样：SCOPE_TOG 每样点翻转一次 ──────────────
    input  wire signed [15:0] SCOPE_SMP,
    input  wire               SCOPE_TOG,
    // ── note-on 触发（每次按键触发翻转一次）────────────────────────
    input  wire               SCOPE_TRG,

    output wire       tmds_clk_n_0,
    output wire       tmds_clk_p_0,
    output wire [2:0] tmds_d_n_0,
    output wire [2:0] tmds_d_p_0
);

    // ══════════════════════════════════════════════════════════════
    //  时钟与复位
    //  ★ SIM_UI3 仅用于离线出图（tb 直接喂 clk，绕过 PLL 与 DVI 原语），
    //    build_full.tcl 从不定义它，不影响综合。
    // ══════════════════════════════════════════════════════════════
`ifdef SIM_UI3
    wire pll_lock = 1'b1;
    wire clk_p    = clk;
    wire clk_p5   = clk;
`else
    wire pll_lock, clk_p, clk_p5;
    Gowin_PLL_720P u_pll (
        .lock(pll_lock), .clkout0(clk_p), .clkout1(clk_p5), .clkin(clk)
    );
`endif

    reg [3:0] por = 4'd0;
    always @(posedge clk_p) begin
        if (!resetn || !pll_lock) por <= 4'd0;
        else if (por != 4'hF)     por <= por + 4'd1;
    end
    wire rst_n     = (por == 4'hF);
    wire dvi_reset = ~rst_n;

    // ══════════════════════════════════════════════════════════════
    //  BANDS 跨时钟域：clk_sys(50 MHz) → clk_p(75 MHz)
    //
    //  ★ 不要加 tick 门控！第一版写成 `if (bt_sync[1]) bands_cap <= BANDS;`，
    //    结果 bt_sync 又只来自 BANDS_TICK，两边互为前提，综合器判定这段
    //    无用，直接把整个 spec_cqt 扫掉（NL0002 is swept in optimizing）。
    //    物理上也根本不需要：BANDS 只在扫完 32 段时更新，两次更新之间静止
    //    几十毫秒，不存在多位撕裂窗口。直接每拍采样最稳。
    //  ★ 必须加复位，否则综合器按「上电未知 = don't care」处理。
    // ══════════════════════════════════════════════════════════════
    reg [255:0] bands_cap;
    reg [511:0] comp_cap;
    reg [18:0]  info_s0, info_s1;

    always @(posedge clk_p) begin
        if (!rst_n) begin
            bands_cap <= 256'd0;
            comp_cap  <= 512'd0;
            info_s0   <= 19'd0;
            info_s1   <= 19'd0;
        end
        else begin
            bands_cap <= BANDS;
            comp_cap  <= COMP_AMP;
            info_s0   <= UI_INFO;
            info_s1   <= info_s0;
        end
    end

    // Atomic status mailbox from the audio clock domain.
    reg [2:0] song_toggle_sync;
    reg [255:0] song_status;
    always @(posedge clk_p) begin
        if(!rst_n) begin song_toggle_sync<=0; SONG_UI_ACK<=0; song_status<=0; end
        else begin
            song_toggle_sync<={song_toggle_sync[1:0],SONG_UI_TOGGLE};
            if(song_toggle_sync[2]!=SONG_UI_ACK) begin
                song_status<=SONG_UI;
                SONG_UI_ACK<=song_toggle_sync[2];
            end
        end
    end
    wire guide_catalog_ready=song_status[232];
    wire [4:0] guide_count=song_status[132:128];
    wire [3:0] guide_selected=song_status[136:133];
    wire [2:0] guide_state=song_status[139:137];
    wire guide_teach=song_status[140];
    wire [1:0] guide_countdown=song_status[143:142];
    wire [6:0] guide_expected=song_status[150:144];
    wire [6:0] guide_matched=song_status[157:151];
    wire [7:0] guide_error=song_status[165:158];
    wire [31:0] guide_ms=song_status[197:166];
    wire [1:0]        page_req = info_s1[1:0];
    wire [1:0]        timbre   = info_s1[3:2];
    wire [2:0]        fx       = info_s1[6:4];   // 0=NONE 1=REVERB 2=DELAY 3=SUSTAIN 4=CHORUS
    wire [1:0]        agl      = info_s1[8:7];
    wire [1:0]        flt_sel  = info_s1[10:9];
    wire signed [7:0] tr       = info_s1[18:11];

    // ══════════════════════════════════════════════════════════════
    //  李萨如（相位图）：取样 + AGC + 单次捕获
    //
    //  1) 取样：发端（add_top）每样点锁一次 SCOPE_SMP 并翻转 SCOPE_TOG。
    //     这里把 SCOPE_TOG 打两拍后检测翻转沿产生单拍 plot；
    //     SCOPE_SMP 在两次翻转之间稳定 1024 个 clk_sys 周期（20.5 us），
    //     远大于两拍 clk_p（26.7 ns），所以直接在 plot 那拍采样即可。
    //
    //  2) AGC：峰值跟随（瞬时攻击 / 慢衰减）→ 归一化增益。
    //     解决两个问题：
    //       · 轻力度时图只有窗口的 1/8 大 → 现在一律撑满
    //       · 音符衰减过程中同一个椭圆被画成一串同心环 → 现在半径恒定
    //         （这是钢琴/古筝"模糊"的真正原因，不是分辨率不够）
    //
    //  3) 单次捕获：SCOPE_TRG（note-on）→ 清零 → 画 200 ms → 冻结。
    //     每个音只画一张干净、稳定、满幅的相位图。
    // ══════════════════════════════════════════════════════════════
    reg scope_t0, scope_t1, scope_t2;
    reg trg_t0,   trg_t1,   trg_t2;

    always @(posedge clk_p) begin
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

    always @(posedge clk_p) begin
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

    wire [15:0] ax = smp_q[15] ? (~smp_q + 16'd1) : smp_q;
    wire [15:0] ay = smp_d[15] ? (~smp_d + 16'd1) : smp_d;

    reg [15:0] pk;
    always @(posedge clk_p) begin
        if (!rst_n)       pk <= 16'd0;
        else if (noteon)  pk <= 16'd0;          // 新音：重新起峰
        else if (plot) begin
            if (ax >= pk)          pk <= ax;
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
    always @(posedge clk_p) begin
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
    always @(posedge clk_p) begin
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
    always @(posedge clk_p) begin
        if (pl2) begin
            sh_r <= sh_c;
            g_r  <= agc_gain(p8_c[7:3]);
        end
    end

    // 3 级
    reg [7:0] vx_r, vy_r;
    always @(posedge clk_p) begin
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
    always @(posedge clk_p) begin
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
    wire liss_plot = plot && settle_ok && (pk != 16'd0);

    // 第 5 级：坐标送位图
    reg [7:0] px_pt, py_pt;
    always @(posedge clk_p) begin
        if (!rst_n) begin
            px_pt   <= 8'd128;
            py_pt   <= 8'd128;
        end
        else if (pl5) begin
            px_pt   <= pxc;
            py_pt   <= pyc;
        end
    end

    // ══════════════════════════════════════════════════════════════
    //  切页淡入淡出：12 ms 淡出（15→0）→ 黑场换页 → 12 ms 淡入（0→15）
    //    75 MHz × 12 ms / 15 档 = 60000 拍/档
    // ══════════════════════════════════════════════════════════════
    localparam [15:0] FADE_STEP = 16'd59_999;

    reg [1:0]  page_show;
    reg [1:0]  page_pend;
    reg [3:0]  fade_lvl;
    reg        fading_out;
    reg [15:0] fade_cnt;

    always @(posedge clk_p) begin
        if (!rst_n) begin
            page_show  <= 2'd0;
            page_pend  <= 2'd0;
            fade_lvl   <= 4'd15;
            fading_out <= 1'b0;
            fade_cnt   <= 16'd0;
        end
        else if (!fading_out && (page_req != page_show)) begin
            fading_out <= 1'b1;              // 开始淡出
            page_pend  <= page_req;
            fade_cnt   <= 16'd0;
        end
        else if (fading_out) begin
            if (fade_cnt != FADE_STEP) fade_cnt <= fade_cnt + 16'd1;
            else begin
                fade_cnt <= 16'd0;
                if (fade_lvl != 4'd0) fade_lvl <= fade_lvl - 4'd1;
                else begin
                    page_show  <= page_pend; // 全黑时换页
                    fading_out <= 1'b0;
                end
            end
        end
        else if (fade_lvl != 4'd15) begin    // 淡入
            if (fade_cnt != FADE_STEP) fade_cnt <= fade_cnt + 16'd1;
            else begin
                fade_cnt <= 16'd0;
                fade_lvl <= fade_lvl + 4'd1;
            end
        end
    end

    // ══════════════════════════════════════════════════════════════
    //  720p 时序
    //
    //  ★★ 关键：PLL 出的是 75.000 MHz，不是标准的 74.25 MHz。
    //     如果照抄 CEA-861 的 H_TOTAL=1650，实际行频就是
    //         75e6 / 1650 = 45.4545 kHz（标准 45.000 kHz，快 1.01%）
    //         行频 / 750 = 60.606 Hz（标准 60.000，快 1.01%）
    //     大显示器容差大能认，但挑剔的屏（比如 1080p 小屏）会间歇性
    //     丢锁 —— 现象就是"一会儿亮一会儿灭"。
    //     所以把 H_TOTAL 改成 1667，让行频/帧率回到标准值：
    //         75e6 / 1667 = 44.991 kHz → /750 = 59.988 Hz
    //     多出来的 17 个像素补到后沿（blanking 387 = 110+40+237）。
    //
    //  行：FP 110 | SYNC 40 | BP 237 | ACTIVE 1280   = 1667
    //  场：FP   5 | SYNC  5 | BP  20 | ACTIVE  720   =  750
    // ══════════════════════════════════════════════════════════════
    localparam integer H_TOTAL = 1667, H_FP = 110, H_SYNC = 40, H_BP = 237;
    localparam integer V_TOTAL = 750,  V_FP = 5,   V_SYNC = 5,  V_BP = 20;
    localparam integer H_VIS = 1280, V_VIS = 720;
    localparam integer H_START = H_FP + H_SYNC + H_BP;      // 387
    localparam integer V_START = V_FP + V_SYNC + V_BP;      //  30

    reg [11:0] hcnt, vcnt;
    always @(posedge clk_p) begin
        if (dvi_reset) begin
            hcnt <= 12'd0; vcnt <= 12'd0;
        end
        else if (hcnt == H_TOTAL - 1) begin
            hcnt <= 12'd0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 12'd0 : (vcnt + 12'd1);
        end
        else hcnt <= hcnt + 12'd1;
    end

    wire h_vis = (hcnt >= H_START) && (hcnt < H_START + H_VIS);
    wire v_vis = (vcnt >= V_START) && (vcnt < V_START + V_VIS);
    wire vis   = h_vis && v_vis;

    // ── 帧存维护：上电全清一次 + 每帧荧光衰减 ────────────────
    //   ★ 不再周期全清。衰减 = 每帧整屏强度 -1，于是：
    //       最长余辉 15 帧（60 Hz 下 250 ms），就是记忆空档
    //       瞬态垃圾只有 1 级亮度，一两个周期内就看不见了
    //   衰减扇描 4096 字 × 2 拍 = 109 us，放在场消隐里（消隐 4.4 ms）
    reg [3:0] boot_cnt;
    always @(posedge clk_p) begin
        if (!rst_n)                 boot_cnt <= 4'd0;
        else if (boot_cnt != 4'd15) boot_cnt <= boot_cnt + 4'd1;
    end
    wire liss_clr   = (boot_cnt == 4'd8);
    wire liss_decay = (vcnt == 12'd1) && (hcnt == 12'd0);

    // ── 余辉档位（add_top 用 KEY_R2[0] 切换，经 UI_INFO[7:6] 传过来）──
    //   L1: 衰减 1 / 余辉 250 ms     L2: 衰减 3 / 余辉 83 ms
    //   L3: 衰减 7 / 余辉 36 ms      L4: 衰减 15 / 余辉 17 ms（≈每帧清空）
    //
    //   ★★ 打点固定【写满 15】，不是 +1。这是参考工程的做法：
    //      rschlaikjer/lissajous 里 alpha = (age/window)^2
    //      —— 亮度只跟"多久之前被扫过"有关，跟"被扫过多少次"无关。
    //      我们原来是 +1 累积（驻留性），于是束流慢的转折点疯狂累加成
    //      亮区、快的地方始终暗，用户看到的就是"右下一条边亮，其他
    //      地方隐隐约约"。改成写满后整个拖尾亮度均匀，只有新旧之分。
    //
    //   ★ 为什么 L4 要“每帧清空”：钢琴/古筝的 128 个模态频率是实测
    //     拟合值、不是精确谐波 → 波形准周期 → 相图缓慢旋转。余辉一长
    //     就把十多个转角度的副本叠成一条宽带，看起来"线条很粗"。
    //     唢呐谐波严格整数倍 → 图固定不动 → 余辉再长也是 1 px 细线。
    //    ★ agl 已在上面 info_s1 解析处统一提取（info_s1[8:7]），此处不再重复定义
    wire [3:0] agl_dec = (agl == 2'd0) ? 4'd1  :
                         (agl == 2'd1) ? 4'd3  :
                         (agl == 2'd2) ? 4'd7  : 4'd15;
    wire [3:0] agl_ink = 4'd15;          // 直接写满 → 亮度 = 最近性

    // 同步脉冲位置按 CEA-861：跟在【前沿】之后
    wire hsync = ~((hcnt >= H_FP) && (hcnt < H_FP + H_SYNC));
    wire vsync = ~((vcnt >= V_FP) && (vcnt < V_FP + V_SYNC));

    wire [11:0] px = hcnt - H_START;      // 0..1279
    wire [11:0] py = vcnt - V_START;      // 0..719

    // ══════════════════════════════════════════════════════════════
    //  t0：字符网格 + 柱选择
    // ══════════════════════════════════════════════════════════════
    wire cx_ok = (px >= 12'd8) && (px < 12'd1288);
    wire cy_ok = (py >= 12'd8) && (py < 12'd728);
    wire [11:0] cx = px - 12'd8;
    wire [11:0] cy = py - 12'd8;

    wire [7:0] tcol = cx[10:3];
    wire [2:0] tbit = cx[2:0];
    // ★★ 必须取 cy[9:4]（6 位，0..44）。写成 cy[8:4] 只有 5 位、最大 31，
    //    超过 py=519 之后行号回绕，第 0/4 行会被重复画到下面去
    //    （实测 y=520 处又出现一次 "PIANO64 MAIN"）。
    wire [5:0] tln  = cy[9:4];
    wire [3:0] tgy  = cy[3:0];

    // 柱子列选：列距 32、柱宽 24、起点 x=16
    // ★ 5 位字面量装不下 32 的坑踩过一次（被截断成 0 → 恒假 → 整个
    //   spec_cqt 被综合器扫掉），这里一律用 7 位字面量。
    wire [12:0] bx_raw = {1'b0, px} - 13'd16;
    wire b_sel = !bx_raw[12] && (bx_raw[11:10] == 2'b00) &&
                 (bx_raw[11:5] < 7'd32) && (bx_raw[4:0] < 5'd24);

    // 分量柱列选：列距 16（2 的幂）、柱宽 11、起点 x=64，共 64 根
    //   64 × 16 = 1024 px → 64..1087；左侧 8..63 留给 Y 轴刻度文字
    // ★★ 又是同一个坑：`ccx[9:4] < 6'd64` —— 6 位最大 63，64 被截断成 0，
    //    判断恒假，64 根柱子一根都不亮（iverilog 只给了一句
    //    "Numeric constant truncated to 6 bits" 的 warning）。
    //    这里改用 7 位字面量。
    wire [12:0] ccx  = {1'b0, px} - 13'd64;
    wire c_sel = !ccx[12] && (ccx[11:10] == 2'b00) &&
                 (ccx[9:4] < 7'd64) && (ccx[3:0] < 4'd11);

    // ══════════════════════════════════════════════════════════════
    //  t1 登记
    // ══════════════════════════════════════════════════════════════
    reg [11:0] px1, py1;
    reg [7:0]  tcol1;
    reg [2:0]  tbit1;
    reg [5:0]  tln1;
    reg [3:0]  tgy1;
    reg        txt_on1;
    reg [4:0]  bidx1;
    reg        bsel1;
    reg [5:0]  cidx1;
    reg        csel1;

    always @(posedge clk_p) begin
        px1     <= px;
        py1     <= py;
        tcol1   <= tcol;
        tbit1   <= tbit;
        tln1    <= tln;
        tgy1    <= tgy;
        txt_on1 <= cx_ok && cy_ok;
        bidx1   <= bx_raw[9:5];
        bsel1   <= b_sel;
        cidx1   <= ccx[9:4];
        csel1   <= c_sel;
    end

    // ══════════════════════════════════════════════════════════════
    //  字符串常量（32 字符定宽，右补空格）
    // ══════════════════════════════════════════════════════════════
    wire [255:0] S_MAIN   = {"PIANO64  MAIN",                {19{8'h20}}};  // 13
    wire [255:0] S_SPEC   = {"SPECTRUM 32",                  {21{8'h20}}};  // 11
    wire [255:0] S_COMP   = {"COMPONENT 64",                 {20{8'h20}}};  // 12
    wire [255:0] S_LISS   = {"LISSAJOUS",                    {23{8'h20}}};  //  9
    wire [255:0] S_TIMBR  = {"TIMBRE:",                      {25{8'h20}}};  //  7
    wire [255:0] S_FXL    = {"FX:",                          {29{8'h20}}};  //  3
    wire [255:0] S_TRL    = {"TRANS:",                       {26{8'h20}}};  //  6
    wire [255:0] S_AGL    = {"AGL:",                         {28{8'h20}}};  //  4
    wire [255:0] S_FILT   = {"FILT:",                        {27{8'h20}}};  //  5
    wire [255:0] S_FOFF   = {"OFF",                          {29{8'h20}}};
    wire [255:0] S_FMID   = {"MID",                          {29{8'h20}}};
    wire [255:0] S_FSTR   = {"STR",                          {29{8'h20}}};
    wire [255:0] s_fltname = (flt_sel == 2'd0) ? S_FOFF :
                             (flt_sel == 2'd1) ? S_FMID : S_FSTR;
    wire [255:0] S_TEST   = {"TEST MODE  8 SINE",            {15{8'h20}}};  // 17
    wire [255:0] S_GUIDE  = {"GUIDE MODE",                   {22{8'h20}}};  // 10
    wire [255:0] S_PEND   = {"PENDING",                      {25{8'h20}}};  //  7
    wire [255:0] S_NONE   = {"NONE",                         {28{8'h20}}};  //  4
    wire [255:0] S_REVERB = {"REVERB",                       {26{8'h20}}};  //  6
    wire [255:0] S_DELAY  = {"DELAY",                        {27{8'h20}}};  //  5
    wire [255:0] S_SUSTAIN= {"SUSTAIN",                      {25{8'h20}}};  //  7
    wire [255:0] S_CHORUS = {"CHORUS",                       {26{8'h20}}};  //  6
    wire [255:0] S_PIANO  = {"PIANO",                        {27{8'h20}}};  //  5
    wire [255:0] S_GUZH   = {"GUZHENG",                      {25{8'h20}}};  //  7
    wire [255:0] S_SUONA  = {"SUONA",                        {27{8'h20}}};  //  5
    wire [255:0] S_DIZI   = {"DIZI",                         {28{8'h20}}};  //  4
    // COMPONENT 64 的坐标轴刻度
    wire [255:0] S_Y192   = {"192",                          {29{8'h20}}};  //  3
    wire [255:0] S_Y128   = {"128",                          {29{8'h20}}};  //  3
    wire [255:0] S_Y64    = {"64",                           {30{8'h20}}};  //  2
    wire [255:0] S_CSUB   = {"128 SINE / 2 PER BAR",         {12{8'h20}}};  // 20

    wire [255:0] s_tname = (timbre == 2'd0) ? S_PIANO :
                           (timbre == 2'd1) ? S_GUZH  :
                           (timbre == 2'd2) ? S_SUONA : S_DIZI;
    wire [255:0] s_fname = (fx == 3'd0) ? S_NONE   :
                           (fx == 3'd1) ? S_REVERB :
                           (fx == 3'd2) ? S_DELAY  :
                           (fx == 3'd3) ? S_SUSTAIN : S_CHORUS;

    // ── ASCII → 字库 ROM 索引 ───────────────────────────────────────
    function [5:0] a2i;
        input [7:0] c;
        begin
            if      (c >= 8'h30 && c <= 8'h39) a2i = c - 8'h30;         // 0-9
            else if (c >= 8'h41 && c <= 8'h5A) a2i = c - 8'h41 + 6'd10; // A-Z
            else case (c)
                8'h20: a2i = 6'd36;   // 空格
                8'h2E: a2i = 6'd37;   // .
                8'h3A: a2i = 6'd38;   // :
                8'h2F: a2i = 6'd39;   // /
                8'h25: a2i = 6'd40;   // %
                8'h2B: a2i = 6'd41;   // +
                8'h2D: a2i = 6'd42;   // -
                8'h78: a2i = 6'd43;   // x
                8'h28: a2i = 6'd44;   // (
                8'h29: a2i = 6'd45;   // )
                8'h5B: a2i = 6'd46;   // [
                8'h5D: a2i = 6'd47;   // ]
                8'h3C: a2i = 6'd48;   // <
                8'h3E: a2i = 6'd49;   // >
                8'h3D: a2i = 6'd50;   // =
                8'h23: a2i = 6'd51;   // #
                8'h2A: a2i = 6'd52;   // *
                8'h2C: a2i = 6'd53;   // ,
                8'h21: a2i = 6'd54;   // !
                default: a2i = 6'd36;
            endcase
        end
    endfunction

    // 取定宽字符串的第 i 个字符
    function [5:0] gch;
        input [255:0] s;
        input [4:0]   i;
        begin
            gch = a2i(s[(5'd31 - i) * 8 +: 8]);
        end
    endfunction

    // COMPONENT 64 的 X 轴刻度（每 8 根标一个，第 1/9/17/25/33/41/49/57 根）
    //   ★ 只用单字符比较，不占资源；落在其它列就返回空格。
    function [5:0] xlbl;
        input [7:0] col;
        begin
            case (col)
            8'd7  : xlbl = 6'd1;              // 1
            8'd23 : xlbl = 6'd9;              // 9
            8'd39 : xlbl = 6'd1;              // 17
            8'd40 : xlbl = 6'd7;
            8'd55 : xlbl = 6'd2;              // 25
            8'd56 : xlbl = 6'd5;
            8'd71 : xlbl = 6'd3;              // 33
            8'd72 : xlbl = 6'd3;
            8'd87 : xlbl = 6'd4;              // 41
            8'd88 : xlbl = 6'd1;
            8'd103: xlbl = 6'd4;              // 49
            8'd104: xlbl = 6'd9;
            8'd119: xlbl = 6'd5;              // 57
            8'd120: xlbl = 6'd7;
            default: xlbl = 6'd36;
            endcase
        end
    endfunction

    // ── 移调值 → 3 字符（符号 / 十位 / 个位）─────────────────────────
    wire [7:0] tr_abs  = tr[7] ? (~tr + 8'd1) : tr;
    wire [3:0] tr_tens = (tr_abs >= 8'd20) ? 4'd2 : (tr_abs >= 8'd10) ? 4'd1 : 4'd0;
    wire [7:0] tr_ten10 = {tr_tens, 3'b000} + {2'b00, tr_tens, 1'b0};  // tens*10
    wire [3:0] tr_ones = tr_abs[3:0] - tr_ten10[3:0];

    function [255:0] guide_line;
        input [5:0] ln;
        begin
            guide_line={32{8'h20}};
            case(ln)
                4:case(guide_state)
                    0:guide_line={"SELECT SONG",{21{8'h20}}};
                    1:guide_line={"SELECT MODE",{21{8'h20}}};
                    2:guide_line={"LOADING SONG",{20{8'h20}}};
                    3:guide_line=guide_teach ? {"TEACHING",{24{8'h20}}} : {"AUTO PLAY",{23{8'h20}}};
                    default:guide_line={"READ ERROR",{22{8'h20}}};
                endcase
                8:case(guide_state)
                    0:if(guide_count==0) guide_line=guide_catalog_ready ?
                        {"NO SONG FILES ON SD CARD",{8{8'h20}}} : {"WAITING FOR SD CATALOG",{10{8'h20}}};
                    1:guide_line=guide_teach ? {"AUTO PLAY    > TEACHING",{9{8'h20}}} :
                        {"> AUTO PLAY    TEACHING",{9{8'h20}}};
                    3:guide_line=guide_teach ? {"C D E F G A B   FOLLOW LED",{6{8'h20}}} :
                        {"AUTOMATIC PERFORMANCE",{11{8'h20}}};
                    4:guide_line={"ERROR:",{26{8'h20}}};
                    default:;
                endcase
                12:if(guide_state==3) guide_line={"C D E F G A B",{19{8'h20}}};
                37:guide_line={"R1 KEY9: NEXT / CHANGE MODE",{5{8'h20}}};
                39:guide_line={"R2 KEY9: SELECT / START / STOP",{2{8'h20}}};
                41:guide_line={"HOLD R2 KEY9: BACK",{14{8'h20}}};
                default:;
            endcase
        end
    endfunction
    // These belong to t1, alongside the existing x/y/character coordinates.
    // Stage t2 only extracts one character and addresses the glyph RAM.
    reg [255:0] guide_line1;
    reg [3:0] guide_row1;
    reg [7:0] guide_id1;
    wire [3:0] guide_row0={guide_selected[3],3'd0} | ((tln-6'd6)>>1);
    always @(posedge clk_p) begin
        guide_line1<=guide_line(tln);
        guide_row1<=guide_row0;
        guide_id1<=song_status[guide_row0*8+:8];
    end
    function [5:0] guide_text;
        input [5:0] ln;
        input [7:0] col;
        reg [3:0] row;
        begin
            guide_text=6'd36;row=0;
            if(col>=4 && col<36) guide_text=gch(guide_line1,col-4);
            if(ln==0 && col>=2 && col<12) guide_text=gch(S_GUIDE,col-2);
            if(guide_state==0 && ln>=6 && ln<=20 && !ln[0] && {1'b0,guide_row1}<guide_count) begin
                if(col==4 && guide_row1==guide_selected) guide_text=a2i(">");
                if(col>=6 && col<10) guide_text=gch({"SONG",{28{8'h20}}},col-6);
                if(col==10) guide_text={2'b0,guide_id1[7:4]};
                if(col==11) guide_text={2'b0,guide_id1[3:0]};
                if(col>=12 && col<16) guide_text=gch({".BIN",{28{8'h20}}},col-12);
            end
            if(guide_state==3 && ln==10 && col==4 && guide_countdown!=0)
                guide_text={4'd0,guide_countdown};
            if(guide_state==3 && ln==13 && col>=4 && col<=16 && !col[0]) begin
                row=(col-4)>>1;
                guide_text=guide_matched[row] ? a2i("+") : guide_expected[row] ? a2i("*") : a2i("-");
            end
            if(guide_state==4 && ln==8 && col==11) guide_text={2'd0,guide_error[3:0]};
        end
    endfunction

    // ══════════════════════════════════════════════════════════════
    //  文字查表：某一行的某一列是什么字
    // ══════════════════════════════════════════════════════════════
    function [5:0] txt;
        input [5:0] ln;
        input [7:0] col;
        input [1:0] pg;
        reg   [4:0] j;
        begin
            txt = 6'd36;                                  // 默认空格
            if (pg == 2'd0) begin
                // ═══ 主页面 ═══
                case (ln)
                6'd0:                                                  // 状态栏标题
                    if (col >= 8'd2 && col < 8'd15)
                        txt = gch(S_MAIN, col - 8'd2);
                6'd4: begin                                            // 频谱 / 李萨如标题
                    if (col >= 8'd2 && col < 8'd13)
                        txt = gch(S_SPEC, col - 8'd2);
                    if (col >= 8'd133 && col < 8'd142)
                        txt = gch(S_LISS, col - 8'd133);
                end
                6'd24: begin                                          // 分量高度标题 + 副标题
                    if (col >= 8'd2 && col < 8'd14)
                        txt = gch(S_COMP, col - 8'd2);
                    if (col >= 8'd60 && col < 8'd80)
                        txt = gch(S_CSUB, col - 8'd60);
                end
                6'd30:                                                 // Y 轴刻度 192
                    if (col >= 8'd2 && col < 8'd5)
                        txt = gch(S_Y192, col - 8'd2);
                6'd34:                                                 // Y 轴刻度 128
                    if (col >= 8'd2 && col < 8'd5)
                        txt = gch(S_Y128, col - 8'd2);
                6'd38:                                                 // Y 轴刻度 64
                    if (col >= 8'd2 && col < 8'd4)
                        txt = gch(S_Y64, col - 8'd2);
                6'd42:                                                 // X 轴分量序号
                    txt = xlbl(col);
                6'd18: begin                                          // 信息框 1：音色
                    if (col >= 8'd133 && col < 8'd140)
                        txt = gch(S_TIMBR, col - 8'd133);
                    if (col >= 8'd141 && col < 8'd156)
                        txt = gch(s_tname, col - 8'd141);
                end
                6'd19: begin                                          // 信息框 2：效果器
                    if (col >= 8'd133 && col < 8'd136)
                        txt = gch(S_FXL, col - 8'd133);
                    if (col >= 8'd137 && col < 8'd152)
                        txt = gch(s_fname, col - 8'd137);
                end
                6'd20: begin                                          // 信息框 3：移调
                    if (col >= 8'd133 && col < 8'd139)
                        txt = gch(S_TRL, col - 8'd133);
                    if (col >= 8'd140 && col < 8'd143) begin
                        j = col - 8'd140;
                        case (j)
                        5'd0: txt = tr[7] ? 6'd42 : 6'd41;   // '-' : '+'
                        5'd1: txt = {2'b00, tr_tens};
                        default: txt = {2'b00, tr_ones};
                        endcase
                    end
                end
                6'd21: begin                                          // 信息框 4：余辉档位
                    if (col >= 8'd133 && col < 8'd137)
                        txt = gch(S_AGL, col - 8'd133);
                    if (col == 8'd138) txt = 6'd21;                    // 'L' = A+11
                    if (col == 8'd139)
                        txt = {4'd0, agl} + 6'd1;                      // '1'..'4'
                end
                6'd22: begin                                          // 信息框 5：显示低通
                    if (col >= 8'd133 && col < 8'd138)
                        txt = gch(S_FILT, col - 8'd133);
                    if (col >= 8'd139 && col < 8'd142)
                        txt = gch(s_fltname, col - 8'd139);
                end
                default: ;
                endcase
            end
            else if (pg == 2'd1) begin
                // ═══ 测试页面 ═══
                if (ln == 6'd0 && col >= 8'd2 && col < 8'd19)
                    txt = gch(S_TEST, col - 8'd2);
            end
            else begin
                txt = guide_text(ln,col);
            end
        end
    endfunction

    // ══════════════════════════════════════════════════════════════
    //  字模 ROM（8×16，55 字 × 16 行 = 880 字）
    // ══════════════════════════════════════════════════════════════
    reg [15:0] glyph [0:879];
    initial begin
        $readmemh("src/hdmi/ui/ui_font_asc.hex", glyph);
    end

    wire [5:0]  char1 = txt(tln1, tcol1, page_show);
    wire [9:0]  gaddr = {char1, 4'd0} + {6'd0, tgy1};

    // ══════════════════════════════════════════════════════════════
    //  李萨如帧存读口（128×128，4 bit/像素）
    //    addr = row*32 + (x>>2)，nibble = x&3
    //    显示窗口 = 盒子 (1060..1271, 60..271) = 212×212
    //    212 px 显示 128 位图 → 2 倍放大：lbx = lpx/2 + 11
    //      打点区 16..112 → 屏幕 10..202，与原来（位图 32..224 取 22..233）
    //      的像素范围完全一致，视觉不变
    // ══════════════════════════════════════════════════════════════
    wire [12:0] lpx = {1'b0, px1} - 13'd1060;
    wire [12:0] lpy = {1'b0, py1} - 13'd60;
    wire        liss_in1 = !lpx[12] && !lpy[12] &&
                           (lpx < 13'd212) && (lpy < 13'd212);
    wire [8:0]  lbx = {1'b0, lpx[8:1]} + 9'd11;   // 位图 x 11..116
    wire [8:0]  lby = {1'b0, lpy[8:1]} + 9'd11;   // 位图 y 11..116
    wire [11:0] liss_raddr = liss_in1 ? ({lby[6:0], 5'd0} +
                                        {7'd0, lbx[6:2]}) : 12'd0;
    wire [15:0] liss_rdata;

    ui_liss_ram u_liss (
        .clk       (clk_p),
        .rst_n     (rst_n),
        .plot      (pl5),           // 坐标已对齐，且由 settle 门控
        .plot_x    (px_pt),
        .plot_y    (py_pt),
        .clr_en    (liss_clr),
        .clr_done  (),
        .decay_req (liss_decay),
        .decay_step(agl_dec),
        .ink_step  (agl_ink),
        .decay_busy(),
        .raddr     (liss_raddr),
        .rdata     (liss_rdata)
    );

    // ══════════════════════════════════════════════════════════════
    //  t1 组合：柱高 → 像素高度（两页系数不同，按页面选）
    //    page0 系数 1.203125 = 1 + 1/8 + 1/16 + 1/64  → h=255 时 304 px
    //    page1 系数 2.5      = 2 + 1/2                → h=255 时 637 px
    //    全部用移位相加，扫描路径上没有乘法器
    // ══════════════════════════════════════════════════════════════
    wire [7:0] bh = bands_cap[{bidx1, 3'b000} +: 8];

    wire [9:0] bh_a = {2'b00, bh} + {3'b000, bh[7:3]} +
                      {4'b0000, bh[7:4]} + {6'b000000, bh[7:6]};
    wire [9:0] bh_b = {1'b0, bh, 1'b0} + {2'b00, bh[7:1]};

    wire [9:0] bhpx_sel = (page_show == 2'd1) ? bh_b : bh_a;

    // ══════════════════════════════════════════════════════════════
    //  t2 登记
    // ══════════════════════════════════════════════════════════════
    reg [11:0] px2, py2;
    reg [2:0]  tbit2;
    reg        txt_on2;
    reg        bsel2;
    reg [9:0]  bhpx2;
    reg [15:0] glyph_d;
    reg        csel2;
    reg [7:0]  camp2;
    reg        liss_in2;
    reg [1:0]  liss_bit2;

    always @(posedge clk_p) begin
        px2     <= px1;
        py2     <= py1;
        tbit2   <= tbit1;
        txt_on2 <= txt_on1;
        bsel2   <= bsel1;
        bhpx2   <= bhpx_sel;
        glyph_d <= glyph[gaddr];
        csel2   <= csel1;
        camp2   <= comp_cap[{cidx1, 3'b000} +: 8];
        liss_in2  <= liss_in1;
        liss_bit2 <= lbx[1:0];
    end

    wire t_lit2 = txt_on2 && glyph_d[tbit2];

    // ══════════════════════════════════════════════════════════════
    //  t2 组合：柱子 + 版面框线
    // ══════════════════════════════════════════════════════════════
    localparam [9:0] BASE_P0 = 10'd372;    // 主页面频谱柱底
    localparam [9:0] BASE_P1 = 10'd700;    // 测试页柱底

    wire [9:0] bar_base = (page_show == 2'd1) ? BASE_P1 : BASE_P0;

    wire bar_lit = bsel2 && (page_show != 2'd2) &&
                   ({2'b00, py2[9:0]} >= (bar_base - bhpx2)) &&
                   ({2'b00, py2[9:0]} <  bar_base);

    wire base_line = bsel2 && (page_show != 2'd2) &&
                     (({2'b00, py2[9:0]} == bar_base) ||
                      ({2'b00, py2[9:0]} == bar_base + 10'd1));

    // ── 框线工具：给定矩形四边，判断是否落在边框上（1 px） ──────────
    //    x0..x1 / y0..y1 都是常数，只有比较，没有加减链
    wire [11:0] x2 = px2;
    wire [11:0] y2 = py2;

    wire e_status, e_spec, e_comp, e_liss, e_info, e_test, e_guide, e_jline, e_lane;

    // 主页面 —— 状态栏
    assign e_status = (x2 >= 12'd8)   && (x2 <= 12'd1271) &&
                      (y2 >= 12'd8)   && (y2 <= 12'd51)   &&
                      ((x2 == 12'd8) || (x2 == 12'd1271) ||
                       (y2 == 12'd8) || (y2 == 12'd51));
    // 主页面 —— 频谱框 8..1047 × 60..377
    assign e_spec   = (x2 >= 12'd8)   && (x2 <= 12'd1047) &&
                      (y2 >= 12'd60)  && (y2 <= 12'd377)  &&
                      ((x2 == 12'd8) || (x2 == 12'd1047) ||
                       (y2 == 12'd60) || (y2 == 12'd377));
    // 主页面 —— 分量高度框 8..1271 × 388..705
    //    ★ 比频谱框宽：64 根柱 × 16 px = 1024 px，再加上左侧 Y 轴刻度
    //      和右侧留白，需要整行宽度。信息框相应缩到 284..377。
    assign e_comp   = (x2 >= 12'd8)   && (x2 <= 12'd1271) &&
                      (y2 >= 12'd388) && (y2 <= 12'd705)  &&
                      ((x2 == 12'd8) || (x2 == 12'd1271) ||
                       (y2 == 12'd388) || (y2 == 12'd705));
    // 主页面 —— 李萨如框 1060..1271 × 60..271
    assign e_liss   = (x2 >= 12'd1060) && (x2 <= 12'd1271) &&
                      (y2 >= 12'd60)   && (y2 <= 12'd271)  &&
                      ((x2 == 12'd1060) || (x2 == 12'd1271) ||
                       (y2 == 12'd60)   || (y2 == 12'd271));
    // 主页面 —— 信息框 1060..1271 × 284..377
    assign e_info   = (x2 >= 12'd1060) && (x2 <= 12'd1271) &&
                      (y2 >= 12'd284)  && (y2 <= 12'd377)  &&
                      ((x2 == 12'd1060) || (x2 == 12'd1271) ||
                       (y2 == 12'd284)  || (y2 == 12'd377));
    // 测试页 —— 满幅框 8..1271 × 60..705
    assign e_test   = (x2 >= 12'd8)   && (x2 <= 12'd1271) &&
                      (y2 >= 12'd60)  && (y2 <= 12'd705)  &&
                      ((x2 == 12'd8) || (x2 == 12'd1271) ||
                       (y2 == 12'd60) || (y2 == 12'd705));
    // 教学页 —— 同满幅框 + 判定线 + 8 条轨道
    assign e_guide  = (x2 >= 12'd8)   && (x2 <= 12'd1271) &&
                      (y2 >= 12'd60)  && (y2 <= 12'd705)  &&
                      ((x2 == 12'd8) || (x2 == 12'd1271) ||
                       (y2 == 12'd60) || (y2 == 12'd705));
    // 判定线 y = 640
    assign e_jline  = (x2 >= 12'd8) && (x2 <= 12'd1271) &&
                      ((y2 == 12'd640) || (y2 == 12'd641));
    // 轨道分隔：x = 8+158k，宽 2 px（k=1..7）
    assign e_lane   = (y2 > 12'd60) && (y2 < 12'd640) &&
                      ((x2 == 12'd166)  || (x2 == 12'd167)  ||
                       (x2 == 12'd324)  || (x2 == 12'd325)  ||
                       (x2 == 12'd482)  || (x2 == 12'd483)  ||
                       (x2 == 12'd640)  || (x2 == 12'd641)  ||
                       (x2 == 12'd798)  || (x2 == 12'd799)  ||
                       (x2 == 12'd956)  || (x2 == 12'd957)  ||
                       (x2 == 12'd1114) || (x2 == 12'd1115));

    wire edge_main = e_status | e_spec | e_comp | e_liss | e_info;
    wire edge_box  = (page_show == 2'd0) ? edge_main :
                     (page_show == 2'd1) ? e_test   : e_guide;

    wire edge_lane = 1'b0; // menu replaces the old empty note lanes

    // ══════════════════════════════════════════════════════════════
    //  COMPONENT 64 柱图 + 坐标轴（仅主页面）
    //
    //  绘图区：x 64..1087（64 根 × 16 px），y 424..680（256 px）
    //    柱高直接用 8 位幅度值 → py 与 amp 一一对应，不需要换算
    //  坐标轴：
    //    左 Y 轴竖线  x = 56..57，y 424..681
    //    底 X 轴线    y = 680..681，x 56..1088
    //    横向网格线   y = 488 / 552 / 616（对应幅度 192 / 128 / 64）
    //                  且正好落在字符网格第 30 / 34 / 38 行上，
    //                  刻度文字就画在同一行的最左侧，天然对齐
    // ══════════════════════════════════════════════════════════════
    localparam [9:0] COMP_BASE = 10'd680;

    wire [9:0] py10 = {2'b00, py2[9:0]};

    wire comp_lit = csel2 && (page_show == 2'd0) &&
                    (py10 >= (COMP_BASE - {2'b00, camp2})) &&
                    (py10 <   COMP_BASE);

    wire c_yaxis = (page_show == 2'd0) &&
                   ((x2 == 12'd56) || (x2 == 12'd57)) &&
                   (y2 >= 12'd424) && (y2 <= 12'd681);

    wire c_xaxis = (page_show == 2'd0) &&
                   ((y2 == 12'd680) || (y2 == 12'd681)) &&
                   (x2 >= 12'd56) && (x2 <= 12'd1088);

    wire c_grid  = (page_show == 2'd0) &&
                   ((y2 == 12'd488) || (y2 == 12'd552) || (y2 == 12'd616)) &&
                   (x2 >= 12'd60) && (x2 <= 12'd1088);

    // 状态栏底色（整块填充）
    wire status_bg = (page_show == 2'd0) &&
                     (x2 >= 12'd8) && (x2 <= 12'd1271) &&
                     (y2 >= 12'd8) && (y2 <= 12'd51);

    // ══════════════════════════════════════════════════════════════
    //  李萨如：荧光强度 → 颜色 + 中心十字线（仅主页面）
    //    盒子 (1060..1271, 60..271)，中心 (1166, 166)
    //    强度 0..15 → 亮度 0..100%（橙色 0xFF8020 等比缩放）
    // ══════════════════════════════════════════════════════════════
    wire [3:0]  liss_int = liss_rdata[{liss_bit2, 2'b00} +: 4];
    wire [7:0]  li       = {liss_int, 4'd0};       // 0,16,...,240
    wire [7:0]  liss_r8  = li + li[7:4];           // ×1.0625 → 255
    wire [7:0]  liss_g8  = li >> 1;                // ≈ 0x80
    wire [7:0]  liss_b8  = li >> 3;                // ≈ 0x20
    wire [23:0] liss_col = {liss_r8, liss_g8, liss_b8};

    wire liss_lit = (page_show == 2'd0) && liss_in2 && (liss_int != 4'd0);

    wire liss_cross = (page_show == 2'd0) &&
                      (x2 > 12'd1060) && (x2 < 12'd1271) &&
                      (y2 > 12'd60)   && (y2 < 12'd271)   &&
                      ((x2 == 12'd1166) || (y2 == 12'd166));

    // ══════════════════════════════════════════════════════════════
    //  上色
    // ══════════════════════════════════════════════════════════════
    reg [23:0] rgb;
    always @(*) begin
        if      (edge_lane)  rgb = 24'hFF8020;      // 轨道 / 判定线
        else if (edge_box)   rgb = 24'h607080;      // 版面框
        else if (c_yaxis)    rgb = 24'h90A0B0;      // 分量图 Y 轴
        else if (c_xaxis)    rgb = 24'h90A0B0;      // 分量图 X 轴
        else if (c_grid)     rgb = 24'h303840;      // 分量图网格线
        else if (liss_lit)   rgb = liss_col;        // 李萨如荧光（强度→亮度）
        else if (liss_cross) rgb = 24'h303840;      // 李萨如中心十字
        else if (comp_lit)   rgb = 24'h40C0FF;      // 分量柱（青）
        else if (t_lit2)     rgb = 24'hFFFFFF;      // 文字
        else if (bar_lit)    rgb = 24'h30FF60;      // 频谱柱（绿）
        else if (base_line)  rgb = 24'h405060;      // 频谱柱底基线
        else if (status_bg)  rgb = 24'h101820;      // 状态栏底色
        else                 rgb = 24'h000000;
    end

    // ══════════════════════════════════════════════════════════════
    //  淡入淡出：rgb × fade_lvl / 16
    // ══════════════════════════════════════════════════════════════
    wire [11:0] fr = rgb[23:16] * fade_lvl;
    wire [11:0] fg = rgb[15:8]  * fade_lvl;
    wire [11:0] fb = rgb[7:0]   * fade_lvl;
    wire [23:0] rgb_f = {fr[11:4], fg[11:4], fb[11:4]};

    // ══════════════════════════════════════════════════════════════
    //  t3 输出寄存器（de/hs/vs 同步延 3 拍，与数据严格对齐）
    // ══════════════════════════════════════════════════════════════
    reg [23:0] rgb_r;
    reg        vis_d1, vis_d2, vis_d3;
    reg        hs_d1,  hs_d2,  hs_d3;
    reg        vs_d1,  vs_d2,  vs_d3;

    always @(posedge clk_p) begin
        rgb_r  <= rgb_f;
        vis_d1 <= vis;    vis_d2 <= vis_d1;   vis_d3 <= vis_d2;
        hs_d1  <= hsync;  hs_d2  <= hs_d1;    hs_d3  <= hs_d2;
        vs_d1  <= vsync;  vs_d2  <= vs_d1;    vs_d3  <= vs_d2;
    end

    // ══════════════════════════════════════════════════════════════
    //  DVI 输出
    // ══════════════════════════════════════════════════════════════
`ifndef SIM_UI3
    dvi_tx_top u_dvi (
        .pixel_clock   (clk_p),
        .ddr_bit_clock (clk_p5),
        .reset         (dvi_reset),
        .den           (vis_d3),
        .hsync         (hs_d3),
        .vsync         (vs_d3),
        .pixel_data    (rgb_r),
        .tmds_clk      ({tmds_clk_p_0, tmds_clk_n_0}),
        .tmds_d0       ({tmds_d_p_0[0], tmds_d_n_0[0]}),
        .tmds_d1       ({tmds_d_p_0[1], tmds_d_n_0[1]}),
        .tmds_d2       ({tmds_d_p_0[2], tmds_d_n_0[2]})
    );
`endif

    // BANDS_TICK 只用于说明数据静止窗口，渲染侧不做门控，这里显式忽略
    /* verilator lint_off UNUSED */
    wire _unused_tick = BANDS_TICK;
    /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
