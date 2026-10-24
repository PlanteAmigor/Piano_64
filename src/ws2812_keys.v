//==========================================================================
//  ws2812_keys —— 只做「按键指示灯」的最简 WS2812 驱动
//
//  · 20 颗灯里只有 NKEY 颗有用：第 (KEY_LED_HI-NKEY+1) ~ KEY_LED_HI 颗
//    KEY[0] → 索引 KEY_LED_HI（最右），KEY[i] → 索引 KEY_LED_HI-i
//  · 按下亮、松开灭；其余灯（包括第 1、2 颗）全黑 —— 没有任何常亮灯
//  · 时序：经典 WS2812B 与 WS2812B-2020-V6 双兼容（见下方参数表）
//==========================================================================
`default_nettype none

module ws2812_keys #(
    parameter integer N_LED      = 20,
    parameter integer NKEY       = 7,
    parameter integer KEY_LED_HI = 10      // KEY[0] 对应的灯索引
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [NKEY-1:0]   key_state,
    input  wire [1:0]        mode,         // 1=按键  2=指导小星星  3=指导欢乐颂
    input  wire [2:0]        guide_key,     // 当前该按的键（亮）
    input  wire [2:0]        guide_key2,    // 再下一个音（暗预告）
    input  wire              timbre,       // 0=钢琴
    output wire              dout
);

    // ── 位时序（50 MHz / 20 ns 一拍）────────────────────────────────
    //   按 WS2812B-2020-V6 规格，和原工程 ws2812_keyind.v 完全一致
    //   T0H 340 ns / T1H 660 ns / 周期 1300 ns / 复位 400 us
    localparam integer T1H  = 33;      // 660 ns
    localparam integer T0H  = 17;      // 340 ns
    localparam integer TDUR = 65;      // 周期 1300 ns
    localparam integer TRST = 20_000;  // 400 us
    localparam integer NBIT = 24 * N_LED;

    // ── 颜色（GRB 顺序）─────────────────────────────────────────────
    localparam [23:0] C_RED    = {8'h00, 8'h3F, 8'h00};   // 模式1 按键
    localparam [23:0] C_GREEN  = {8'h3F, 8'h00, 8'h00};   // 模式2 指导小星星
    localparam [23:0] C_BLUE   = {8'h00, 8'h00, 8'h3F};   // 模式3 指导欢乐颂
    localparam [23:0] C_KEY    = {8'h3F, 8'h00, 8'h00};   // 按键按下：绿
    localparam [23:0] C_TGT    = {8'h00, 8'h00, 8'h7F};   // 指导目标：蓝亮
    localparam [23:0] C_NEXT   = {8'h00, 8'h00, 8'h1F};   // 预告音  ：蓝暗

    // ── 每颗灯该显示什么 ───────────────────────────────────────────
    //    索引 0        = 不亮（这颗灯珠不亮，保留位置）
    //    索引 1        = 模式灯（红/绿/蓝）
    //    索引 4~10     = 7 个按键灯（按下绿；指导时目标蓝亮、预告蓝暗）
    //    其余          = 黑
    function [23:0] led_grb;
        input [4:0]        j;
        input [NKEY-1:0]   ks;
        input [1:0]        md;
        input [2:0]        g1;
        input [2:0]        g2;
        input              tm;
        integer rel;
        begin
            if (j == 5'd0) begin
                led_grb = 24'd0;      // ★ 第 1 颗保持不亮（硬件原因：这颗不亮）
            end
            else if (j == 5'd1) begin
                case (md)
                    2'd1:    led_grb = C_RED;
                    2'd2:    led_grb = C_GREEN;
                    default: led_grb = C_BLUE;
                endcase
            end
            else begin
                rel = KEY_LED_HI - j;
                if ((rel >= 0) && (rel < NKEY)) begin
                    if (ks[rel])                      led_grb = C_KEY;
                    else if ((md >= 2'd2) && (g1 == rel[2:0])) led_grb = C_TGT;
                    else if ((md >= 2'd2) && (g2 == rel[2:0])) led_grb = C_NEXT;
                    else                              led_grb = 24'd0;
                end
                else led_grb = 24'd0;
            end
        end
    endfunction

    // ── 状态机 ─────────────────────────────────────────────────────
    localparam S_RESET = 1'b0;
    localparam S_SEND  = 1'b1;

    reg        state;
    reg [15:0] t;
    reg [15:0] rcnt;
    reg [9:0]  bitn;
    reg [4:0]  bic;
    reg [4:0]  led;
    reg [23:0] sh;
    reg        dout_r;

    wire [4:0]  led_nxt  = (led == N_LED - 1) ? 5'd0 : led + 5'd1;
    wire [23:0] next_grb = led_grb(led_nxt, key_state, mode, guide_key, guide_key2, timbre);

    // ★ 必须寄存输出：组合输出会在帧边界产生零宽毛刺，灯带会当成一位数据
    always @(posedge clk) begin
        if (!rst_n) dout_r <= 1'b0;
        else        dout_r <= (state == S_SEND) && (t < (sh[23] ? T1H : T0H));
    end
    assign dout = dout_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_RESET;
            t     <= 16'd0;
            rcnt  <= 16'd0;
            bitn  <= 10'd0;
            bic   <= 5'd0;
            led   <= 5'd0;
            sh    <= 24'd0;
        end
        else case (state)

            S_RESET: begin
                if (rcnt == TRST - 1) begin
                    rcnt  <= 16'd0;
                    led   <= 5'd0;
                    sh    <= led_grb(5'd0, key_state, mode, guide_key, guide_key2, timbre);
                    bic   <= 5'd0;
                    bitn  <= 10'd0;
                    t     <= 16'd0;
                    state <= S_SEND;
                end
                else rcnt <= rcnt + 16'd1;
            end

            S_SEND: begin
                if (t == TDUR - 1) begin
                    t    <= 16'd0;
                    bitn <= bitn + 10'd1;

                    if (bic == 5'd23) begin
                        bic <= 5'd0;
                        led <= led_nxt;
                        sh  <= next_grb;
                    end
                    else begin
                        bic <= bic + 5'd1;
                        sh  <= { sh[22:0], 1'b0 };
                    end

                    if (bitn == NBIT - 1) state <= S_RESET;
                end
                else t <= t + 16'd1;
            end

        endcase
    end

endmodule

`default_nettype wire
