//==========================================================================
//  mix_sum —— 【最终加法级】：N 路声部相加 → 音量 → 软限幅 → 帧边界输出
//
//  ⚠️ 本模块【只管一件事】：把 N 个声部的样点加起来，变成一个输出样点。
//     不含发声、不含按键、不含 I2S。
//
//  ── 为什么需要一个"大加法器" ──────────────────────────────────────
//     每个 add_voice 只能管自己那 32 个分量。要"多个音同时响"，
//     必须在最后把 N 路 16bit 样点【同时】加起来。
//     这就是整机唯一的求和点，也是整机唯一的削顶点。
//
//  ── 位宽怎么定（★ 加声部时一定要跟着改）─────────────────────────
//     每路 16bit 有符号 → 满量程 32767
//     N 路最坏情况同时到满量程 → N × 32767
//     SUM_W 必须 ≥ 16 + ceil(log2(N)) + 1（那个 +1 是留符号位余量）
//       N=4  → 16+2+1 = 19 → 取 20
//       N=8  → 16+3+1 = 20 → 取 22
//       N=32 → 16+5+1 = 22 → 取 24
//     ★ 如果 SUM_W 不够，加法会【环绕溢出】——听起来是炸裂的爆音，
//       而不是简单的削顶。所以宁可比算出来的宽 1~2 位。
//
//  ── 软限幅（这是"多音同响"好不好听的关键）───────────────────────
//     硬削顶（超过就钳位）在 4 路和弦上会产生刺耳的谐波。这里用
//     【线性段 + 二次肩】：
//
//         |x| ≤ T :  y = |x|                                  （原样通过）
//         |x| > T :  d = |x| − T
//                    y = T + d − d²/65536                      （平滑压到 0 斜率）
//
//     取 T = 16384（半满刻度）时：y 的斜率在 d=0 处仍是 1（连续），
//     在 d=32768 处降到 0，此时 y = T + 32768 − 16384 = 32768 → 正好满刻度。
//     也就是**输入到 1.5 倍满刻度都还能平滑地压回来，不会硬削**。
//
//     代价：一次 16×16 乘法 + 一次右移。一个 DSP 的事。
//
//  ── 实测（tools/tb_mix.v）────────────────────────────────────────
//     4 路都弹最响的音（MIDI 36，单路峰值 30842）：
//        硬削顶：峰值钳在 32767，削顶样点一大片
//        软限幅：峰值 ~27270，0 个削顶样点
//
//  ── 为什么输出要按 sample_tick 锁存 ─────────────────────────────
//     pcm5102a_tx 在一帧里分 16 次去读 sample_l 的各个 bit，
//     如果 sample_l 在帧中间变了，那一帧就拼出两个样点的碎片 → 每帧一响。
//     这里是整机最后一个寄存器，正好用 sample_tick 把它钉在帧边界上。
//==========================================================================
`default_nettype none

module mix_sum #(
    parameter integer NVOICE    = 4,
    parameter integer IN_W      = 16,
    parameter integer SUM_W     = 20,       // 见上面「位宽怎么定」
    parameter integer MIX_SHIFT = 1,        // 整机音量：0=原样 1=−6dB 2=−12dB
    parameter integer SOFT      = 1,        // 1=软限幅  0=硬削顶（用来 A/B）
    parameter integer KNEE      = 16384     // 软限幅膝点（半满刻度）
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [NVOICE*IN_W-1:0]   vin,          // 各声部，扁平排列
    input  wire                     sample_tick,  // 来自 pcm5102a_tx，每帧一个脉冲
    output reg  signed [15:0]       sample_l,
    output reg  signed [15:0]       sample_r
);

    // ════════════════════════════════════════════════════════════════
    //  1) 大加法器：N 路两两配对，再做一级链式相加
    //     深度 = 1 + ceil(N/2) − 1 级，比纯串行链短一半。
    //     （N=4 时是 2 级；再大就该写成完整二叉树了，见文件头）
    // ════════════════════════════════════════════════════════════════
    localparam integer NH = (NVOICE + 1) / 2;
    localparam integer IW = IN_W;

    reg signed [SUM_W-1:0] pair [0:NH-1];
    reg signed [SUM_W-1:0] sum;
    integer i;

    always @(*) begin
        for (i = 0; i < NH; i = i + 1) begin
            if (2*i + 1 < NVOICE)
                pair[i] = $signed(vin[(2*i)*IW +: IW]) + $signed(vin[(2*i+1)*IW +: IW]);
            else
                pair[i] = $signed(vin[(2*i)*IW +: IW]);
        end
    end

    always @(*) begin
        sum = {SUM_W{1'b0}};
        for (i = 0; i < NH; i = i + 1)
            sum = sum + pair[i];
    end

    // ════════════════════════════════════════════════════════════════
    //  ★★ 流水化：原来「加法树 → 取绝对值 → 软限幅(含 16×16 乘法) → 还原符号」
    //     全塞在一拍里，50 MHz 下 setup 违例 −2.7 ns（实测 25 级、23.3 ns）。
    //     但输出只在 sample_tick 采一次（每 1024 拍），余量巨大 → 拆成 3 拍：
    //       第1拍：加法树         → sum_r
    //       第2拍：音量/绝对值/d  → ax_r, d_r, sgn_r
    //       第3拍：软限幅/还原符号 → out_v（组合，下一拍锁存）
    //     代价：音频多 3 拍延迟 = 60 ns，可忽略。
    // ════════════════════════════════════════════════════════════════
    // 第 1 拍：加法树结果打拍
    reg signed [SUM_W-1:0] sum_r;
    // 第 2 拍：音量/绝对值/差值/符号 打拍
    reg        [SUM_W-1:0] ax_r;
    reg        [15:0]      d_r;
    reg                    sgn_r;

    // ── 组合逻辑（基于打拍后的和）★ 必须先声明再用 ──
    wire signed [SUM_W-1:0] x      = sum_r >>> MIX_SHIFT;
    wire        [SUM_W-1:0] ax     = x[SUM_W-1] ? -x : x;
    wire [SUM_W+1:0]        d_full = ax - KNEE[SUM_W:0];
    wire        [15:0]      d      = (ax <= KNEE)         ? 16'd0 :
                                     (d_full > 17'd32768) ? 16'd32768 :
                                                            d_full[15:0];

    always @(posedge clk) begin
        sum_r <= sum;                                   // 第 1 拍
        ax_r  <= ax;  d_r <= d;  sgn_r <= x[SUM_W-1];   // 第 2 拍
    end

    // 第 3 拍：乘法结果单独打拍（乘法器前后都有寄存器，0 DSP 竞争）
    reg  [31:0]   d2_r;
    always @(posedge clk) d2_r <= d_r * d_r;

    // 第 4 拍（组合）：软限幅
    wire [16:0]   y  = KNEE[16:0] + {1'b0, d_r} - {1'b0, d2_r[31:16]};

    wire [15:0]   mag_soft = (ax_r <= KNEE) ? ax_r[15:0] :
                             (y > 17'd32767) ? 16'd32767 : y[15:0];
    wire [15:0]   mag_hard = (ax_r > 17'd32767) ? 16'd32767 : ax_r[15:0];

    wire [15:0]   mag = SOFT ? mag_soft : mag_hard;
    // 第 5 拍：输出也打一拍，让长组合链止步于一个就近的寄存器
    reg  signed [15:0] out_v_r;
    always @(posedge clk) out_v_r <= sgn_r ? -$signed(mag) : $signed(mag);

    // ════════════════════════════════════════════════════════════════
    //  4) 只在帧边界更新（tick 延后 3 拍对齐流水线）
    // ════════════════════════════════════════════════════════════════
    reg [4:0] tick_d;      // tick 延后 5 拍，对齐上面 5 级流水
    always @(posedge clk) tick_d <= {tick_d[3:0], sample_tick};

    always @(posedge clk) begin
        if (!rst_n) begin
            sample_l <= 16'sd0;
            sample_r <= 16'sd0;
        end
        else if (tick_d[4]) begin
            sample_l <= out_v_r;    // 单声道 → 左右都送同一份
            sample_r <= out_v_r;
        end
    end

endmodule

`default_nettype wire
