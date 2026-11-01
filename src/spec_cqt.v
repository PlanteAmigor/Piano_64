//==========================================================================
//  spec_cqt —— 32 段变窗长常数-Q 实时频谱分析
//
//  ════════ 为什么不用 FFT ════════
//  时频不确定性 Δf·T ≥ 1。我们要 32 段覆盖 40 Hz–16 kHz（8.6 个倍频程）：
//      最低段 40 Hz，带宽 8.5 Hz  → 必须 N ≥ fs/8.5 ≈ 5700
//      最高段 16 kHz，带宽 2800 Hz → 只要 N ≈ 28
//  FFT / 滑动 DFT 的 N 对全部 bin 是同一个，取 5700 则高频段白算 200 倍；
//  取 1024 则 40/50/63/79 Hz 全部挤进同一个 bin（实测见模型脚本）。
//
//  本模块每段窗长独立：
//      段 0 (40 Hz)  N = 11450 → 234 ms 窗，4.3 fps
//      段 31(16 kHz) N = 28    → 0.57 ms 窗，1700 fps
//  低频本来变化就慢，慢刷新不影响观感；高频刷新快，动画反而流畅。
//
//  ════════ 为什么不用实 Goertzel ════════
//  实 Goertzel 的递推  s[n] = x[n] + 2cos(ω)s[n-1] − s[n-2]
//  中间状态峰值 ≈ A·N/(2 sinω)：40 Hz 时 1/(2 sinω) = 97 倍，
//  满幅 17.5e9，32 位直接溢出 813%（模型实测）。
//  改用【复单极点谐振器】 X[n] = x[n]·w[n] + e^{-jω}·X[n−1]，
//  状态增长恒为 A·N/2，与频率无关 → 位宽统一。
//  代价 4 次乘法（vs 1 次），32 段时分复用后只占时钟的 ~2%。
//
//  ════════ 为什么必须加窗 ════════
//  不加窗（矩形）旁瓣只有 −13 dB，40 Hz 的音会漏到 100 Hz 的段。
//  Hann 主瓣宽 4 bin，所以窗长要取 2 倍最小值才能压住邻段：
//      N×1 + Hann → 邻段 −4.6 dB  （主瓣横跨 ±2 段，最差组合）
//      N×2 + Hann → 邻段 −15.5 dB，隔一段 −45.6 dB   ← 本设计
//      N×4 + Hann → 邻段 −46.5 dB，但段 0 要 469 ms，太慢
//
//  ════════ 定标链（全定点，模型验证误差 0/255）════════
//      sample(16b) × win(Q1.15,16b) >>> 22      → 幅度 256
//      X(32b) ← xw + (X·e^{-jω} >>> 23)         → 峰值峰值 1.47e6（21 bit）
//      P = re²+im²                              → 最大 2^42
//      L2  = log2(P) 的 Q8.8（前导 1 + 尾数表）
//      rel = (L2>>>1) − log2(N_k)·256           → 归一化到「每样点幅度」尺度
//      bar = clamp((rel + 759)·205 >>> 11, 0, 255)   ← −60 dB → 0，满刻度 → 255
//
//  ════════ 时序 ════════
//  每采样 1024 拍。32 段 × 最多 6 拍 = 192 拍，占 19%。
//  S_RD/MUL/ADD/WB 4 拍常态；块结束时多 2 拍（SQ/LOG/BAR）做幅度与对数。
//
//  资源：状态 32×32×2 + 32×24 = 2816 bit（分布式寄存器）
//        ROM  32×24×3 + 32×16×2 + 256×16×2 = 11.3 Kbit
//        乘法器 5 组（4 旋转 + 1 加窗），2 平方（仅块尾用）
//==========================================================================
`default_nettype none

// ── 关于综合属性：这里【不要】加 syn_preserve / syn_keep ──────────
//
//  踩坑经过（值得记住，绕了很久）：
//  合并 HDMI 后综合日志里出现
//      WARN (NL0002): The module "spec_cqt" instantiated to "u_spec"
//                     is swept in optimizing
//  也就是整个频谱被删了：DSP 109.5→91.5、Logic 27232→21209。
//
//  加回 syn_preserve 确实能把模块保住，但那是「把优化全关掉」的暴力解法：
//      加 syn_preserve : Logic 27232 / Register 21532 / BSRAM 205 / DSP 109.5
//                        → 布线拥塞，100 MHz 的 u_ld 被挤到 62 处违规
//
//  真正的根因在显示侧 hdmi_spec_top.v —— 一行
//      (bx_raw[11:5] < 5'd32)
//  5 位字面量装不下 32，被截断成 0，判断恒假 → 柱子永远不亮 →
//  bands 无人消费 → 反推把本模块判死。
//  修掉那行之后，不加任何属性就两全其美：
//      不加（修好后）: Logic 22486 / Register 18950 / BSRAM 216 / DSP 109.5
//                      → 0 处 setup 违规、0 处 hold 违规
//  ★ 注意 BSRAM 205→216：去掉 syn_preserve 后综合器自己把 st_re/st_im/st_wp
//    这三个「读+写都在同一个 always 里」的数组推断成了 BSRAM，
//    分布式 RAM 的查表逻辑全部释放出来 —— 这才是它应该有的样子。
//
//  教训：看到 NL0002 "is swept" 不要急着加 syn_preserve，
//        要顺着输出往回找「谁让它变成无用的」，通常是上游某个常量被截断。
module spec_cqt (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                tick,       // 采样节拍（48828.125 Hz）
    input  wire signed [15:0]  sample,     // 音频输入
    output wire [32*8-1:0]     bands,      // 32 段柱高，每段 8 位（0..255）
    output wire                bands_tick  // 一轮 32 段扫完的脉冲（给显示用）
);

    localparam integer NB = 32;

    // ══════════════════════════════════════════════════════════════
    //  常数表（由 tools/gen_spec_cqt.py 生成）
    // ══════════════════════════════════════════════════════════════
    reg  [23:0] AR_TAB  [0:NB-1];      //  cos(2πf/fs)  Q1.23
    reg  [23:0] AI_TAB  [0:NB-1];      // −sin(2πf/fs)  Q1.23
    reg  [23:0] INC_TAB [0:NB-1];      //  2^24 / N_k
    reg  [15:0] L2N_TAB [0:NB-1];      //  log2(N_k)  Q8.8
    reg  [15:0] WIN_TAB [0:255];       //  Hann 窗 Q1.15
    reg  [15:0] LOG_TAB [0:255];       //  log2(1+m/256) Q8.8

    initial begin
        $readmemh("spec_ar.hex",  AR_TAB);
        $readmemh("spec_ai.hex",  AI_TAB);
        $readmemh("spec_inc.hex", INC_TAB);
        $readmemh("spec_l2n.hex", L2N_TAB);
        $readmemh("spec_win.hex", WIN_TAB);
        $readmemh("spec_log.hex", LOG_TAB);
    end

    // ══════════════════════════════════════════════════════════════
    //  每段状态
    // ══════════════════════════════════════════════════════════════
    reg signed [31:0] st_re [0:NB-1];
    reg signed [31:0] st_im [0:NB-1];
    reg        [23:0] st_wp [0:NB-1];      // 窗相位，回绕 = 一块结束

    reg  [4:0]  k;
    reg  [2:0]  st;

    localparam [2:0] S_RD  = 3'd0,
                     S_MUL = 3'd1,
                     S_ADD = 3'd2,
                     S_WB  = 3'd3,
                     S_LOG = 3'd4,
                     S_BAR = 3'd5,
                     S_IDLE= 3'd6;

    // 流水寄存器
    //  ★ 必须显式 signed！ar_r/ai_r/nr/ni 若声明成 unsigned，
    //    与有符号数相乘时 Verilog 会把整个表达式当成无符号 →
    //    零扩展而不再是符号扩展 → 负数变成巨大正数 → 状态爆炸。
    //    实测现象：p_r 达到 1.8e19，32 段全 255。
    reg signed [31:0] re_r, im_r;
    reg        [23:0] wp_r, wp_new;
    reg signed [23:0] ar_r, ai_r;
    reg        [23:0] inc_r;
    reg        [15:0] l2n_r, win_r;
    reg signed [55:0] pe1, pe2, pe3, pe4;
    reg signed [31:0] xw;
    reg signed [32:0] nr, ni;
    reg               ovf;
    reg        [63:0] p_r;
    reg        [15:0] l2_r;

    // ── 异步读表（k 与 wp_r 都是寄存器，组合读出）────────────────
    wire [23:0] ar_v  = AR_TAB[k];
    wire [23:0] ai_v  = AI_TAB[k];
    wire [23:0] inc_v = INC_TAB[k];
    wire [15:0] l2n_v = L2N_TAB[k];
    // ★ 必须用 st_wp[k] 而不是 wp_r！
    //   wp_r 在 S_RD 拍仍是【上一个段】的相位（非阻塞赋值晚一拍），
    //   拿它查窗 → 每段套错窗口 → 频谱全面抹平。实测现象：32 段全 255。
    wire [15:0] win_v = WIN_TAB[st_wp[k][23:16]];

    // ══════════════════════════════════════════════════════════════
    //  log2(P) 的 Q8.8：前导 1 定位 + 256 项尾数表
    //    P 最大 2^42，取 MSB 位置 e，尾数 m = MSB 下面 8 位
    //    log2(P) ≈ e + log2(1 + m/256)
    // ══════════════════════════════════════════════════════════════
    reg  [5:0]  le;
    reg  [63:0] sh;
    integer     li;
    always @(*) begin
        le = 6'd0;
        for (li = 0; li < 64; li = li + 1)
            if (p_r[li]) le = li[5:0];
        sh = p_r << (6'd63 - le);
    end
    wire [15:0] log2_v = {le, 8'd0} + LOG_TAB[sh[62:55]];

    // ══════════════════════════════════════════════════════════════
    //  柱高
    // ══════════════════════════════════════════════════════════════
    //  满刻度参考：满幅单音落在段中心时
    //      A_eff = 32767 × 32767 >> 22 = 256
    //      |X|  = A_eff × Σw[n] / 2，而 Hann 的 Σw = N/2
    //           = A_eff × N / 4
    //      ⇒ |X|/N = A_eff/4 = 64 ⇒ log2 = 6.0 bit = 1536 (Q8.8)
    //  ★ 这里差一个 2 倍（6 dB）：窗的相干增益是 N/2 而不是 N。
    //    第一版按 N/2 算 → 满幅只到 225，整体偏低 6.4 dB。
    //  动态范围 60 dB = 9.966 bit = 2551 (Q8.8)
    //  bar = (rel − 1536 + 2551) × 255/2551 = (rel + 1015) × 0.1
    reg signed [16:0] rel_s;
    reg signed [24:0] bar_m;
    reg        [7:0]  bar_v;
    always @(*) begin
        rel_s = $signed({1'b0, (l2_r >> 1)}) - $signed({1'b0, l2n_r});
        bar_m = (rel_s + 17'sd1015) * 17'sd205;
        if (bar_m < 0)                 bar_v = 8'd0;
        else if ((bar_m >>> 11) > 255) bar_v = 8'd255;
        else                           bar_v = bar_m[18:11];
    end

    // ══════════════════════════════════════════════════════════════
    //  输入寄存
    //  ★ 必须！外部送进来的是 sat_gain 的组合输出（含膝点比较与 d×d 乘法），
    //    不在这里断开的话，综合器会把 out_l_r 那一级寄存器并进乘法器，
    //    实测路径 mix_l_r → u_spec/mult/A = 20.7 ns，SETUP −1.472 ns，
    //    全设计 137 处违例。
    // ══════════════════════════════════════════════════════════════
    reg signed [15:0] snd_r;
    always @(posedge clk)
        if (!rst_n) snd_r <= 16'sd0;
        else        snd_r <= sample;

    // ★★ 坑：Verilog 的乘法结果位宽 = 【较大操作数的位宽】，不是两者之和。
    //    写成  $signed(sample) * $signed({1'b0,win_r})  时是 17 位上下文，
    //    30000×31809 = 9.5e8 直接溢出成垃圾 → 加窗后的样点恒为 −1/0，
    //    状态永远长不大，32 段全 0。
    //    必须先用一个宽 wire 接住，让 32 位上下文传播下去。
    wire signed [31:0] xmul = $signed(snd_r) * $signed({1'b0, win_r});
    // 舍入而非截断：截断对负数是向 −∞ 取整，会给 xw 引入固定负偏置
    wire signed [31:0] xrnd = (xmul + 32'sd2_097_152) >>> 22;   // +2^21 后右移 22 = 四舍五入
    wire signed [63:0] p_v  = nr * nr + ni * ni;   // 同理，必须给有符号上下文

    // ── 柱高存储 ────────────────────────────────────────────────────
    //  ★ 用 32 项数组 + 显式展开输出，而不是 bar_ram[k*8 +: 8] 变位选。
    //    变位选写在综合器里会退化成一堆 one-hot 门控 / 甚至被整块丢弃，
    //    数组写 bar[k] <= v 是最朴素、最不会被误优化的形式。
    reg [7:0] bar [0:NB-1];
    reg       btick;
    integer   ri;

    genvar gi;
    generate
        for (gi = 0; gi < NB; gi = gi + 1) begin : g_bar_out
            assign bands[gi*8 +: 8] = bar[gi];
        end
    endgenerate
    assign bands_tick = btick;

    // ══════════════════════════════════════════════════════════════
    //  主状态机
    // ══════════════════════════════════════════════════════════════
    always @(posedge clk) begin
        if (!rst_n) begin
            st    <= S_RD;
            k     <= 5'd0;
            ovf   <= 1'b0;
            btick <= 1'b0;
            for (ri = 0; ri < NB; ri = ri + 1) begin
                st_re[ri] <= 32'sd0;
                st_im[ri] <= 32'sd0;
                st_wp[ri] <= 24'd0;
                bar[ri]   <= 8'd0;
            end
        end        else begin
            btick <= 1'b0;

            // 采样节拍：重头扫 32 段
            if (tick) begin
                k  <= 5'd0;
                st <= S_RD;
            end
            else begin
                case (st)
                // ── 读状态 + 读表 ────────────────────────────────
                S_RD: begin
                    re_r  <= st_re[k];
                    im_r  <= st_im[k];
                    wp_r  <= st_wp[k];
                    ar_r  <= ar_v;
                    ai_r  <= ai_v;
                    inc_r <= inc_v;
                    l2n_r <= l2n_v;
                    win_r <= win_v;
                    st    <= S_MUL;
                end

                // ── 加窗 + 4 次旋转乘 ────────────────────────────
                S_MUL: begin
                    pe1 <= re_r * ar_r;
                    pe2 <= im_r * ai_r;
                    pe3 <= re_r * ai_r;
                    pe4 <= im_r * ar_r;
                    xw  <= xrnd;
                    wp_new <= wp_r + inc_r;
                    // 窗相位 24 位回绕 = 一块结束
                    // ★ 2^24 = 25 位常数，必须写成 25'h1000000，
                    //   写成 24'h1000000 会被截断成 0 → ovf 永远为真
                    ovf <= ({1'b0, wp_r} + {1'b0, inc_r}) >= 25'h1000000;
                    st  <= S_ADD;
                end

                // ── 合成新的 I/Q ─────────────────────────────────
                S_ADD: begin
                    nr <= xw + ((pe1 - pe2 + 56'sd8_388_608) >>> 23);
                    ni <=      ((pe3 + pe4 + 56'sd8_388_608) >>> 23);
                    st <= S_WB;
                end

                // ── 写回；块尾额外算功率 ─────────────────────────
                S_WB: begin
                    st_re[k] <= nr[31:0];
                    st_im[k] <= ni[31:0];
                    st_wp[k] <= wp_new;
                    if (ovf) begin
                        p_r <= p_v;
                        st  <= S_LOG;
                    end
                    // ★ 无溢出时 k=31 也必须收尾！
                    //   如果只写 k<=k+1，5 位的 k 从 31 加到 32 会回绕成 0，
                    //   FSM 直接重新扫 → 一个采样内扫 8 遍（实测块长只有 N/8）。
                    else if (k == NB-1) begin
                        btick <= 1'b1;
                        k     <= 5'd0;
                        st    <= S_IDLE;
                    end
                    else begin
                        k  <= k + 5'd1;
                        st <= S_RD;
                    end
                end

                // ── log2(P) ─────────────────────────────────────
                S_LOG: begin
                    l2_r <= log2_v;
                    st   <= S_BAR;
                end

                // ── 出柱高，清零该段状态，下一段 ─────────────────
                S_BAR: begin
                    bar[k]   <= bar_v;
                    st_re[k] <= 32'sd0;
                    st_im[k] <= 32'sd0;
                    st_wp[k] <= 24'd0;
                    // ★ 扫完 32 段必须回 S_IDLE 等下一个 tick！
                    //   否则 FSM 会立即从 k=0 重新扫，一个采样内扫 8 遍，
                    //   窗相位步进快 8 倍 → 块长只有 N/8，|X| 小 64 倍
                    //   → 实测柱高全 0。
                    if (k == NB-1) begin
                        btick <= 1'b1;
                        k     <= 5'd0;
                        st    <= S_IDLE;
                    end
                    else begin
                        k  <= k + 5'd1;
                        st <= S_RD;
                    end
                end

                // ── 等下一个采样节拍 ────────────────────────────
                S_IDLE: ;

                default: st <= S_RD;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
