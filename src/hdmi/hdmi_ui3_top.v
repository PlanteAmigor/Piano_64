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
//    page 2 教学    骨架：8 条轨道 + 判定线 + "PENDING"
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
    //    [1:0] ui_mode  [3:2] timbre  [5:4] fx  [15:8] transpose
    input  wire [15:0]     UI_INFO,

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
    reg [15:0]  info_s0, info_s1;

    always @(posedge clk_p) begin
        if (!rst_n) begin
            bands_cap <= 256'd0;
            info_s0   <= 16'd0;
            info_s1   <= 16'd0;
        end
        else begin
            bands_cap <= BANDS;
            info_s0   <= UI_INFO;
            info_s1   <= info_s0;
        end
    end

    wire [1:0]        page_req = info_s1[1:0];
    wire [1:0]        timbre   = info_s1[3:2];
    wire [1:0]        fx       = info_s1[5:4];
    wire signed [7:0] tr       = info_s1[15:8];

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
    wire [255:0] S_TEST   = {"TEST MODE  8 SINE",            {15{8'h20}}};  // 17
    wire [255:0] S_GUIDE  = {"GUIDE MODE",                   {22{8'h20}}};  // 10
    wire [255:0] S_PEND   = {"PENDING",                      {25{8'h20}}};  //  7
    wire [255:0] S_NONE   = {"NONE",                         {28{8'h20}}};  //  4
    wire [255:0] S_REVERB = {"REVERB",                       {26{8'h20}}};  //  6
    wire [255:0] S_DELAY  = {"DELAY",                        {27{8'h20}}};  //  5
    wire [255:0] S_CHORUS = {"CHORUS",                       {26{8'h20}}};  //  6
    wire [255:0] S_PIANO  = {"PIANO",                        {27{8'h20}}};  //  5
    wire [255:0] S_GUZH   = {"GUZHENG",                      {25{8'h20}}};  //  7
    wire [255:0] S_SUONA  = {"SUONA",                        {27{8'h20}}};  //  5
    wire [255:0] S_DIZI   = {"DIZI",                         {28{8'h20}}};  //  4

    wire [255:0] s_tname = (timbre == 2'd0) ? S_PIANO :
                           (timbre == 2'd1) ? S_GUZH  :
                           (timbre == 2'd2) ? S_SUONA : S_DIZI;
    wire [255:0] s_fname = (fx == 2'd0) ? S_NONE :
                           (fx == 2'd1) ? S_REVERB :
                           (fx == 2'd2) ? S_DELAY : S_CHORUS;

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

    // ── 移调值 → 3 字符（符号 / 十位 / 个位）─────────────────────────
    wire [7:0] tr_abs  = tr[7] ? (~tr + 8'd1) : tr;
    wire [3:0] tr_tens = (tr_abs >= 8'd20) ? 4'd2 : (tr_abs >= 8'd10) ? 4'd1 : 4'd0;
    wire [7:0] tr_ten10 = {tr_tens, 3'b000} + {2'b00, tr_tens, 1'b0};  // tens*10
    wire [3:0] tr_ones = tr_abs[3:0] - tr_ten10[3:0];

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
                6'd24:                                                 // 分量高度标题
                    if (col >= 8'd2 && col < 8'd14)
                        txt = gch(S_COMP, col - 8'd2);
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
                default: ;
                endcase
            end
            else if (pg == 2'd1) begin
                // ═══ 测试页面 ═══
                if (ln == 6'd0 && col >= 8'd2 && col < 8'd19)
                    txt = gch(S_TEST, col - 8'd2);
            end
            else begin
                // ═══ 教学页面（骨架）═══
                if (ln == 6'd0 && col >= 8'd2 && col < 8'd12)
                    txt = gch(S_GUIDE, col - 8'd2);
                if (ln == 6'd31 && col >= 8'd70 && col < 8'd77)
                    txt = gch(S_PEND, col - 8'd70);
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

    always @(posedge clk_p) begin
        px2     <= px1;
        py2     <= py1;
        tbit2   <= tbit1;
        txt_on2 <= txt_on1;
        bsel2   <= bsel1;
        bhpx2   <= bhpx_sel;
        glyph_d <= glyph[gaddr];
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
    // 主页面 —— 分量高度框 8..1047 × 388..705
    assign e_comp   = (x2 >= 12'd8)   && (x2 <= 12'd1047) &&
                      (y2 >= 12'd388) && (y2 <= 12'd705)  &&
                      ((x2 == 12'd8) || (x2 == 12'd1047) ||
                       (y2 == 12'd388) || (y2 == 12'd705));
    // 主页面 —— 李萨如框 1060..1271 × 60..271
    assign e_liss   = (x2 >= 12'd1060) && (x2 <= 12'd1271) &&
                      (y2 >= 12'd60)   && (y2 <= 12'd271)  &&
                      ((x2 == 12'd1060) || (x2 == 12'd1271) ||
                       (y2 == 12'd60)   || (y2 == 12'd271));
    // 主页面 —— 信息框 1060..1271 × 284..705
    assign e_info   = (x2 >= 12'd1060) && (x2 <= 12'd1271) &&
                      (y2 >= 12'd284)  && (y2 <= 12'd705)  &&
                      ((x2 == 12'd1060) || (x2 == 12'd1271) ||
                       (y2 == 12'd284)  || (y2 == 12'd705));
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

    wire edge_lane = (page_show == 2'd2) && (e_lane | e_jline);

    // 状态栏底色（整块填充）
    wire status_bg = (page_show == 2'd0) &&
                     (x2 >= 12'd8) && (x2 <= 12'd1271) &&
                     (y2 >= 12'd8) && (y2 <= 12'd51);

    // ══════════════════════════════════════════════════════════════
    //  上色
    // ══════════════════════════════════════════════════════════════
    reg [23:0] rgb;
    always @(*) begin
        if      (edge_lane)  rgb = 24'hFF8020;      // 轨道 / 判定线
        else if (edge_box)   rgb = 24'h607080;      // 版面框
        else if (t_lit2)     rgb = 24'hFFFFFF;      // 文字
        else if (bar_lit)    rgb = 24'h30FF60;      // 频谱柱
        else if (base_line)  rgb = 24'h405060;      // 柱底基线
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
