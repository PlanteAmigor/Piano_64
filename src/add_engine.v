//==========================================================================
//  add_engine —— NVOICE 个加法声部 + 最终加法级（mix_sum）
//
//  ⚠️ 本模块【只管一件事】：把 NVOICE 个声部的声音合起来。
//     不含按键、不含音色、不含 I2S。
//
//  ── 分层 ────────────────────────────────────────────────────────
//      add_engine
//        ├── add_voice × NVOICE      每个声部：32 个正弦分量（时分复用）
//        └── mix_sum                 ★【最终大加法器】：N 路相加 + 软限幅
//
//  ── 加声部要改什么 ──────────────────────────────────────────────
//      1. 这里的 .NVOICE(...) 和 top 的 NVOICE 一起改
//      2. mix_sum 的 SUM_W 跟着改（公式见 mix_sum.v 文件头）
//      3. ★ 注意 add_voice 内部有一份【完整的参数 ROM】，
//         每加一个声部就多占约 30 个 BSRAM（全片 335 个）。
//         现在 4 声部用了 144 个（43%），所以：
//             8 声部 ≈ 284 个（85%），再往上就装不下。
//         要更多声部必须让多个声部【共用一份 ROM】——
//         把各声部的计数器错开 8 拍，加一个 NVOICE:1 的地址多路器即可。
//==========================================================================
`default_nettype none

module add_engine #(
    parameter integer NVOICE    = 4,
    parameter integer MIX_SHIFT = 1,
    parameter integer SOFT      = 1,
    // ── 音色（透传给 add_voice）──────────────────────────────────
    parameter integer ROM_DEPTH = 1696,     // 53 音 × 32
    parameter integer NOTE_LO   = 36,
    parameter integer NOTE_HI   = 88,
    parameter integer ATK       = 1,        // 1 = 启用起音上升项（古筝）
    parameter integer TIMBRE    = 1         // 1 = 古筝  0 = 钢琴
)(
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire [NVOICE*7-1:0]     v_note,
    input  wire [NVOICE-1:0]       v_trig,
    input  wire [NVOICE-1:0]       v_gate,
    input  wire                    sample_tick,   // 来自 pcm5102a_tx，每帧一个脉冲

    output wire signed [15:0]      sample_l,
    output wire signed [15:0]      sample_r,
    output wire [NVOICE-1:0]       v_idle
);

    wire signed [15:0]   vs [0:NVOICE-1];
    wire [NVOICE-1:0]    idle_w;
    wire [NVOICE*16-1:0] vflat;

    genvar g;
    generate
        for (g = 0; g < NVOICE; g = g + 1) begin : g_voice
            add_voice #(
                .ROM_AW(13), .NPART(64), .NOTE_LO(NOTE_LO), .NOTE_HI(NOTE_HI),
                .ATK(ATK), .TIMBRE(TIMBRE), .ROM_DEPTH(ROM_DEPTH)
            ) u_v (
                .clk(clk), .rst_n(rst_n),
                .note(v_note[g*7 +: 7]),
                .trig(v_trig[g]),
                .gate(v_gate[g]),
                .sample(vs[g]),
                .idle(idle_w[g])
            );
            assign vflat[g*16 +: 16] = vs[g];
        end
    endgenerate

    assign v_idle = idle_w;

    // ── 最终大加法器 + 软限幅 + 帧边界锁存 ──────────────────────
    mix_sum #(
        .NVOICE    (NVOICE),
        .IN_W      (16),
        .SUM_W     (20),          // ≥ 16 + log2(NVOICE) + 1
        .MIX_SHIFT (MIX_SHIFT),
        .SOFT      (SOFT)
    ) u_mix (
        .clk         (clk),
        .rst_n       (rst_n),
        .vin         (vflat),
        .sample_tick (sample_tick),
        .sample_l    (sample_l),
        .sample_r    (sample_r)
    );

endmodule

`default_nettype wire
