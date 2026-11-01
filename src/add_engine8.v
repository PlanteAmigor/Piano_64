//==========================================================================
//  add_engine8 —— NVOICE 个 128 分量声部（★ per-voice cache + DMA 架构）
//
//  ── 2026-10-31 架构切换：共用大表 → 每声部独占 cache ──────────────
//    旧架构：8 个声部共用一份完整参数表，靠相位错开（PH_SHIFT=1）抢读口，
//            于是 NVOICE ≤ 8 被死锁，BSRAM 还要占 90 块。
//    新架构（总架构文档 BSRAM 层 ②）：note-on 时把该音的 128 个分量 DMA
//            进该声部独占的 cache（1 块 BSRAM/声部），各声部同相位同时读
//            也不冲突 —— PH_SHIFT 约束消失。
//
//  ── note-on 流程（比旧架构多 2.6 µs）────────────────────────────
//      v_trig[g]
//        → 置 dma_pend[g]
//        → 仲裁器选出最低位的 pending 声部
//        → param_dma 从源表搬 128 分量 = 129 拍 = 2.58 µs
//        → 搬完发 vtrig_q[g] 给 add_voice8 开始装载
//    8 个音同时 note-on 串行搬 = 20.6 µs，仍远小于起音可辨阈值。
//
//  ── 源表仍是 BSRAM（阶段 2）────────────────────────────────────
//    这一步先把「cache + DMA + 搬运正确性」跑通，源表暂留 BSRAM 大表。
//    阶段 3 只需把 src_d0/d1/d2 换成 DDR 读出的数据，本模块其余不动。
//
//  ★ 音色切换：DMA 源数据 MUX 受 timbre 控制，换音色后新音自动从另一张
//    表搬。正在响的音保持不变（数据已在各自 cache 里）——这是旧架构做不到的。
//==========================================================================
`default_nettype none

module add_engine8 #(
    parameter integer NVOICE    = 8,
    parameter integer NPART     = 128,
    parameter integer ROM_AW    = 14,
    parameter integer ROM_DEPTH = 11264,
    parameter integer NOTE_LO   = 21,
    parameter integer NOTE_HI   = 108,
    parameter integer ATK       = 0,
    parameter integer MIX_SHIFT = 1,
    parameter integer SOFT      = 1,
    // ── 参数源：0 = BSRAM 源表（旧路径，可回退）  1 = DDR3（第 3 步）──
    parameter integer USE_DDR   = 1,
    // DDR 镜像 v2 的布局参数（与 tools/make_ddr_image.py、文件头一致）
    parameter integer PIANO_BASE = 1,       // 钢琴表起始 word 地址
    parameter integer GZ_BASE    = 5633,    // 古筝表起始 word 地址
    parameter integer WORDS_NOTE = 64,      // 每音的 256 位字数（128 分量 / 2）
    parameter integer ADDR_SHIFT = 3        // word 地址 → DDR 地址单位（×8）
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // ── DDR 用户口（clk_x1 = 100 MHz 域，由 add_top 与 SD 加载器仲裁）──
    input  wire                    clk100,
    input  wire                    rst100_n,
    output wire [2:0]              app_cmd,
    output wire                    app_en,
    output wire [28:0]             app_addr,
    input  wire                    app_rdy,
    input  wire                    app_rd_data_valid,
    input  wire [255:0]            app_rd_data,

    input  wire [NVOICE*7-1:0]     v_note,
    input  wire [NVOICE-1:0]       v_trig,
    input  wire [NVOICE-1:0]       v_gate,
    input  wire [NVOICE*8-1:0]     v_vel,
    input  wire                    timbre,
    input  wire                    sample_tick,

    output wire signed [15:0]      sample_l,
    output wire signed [15:0]      sample_r,
    output wire [NVOICE-1:0]       v_idle,

    // ── 「COMPONENT 64」柱图数据源 ─────────────────────────────────
    //    只取【最近一次 note-on 的那个声部】—— 8 个声部全叠在一起会把
    //    64 根柱变成一团糊，看不出谐波包络。
    //    三个信号同属 clk 域、单拍脉冲，直接送 add_top 累加。
    output wire [6:0]              comp_idx,     // 分量号 0..NPART-1
    output wire [7:0]              comp_amp,     // 该分量实时幅度
    output wire                    comp_vld
);

    localparam [6:0] P_LO = 21, P_HI = 108, P_BASE = 21;
    localparam [6:0] G_LO = 38, G_HI = 86,  G_BASE = 38;

    // ════════════════════════════════════════════════════════════════
    //  音域钳位 → 表内偏移（每声部独立）
    // ════════════════════════════════════════════════════════════════
    wire [NVOICE*7-1:0] v_note_off;

    genvar gi;
    generate
        for (gi = 0; gi < NVOICE; gi = gi + 1) begin : g_off
            wire [6:0] n  = v_note[gi*7 +: 7];
            wire [6:0] op = (n < P_LO) ? 7'd0 : (n > P_HI) ? (P_HI - P_BASE) : (n - P_BASE);
            wire [6:0] og = (n < G_LO) ? 7'd0 : (n > G_HI) ? (G_HI - G_BASE) : (n - G_BASE);
            assign v_note_off[gi*7 +: 7] = timbre ? og : op;
        end
    endgenerate

    // ════════════════════════════════════════════════════════════════
    //  DMA 仲裁：同一时刻只服务一个声部（共享一份源表读口）
    // ════════════════════════════════════════════════════════════════
    reg  [NVOICE-1:0] dma_pend;
    reg  [NVOICE-1:0] vtrig_q;
    reg               dma_start, dma_active;
    reg  [2:0]        dma_sel;
    reg  [6:0]        dma_note_off;

    wire [NVOICE*14-1:0] dma_src_addrs;

    // 取最低置位位（独热 → 索引）
    // ★ 注意：返回 k 而不是 k[2:0] —— 对 integer 做位选在 iverilog/Gowin 里
    //   都可能退化，实测导致所有声部装成同一份数据。
    function [2:0] pick_lo;
        input [NVOICE-1:0] x;
        integer k;
        begin
            pick_lo = 3'd0;
            for (k = NVOICE-1; k >= 0; k = k - 1)
                if (x[k]) pick_lo = k;
        end
    endfunction

    wire [2:0] sel_now = pick_lo(dma_pend);

    // ★★ 用「循环展开 + 常量索引」代替运行时变量位选 [sel*7 +: 7]
    reg [6:0] note_now;
    always @(*) begin
        note_now = 7'd0;
        for (j2 = 0; j2 < NVOICE; j2 = j2 + 1)
            if (sel_now == j2)
                note_now = v_note_off[j2*7 +: 7];
    end

    // ★★ 每个 always 块用【独立的】循环变量：
    //    simulation 里多个 always 共用同一个 integer 会互相干扰
    //    （之前在仿真里导致 note_now 算成 0，所有声部都装了 note 21 的数据）。
    integer i2, j2, k2;
    always @(posedge clk) begin
        if (!rst_n) begin
            dma_pend     <= {NVOICE{1'b0}};
            vtrig_q      <= {NVOICE{1'b0}};
            dma_start    <= 1'b0;
            dma_active   <= 1'b0;
            dma_sel      <= 3'd0;
            dma_note_off <= 7'd0;
        end
        else begin
            dma_start <= 1'b0;
            vtrig_q   <= {NVOICE{1'b0}};

            // 请求优先于完成清除（快速连弹时不会被吞）
            for (i2 = 0; i2 < NVOICE; i2 = i2 + 1) begin
                if (v_trig[i2])          dma_pend[i2] <= 1'b1;
                else if (dma_done_v[i2]) dma_pend[i2] <= 1'b0;
            end

            // 搬运完成 → 给对应声部发 trig
            for (i2 = 0; i2 < NVOICE; i2 = i2 + 1)
                if (dma_done_v[i2]) vtrig_q[i2] <= 1'b1;

            if (dma_start)
                dma_active <= 1'b1;
            else if (dma_done_v[dma_sel])
                dma_active <= 1'b0;

            if (!dma_active && !dma_start && (|dma_pend)) begin
                dma_sel      <= sel_now;
                dma_note_off <= note_now;
                dma_start    <= 1'b1;
            end
        end
    end

    // ── 源地址 MUX：只有当前被服务的 DMA 的地址有效 ──────────────
    reg [13:0] src_addr_mux;
    always @(*) begin
        src_addr_mux = 14'd0;
        for (k2 = 0; k2 < NVOICE; k2 = k2 + 1)
            if (dma_sel == k2)
                src_addr_mux = dma_src_addrs[k2*14 +: 14];
    end

    // ════════════════════════════════════════════════════════════════
    //  参数源
    //    USE_DDR=0：BSRAM 源表（piano_param_rom / guzheng_param_rom）
    //    USE_DDR=1：DDR3（ddr_param_dma 直接从 DDR 取表写 cache）
    //  两条路径对 param_cache 的写口（we/waddr/wdata）接口完全一致，
    //  所以下面的 cache 例化不用改。
    // ════════════════════════════════════════════════════════════════
    wire [NVOICE-1:0]    dma_busy_bs, dma_done_bs;

    wire [NVOICE-1:0]    dma_busy_v = USE_DDR ? {NVOICE{1'b0}} : dma_busy_bs;
    wire [NVOICE-1:0]    dma_done_v = USE_DDR ? dma_done_ddr  : dma_done_bs;

    // ★ cache 写时钟：DDR 模式下用 clk_x1（100 MHz），BSRAM 模式下用引擎时钟。
    //   param_cache 是双时钟 SDP BSRAM，本来就能读写各用独立时钟。
    wire cache_wclk = USE_DDR ? clk100 : clk;

    // 每声部 DDR 口（只有被 dma_sel 选中的那个在动，其余静默）
    wire [NVOICE*3-1:0]  dd_cmd;
    wire [NVOICE-1:0]    dd_en;
    wire [NVOICE*29-1:0] dd_addr;
    wire [NVOICE-1:0]    dma_done_ddr;

    // ★ BSRAM 源表的读出口（声明必须在 generate 之前，否则是前向引用）
    wire [31:0] src_d0;
    wire [31:0] src_d1;
    wire [31:0] src_d2;

    generate if (USE_DDR == 0) begin : g_src_bsram

        wire [31:0] p0, p1, p2, g0, g1, g2;

        piano_param_rom #(.ADDR_W(14), .DEPTH(11264)) u_rom_p (
            .clk(clk), .addr(src_addr_mux[13:0]), .d0(p0), .d1(p1), .d2(p2));

        guzheng_param_rom #(.ADDR_W(13), .DEPTH(6272)) u_rom_g (
            .clk(clk), .addr(src_addr_mux[12:0]), .d0(g0), .d1(g1), .d2(g2));

        assign src_d0 = timbre ? g0 : p0;
        assign src_d1 = timbre ? g1 : p1;
        assign src_d2 = timbre ? g2 : p2;

    end
    endgenerate

    // ════════════════════════════════════════════════════════════════
    //  每声部：DMA + cache + 合成核心
    // ════════════════════════════════════════════════════════════════
    wire [NVOICE*16-1:0] vs;
    wire [NVOICE-1:0]    idle_w;

    // 分量幅度监控（每声部一份，再由 last_v 选出最近触发的那个）
    wire [NVOICE*7-1:0]  vp_idx;
    wire [NVOICE*8-1:0]  vp_amp;
    wire [NVOICE-1:0]    vp_vld;

    genvar g;
    generate
        for (g = 0; g < NVOICE; g = g + 1) begin : g_voice

            wire        dma_we;
            wire [6:0]  dma_waddr;
            wire [95:0] dma_wdata;
            wire [6:0]  v_raddr;
            wire [31:0] c_d0, c_d1, c_d2;

            // ── 搬运器（两种数据源二选一）────────────────────────
            //   ★ 这里【不能】写 generate/endgenerate：本块已经在 generate-for
            //   内部，Verilog-2001 不允许嵌套 generate（Gowin 报 EX2656）。
            //   直接写条件 if ... begin : label ... end 即可。
            if (USE_DDR == 0) begin : g_dma_bsram
                param_dma #(.NPART(NPART)) u_dma (
                    .clk      (clk),
                    .rst_n    (rst_n),
                    .start    (dma_start && (dma_sel == g)),
                    .note_off (dma_note_off),
                    .busy     (dma_busy_bs[g]),
                    .done     (dma_done_bs[g]),
                    .src_addr (dma_src_addrs[g*14 +: 14]),
                    .src_d0   (src_d0),
                    .src_d1   (src_d1),
                    .src_d2   (src_d2),
                    .we       (dma_we),
                    .waddr    (dma_waddr),
                    .wdata    (dma_wdata)
                );
                // DDR 口在 BSRAM 模式下静默
                assign dd_cmd[g*3 +: 3] = 3'b001;
                assign dd_en[g]         = 1'b0;
                assign dd_addr[g*29 +: 29] = 29'd0;
                assign dma_done_ddr[g]  = 1'b0;
            end
            else begin : g_dma_ddr
                reg        start_tog_v;         // clk50 域：启动翻转
                reg [1:0]  st_sync;             // → clk100
                reg [1:0]  dt_sync;             // ← clk100
                reg        dt_prev;
                wire       done_tog_w;
                wire [28:0] base_addr;

                // 该音的 DDR 起始 word 地址 = 乐器基址 + 表内偏移 × 64
                // ★ 用 {x, 6'b0} 移位而不是乘法：integer 参数乘法可能被综合成真乘法器
                assign base_addr = (timbre ? GZ_BASE[28:0] : PIANO_BASE[28:0])
                                 + {22'd0, dma_note_off, 6'b0};

                always @(posedge clk) begin
                    if (!rst_n) start_tog_v <= 1'b0;
                    else if (dma_start && (dma_sel == g)) start_tog_v <= ~start_tog_v;
                end

                always @(posedge clk100) begin
                    if (!rst100_n) st_sync <= 2'd0;
                    else           st_sync <= {st_sync[0], start_tog_v};
                end

                // 完成信号从 clk100 回 clk50，边沿检测成一拍脉冲
                always @(posedge clk) begin
                    if (!rst_n) begin
                        dt_sync <= 2'd0;
                        dt_prev <= 1'b0;
                    end
                    else begin
                        dt_sync <= {dt_sync[0], done_tog_w};
                        dt_prev <= dt_sync[1];
                    end
                end
                assign dma_done_ddr[g] = dt_sync[1] ^ dt_prev;

                ddr_param_dma #(
                    .WORDS_PER_NOTE (WORDS_NOTE),
                    .ADDR_SHIFT     (ADDR_SHIFT)
                ) u_dma (
                    .clk       (clk100),
                    .rst_n     (rst100_n),
                    .start_tog (st_sync[1]),
                    .base_addr (base_addr),
                    .done_tog  (done_tog_w),
                    .busy      (),
                    .we        (dma_we),
                    .waddr     (dma_waddr),
                    .wdata     (dma_wdata),
                    .app_cmd   (dd_cmd[g*3 +: 3]),
                    .app_en    (dd_en[g]),
                    .app_addr  (dd_addr[g*29 +: 29]),
                    .app_rdy   (app_rdy),
                    .app_rd_data_valid (app_rd_data_valid),
                    .app_rd_data       (app_rd_data)
                );
            end

            // ── 本声部参数 cache（128 × 96bit，双时钟 SDP BSRAM）──
            param_cache #(.NPART(NPART)) u_cache (
                .wclk  (cache_wclk),
                .rclk  (clk),
                .we    (dma_we),
                .waddr (dma_waddr),
                .wdata (dma_wdata),
                .raddr (v_raddr),
                .d0    (c_d0),
                .d1    (c_d1),
                .d2    (c_d2)
            );

            // ── 合成核心（装载完成才收到 trig）───────────────────
            add_voice8 #(
                .G(g), .NVOICE(NVOICE), .ROM_AW(7), .NPART(NPART),
                .NOTE_LO(NOTE_LO), .NOTE_HI(NOTE_HI), .ATK(ATK)
            ) u_v (
                .clk      (clk),
                .rst_n    (rst_n),
                .note     (v_note[g*7 +: 7]),
                .note_off (v_note_off[g*7 +: 7]),
                .trig     (vtrig_q[g]),
                .gate     (v_gate[g]),
                .vel_gain (v_vel[g*8 +: 8]),
                .rd0      (c_d0),
                .rd1      (c_d1),
                .rd2      (c_d2),
                .rom_addr (v_raddr),
                .sample   (vs[g*16 +: 16]),
                .idle     (idle_w[g]),
                .part_idx (vp_idx[g*7 +: 7]),
                .part_amp (vp_amp[g*8 +: 8]),
                .part_vld (vp_vld[g])
            );
        end
    endgenerate

    // ════════════════════════════════════════════════════════════════
    //  最近一次 note-on 的声部 → 它的分量幅度送到 HDMI
    //    v_trig 在 add_top 里已经是「按键按下」的单拍脉冲，直接当优先级信号。
    //    多个同时按下时，循环按 g 递增赋值 → 最大 g 胜出（视觉上无所谓）。
    // ════════════════════════════════════════════════════════════════
    reg [2:0] last_v;
    integer   lv;
    always @(posedge clk) begin
        if (!rst_n) last_v <= 3'd0;
        else begin
            for (lv = 0; lv < NVOICE; lv = lv + 1)
                if (v_trig[lv]) last_v <= lv;
        end
    end

    assign comp_idx = vp_idx[last_v*7 +: 7];
    assign comp_amp = vp_amp[last_v*8 +: 8];
    assign comp_vld = vp_vld[last_v];

    // ════════════════════════════════════════════════════════════════
    //  DDR 用户口多路选择
    //    引擎的 DMA 仲裁保证【同一时刻只有一个声部的 ddr_param_dma 活跃】
    //    （dma_active 未清除前不会再发新的 dma_start），所以这里直接按
    //    dma_sel 选出当前声部的命令通道即可，不需要真正的仲裁器。
    // ════════════════════════════════════════════════════════════════
    reg [2:0]  m_cmd;
    reg        m_en;
    reg [28:0] m_addr;
    integer kk;
    always @(*) begin
        m_cmd  = 3'b001;
        m_en   = 1'b0;
        m_addr = 29'd0;
        for (kk = 0; kk < NVOICE; kk = kk + 1) begin
            if (dma_sel == kk) begin
                m_cmd  = dd_cmd[kk*3 +: 3];
                m_en   = dd_en[kk];
                m_addr = dd_addr[kk*29 +: 29];
            end
        end
    end

    assign app_cmd  = m_cmd;
    assign app_en   = m_en;
    assign app_addr = m_addr;

    assign v_idle = idle_w;

    // ════════════════════════════════════════════════════════════════
    //  最终大加法器 + 软限幅
    // ════════════════════════════════════════════════════════════════
    mix_sum #(
        .NVOICE    (NVOICE),
        .IN_W      (16),
        .SUM_W     (20),
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
