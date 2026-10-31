//==========================================================================
//  ws2812_keyind —— WS2812 灯带：按键指示 + 模式指示 + 双档指导灯
//
//  ── 四种模式 ────────────────────────────────────────────────────
//     1 自动   ：循环自动弹《小星星》，只亮第 2 颗模式灯（红）
//     2 自由   ：按下哪个键亮哪颗灯（绿模式灯）
//     3 指小星星：点亮"下一个该按的键"（全亮）+ "下下个音"（半亮）（蓝）
//     4 指欢乐颂：同上，只是谱子换成欢乐颂（黄模式灯）
//
//  ── 指导灯的两档亮度 ────────────────────────────────────────────
//     当前该按的音  → 正常亮度
//     再下一个音    → 再暗一半（提前预告）
//     ★ 如果两个音是同一个键，按"当前"那档显示
//
//  ── 灯的位置（用户实测，从左到右）─────────────────────────────
//     第 11、10、9、8、7、6 颗  ← 越往左索引越大
//     key i → LED 索引 (LED_BASE − i)，LED_BASE 默认 10
//
//  数据脚 : T21 (J14 脚 4)   时序: bit1=840ns bit0=400ns 位周期1.24us
//  ★ 输出必须打一拍寄存（组合输出在帧边界会出零宽毛刺 → 整帧错位）
//==========================================================================
`default_nettype none

module ws2812_keyind #(
    parameter integer N_LED        = 20,
    parameter integer LED_BASE     = 10,   // 最左按键对应的灯索引（0 基）
    parameter integer NKEY         = 6,
    parameter integer BRIGHT_SHIFT = 2,    // 当前音亮度：2 = 1/4
    parameter integer NEXT_EXTRA   = 2,    // 预告音再暗 2^NEXT_EXTRA 倍 → 1/16
    parameter integer MODE_LED     = 1,    // 模式指示灯索引（第 2 颗）
    parameter integer TIMBRE_LED   = 0,    // 音色指示灯索引（第 1 颗）
    parameter integer OCT_LED_BASE = 11,   // 八度指示条起始索引（第 12 颗）
    parameter integer OCT_NLED     = 5,    // 5 个八度位置（-2..+2）
    parameter integer DOT_EN       = 0,
    parameter integer DIAG         = 0,    // 1 = 诊断：20 颗全发同一个固定颜色
    parameter integer PRE_BITS     = 0     // 帧首预留的 0 位数（先在 led_align 里调好再填这里）
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire [NKEY-1:0] key_state,
    input  wire [2:0]      mode,           // 1/2/3/4（3 位，4 才装得下）
    input  wire [2:0]      guide_key,      // 当前该按的键
    input  wire [2:0]      guide_key2,     // 下下个音（半亮预告）
    input  wire [1:0]      timbre,         // 0=钢琴 1=古筝 2=唢呐
    input  wire signed [2:0] oct,          // 八度位置 -2..+2
    output wire            dout
);

    //======================================================================
    //  时序常数
    //======================================================================
    // ══════════════════════════════════════════════════════════════
    //  ★★ 这组常数按【WS2812B-2020-V6】规格来，和经典 WS2812B 不一样！
    //     V6-2020 数据手册（Worldsemi V1.0）：
    //         T0H  220 ~ 380 ns      T1H  580 ~ 1000 ns
    //         T0L  580 ~ 1000 ns     T1L  580 ~ 1000 ns
    //         RES  > 280 us          T0H+T0L、T1H+T1L ≥ 1.25 us
    //     ⚠ 经典 WS2812B 是 T0H=400±150 / T1L=450±150，按那个算会
    //       T0H 超上限(V6 上限只有 380) + T1L 差 160 ns → 灯不亮
    //     下面在 50 MHz(20 ns/拍) 下的取值：
    //         0 码: T0H=17 拍=340 ns, T0L=48 拍=960 ns
    //         1 码: T1H=33 拍=660 ns, T1L=32 拍=640 ns
    //         周期 = 65 拍 = 1300 ns ≥ 1250 ✓
    // ══════════════════════════════════════════════════════════════
    localparam integer T1H  = 33;      // 660 ns（V6: 580~1000）
    localparam integer T0H  = 17;      // 340 ns（V6: 220~380）
    localparam integer TDUR = 65;      // 周期 1300 ns（V6: ≥1250）
    localparam integer TRST = 20_000;  // 400 us（V6: >280）
    localparam integer NBIT = 24 * N_LED;

    localparam [5:0] BASE       = LED_BASE[5:0];
    localparam [5:0] NKEY_C     = NKEY[5:0];
    localparam [5:0] MODE_LED_C   = MODE_LED[5:0];
    localparam [5:0] TIMBRE_LED_C = TIMBRE_LED[5:0];
    localparam [5:0] OCT_BASE_C   = OCT_LED_BASE[5:0];
    localparam [5:0] OCT_END_C    = OCT_LED_BASE[5:0] + OCT_NLED[5:0];

    //======================================================================
    //  寄存器
    //======================================================================
    reg [1:0]  state;
    reg [4:0]  pre_left;
    reg [15:0] t, rcnt;
    reg [8:0]  bitn;
    reg [4:0]  bic, led;
    reg [23:0] sh;
    reg [9:0]  fdiv;
    reg [4:0]  dot_pos;

    //======================================================================
    //  色相环；half=1 时再暗一半
    //======================================================================
    function [23:0] wheel_grb;
        input [11:0] hue;
        input        half;
        reg [7:0] frac, r, g, b;
        reg [3:0] shf;
        begin
            // ★★ 亮度就是【右移】。绝对不能写成 (x>>n)<<n ——
            //    那只是把低 n 位清零，值还是原来那么大（0xFF→0xF8 = 97%），
            //    根本没有变暗。这个 bug 从最早的版本就埋着，测试台也用同
            //    样的错误公式算期望值，所以一直"对拍通过"、看不出来。
            shf  = half ? (BRIGHT_SHIFT + NEXT_EXTRA) : BRIGHT_SHIFT;
            frac = hue[7:0];
            case (hue[10:8])
                3'd0: begin r = 8'hFF;    g = frac;    b = 8'h00; end
                3'd1: begin r = ~frac;    g = 8'hFF;    b = 8'h00; end
                3'd2: begin r = 8'h00;    g = 8'hFF;    b = frac;  end
                3'd3: begin r = 8'h00;    g = ~frac;    b = 8'hFF; end
                3'd4: begin r = frac;     g = 8'h00;    b = 8'hFF; end
                default: begin r = 8'hFF; g = 8'h00;    b = ~frac; end
            endcase
            wheel_grb = { 8'd0 + (g >> shf),
                          8'd0 + (r >> shf),
                          8'd0 + (b >> shf) };
        end
    endfunction

    //======================================================================
    //  第 j 颗灯发什么（0 = 灭）
    //======================================================================
    function [23:0] led_grb;
        input [4:0] j;
        input [4:0] g1;        // 当前音的灯
        input [4:0] g2;        // 下下个音的灯
        input [2:0] md;
        input [1:0] tb;        // 音色
        input signed [2:0] oc; // 八度
        input       DG;        // 诊断模式
        reg   [5:0] rel;
        reg         key_lit, cur_lit, nxt_lit;
        begin
            if (DG) begin
                // ★ 诊断模式：所有灯同一个暗淡红，无任何动态内容
                led_grb = { 8'd0, 8'h0C, 8'd0 };
            end
            else if (j == MODE_LED_C) begin
                // ── 模式灯：1红 2绿 3蓝 4黄（亮度也减半）──
                case (md)
                    3'd1:    led_grb = { 8'd0,   8'h7F, 8'd0    };
                    3'd2:    led_grb = { 8'h7F, 8'd0,   8'd0    };
                    3'd3:    led_grb = { 8'd0,   8'd0,   8'h7F  };
                    default: led_grb = { 8'h7F, 8'h7F, 8'd0    };   // 4 = 黄
                endcase
            end
            else if (j == TIMBRE_LED_C) begin
                // ── 音色灯（第 1 颗）：钢琴=白  古筝=青  唢呐=橙  笛子=紫 ──
                //    白 = G+R+B 全亮
                //    青 = G+B（R 关）
                case (tb)
                    2'd1:    led_grb = { 8'h7F, 8'd0,   8'h7F  };   // 古筝：青（G+B）
                    2'd2:    led_grb = { 8'h2A, 8'h7F,  8'd0    };   // 唢呐：橙（G+R）
                    2'd3:    led_grb = { 8'd0,   8'h7F,  8'h7F  };   // 笛子：紫（R+B）
                    default: led_grb = { 8'h7F, 8'h7F,  8'h7F  };   // 钢琴：白
                endcase
            end
            // ★ 本工程没有八度功能 → 原八度指示条（第 12~16 颗）整段删掉，
            //   这些索引会落进下面的 else 分支，因为 rel 为负而保持不亮。
            else begin
                rel     = BASE - { 1'b0, j };
                // ★ 本工程的模式编号：1=按键  2=指导小星星  3=指导欢乐颂
                //   （原工程是 1=自动 2=按键 3=指导 4=指导，这里整体下移一位）
                //   按键灯：所有模式都显示"哪颗被按下"
                key_lit = (rel < NKEY_C) && key_state[rel[2:0]];
                //   指导灯：模式 2 / 3 才显示"该按"和"预告"
                cur_lit = (md >= 3'd2) ? (j == g1) : 1'b0;
                nxt_lit = (md >= 3'd2) ? (j == g2) : 1'b0;

                if (cur_lit || key_lit)
                    led_grb = wheel_grb({ 1'b0, j } * 12'd77, 1'b0);   // 全亮档
                else if (nxt_lit)
                    led_grb = wheel_grb({ 1'b0, j } * 12'd77, 1'b1);   // 半亮档
                else
                    led_grb = 24'd0;
            end
        end
    endfunction

    wire [4:0]  g1_idx  = BASE - { 2'd0, guide_key  };
    wire [4:0]  g2_idx  = BASE - { 2'd0, guide_key2 };
    wire [4:0]  led_nxt = (led == N_LED - 1) ? 5'd0 : led + 5'd1;
    wire [23:0] grb_nxt = led_grb(led_nxt, g1_idx, g2_idx, mode, timbre, oct, DIAG[0]);
    wire [23:0] grb_0   = led_grb(5'd0,    g1_idx, g2_idx, mode, timbre, oct, DIAG[0]);

    //======================================================================
    //  上电复位 + 输出寄存
    //======================================================================
    reg [3:0] por_cnt = 4'd0;
    always @(posedge clk)
        if (!por_cnt[3]) por_cnt <= por_cnt + 4'd1;
    wire rst_i = por_cnt[3] & rst_n;

    reg dout_r;
    always @(posedge clk) begin
        if (!rst_i) dout_r <= 1'b0;
        else        dout_r <= (state != S_RESET) && (t < (sh[23] ? T1H : T0H));
    end
    assign dout = dout_r;

    //======================================================================
    //  帧循环
    //======================================================================
    localparam [1:0] S_RESET = 2'd0,
                     S_PRE   = 2'd1,   // 帧首预留的 0 位
                     S_SEND  = 2'd2;

    always @(posedge clk) begin
        if (!rst_i) begin
            state <= S_RESET; t <= 0; rcnt <= 0; bitn <= 0;
            bic   <= 0; led <= 0; sh <= 0; fdiv <= 0; dot_pos <= 0;
        end
        else begin
            case (state)
                //──── 帧首预留若干 0 位（补偿灯带在复位后多吃 1 位）────
                S_PRE: begin
                    if (t == TDUR - 1) begin
                        t <= 16'd0;
                        if (pre_left <= 5'd1) begin
                            pre_left <= 5'd0;
                            led   <= 5'd0;
                            sh    <= grb_0;
                            bic   <= 5'd0;
                            bitn  <= 11'd0;
                            state <= S_SEND;
                        end
                        else pre_left <= pre_left - 5'd1;
                    end
                    else t <= t + 16'd1;
                end

                S_RESET: begin
                    if (rcnt == TRST - 1) begin
                        rcnt <= 0; led <= 0;
                        bic  <= 0; bitn <= 0; t  <= 0;
                        pre_left <= PRE_BITS[4:0];
                        sh   <= 24'd0;                       // 预留位发 0
                        state <= (PRE_BITS == 0) ? S_SEND : S_PRE;
                        if (PRE_BITS == 0) sh <= grb_0;
                    end
                    else rcnt <= rcnt + 16'd1;
                end

                S_SEND: begin
                    if (t == TDUR - 1) begin
                        t    <= 0;
                        bitn <= bitn + 9'd1;
                        if (bic == 5'd23) begin
                            bic <= 0; led <= led_nxt; sh <= grb_nxt;
                        end
                        else begin
                            bic <= bic + 5'd1;
                            sh  <= { sh[22:0], 1'b0 };
                        end
                        if (bitn == NBIT - 1) begin
                            state <= S_RESET;
                            if (fdiv == 10'd559) begin
                                fdiv    <= 0;
                                dot_pos <= (dot_pos >= N_LED - 1) ? 5'd0 : dot_pos + 5'd1;
                            end
                            else fdiv <= fdiv + 10'd1;
                        end
                    end
                    else t <= t + 16'd1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
