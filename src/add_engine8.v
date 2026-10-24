//==========================================================================
//  add_engine8 —— NVOICE 个 128 分量声部 + 【共用一份参数 ROM】
//
//  这是 add_engine.v 的替代版本。两个关键变化：
//
//  ── ① 参数 ROM 从「每声部一份」改成「全部声部共用一份」────────────
//    原设计每个 add_voice 内部都实例化了一份完整参数表，4 声部 = 4 份。
//    实测（25 音 × 128 分量）：pROM 92 块 → 29 块，BSRAM 35% → 16%。
//    256 分量时这一步是决定性的：不共用需要 8.65 Mbit（超出 6.12 Mbit），
//    共用后只要 ~1 Mbit。
//
//    为什么可行：声部 g 的计数器相位错开 PH_SHIFT 拍（见 add_voice8），
//    任意时刻至多一个声部处于 s==0（发地址）或 s==1（收数据）。
//    所以地址侧只需一个 N:1 多路器，数据侧直接【广播】即可。
//    连 tag 寄存器都不需要 —— 这是错开 2 拍带来的最大简化。
//
//  ── ② 每声部 128 分量、8 级流水线 ───────────────────────────────
//    分量数翻倍，但关键路径反而从 15.1 ns 降到 9.3 ns（见 add_voice8）。
//
//  ── ★ 已知的样点对齐容差 ────────────────────────────────────────
//    4 个声部的样点完成时刻相差 0~6 拍（PH_SHIFT×(NVOICE-1)），
//    而参数 pcm5102a_tx 的 sample_tick 与声部计数器各自独立复位，
//    相位关系固定但未知。最坏情况下 g0 声部会用到上一个样点的值，
//    相当于 4 个声部之间 1 个样点（20.5 µs）的偏移。
//    人耳对 <1 ms 的声部间偏移无感，实测听不出，故接受。
//
//  ── 状态 RAM 不能共用 ───────────────────────────────────────────
//    每个声部的相位/包络状态独立，各自一份。
//==========================================================================
`default_nettype none

module add_engine8 #(
    parameter integer NVOICE    = 4,
    parameter integer NPART     = 128,
    parameter integer ROM_AW    = 14,       // 钢琴 14（11264 深）/ 古筝 13（6272 深）
    parameter integer ROM_DEPTH = 11264,
    parameter integer NOTE_LO   = 21,
    parameter integer NOTE_HI   = 108,
    parameter integer ATK       = 0,
    parameter integer TIMBRE    = 0,        // 0 = 钢琴  1 = 古筝
    parameter integer MIX_SHIFT = 1,
    parameter integer SOFT      = 1
)(
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire [NVOICE*7-1:0]     v_note,
    input  wire [NVOICE-1:0]       v_trig,
    input  wire [NVOICE-1:0]       v_gate,
    input  wire                    sample_tick,

    output wire signed [15:0]      sample_l,
    output wire signed [15:0]      sample_r,
    output wire [NVOICE-1:0]       v_idle
);

    // ── 声部 → ROM 的请求 ──────────────────────────────────────────
    wire [NVOICE*ROM_AW-1:0] v_addr;
    wire [NVOICE-1:0]        v_req;

    // ── 共用 ROM 的输出 ────────────────────────────────────────────
    wire [31:0] sh0, sh1, sh2;

    // ── 地址多路器：哪个声部在 s==0 就用谁的地址 ───────────────────
    reg [ROM_AW-1:0] addr_mux;
    integer mi;
    always @(*) begin
        addr_mux = v_addr[ROM_AW-1:0];
        for (mi = 0; mi < NVOICE; mi = mi + 1)
            if (v_req[mi]) addr_mux = v_addr[mi*ROM_AW +: ROM_AW];
    end

    if (TIMBRE == 1) begin : g_gzrom
        guzheng_param_rom #(.ADDR_W(ROM_AW), .DEPTH(ROM_DEPTH)) u_rom (
            .clk(clk), .addr(addr_mux), .d0(sh0), .d1(sh1), .d2(sh2));
    end
    else begin : g_pfrom
        piano_param_rom #(.ADDR_W(ROM_AW), .DEPTH(ROM_DEPTH)) u_rom (
            .clk(clk), .addr(addr_mux), .d0(sh0), .d1(sh1), .d2(sh2));
    end

    // ════════════════════════════════════════════════════════════════
    //  声部实例（★ ROM 数据直接广播给全部声部，靠 s==1 的互斥性保证正确）
    // ════════════════════════════════════════════════════════════════
    wire [NVOICE*16-1:0] vs;
    wire [NVOICE-1:0]    idle_w;

    genvar g;
    generate
        for (g = 0; g < NVOICE; g = g + 1) begin : g_voice
            add_voice8 #(
                .G(g), .NVOICE(NVOICE), .ROM_AW(ROM_AW), .NPART(NPART),
                .NOTE_LO(NOTE_LO), .NOTE_HI(NOTE_HI), .ATK(ATK)
            ) u_v (
                .clk(clk), .rst_n(rst_n),
                .note(v_note[g*7 +: 7]),
                .trig(v_trig[g]),
                .gate(v_gate[g]),
                .rd0(sh0), .rd1(sh1), .rd2(sh2),
                .rom_addr(v_addr[g*ROM_AW +: ROM_AW]),
                .rom_req(v_req[g]),
                .sample(vs[g*16 +: 16]),
                .idle(idle_w[g])
            );
        end
    endgenerate

    assign v_idle = idle_w;

    // ════════════════════════════════════════════════════════════════
    //  最终大加法器 + 软限幅
    // ════════════════════════════════════════════════════════════════
    mix_sum #(
        .NVOICE    (NVOICE),
        .IN_W      (16),
        .SUM_W     (20),            // ≥ 16 + log2(NVOICE) + 1
        .MIX_SHIFT (MIX_SHIFT),
        .SOFT      (SOFT)
    ) u_mix (
        .clk         (clk),
        .rst_n       (rst_n),
        .vin         (vs),
        .sample_tick (sample_tick),
        .sample_l    (sample_l),
        .sample_r    (sample_r)
    );

endmodule

`default_nettype wire
