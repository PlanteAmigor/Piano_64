//==========================================================================
//  hdmi_ui_top —— 1280×720@60 乐器可视化 UI（V1）
//
//  显示内容
//    ┌──────────────────────────────────────────────────────┐
//    │ 状态条：UI TEST 720P                                 │
//    ├───────────────────────────────┬──────────────────────┤
//    │  波形 736×646                  │  相图 512×512        │
//    │  （1024 点，竖线连接）          │  X=s[n], Y=s[n-24]  │
//    │                               ├──────────────────────┤
//    │                               │  INFO                │
//    └───────────────────────────────┴──────────────────────┘
//
//  ★ V1 用内置 ui_dds 合成音源，先把绘制链路验证通；
//    接真实引擎时把 sample/sample_tick 换掉即可。
//
//  绘制架构：**不做帧缓冲**，逐像素组合计算。
//    像素时钟 75 MHz → 每像素 13.3 ns，地址计算全用移位，
//    数据通路打 1 拍流水（px/py 同步延 1 拍，de/hs/vs 延 2 拍）。
//==========================================================================
`default_nettype none

module hdmi_ui_top (
    input  wire clk,            // 50 MHz
    input  wire resetn,
    input  wire key0,           // 板上 KEY.0 (AA13) → 测试模式开关

    output wire       tmds_clk_n_0,
    output wire       tmds_clk_p_0,
    output wire [2:0] tmds_d_n_0,
    output wire [2:0] tmds_d_p_0
);

    // ══════════════════════════════════════════════════════════════
    //  时钟与复位
    // ══════════════════════════════════════════════════════════════
    wire pll_lock, clk_p, clk_p5;
    Gowin_PLL_720P u_pll (
        .lock(pll_lock), .clkout0(clk_p), .clkout1(clk_p5), .clkin(clk)
    );

    reg [3:0] por = 4'd0;
    always @(posedge clk_p) begin
        if (!resetn || !pll_lock) por <= 4'd0;
        else if (por != 4'hF)     por <= por + 4'd1;
    end
    wire rst_n     = (por == 4'hF);
    wire dvi_reset = ~rst_n;

    // ══════════════════════════════════════════════════════════════
    //  板上 KEY.0（AA13）→ 测试模式开关
    //
    //  赛题「现场验证要求」要一个测试模式：输出 8 路不同频率的纯正弦，
    //  频谱上能数出对应数量的独立谱峰。这里用板载 KEY.0 短按进出。
    //
    //  板上三个用户键都是「悬空=1、按下=0」，悬空靠内部上拉。
    //  去抖 20 ms @75MHz ≈ 1.5M 拍。它不参与演奏计时，不需要双触点精度。
    //  注意：HDMI 和主音频工程是【两个独立码流】，两边各自识别 KEY0。
    //  ══════════════════════════════════════════════════════════════
    reg  [1:0]  k0_sync;
    always @(posedge clk_p) k0_sync <= {k0_sync[0], key0};

    reg [20:0] k0_cnt;
    reg        k0_st, k0_st_d;
    always @(posedge clk_p) begin
        if (!rst_n) begin
            k0_cnt  <= 21'd0;
            k0_st   <= 1'b1;
            k0_st_d <= 1'b1;
        end
        else begin
            k0_st_d <= k0_st;
            if (k0_sync[1] != k0_st) begin
                if (k0_cnt == 21'd1_499_999) begin
                    k0_cnt <= 21'd0;
                    k0_st  <= k0_sync[1];
                end
                else k0_cnt <= k0_cnt + 21'd1;
            end
            else k0_cnt <= 21'd0;
        end
    end
    wire k0_press = k0_st_d & ~k0_st;      // 按下沿（低有效）

    reg test_mode;
    always @(posedge clk_p) begin
        if (!rst_n)        test_mode <= 1'b0;
        else if (k0_press) test_mode <= ~test_mode;
    end

    // ══════════════════════════════════════════════════════════════
    //  720p 时序
    // ══════════════════════════════════════════════════════════════
    localparam integer H_TOTAL = 1650, H_SYNC = 40,  H_BP = 220, H_VIS = 1280;
    localparam integer V_TOTAL = 750,  V_SYNC = 5,   V_BP = 20,  V_VIS = 720;
    localparam integer H_START = H_SYNC + H_BP;      // 260
    localparam integer V_START = V_SYNC + V_BP;      //  25

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

    wire hsync = ~((hcnt >= H_SYNC) && (hcnt < H_SYNC + 96));
    wire vsync = ~((vcnt >= V_SYNC) && (vcnt < V_SYNC + 5));

    wire [11:0] px = hcnt - H_START;      // 0..1279
    wire [11:0] py = vcnt - V_START;      // 0..719

    // 场消隐：vcnt 在有效区之外时给一个单拍脉冲（每帧一次）
    wire vblank = (vcnt == 12'd2);
    reg  vblank_d;
    always @(posedge clk_p) vblank_d <= vblank;
    wire frame_clr = vblank & ~vblank_d;

    // ══════════════════════════════════════════════════════════════
    //  测试音源（换成真实引擎输出即可）
    // ══════════════════════════════════════════════════════════════
    wire signed [15:0] snd;
    wire               snd_tick;
    ui_dds u_src (
        .clk(clk_p), .rst_n(rst_n),
        .inc(32'd38_702_809),              // 440.00 Hz @ 48828（f x 2^32 / fs）
        .sample(snd), .sample_tick(snd_tick)
    );

    // ══════════════════════════════════════════════════════════════
    //  波形缓冲
    // ══════════════════════════════════════════════════════════════
    reg  [9:0] wptr;
    always @(posedge clk_p) begin
        if (!rst_n)      wptr <= 10'd0;
        else if (snd_tick) wptr <= wptr + 10'd1;
    end

    // 扫描地址：屏幕列 → 样点下标（736 像素显示 1024 点）
    //   idx = lx*1024/736 ≈ lx*1.391 ≈ (lx*89)>>6
    //
    // ★ 必须画「上一列样点 → 当前列样点」，不能画「idx → idx+1」。
    //   因为 idx 每列前进 1 或 2，画 idx→idx+1 时会漏掉中间那一段，
    //   实测波形呈虚线状。取相邻两列各自的 idx 就连续了。
    wire [11:0] wpx  = px - 12'd8;
    wire [11:0] wpxm = wpx - 12'd1;              // 上一列（会下溢，下面靠 mask 兜住）
    wire [17:0] wmul0 = {6'd0, wpx } * 18'd89;
    wire [17:0] wmul1 = {6'd0, wpxm} * 18'd89;
    wire [9:0]  widx  = wmul0[15:6];             // 当前列
    wire [9:0]  widxp = wmul1[15:6];             // 上一列

    wire signed [15:0] ws0, ws1;
    ui_wave_ram u_wave (
        .clk(clk_p),
        .we(snd_tick), .waddr(wptr), .wdata(wy_new),
        .raddr(widxp),      .rdata(ws1)          // 上一列
    );
    // ★★ 两份 RAM 都是【同一份数据的副本】，写口必须都接上！
    //    原来这份的 we 接死 1'b0 → 读出来是空的，波形就是一堆乱线。
    //    （拆两份是为了同一拍能读两个相邻下标，等价于一个双读口 RAM。）
    ui_wave_ram u_wave2 (
        .clk(clk_p),
        .we(snd_tick), .waddr(wptr), .wdata(wy_new),
        .raddr(widx),       .rdata(ws0)          // 当前列
    );

    // ── 样点 → 面板内 y（★ 在【写入端】算，扫描端不再做算术）──────
    //   y = 323 − s×300/32768，即 ±300 像素（面板高 646，留 23 边距）
    //
    //   ★★ 为什么写进 RAM 的是 y 而不是样点：
    //      原来扫描端要做 s*300（16×32 乘法）或 4 次移位相加，
    //      叠在 BSRAM 输出后面 → SETUP −1.9 ns。
    //      写入端每个样点有 1024 拍可用，算一次 y 存起来，
    //      扫描路径上只剩「两个数取 min/max + 比较」，非常短。
    //
    //   300 = 256+32+8+4 → s×300/32768 = s/128 + s/1024 + s/4096 + s/8192
    //   （纯算术右移相加，没有乘法）
    function signed [11:0] wave_y;
        input signed [15:0] sv;
        reg signed [15:0] a, b, c, d;
        begin
            a = sv >>> 7;
            b = sv >>> 10;
            c = sv >>> 12;
            d = sv >>> 13;
            wave_y = 12'sd323 - (a + b + c + d);
        end
    endfunction

    wire signed [11:0] wy_new = wave_y(snd);

    // 扫描端直接拿到 y（RAM 里存的就是 y）
    wire [15:0] wy0 = ws0;
    wire [15:0] wy1 = ws1;

    // ══════════════════════════════════════════════════════════════
    //  相图位图
    // ══════════════════════════════════════════════════════════════
    // 延迟线 Δ=24 样点
    reg signed [15:0] dl [0:23];
    integer di;
    always @(posedge clk_p) begin
        if (!rst_n) begin
            for (di = 0; di < 24; di = di + 1) dl[di] <= 16'sd0;
        end
        else if (snd_tick) begin
            for (di = 23; di > 0; di = di - 1) dl[di] <= dl[di-1];
            dl[0] <= snd;
        end
    end
    wire signed [15:0] snd_d = dl[23];

    // 样点 → 位图坐标（0..255）
    wire [7:0] lx_pt = snd[15:8]   + 8'd128;
    wire [7:0] ly_pt = snd_d[15:8] + 8'd128;

    wire [11:0] liss_rd;
    wire [15:0] liss_dat;
    wire        liss_clr_done;

    ui_liss_ram u_liss (
        .clk(clk_p), .rst_n(rst_n),
        .plot(snd_tick), .plot_x(lx_pt), .plot_y(ly_pt),
        .clr_en(frame_clr), .clr_done(liss_clr_done),
        .raddr(liss_rd), .rdata(liss_dat)
    );

    // 扫描：面板 (752,60) 起 512×512，2×2 放大
    wire [11:0] lpx = px - 12'd752;      // 0..511
    wire [11:0] lpy = py - 12'd60;
    wire [9:0]  lu  = lpx[9:1];          // 0..255
    wire [9:0]  lv  = lpy[9:1];
    assign liss_rd = (lv[7:0] << 4) + {6'd0, lu[7:4]};
    // ★★ 必须用 in_liss_p 门控！否则 lpx/lpy 在面板外继续增大，
    //    lu/lv 取低 8 位后循环，256×256 位图会被平铺到整个屏幕
    //    → 满屏「多组重复图案」。
    wire liss_lit  = in_liss_p && !edge_liss && liss_dat[lu[3:0]];

    // ══════════════════════════════════════════════════════════════
    //  字库
    //
    //  ★★ 关键设计：**字符串表用纯组合逻辑（function），字模用 BSRAM**
    //    原来把 txrom(128×6) 也做成数组：它的数据要【当拍】算出 glyph 地址，
    //    是「BSRAM → 组合 → BSRAM」的级联依赖读，一拍做不完
    //    → 文字整体错乱。字符串表只有 64 项，写成 case 就是纯 LUT，
    //      字模 880×16 才走 BSRAM（读延迟 1 拍，用级流水吸收）。
    // ══════════════════════════════════════════════════════════════
    reg [15:0] glyph [0:879];            // 55 字 × 16 行

    initial begin
        $readmemh("src/hdmi/ui/ui_font_asc.hex", glyph);
    end

    // 字符索引（与 tools/gen_ui_font.py 的 ASC 表一一对应）
    //   0..9 数字  10..35 A-Z  36 空格  37 '.'  38 ':'  39 '/'
    //
    //  sel 0..3  = 主界面：状态条 / WAVE / LISSAJOUS / INFO
    //  sel 4     = 测试模式状态条 "TEST 8CH SINE"
    //  sel 5..12 = 测试模式 8 路频率标签（每个 6 字符）
    function [5:0] tx_char;
        input [3:0] sel;
        input [4:0] ci;                  // 串内第几个字符（0..15）
        reg [47:0] lab;
        begin
            if (sel == 4'd4) begin
                // ── 测试模式状态条 "TEST 8CH SINE" ─────────────
                case (ci)
                5'd0 : tx_char = 6'd29;  // T
                5'd1 : tx_char = 6'd14;  // E
                5'd2 : tx_char = 6'd28;  // S
                5'd3 : tx_char = 6'd29;  // T
                5'd4 : tx_char = 6'd36;  // sp
                5'd5 : tx_char = 6'd8;   // 8
                5'd6 : tx_char = 6'd12;  // C
                5'd7 : tx_char = 6'd17;  // H
                5'd8 : tx_char = 6'd36;  // sp
                5'd9 : tx_char = 6'd28;  // S
                5'd10: tx_char = 6'd18;  // I
                5'd11: tx_char = 6'd23;  // N
                5'd12: tx_char = 6'd14;  // E
                default: tx_char = 6'd36;
                endcase
            end
            else if (sel >= 4'd5 && sel <= 4'd12) begin
                // ── 8 路频率标签：6 个字符挤进 48 bit ──────────
                //    lab[5:0] = 第 0 个字符，所以 lab 按【倒序】拼接
                case (sel)
                4'd5 : lab = {6'd36,6'd0, 6'd3, 6'd1, 6'd36,6'd36};  // "  130"
                4'd6 : lab = {6'd36,6'd1, 6'd6, 6'd2, 6'd36,6'd36};  // "  261"
                4'd7 : lab = {6'd36,6'd3, 6'd2, 6'd5, 6'd36,6'd36};  // "  523"
                4'd8 : lab = {6'd36,6'd6, 6'd4, 6'd0, 6'd1, 6'd36};  // " 1046"
                4'd9 : lab = {6'd36,6'd3, 6'd9, 6'd0, 6'd2, 6'd36};  // " 2093"
                4'd10: lab = {6'd36,6'd6, 6'd8, 6'd1, 6'd4, 6'd36};  // " 4186"
                4'd11: lab = {6'd36,6'd2, 6'd7, 6'd3, 6'd8, 6'd36};  // " 8372"
                default: lab = {6'd36,6'd4, 6'd4, 6'd7, 6'd6, 6'd1};  // "16744"
                endcase
                tx_char = lab[ci[2:0]*6 +: 6];
            end
            else case ({sel[1:0], ci})
            // ── sel0: "UI TEST 720P" ──────────────────────────
            {2'd0, 5'd0 }: tx_char = 6'd30;  // U
            {2'd0, 5'd1 }: tx_char = 6'd18;  // I
            {2'd0, 5'd2 }: tx_char = 6'd36;  // sp
            {2'd0, 5'd3 }: tx_char = 6'd29;  // T
            {2'd0, 5'd4 }: tx_char = 6'd14;  // E
            {2'd0, 5'd5 }: tx_char = 6'd28;  // S
            {2'd0, 5'd6 }: tx_char = 6'd29;  // T
            {2'd0, 5'd7 }: tx_char = 6'd36;  // sp
            {2'd0, 5'd8 }: tx_char = 6'd7;   // 7
            {2'd0, 5'd9 }: tx_char = 6'd2;   // 2
            {2'd0, 5'd10}: tx_char = 6'd0;   // 0
            {2'd0, 5'd11}: tx_char = 6'd25;  // P
            // ── sel1: "WAVE" ──────────────────────────────────
            {2'd1, 5'd0 }: tx_char = 6'd32;  // W
            {2'd1, 5'd1 }: tx_char = 6'd10;  // A
            {2'd1, 5'd2 }: tx_char = 6'd31;  // V
            {2'd1, 5'd3 }: tx_char = 6'd14;  // E
            // ── sel2: "LISSAJOUS" ─────────────────────────────
            {2'd2, 5'd0 }: tx_char = 6'd21;  // L
            {2'd2, 5'd1 }: tx_char = 6'd18;  // I
            {2'd2, 5'd2 }: tx_char = 6'd28;  // S
            {2'd2, 5'd3 }: tx_char = 6'd28;  // S
            {2'd2, 5'd4 }: tx_char = 6'd10;  // A
            {2'd2, 5'd5 }: tx_char = 6'd19;  // J
            {2'd2, 5'd6 }: tx_char = 6'd24;  // O
            {2'd2, 5'd7 }: tx_char = 6'd30;  // U
            {2'd2, 5'd8 }: tx_char = 6'd28;  // S
            // ── sel3: "INFO" ──────────────────────────────────
            {2'd3, 5'd0 }: tx_char = 6'd18;  // I
            {2'd3, 5'd1 }: tx_char = 6'd23;  // N
            {2'd3, 5'd2 }: tx_char = 6'd15;  // F
            {2'd3, 5'd3 }: tx_char = 6'd24;  // O
            default:       tx_char = 6'd36;  // 其余补空格
            endcase
        end
    endfunction

    // ══════════════════════════════════════════════════════════════
    //  文本命中判定（组合）：返回 {命中, 串号, 串内字符号, 行号}
    //    四个文本块的左上角：
    //      状态条  (24, 20)  sel0
    //      WAVE    (20, 72)  sel1
    //      LISS    (764,72)  sel2
    //      INFO    (764,592) sel3
    // ══════════════════════════════════════════════════════════════
    // ── 矩形命中（组合）：dx[12]=1 表示 px < x0，借此判断越界 ──────
    function in_rect;
        input [11:0] x, y, x0, y0, w, h;
        reg [12:0] dx, dy;
        begin
            dx = {1'b0, x} - {1'b0, x0};
            dy = {1'b0, y} - {1'b0, y0};
            in_rect = !dx[12] && !dy[12] && (dx[11:0] < w) && (dy[11:0] < h);
        end
    endfunction

    // 主界面 4 个文本块
    wire hit_m0 = in_rect(px, py, 12'd24,  12'd20,  12'd128, 12'd16);
    wire hit_m1 = in_rect(px, py, 12'd20,  12'd72,  12'd64,  12'd16);
    wire hit_m2 = in_rect(px, py, 12'd764, 12'd72,  12'd144, 12'd16);
    wire hit_m3 = in_rect(px, py, 12'd764, 12'd592, 12'd64,  12'd16);
    // 测试模式：状态条 + 8 个频率标签（每个 6 字符 = 48px）
    wire hit_t0 = in_rect(px, py, 12'd24,   12'd20,  12'd112, 12'd16);
    wire hit_t1 = in_rect(px, py, 12'd63,   12'd660, 12'd48,  12'd16);
    wire hit_t2 = in_rect(px, py, 12'd221,  12'd660, 12'd48,  12'd16);
    wire hit_t3 = in_rect(px, py, 12'd379,  12'd660, 12'd48,  12'd16);
    wire hit_t4 = in_rect(px, py, 12'd537,  12'd660, 12'd48,  12'd16);
    wire hit_t5 = in_rect(px, py, 12'd695,  12'd660, 12'd48,  12'd16);
    wire hit_t6 = in_rect(px, py, 12'd853,  12'd660, 12'd48,  12'd16);
    wire hit_t7 = in_rect(px, py, 12'd1011, 12'd660, 12'd48,  12'd16);
    wire hit_t8 = in_rect(px, py, 12'd1169, 12'd660, 12'd48,  12'd16);

    reg        tx_hit;
    reg [3:0]  tx_sel;
    reg [4:0]  tx_ci;
    reg [3:0]  tx_ly;
    reg [2:0]  tx_bit;
    reg [11:0] tlx, tly;

    always @(*) begin
        tx_hit = 1'b0; tx_sel = 4'd0; tx_ci = 5'd0; tx_ly = 4'd0; tx_bit = 3'd0;
        tlx = 12'd0; tly = 12'd0;

        if (!test_mode) begin
            if      (hit_m0) begin tx_hit = 1'b1; tx_sel = 4'd0;
                               tlx = px - 12'd24;  tly = py - 12'd20;  end
            else if (hit_m1) begin tx_hit = 1'b1; tx_sel = 4'd1;
                               tlx = px - 12'd20;  tly = py - 12'd72;  end
            else if (hit_m2) begin tx_hit = 1'b1; tx_sel = 4'd2;
                               tlx = px - 12'd764; tly = py - 12'd72;  end
            else if (hit_m3) begin tx_hit = 1'b1; tx_sel = 4'd3;
                               tlx = px - 12'd764; tly = py - 12'd592; end
        end
        else begin
            if      (hit_t0) begin tx_hit = 1'b1; tx_sel = 4'd4;
                               tlx = px - 12'd24;   tly = py - 12'd20;  end
            else if (hit_t1) begin tx_hit = 1'b1; tx_sel = 4'd5;
                               tlx = px - 12'd63;   tly = py - 12'd660; end
            else if (hit_t2) begin tx_hit = 1'b1; tx_sel = 4'd6;
                               tlx = px - 12'd221;  tly = py - 12'd660; end
            else if (hit_t3) begin tx_hit = 1'b1; tx_sel = 4'd7;
                               tlx = px - 12'd379;  tly = py - 12'd660; end
            else if (hit_t4) begin tx_hit = 1'b1; tx_sel = 4'd8;
                               tlx = px - 12'd537;  tly = py - 12'd660; end
            else if (hit_t5) begin tx_hit = 1'b1; tx_sel = 4'd9;
                               tlx = px - 12'd695;  tly = py - 12'd660; end
            else if (hit_t6) begin tx_hit = 1'b1; tx_sel = 4'd10;
                               tlx = px - 12'd853;  tly = py - 12'd660; end
            else if (hit_t7) begin tx_hit = 1'b1; tx_sel = 4'd11;
                               tlx = px - 12'd1011; tly = py - 12'd660; end
            else if (hit_t8) begin tx_hit = 1'b1; tx_sel = 4'd12;
                               tlx = px - 12'd1169; tly = py - 12'd660; end
        end

        tx_ci   = tlx[6:3];
        tx_ly   = tly[3:0];
        tx_bit  = tlx[2:0];
    end

    // 字模地址 = 字符索引 × 16 + 行号（组合）→ BSRAM 读（1 拍）
    wire [9:0]  glyph_a = {tx_char(tx_sel, tx_ci), 4'd0} + {6'd0, tx_ly};
    reg  [15:0] glyph_d;
    reg         tx_hit_d;
    reg  [2:0]  tx_bit_d;
    always @(posedge clk_p) begin
        glyph_d   <= glyph[glyph_a];
        tx_hit_d  <= tx_hit;
        tx_bit_d  <= tx_bit;
    end
    wire tx_lit = tx_hit_d && glyph_d[tx_bit_d];

    // ══════════════════════════════════════════════════════════════
    //  绘制（组合 + 1 拍流水）
    //    数据通路：地址在 px/py 那一拍发出，数据下一拍到。
    //    所以几何判断统一用 px1/py1（= px/py 延 1 拍），和数据对齐。
    // ══════════════════════════════════════════════════════════════
    reg [11:0] px1, py1;
    always @(posedge clk_p) begin
        px1 <= px;
        py1 <= py;
    end

    // 面板边框
    wire in_wave_p = (px1 >= 12'd8)   && (px1 < 12'd744)  && (py1 >= 12'd60) && (py1 < 12'd706);
    wire in_liss_p = (px1 >= 12'd752) && (px1 < 12'd1264) && (py1 >= 12'd60) && (py1 < 12'd572);
    wire in_info_p = (px1 >= 12'd752) && (px1 < 12'd1264) && (py1 >= 12'd580)&& (py1 < 12'd706);
    wire in_stat_p = (px1 >= 12'd8)   && (px1 < 12'd1272) && (py1 >= 12'd8)  && (py1 < 12'd52);

    wire edge_wave = in_wave_p && ((px1 == 12'd8)   || (px1 == 12'd743) ||
                                   (py1 == 12'd60)  || (py1 == 12'd705));
    wire edge_liss = in_liss_p && ((px1 == 12'd752) || (px1 == 12'd1263)||
                                   (py1 == 12'd60)  || (py1 == 12'd571));
    wire edge_info = in_info_p && ((px1 == 12'd752) || (px1 == 12'd1263)||
                                   (py1 == 12'd580) || (py1 == 12'd705));
    wire edge_stat = in_stat_p && ((py1 == 12'd8) || (py1 == 12'd51));

    // 波形：ly 落在相邻两列样点连线之间
    wire [15:0] wly  = {4'd0, py1} - 16'd60;          // 面板内行号 0..645
    wire [15:0] w_lo = (((wy0 < wy1) ? wy0 : wy1) > 16'd1)
                       ? (((wy0 < wy1) ? wy0 : wy1) - 16'd1) : 16'd0;
    wire [15:0] w_hi = ((wy0 < wy1) ? wy1 : wy0) + 16'd1;
    wire wave_lit = in_wave_p && !edge_wave &&
                    (wly >= w_lo) && (wly <= w_hi);

    // 相图中心十字
    wire [11:0] lpx1 = px1 - 12'd752;
    wire [11:0] lpy1 = py1 - 12'd60;
    wire liss_cross = in_liss_p && !edge_liss &&
                      ((lpy1 == 12'd256) || (lpx1 == 12'd256));

    // ══════════════════════════════════════════════════════════════
    //  测试模式画面：8 根竖柱，高度 = 该路力度
    //
    //  ★ 高度走「力度层」：ch_vel(k) → vel_h → 柱顶位置。
    //    以后力度层逻辑改了，只要改 ch_vel 这一处，柱子高度自动跟着变。
    //
    //  面板 (8,60)-(1272,706)，柱底 y=650，柱宽 110，列距 158
    //    列 k 左边界 = 32 + k×158 → 32 190 348 506 664 822 980 1138
    // ══════════════════════════════════════════════════════════════
    function [7:0] ch_vel;
        input [2:0] k;
        begin
            case (k)
            3'd0:    ch_vel = 8'd255;
            3'd1:    ch_vel = 8'd240;
            3'd2:    ch_vel = 8'd225;
            3'd3:    ch_vel = 8'd210;
            3'd4:    ch_vel = 8'd195;
            3'd5:    ch_vel = 8'd180;
            3'd6:    ch_vel = 8'd165;
            default: ch_vel = 8'd150;
            endcase
        end
    endfunction

    // 柱高 = vel × 9 / 4（最大 255×9/4 = 573，柱顶最高到 y=77）
    function [9:0] vel_h;
        input [7:0] v;
        reg [11:0] t;
        begin
            t = v * 12'd9;
            vel_h = t >> 2;
        end
    endfunction

    localparam [11:0] BAR_BASE = 12'd650;
    wire [11:0] bt0 = BAR_BASE - {2'b0, vel_h(ch_vel(3'd0))};
    wire [11:0] bt1 = BAR_BASE - {2'b0, vel_h(ch_vel(3'd1))};
    wire [11:0] bt2 = BAR_BASE - {2'b0, vel_h(ch_vel(3'd2))};
    wire [11:0] bt3 = BAR_BASE - {2'b0, vel_h(ch_vel(3'd3))};
    wire [11:0] bt4 = BAR_BASE - {2'b0, vel_h(ch_vel(3'd4))};
    wire [11:0] bt5 = BAR_BASE - {2'b0, vel_h(ch_vel(3'd5))};
    wire [11:0] bt6 = BAR_BASE - {2'b0, vel_h(ch_vel(3'd6))};
    wire [11:0] bt7 = BAR_BASE - {2'b0, vel_h(ch_vel(3'd7))};

    wire in_test_p = (px1 >= 12'd8) && (px1 < 12'd1272) &&
                     (py1 >= 12'd60) && (py1 < 12'd706);
    wire edge_test = in_test_p && ((px1 == 12'd8)   || (px1 == 12'd1271) ||
                                   (py1 == 12'd60)  || (py1 == 12'd705));

    wire bx0 = (px1 >= 12'd32)   && (px1 < 12'd142);
    wire bx1 = (px1 >= 12'd190)  && (px1 < 12'd300);
    wire bx2 = (px1 >= 12'd348)  && (px1 < 12'd458);
    wire bx3 = (px1 >= 12'd506)  && (px1 < 12'd616);
    wire bx4 = (px1 >= 12'd664)  && (px1 < 12'd774);
    wire bx5 = (px1 >= 12'd822)  && (px1 < 12'd932);
    wire bx6 = (px1 >= 12'd980)  && (px1 < 12'd1090);
    wire bx7 = (px1 >= 12'd1138) && (px1 < 12'd1248);

    wire bb0 = (py1 >= bt0) && (py1 < BAR_BASE);
    wire bb1 = (py1 >= bt1) && (py1 < BAR_BASE);
    wire bb2 = (py1 >= bt2) && (py1 < BAR_BASE);
    wire bb3 = (py1 >= bt3) && (py1 < BAR_BASE);
    wire bb4 = (py1 >= bt4) && (py1 < BAR_BASE);
    wire bb5 = (py1 >= bt5) && (py1 < BAR_BASE);
    wire bb6 = (py1 >= bt6) && (py1 < BAR_BASE);
    wire bb7 = (py1 >= bt7) && (py1 < BAR_BASE);

    wire bar_lit = in_test_p && !edge_test &&
                   ((bx0 && bb0) || (bx1 && bb1) || (bx2 && bb2) || (bx3 && bb3) ||
                    (bx4 && bb4) || (bx5 && bb5) || (bx6 && bb6) || (bx7 && bb7));

    // 颜色
    reg [23:0] rgb;
    always @(*) begin
        if (test_mode) begin
            if      (edge_stat || edge_test) rgb = 24'h8090A0;
            else if (tx_lit)                 rgb = 24'hFFFFFF;
            else if (bar_lit)                rgb = 24'h30FF60;
            else                             rgb = 24'h000000;
        end
        else begin
            if      (edge_stat || edge_wave || edge_liss || edge_info) rgb = 24'h8090A0;
            else if (tx_lit)     rgb = 24'hFFFFFF;
            else if (wave_lit)   rgb = 24'h30FF60;
            else if (liss_lit)   rgb = 24'hFF8020;
            else if (liss_cross) rgb = 24'h303840;
            else                 rgb = 24'h000000;
        end
    end

    // 1 拍流水：rgb 在下一拍输出，de/hs/vs 延 2 拍对齐
    reg [23:0] rgb_r;
    reg        vis_d1, vis_d2, hs_d1, hs_d2, vs_d1, vs_d2;
    reg        de_r, hs_r, vs_r;
    always @(posedge clk_p) begin
        rgb_r  <= rgb;
        vis_d1 <= vis;    vis_d2 <= vis_d1;
        hs_d1  <= hsync;  hs_d2  <= hs_d1;
        vs_d1  <= vsync;  vs_d2  <= vs_d1;
        de_r   <= vis_d2;
        hs_r   <= hs_d2;
        vs_r   <= vs_d2;
    end

    // ══════════════════════════════════════════════════════════════
    //  DVI 输出
    // ══════════════════════════════════════════════════════════════
    dvi_tx_top u_dvi (
        .pixel_clock   (clk_p),
        .ddr_bit_clock (clk_p5),
        .reset         (dvi_reset),
        .den           (de_r),
        .hsync         (hs_r),
        .vsync         (vs_r),
        .pixel_data    (rgb_r),
        .tmds_clk      ({tmds_clk_p_0, tmds_clk_n_0}),
        .tmds_d0       ({tmds_d_p_0[0], tmds_d_n_0[0]}),
        .tmds_d1       ({tmds_d_p_0[1], tmds_d_n_0[1]}),
        .tmds_d2       ({tmds_d_p_0[2], tmds_d_n_0[2]})
    );

endmodule

`default_nettype wire
