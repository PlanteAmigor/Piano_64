//==========================================================================
//  hdmi_test_top —— HDMI 点亮测试（1280×720@60）
//
//  ★★ 设计原则：HDMI 这一整条链路【完全照抄队友已跑通的 ir4 工程】
//       src/hdmi/ir4/dvi_tx_tmds_enc.v   TMDS 8b10b 编码
//       src/hdmi/ir4/dvi_tx_tmds_phy.v   OSER10 + ELVDS_OBUF
//       src/hdmi/ir4/dvi_tx_clk_drv.v    时钟通道（★ 像素时钟直接差分输出，
//                                        不经过 OSER10！我在这里错过一次）
//       src/hdmi/ir4/dvi_tx_top.v        三通道封装
//       src/hdmi/ir4/gowin_pll_720p.v    PLL（50 → 75 / 375 MHz）
//
//     时序参数也照抄 ir4/src/timing_gen.v：
//       H_TOTAL=1650 H_SYNC=40 H_BP=220 H_VIS=1280
//       V_TOTAL=750  V_SYNC=5  V_BP=20  V_VIS=720
//
//  唯一自己写的是【图案】：8 条竖彩条 + 白边框 + 网格。
//  验证通过后再换成正式 UI（波形 / 频谱 / 相图 / 状态条）。
//==========================================================================
`default_nettype none

module hdmi_test_top (
    input  wire clk,            // V22  50 MHz
    input  wire resetn,         // AB13 按下为低

    output wire       tmds_clk_n_0,
    output wire       tmds_clk_p_0,
    output wire [2:0] tmds_d_n_0,
    output wire [2:0] tmds_d_p_0
);

    // ── 时钟：50 → 75 MHz（像素）/ 375 MHz（串行，5×）─────────────
    wire pll_lock;
    wire clk_p;      // 75  MHz
    wire clk_p5;     // 375 MHz

    Gowin_PLL_720P u_pll (
        .lock   (pll_lock),
        .clkout0(clk_p),
        .clkout1(clk_p5),
        .clkin  (clk)
    );

    // ── 复位：PLL 锁定后 16 拍释放 ────────────────────────────────
    reg [3:0] por = 4'd0;
    always @(posedge clk_p) begin
        if (!resetn || !pll_lock) por <= 4'd0;
        else if (por != 4'hF)     por <= por + 4'd1;
    end
    wire sys_resetn = (por == 4'hF);
    wire dvi_reset  = ~sys_resetn;      // dvi_tx_top 的 reset 是高有效

    // ── 时序（照抄 ir4）──────────────────────────────────────────
    localparam integer H_TOTAL = 1650,
                       H_SYNC  = 40,
                       H_BP    = 220,
                       H_VIS   = 1280,
                       V_TOTAL = 750,
                       V_SYNC  = 5,
                       V_BP    = 20,
                       V_VIS   = 720;

    localparam integer H_START = H_SYNC + H_BP;   // 260
    localparam integer V_START = V_SYNC + V_BP;   // 25

    reg [11:0] hcnt, vcnt;
    always @(posedge clk_p) begin
        if (dvi_reset) begin
            hcnt <= 12'd0;
            vcnt <= 12'd0;
        end
        else if (hcnt == H_TOTAL - 1) begin
            hcnt <= 12'd0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 12'd0 : (vcnt + 12'd1);
        end
        else begin
            hcnt <= hcnt + 12'd1;
        end
    end

    wire h_vis = (hcnt >= H_START) && (hcnt < H_START + H_VIS);
    wire v_vis = (vcnt >= V_START) && (vcnt < V_START + V_VIS);
    wire vis   = h_vis && v_vis;

    // 同步极性：负极性
    wire hsync = ~((hcnt >= H_SYNC) && (hcnt < H_SYNC + 96));
    wire vsync = ~((vcnt >= V_SYNC) && (vcnt < V_SYNC + 5));

    wire [11:0] px = hcnt - H_START;     // 0..1279
    wire [11:0] py = vcnt - V_START;     // 0..719

    // ── 图案 ──────────────────────────────────────────────────────
    // 8 条竖彩条，每条 160 像素
    wire [2:0] bar_k = (px >= 12'd1120) ? 3'd7 :
                       (px >= 12'd 960) ? 3'd6 :
                       (px >= 12'd 800) ? 3'd5 :
                       (px >= 12'd 640) ? 3'd4 :
                       (px >= 12'd 480) ? 3'd3 :
                       (px >= 12'd 320) ? 3'd2 :
                       (px >= 12'd 160) ? 3'd1 : 3'd0;

    function [23:0] bar_color;
        input [2:0] k;
        begin
            case (k)
                3'd0: bar_color = 24'hFFFFFF;   // 白
                3'd1: bar_color = 24'hFFFF00;   // 黄
                3'd2: bar_color = 24'h00FFFF;   // 青
                3'd3: bar_color = 24'h00FF00;   // 绿
                3'd4: bar_color = 24'hFF00FF;   // 品红
                3'd5: bar_color = 24'hFF0000;   // 红
                3'd6: bar_color = 24'h0000FF;   // 蓝
                default: bar_color = 24'h000000; // 黑
            endcase
        end
    endfunction

    wire [23:0] bar = bar_color(bar_k);

    // 4 像素白边框 + 每 64 像素灰网格
    wire border = (px < 12'd4) || (px >= 12'd1276) ||
                  (py < 12'd4) || (py >= 12'd716);
    wire grid   = (px[5:0] == 6'd0) || (py[5:0] == 6'd0);

    wire [23:0] pix = border ? 24'hFFFFFF :
                      grid   ? 24'h404040 :
                               bar;

    // ── DVI 发送（照抄 ir4）──────────────────────────────────────
    dvi_tx_top u_dvi (
        .pixel_clock   (clk_p),
        .ddr_bit_clock (clk_p5),
        .reset         (dvi_reset),

        .den           (vis),
        .hsync         (hsync),
        .vsync         (vsync),
        .pixel_data    (pix),

        .tmds_clk      ({tmds_clk_p_0, tmds_clk_n_0}),
        .tmds_d0       ({tmds_d_p_0[0], tmds_d_n_0[0]}),
        .tmds_d1       ({tmds_d_p_0[1], tmds_d_n_0[1]}),
        .tmds_d2       ({tmds_d_p_0[2], tmds_d_n_0[2]})
    );

endmodule

`default_nettype wire
