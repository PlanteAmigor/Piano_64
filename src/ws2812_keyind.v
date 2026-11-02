//==========================================================================
//  ws2812_keyind —— WS2812 灯带：按键力度 / 乐器 / 效果器 / 移调 指示
//
//  ── 灯的位置（20 颗，index 0 是最靠近数据输入的那颗）────────────
//     第几颗   index   用途
//     ────────────────────────────────────────────────────────────
//      1~ 6     0~ 5   ★ 坏灯，永远发 0（保持黑）
//      7        6      乐器：白=钢琴  青=古筝  橙=唢呐  紫=笛子
//      8        7      ★ 效果器（单颗灯，颜色区分 5 档）
//                          灭=NONE  蓝=REVERB  青=DELAY
//                          黄=SUSTAIN  品红=CHORUS
//      9~11   8~10     空（效果器已合并到第 8 颗，永远灭）
//     12       11      键 9 移调    （重按闪红 -12 / 轻按闪蓝 +12，300 ms）
//     13       12   键 8 do'        14       13   键 7 si
//     15       14   键 6 la         16       15   键 5 sol
//     17       16   键 4 fa         18       17   键 3 mi
//     19       18   键 2 re         20       19   键 1 do
//
//  ── 按键亮度 ∝ 力度 ────────────────────────────────────────────
//     kd_vel 是双触点 Δt 算出来的 0..255。这里不乘（省乘法器），
//     直接取高 2 位当档位，右移 0/1/2/3：
//         vel 192~255 → 不移   （100%）
//         vel 128~191 → >>1    （ 50%）
//         vel  64~127 → >>2    （ 25%）
//         vel   0~ 63 → >>3    （ 12.5%，轻按也看得见）
//
//  ── 颜色字节序 ──────────────────────────────────────────────────
//     WS2812 的数据顺序是 G→R→B，所以下面的 24 位常量一律写成
//         { G[7:0], R[7:0], B[7:0] }
//     例：纯红 = {8'h00, 8'hFF, 8'h00} = 24'h00FF00
//
//  ── 时序（WS2812B-2020-V6，50 MHz / 20 ns 每拍）────────────────
//         0 码: T0H=17 拍=340 ns, T0L=48 拍=960 ns
//         1 码: T1H=33 拍=660 ns, T1L=32 拍=640 ns
//         周期 = 65 拍 = 1300 ns ≥ 1250 ✓
//     ★ 输出必须打一拍寄存：组合输出在帧边界会出零宽毛刺 → 整帧错位
//==========================================================================
`default_nettype none

module ws2812_keyind #(
    parameter integer N_LED = 20,
    parameter integer DIAG  = 0        // 1 = 全部灯发暗淡红（验证灯带用）
)(
    input  wire        clk,            // CLOCK_50 直连（不走 PLL）
    input  wire        rst_n,

    input  wire [7:0]  key_on,         // 8 个音键：1 = 按住
    input  wire [63:0] key_vel,        // 8 键 × 8 位力度

    input  wire [1:0]  timbre,         // 0=钢琴 1=古筝 2=唢呐 3=笛子
    input  wire [2:0]  fx,             // 0=NONE 1=REVERB 2=DELAY 3=SUSTAIN 4=CHORUS

    input  wire        tr_led,         // 移调刚刚动作过（高电平 300 ms）
    input  wire        tr_neg,         // 1 = 降(-12) → 红   0 = 升(+12) → 蓝

    output wire        dout
);

    //======================================================================
    //  时序常数
    //======================================================================
    localparam integer T1H  = 33;      // 660 ns（V6: 580~1000）
    localparam integer T0H  = 17;      // 340 ns（V6: 220~380）
    localparam integer TDUR = 65;      // 周期 1300 ns（V6: ≥1250）
    localparam integer TRST = 20_000;  // 400 us（V6: >280）
    localparam integer NBIT = 24 * N_LED;

    //======================================================================
    //  8 个音键的固定配色（{G,R,B}）
    //    1 do  红     2 re  橙     3 mi  黄     4 fa  绿
    //    5 sol 青     6 la  蓝     7 si  紫     8 do' 粉
    //======================================================================
    function [23:0] key_color;
        input [2:0] k;                 // 0 = 键1(do) … 7 = 键8(do')
        begin
            case (k)
                3'd0: key_color = 24'h00FF00;   // 红  G00 RFF B00
                3'd1: key_color = 24'h40FF00;   // 橙  G40 RFF B00
                3'd2: key_color = 24'hFFFF00;   // 黄  GFF RFF B00
                3'd3: key_color = 24'hFF0000;   // 绿  GFF R00 B00
                3'd4: key_color = 24'hFF00FF;   // 青  GFF R00 BFF
                3'd5: key_color = 24'h0000FF;   // 蓝  G00 R00 BFF
                3'd6: key_color = 24'h0080FF;   // 紫  G00 R80 BFF
                default: key_color = 24'h00FF80; // 粉 G00 RFF B80
            endcase
        end
    endfunction

    //======================================================================
    //  第 j 颗灯发什么（{G,R,B}，0 = 灭）
    //======================================================================
    function [23:0] led_grb;
        input [4:0]  j;
        input [7:0]  kon;
        input [63:0] kvel;
        input [1:0]  tb;
        input [2:0]  fx2;
        input        tl;
        input        tn;
        reg   [4:0]  ki5;
        reg   [2:0]  ki;
        reg   [7:0]  v;
        reg   [2:0]  shf;
        reg   [23:0] base;
        begin
            if (DIAG != 0) begin
                led_grb = 24'h000C00;                       // 全暗红（诊断）
            end
            // ── 1~6 颗：坏灯 ─────────────────────────────────────
            else if (j < 5'd6) begin
                led_grb = 24'd0;
            end
            // ── 7 颗：乐器 ───────────────────────────────────────
            else if (j == 5'd6) begin
                case (tb)
                    2'd1:    led_grb = 24'h7F007F;    // 古筝 青   G7F R00 B7F
                    2'd2:    led_grb = 24'h7FFF00;    // 唢呐 橙   G7F RFF B00
                    2'd3:    led_grb = 24'h007F7F;    // 笛子 紫   G00 R7F B7F
                    default: led_grb = 24'h7F7F7F;    // 钢琴 白
                endcase
            end
            // ── 8 颗：效果器（单颗灯，颜色区分 5 档）───────────
            //    亮色代表当前选中的档位，灭 = NONE。
            else if (j == 5'd7) begin
                case (fx2)
                    3'd1:    led_grb = 24'h00007F;  // REVERB   蓝
                    3'd2:    led_grb = 24'h7F007F;  // DELAY    青  (G+B)
                    3'd3:    led_grb = 24'h7F7F00;  // SUSTAIN  黄  (G+R)
                    3'd4:    led_grb = 24'h007F7F;  // CHORUS   品红 (R+B)
                    default: led_grb = 24'd0;       // NONE     灭
                endcase
            end
            // ── 9~11 颗：效果器已合并，空置 ──────────────────────
            else if (j <= 5'd10) led_grb = 24'd0;
            // ── 12 颗：键 9 移调 ─────────────────────────────────
            else if (j == 5'd11) begin
                if (tl) led_grb = tn ? 24'h00C000 : 24'h00007F;  // 降=红 / 升=蓝
                else    led_grb = 24'd0;
            end
            // ── 13~20 颗：键 8 → 键 1 ────────────────────────────
            else begin
                ki5 = 5'd19 - j;                  // j=19 → 0(键1) ; j=12 → 7(键8)
                ki  = ki5[2:0];
                v   = kvel[{ki, 3'b000} +: 8];
                // 力度 → 亮度档：取高 2 位，右移 0/1/2/3
                shf  = 3'd3 - v[7:6];
                base = key_color(ki);
                if (kon[ki])
                    led_grb = { (base[23:16] >> shf),
                                (base[15:8]  >> shf),
                                (base[7:0]   >> shf) };
                else
                    led_grb = 24'd0;
            end
        end
    endfunction

    wire [4:0]  led_nxt = (led == N_LED - 1) ? 5'd0 : (led + 5'd1);
    wire [23:0] grb_nxt = led_grb(led_nxt, key_on, key_vel, timbre, fx, tr_led, tr_neg);
    wire [23:0] grb_0   = led_grb(5'd0,    key_on, key_vel, timbre, fx, tr_led, tr_neg);

    //======================================================================
    //  寄存器
    //======================================================================
    reg [1:0]  state;
    reg [15:0] t, rcnt;
    reg [8:0]  bitn;
    reg [4:0]  bic, led;
    reg [23:0] sh;

    localparam [1:0] S_RESET = 2'd0,
                     S_SEND  = 2'd1;

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
    always @(posedge clk) begin
        if (!rst_i) begin
            state <= S_RESET; t <= 0; rcnt <= 0; bitn <= 0;
            bic   <= 0; led <= 0; sh <= 0;
        end
        else begin
            case (state)
                S_RESET: begin
                    if (rcnt == TRST - 1) begin
                        rcnt  <= 0;
                        led   <= 5'd0;
                        bic   <= 5'd0;
                        bitn  <= 11'd0;
                        t     <= 16'd0;
                        sh    <= grb_0;
                        state <= S_SEND;
                    end
                    else rcnt <= rcnt + 16'd1;
                end

                S_SEND: begin
                    if (t == TDUR - 1) begin
                        t    <= 16'd0;
                        bitn <= bitn + 9'd1;
                        if (bic == 5'd23) begin
                            bic <= 5'd0;
                            led <= led_nxt;
                            sh  <= grb_nxt;
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
    end

endmodule

`default_nettype wire
