//==========================================================================
//  hdmi_spec_top —— 1280×720@60 的 32 段实时频谱显示
//
//  数据来源：add_top 里的 spec_cqt（clk_sys 50 MHz 域），
//            32 个 8 位柱高 + 一个 bands_tick 脉冲。
//
//  为什么不用帧缓冲：与 hdmi_ui_top 同一套思路 —— 逐像素组合计算。
//    75 MHz 像素时钟 → 每像素 13.3 ns，地址全用移位/循环小表，
//    数据通路打 1 拍流水（px1/py1 与 BSRAM/字模输出对齐）。
//
//  版面
//    ┌──────────────────────────────────────────────────────────────┐
//    │ SPECTRUM 32 BAND                                             │  y 20..36
//    ├──────────────────────────────────────────────────────────────┤
//    │  ▁▂▃▅▇  32 根柱子，柱底 y=690，最高 589 px                    │  y 60..706
//    └──────────────────────────────────────────────────────────────┘
//
//  柱子几何：列距 32（2 的幂，纯位移）、柱宽 24、缝隙 8、起点 x=128
//     列 k 左边界 = 128 + 32k ，k=0..31 → 最后一根 1120..1143
//     32×32 = 1024 px 居中，左右各留 128 px
//
//  柱高映射：spec_cqt 给的是 0..255（-60 dB → 满幅）
//     高度 = h×2.3125 = (h<<1) + (h>>2) + (h>>4)，h=255 时 588 px
//     用移位相加而不是乘法，扫描路径上没有 DSP
//==========================================================================
`default_nettype none

module hdmi_spec_top (
    input  wire clk,                    // 50 MHz 晶振
    input  wire resetn,                 // 低有效

    // ── 来自 spec_cqt（clk_sys 域）──────────────────────────────────
    input  wire [32*8-1:0] BANDS,       // 32 × 8 位柱高，两次 tick 之间不变
    input  wire            BANDS_TICK,  // clk_sys 域单拍脉冲（20 ns 宽）

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
    //  BANDS 跨时钟域：clk_sys(50 MHz) → clk_p(75 MHz)
    //
    //  ★ 只要打一拍就够，不要加 tick 门控！
    //    第一版写成 `if (bt_sync[1]) bands_cap <= BANDS;`（只在 bands_tick
    //    时抓），结果综合器把这段判成无用 —— 因为 bt_sync 又只来自
    //    BANDS_TICK，两边互为前提，它就先挑 spec_cqt 开刀：
    //        WARN (NL0002): The module "spec_cqt" instantiated to "u_spec"
    //                       is swept in optimizing (add_top.v:832)
    //    实测 DSP 109.5→91.5、Logic 27232→21209，频谱整个消失。
    //
    //    从物理上讲也根本不需要门控：BANDS 只在 spec_cqt 扫完 32 段时更新，
    //    两次更新之间静止几十毫秒（最短的一段也有 0.57 ms ≈ 4 万个像素时钟），
    //    不存在多位数据撕裂的窗口。直接每拍采样就是最稳的写法。
    //
    //  ★ 必须加复位，否则综合器按「上电值未知 = don't care」处理。
    // ══════════════════════════════════════════════════════════════
    reg [255:0] bands_cap;
    always @(posedge clk_p) begin
        if (!rst_n) bands_cap <= 256'd0;
        else        bands_cap <= BANDS;
    end

    // ══════════════════════════════════════════════════════════════
    //  720p 时序（与 hdmi_ui_top 完全一致）
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

    // ══════════════════════════════════════════════════════════════
    //  柱子几何
    //
    //  ★ 列距取 32（2 的幂）而不是「排满 1264 px」：
    //    32 根 × 32 px = 1024 px，正好居中留 128 px 边距；
    //    而列索引 = (px−128)>>5、柱内偏移 = (px−128)&31，全是位移，
    //    扫描路径上没有乘法器也没有 32 路比较链。
    //    柱宽 24、缝隙 8。
    // ══════════════════════════════════════════════════════════════
    localparam [11:0] BAR_X0    = 12'd128;   // 第 0 根左边界
    localparam [11:0] BAR_BASE  = 12'd690;   // 柱底
    localparam [11:0] BAR_W     = 12'd24;    // 柱宽（列距 32，缝隙 8）

    wire [12:0] bx_raw = {1'b0, px} - {1'b0, BAR_X0};   // bit12=1 表示 px<BAR_X0
    //  ★★ 这里踩过一个致命坑：原来写
    //          (bx_raw[11:5] < 5'd32)
    //     5 位宽的字面量装不下 32（5 位最大 31），综合器把它截断成 0，
    //     于是判断变成 `bx_raw[11:5] < 0` —— 恒假。
    //     结果：b_in_x 恒假 → binbar1 恒假 → bar_lit 恒假 → 柱子一个都不亮
    //     → bands_cap 变成无用逻辑 → 一路反推把整个 spec_cqt 判死：
    //          WARN (NL0002): The module "spec_cqt" ... is swept in optimizing
    //     现象是 DSP 109.5→91.5、Logic 27232→21209，频谱完全消失。
    //     综合器其实早就警告了（EX3792: Literal value 'd32 truncated to
    //     fit in 5 bits），只是很容易被当成普通告警刷过去。
    //     改用 7 位字面量 + 显式高位判断，双重保险。
    wire        b_in_x = !bx_raw[12] && (bx_raw[11:10] == 2'b00) &&
                         (bx_raw[11:5] < 7'd32) &&
                         (bx_raw[4:0] < BAR_W[4:0]);
    wire        b_in_y = (py >= 12'd60) && (py < 12'd706);

    // ── 流水 1：px/py 延一拍，同时把列索引一起带过去 ────────────────
    reg [11:0] px1, py1;
    reg [4:0]  bidx1;
    reg        binbar1;
    always @(posedge clk_p) begin
        px1     <= px;
        py1     <= py;
        bidx1   <= bx_raw[9:5];
        binbar1 <= b_in_x && b_in_y;
    end

    // ── 流水 1 当拍：查柱高 → 换算像素高 → 比较 ────────────────────
    //   高度 = h×2.3125 = (h<<1) + (h>>2) + (h>>4)
    //   h=255 时 588 px，柱顶落在 y=102，面板顶 y=60 还有余量
    wire [7:0] bh   = bands_cap[{bidx1, 3'b000} +: 8];
    wire [9:0] bhpx = {1'b0, bh, 1'b0} + {2'b00, bh[7:2]} + {4'd0, bh[7:4]};

    wire bar_lit = binbar1 && (py1 >= (BAR_BASE - {2'b00, bhpx})) &&
                   (py1 < BAR_BASE);

    // ══════════════════════════════════════════════════════════════
    //  面板 / 边框 / 基线
    // ══════════════════════════════════════════════════════════════
    wire in_panel  = (px1 >= 12'd8) && (px1 < 12'd1272) &&
                     (py1 >= 12'd60) && (py1 < 12'd706);
    wire edge_panel = in_panel && ((px1 == 12'd8)   || (px1 == 12'd1271) ||
                                   (py1 == 12'd60)  || (py1 == 12'd705));
    wire base_line  = (px1 >= 12'd8) && (px1 < 12'd1272) &&
                      ((py1 == BAR_BASE) || (py1 == BAR_BASE + 12'd1));

    // ══════════════════════════════════════════════════════════════
    //  标题文字 "SPECTRUM 32 BAND"
    //
    //  字库复用 src/hdmi/ui/ui_font_asc.hex：8×16 点阵，55 字 × 16 行。
    //  字符索引 0..9 数字、10..35 A-Z、36 空格、37 '.'、38 ':'、39 '/'
    //  ★ 字符串表写成纯组合 function（LUT），字模走 BSRAM —— 与
    //    hdmi_ui_top 同一个理由：BSRAM → 组合 → BSRAM 一拍做不完。
    // ══════════════════════════════════════════════════════════════
    reg [15:0] glyph [0:879];
    initial begin
        $readmemh("src/hdmi/ui/ui_font_asc.hex", glyph);
    end

    function [5:0] title_char;
        input [4:0] i;
        begin
            case (i)
            5'd0 : title_char = 6'd28;  // S
            5'd1 : title_char = 6'd25;  // P
            5'd2 : title_char = 6'd14;  // E
            5'd3 : title_char = 6'd12;  // C
            5'd4 : title_char = 6'd29;  // T
            5'd5 : title_char = 6'd27;  // R
            5'd6 : title_char = 6'd30;  // U
            5'd7 : title_char = 6'd22;  // M
            5'd8 : title_char = 6'd36;  // sp
            5'd9 : title_char = 6'd3;   // 3
            5'd10: title_char = 6'd2;   // 2
            5'd11: title_char = 6'd36;  // sp
            5'd12: title_char = 6'd11;  // B
            5'd13: title_char = 6'd10;  // A
            5'd14: title_char = 6'd23;  // N
            default: title_char = 6'd13; // D
            endcase
        end
    endfunction

    // 标题左上角 (24,20)，16 字符 × 8 px = 128 px 宽
    wire hit_title = (px >= 12'd24) && (px < 12'd152) &&
                     (py >= 12'd20) && (py < 12'd36);
    wire [11:0] tlx = px - 12'd24;
    wire [11:0] tly = py - 12'd20;

    wire [9:0] glyph_a = {title_char(tlx[6:3]), 4'd0} + {6'd0, tly[3:0]};

    reg [15:0] glyph_d;
    reg        t_hit_d;
    reg  [2:0] t_bit_d;
    always @(posedge clk_p) begin
        glyph_d  <= glyph[glyph_a];
        t_hit_d  <= hit_title;
        t_bit_d  <= tlx[2:0];
    end
    wire t_lit = t_hit_d && glyph_d[t_bit_d];

    // ══════════════════════════════════════════════════════════════
    //  颜色
    // ══════════════════════════════════════════════════════════════
    reg [23:0] rgb;
    always @(*) begin
        if      (edge_panel)          rgb = 24'h8090A0;
        else if (t_lit)               rgb = 24'hFFFFFF;
        else if (bar_lit)             rgb = 24'h30FF60;
        else if (base_line)           rgb = 24'h405060;
        else                          rgb = 24'h000000;
    end

    // 1 拍流水：rgb 下一拍输出，de/hs/vs 延 2 拍对齐
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
