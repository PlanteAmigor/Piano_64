//==========================================================================
//  add_engine_harm —— 笛子/唢呐：NVOICE 个声部【全流水】谐波引擎
//
//  ── 为什么要流水线 ─────────────────────────────────────────────
//    一个样点只有 1024 拍（50 MHz ÷ 16 ÷ 64 → 48828 Hz）。
//    旧版 add_voice_harm 一个谐波要 16 拍（9 次串行表读 + 6 拍算术），
//    K=62 时一个声部就吃掉 1003 拍 —— 只够 1 个声部。
//    本引擎把参数表拆成 8 个并行 bank（见 harm_rom.v），
//    再用流水线把「谐波」当成流水线上的零件 → **1 谐波/拍**。
//
//        4 声部 × 最坏 K=62 = 248 谐波 → 248 拍（24%）
//
//  ── 每个样点的调度 ────────────────────────────────────────────
//    ST_PRE   ：声部 v 轮流做 6 拍前置（读 u、Φ、每音信息）；不活动的声部直接跳过
//    ST_HARM  ：按声部顺序把 (v, m) 逐个塞进流水线，每拍一个
//    ST_DRAIN ：等 6 拍把流水线排空，然后输出
//    → 1 个声部最坏 6 + 62 + 6 = 74 拍；4 个声部最坏 24 + 248 + 6 = 278 拍
//
//  ── 流水级（地址在 S0 发，数据 S1 到）──────────────────────────────
//    S0 : 发地址（ab/bc/ee/eo/pe/po 同拍；pi 提前一拍取下一谐波的 psi_off）
//    S1 : 数据到 → Env 插值、Ψ 插值、hAS = A×scale
//    S2 : mphi = m·Φ、dmt = dm·11·t/1024、Θ 相加 → 发 sin 地址
//    S3 : pm = env×hAS；sin 对 {sn[i+1], sn[i]} 到
//    S4 : snf = 正弦插值
//    S5 : acc += pm×snf
//
//  ── 定点 ──────────────────────────────────────────────────────
//    A     Q4.11（SC_A=4096，±8.0 —— 唢呐最大 A=6.83，Q3.13 会削顶）
//    phi_a Q0.16 圈 | dm 0.001 Hz | env_scale Q1.15 | Env int8 | Ψ Q3.12
//    acc = Σ env0·hAS·sn0 = 127·4096·32767·Σ env_true·A·sin
//    ⇒ 单声部满刻度 = acc >>> 19；多声部再右移 MIX_SHIFT 留余量
//==========================================================================
`default_nettype none

module add_engine_harm #(
    parameter integer NVOICE    = 4,
    parameter integer MIX_SHIFT = 2,        // 输出再右移几位（4 声部取 2 = /4）
    parameter integer SOFT      = 1
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // ★★ 音域 / info 基址 / 描述符基址全部改成【运行时端口】：
    //    唢呐和笛子结构完全一样，只差“表放哪里 + 音域从哪到哪”。
    //    共用同一个引擎实例（省 ~50 块 BSRAM，也省一条 DDR 仲裁），
    //    切音色时只改这 4 个输入（反正切音色本就会清移调/停旧音）。
    input  wire [6:0]              note_lo,        // 69 = 唢呐 A4 / 67 = 笛子 G4
    input  wire [6:0]              note_hi,        // 96 / 91
    input  wire [7:0]              inf_base,       // info 表字偏移：0 / 112
    input  wire [28:0]             desc_base,      // 描述符 app 地址已减 note_lo*16

    input  wire [NVOICE*7-1:0]     v_note,
    input  wire [NVOICE-1:0]       v_trig,
    input  wire [NVOICE-1:0]       v_gate,
    input  wire [NVOICE*8-1:0]     v_vel,          // ★ 力度（只调音量）
    input  wire                    sample_tick,

    output wire signed [15:0]      sample_l,
    output wire signed [15:0]      sample_r,
    output wire [NVOICE-1:0]       v_idle,

    // ── 谐波幅度监控（给 HDMI「COMPONENT 64」柱图用）─────────────
    //    与 add_voice8 的同名口完全同构，add_top 按 is_harm 二选一。
    //    r4_pm = 第 m 个谐波的瞬时幅度（= env × hAS），pv4 = 有效。
    //    ★ 纯观察口，不参与任何运算。
    output reg  [6:0]              part_idx,
    output reg  [7:0]              part_amp,
    output reg                     part_vld,

    // ── 唢呐：DDR 按音取表 ──────────────────────────────────
    input  wire                    clk100,         // DDR 用户域
    input  wire                    rst100_n,
    output wire [2:0]              app_cmd,
    output wire                    app_en,
    output wire [28:0]             app_addr,
    input  wire                    app_rdy,
    input  wire                    app_rd_data_valid,
    input  wire [255:0]            app_rd_data
);

    localparam integer AB_AW   = 11;
    localparam integer PSI_AW  = 16;
    localparam integer ENV_AW  = 16;
    localparam integer PHI_AW  = 15;
    localparam integer INFO_AW = 8;         // 224 词：唢呐 0..111 / 笛子 112..211

    localparam integer NT  = 600;           // Φ 表点数
    localparam integer NT2 = 300;           // Ψ 表点数
    localparam integer NT3 = 150;           // Env 表点数
    localparam integer PSI_E = 151;
    localparam integer ENV_E = 76;
    localparam integer NPRE  = 7;
    localparam integer TMAX  = 146400;      // 3 s

    // ════════════════════════════════════════════════════════════════
    //  ROM
    // ════════════════════════════════════════════════════════════════
    reg  [AB_AW-1:0]   a_abc, a_pi;
    reg  [PSI_AW-1:0]  a_pe, a_po;
    reg  [ENV_AW-1:0]  a_ee, a_eo;
    reg  [PHI_AW-1:0]  a_ph;
    reg  [13:0]        a_u;
    reg  [9:0]         a_sn;
    reg  [INFO_AW-1:0] a_inf;

    wire [31:0] rom_ab, rom_bc, rom_ph, rom_u, rom_sn, rom_inf;
    wire [15:0] rom_pi, rom_pe, rom_po;
    wire [7:0]  rom_ee, rom_eo;

    // ★ 改：ROM → 按音缓冲（suona_dma 从 DDR 搬入当前音）
    wire        sd_ab_we, sd_bc_we, sd_pi_we, sd_ee_we, sd_eo_we, sd_pe_we, sd_po_we, sd_ph_we;
    wire [5:0]  sd_ab_a, sd_bc_a, sd_pi_a;
    wire [12:0] sd_ee_a, sd_eo_a;
    wire [11:0] sd_pe_a, sd_po_a;
    wire [9:0]  sd_ph_a;
    wire [31:0] sd_ab_d, sd_bc_d, sd_ph_d;
    wire [15:0] sd_pi_d, sd_pe_d, sd_po_d;
    wire [7:0]  sd_ee_d, sd_eo_d;

    harm_buf u_buf (
        .clk(clk), .rst_n(rst_n),
        .abc_a(a_abc), .pi_a(a_pi),
        .ab_d(rom_ab), .bc_d(rom_bc), .pi_d(rom_pi),
        .pe_a(a_pe), .po_a(a_po), .pe_d(rom_pe), .po_d(rom_po),
        .ee_a(a_ee), .eo_a(a_eo), .ee_d(rom_ee), .eo_d(rom_eo),
        .ph_a(a_ph), .ph_d(rom_ph),
        .u_a(a_u),  .u_d(rom_u),
        .sn_a(a_sn), .sn_d(rom_sn),
        .inf_a(a_inf), .inf_d(rom_inf),
        .wclk(clk100), .wrst_n(rst100_n),
        .ab_we(sd_ab_we), .ab_a(sd_ab_a),  .ab_wd(sd_ab_d),
        .bc_we(sd_bc_we), .bc_a(sd_bc_a),  .bc_wd(sd_bc_d),
        .pi_we(sd_pi_we), .pi_a_w(sd_pi_a), .pi_wd(sd_pi_d),
        .ee_we(sd_ee_we), .ee_a_w(sd_ee_a), .ee_wd(sd_ee_d),
        .eo_we(sd_eo_we), .eo_a_w(sd_eo_a), .eo_wd(sd_eo_d),
        .pe_we(sd_pe_we), .pe_a_w(sd_pe_a), .pe_wd(sd_pe_d),
        .po_we(sd_po_we), .po_a_w(sd_po_a), .po_wd(sd_po_d),
        .ph_we(sd_ph_we), .ph_a_w(sd_ph_a), .ph_wd(sd_ph_d)
    );

    // ── 按音取表（单声部：每次 note-on 都重新搬一份）──────────────
    wire        sd_busy, sd_done;
    reg         start_tog;              // clk 域翻转
    reg  [1:0]  st_s2;                  // → clk100
    wire        sd_start = st_s2[1];
    reg  [6:0]  sd_note;

    // 完成：clk100 域脉冲 → toggle → clk 域边沿
    reg         done_tog_w;
    reg  [1:0]  dt_s2;
    reg         dt_prev;
    wire        dma_done_p = dt_s2[1] ^ dt_prev;

    // DMA 期间静音（表正在被覆盖，必须闭嘴）
    reg  [1:0]  busy_s2;
    reg         sd_pend;
    wire        quiet = sd_pend | busy_s2[0] | busy_s2[1];

    // 启动 toggle → clk100（2FF）
    always @(posedge clk100) begin
        if (!rst100_n) begin
            st_s2      <= 2'd0;
            done_tog_w <= 1'b0;
        end
        else begin
            st_s2 <= {st_s2[0], start_tog};
            if (sd_done) done_tog_w <= ~done_tog_w;
        end
    end

    // 完成 toggle / busy → clk（2FF + 边沿检测）
    always @(posedge clk) begin
        if (!rst_n) begin
            dt_s2   <= 2'd0;
            dt_prev <= 1'b0;
            busy_s2 <= 2'd0;
        end
        else begin
            dt_s2   <= {dt_s2[0], done_tog_w};
            dt_prev <= dt_s2[1];
            busy_s2 <= {busy_s2[0], sd_busy};
        end
    end

    suona_dma #(
        .DESC_OFF  (2)
    ) u_sdma (
        .clk(clk100), .rst_n(rst100_n),
        .desc_base(desc_base),
        .note(sd_note), .start(sd_start), .busy(sd_busy), .done(sd_done),
        .ab_we(sd_ab_we), .ab_a(sd_ab_a), .ab_d(sd_ab_d),
        .bc_we(sd_bc_we), .bc_a(sd_bc_a), .bc_d(sd_bc_d),
        .pi_we(sd_pi_we), .pi_a(sd_pi_a), .pi_d(sd_pi_d),
        .ee_we(sd_ee_we), .ee_a(sd_ee_a), .ee_d(sd_ee_d),
        .eo_we(sd_eo_we), .eo_a(sd_eo_a), .eo_d(sd_eo_d),
        .pe_we(sd_pe_we), .pe_a(sd_pe_a), .pe_d(sd_pe_d),
        .po_we(sd_po_we), .po_a(sd_po_a), .po_d(sd_po_d),
        .ph_we(sd_ph_we), .ph_a(sd_ph_a), .ph_d(sd_ph_d),
        .app_cmd(app_cmd), .app_en(app_en), .app_addr(app_addr),
        .app_rdy(app_rdy),
        .app_rd_data_valid(app_rd_data_valid),
        .app_rd_data(app_rd_data)
    );

    // ════════════════════════════════════════════════════════════════
    //  每声部状态
    // ════════════════════════════════════════════════════════════════
    reg [19:0]       v_ts [0:NVOICE-1];
    reg [31:0]       v_ua [0:NVOICE-1];      // u_acc（Q0.32）
    reg [18:0]       v_pf [0:NVOICE-1];      // Φ 的 19 位小数部分
    reg [7:0]        v_k  [0:NVOICE-1];
    reg [AB_AW-1:0]  v_ab [0:NVOICE-1];
    reg [15:0]       v_eb [0:NVOICE-1];
    reg [15:0]       v_pb [0:NVOICE-1];
    reg [PHI_AW-1:0] v_fb [0:NVOICE-1];
    reg              v_act[0:NVOICE-1];

    // ════════════════════════════════════════════════════════════════
    //  调度
    // ════════════════════════════════════════════════════════════════
    localparam [1:0] ST_IDLE = 2'd0, ST_PRE = 2'd1, ST_HARM = 2'd2, ST_DRAIN = 2'd3;

    reg [1:0]  st;
    reg [2:0]  pp;
    reg [1:0]  hv;
    reg [7:0]  hm;
    reg [3:0]  dr;
    reg [9:0]  cnt;
    reg [4:0]  nidx_r [0:NVOICE-1];          // note − NOTE_LO

    wire        cur_act = v_act[hv];
    wire [7:0]  cur_k   = cur_act ? v_k[hv] : 8'd0;

    // unpacked 数组不能直接做归约运算，打包一份
    wire [NVOICE-1:0] act_vec;
    generate
        genvar gi;
        for (gi = 0; gi < NVOICE; gi = gi + 1) begin : g_avec
            assign act_vec[gi] = v_act[gi];
        end
    endgenerate
    wire any_act = |act_vec;

    // 前置临时（声部串行，公用一份）
    reg [31:0] pre_u0;
    reg [31:0] phi_a;

    wire [31:0] cur_ua = v_ua[hv];

    // ★ u_acc × 599/299/149 都是 32 位常量乘法，放在谐波段里每谐波算一次
    //   会把关键路径拉长（实测 hv → v_ua mux → ×599 → ... -0.675 ns 违例）。
    //   改成在前置阶段算一次，按声部寄存下来。
    reg [14:0] v_px  [0:NVOICE-1];      // Φ 表索引（u_acc×599 的整数部）
    reg [15:0] v_pfx [0:NVOICE-1];      // Φ 表插值小数（高 16 位）
    reg [7:0]  v_ep  [0:NVOICE-1];      // Env 表索引
    reg [15:0] v_ef  [0:NVOICE-1];      // Env 插值小数
    reg [8:0]  v_pp  [0:NVOICE-1];      // Ψ 表索引
    reg [15:0] v_pf2 [0:NVOICE-1];      // Ψ 插值小数

    // 前置阶段的组合乘法（有一整拍可用）
    wire [63:0] cur_up = {32'd0, cur_ua} * (NT  - 1);
    wire [63:0] cur_ep = {32'd0, cur_ua} * (NT3 - 1);
    wire [63:0] cur_pp = {32'd0, cur_ua} * (NT2 - 1);

    // 地址侧的位置（当前拍要发的声部 = hv）
    wire [7:0] a_epos = v_ep[hv];
    wire [8:0] a_ppos = v_pp[hv];

    // 数据侧的位置（上一拍发出去的那一项 = dq_vo）
    reg  [1:0]  dq_vo;
    reg  [7:0]  dq_m;
    wire [7:0]  e_pos = v_ep[dq_vo];
    wire [15:0] e_fr  = v_ef[dq_vo];
    wire [8:0]  p_pos = v_pp[dq_vo];
    wire [15:0] p_fr  = v_pf2[dq_vo];

    wire [15:0] a_env_off = {8'd0, hm} * ENV_E;

    // ★ psi_off 要提前一拍取（Ψ 的地址靠它）。提前量必须按【下一拍真正要发的
    //   (声部, 谐波)】算 —— 直接写 ab[hv]+hm+1 在“跳不活动声部”时会算错，
    //   切声部的第一拍会拿到上一声部的行号（实测多声部全错）。
    // ★★ 扫描必须用【打包位向量 + 移位 + 优先编码】而不是 for 循环逐个 mux
    //    v_k / v_act，否则组合路径长达 32 ns（实测 -8 ns 违例）。
    wire [NVOICE-1:0] k_nz;
    generate
        genvar gk;
        for (gk = 0; gk < NVOICE; gk = gk + 1) begin : g_knz
            assign k_nz[gk] = v_act[gk] && (v_k[gk] != 8'd0);
        end
    endgenerate

    wire [2*NVOICE-1:0] rot = {k_nz, k_nz} >> hv;   // rot[j] = k_nz[(hv+j) mod NVOICE]
    wire      any_after = |rot[NVOICE-1:1];
    wire [1:0] first_j  = rot[1] ? 2'd1 : (rot[2] ? 2'd2 : 2'd3);
    wire [1:0] first_k  = k_nz[0] ? 2'd0 : (k_nz[1] ? 2'd1 : (k_nz[2] ? 2'd2 : 2'd3));

    reg  [1:0]  nx_vo;
    reg  [7:0]  nx_hm;
    always @(*) begin
        if (st == ST_HARM) begin
            if (cur_k != 8'd0 && hm + 8'd1 < cur_k) begin
                nx_vo = hv; nx_hm = hm + 8'd1;
            end
            else if (any_after) begin
                nx_vo = hv + first_j; nx_hm = 8'd0;
            end
            else begin
                nx_vo = hv; nx_hm = 8'd0;      // 已经是最后一个，地址不用了
            end
        end
        else begin
            nx_vo = first_k; nx_hm = 8'd0;       // 前置阶段：指向第一个有声部的谐波 0
        end
    end
    wire [AB_AW-1:0] a_pi_w = v_ab[nx_vo] + {{(AB_AW-8){1'b0}}, nx_hm};

    // ════════════════════════════════════════════════════════════════
    //  流水寄存器
    // ════════════════════════════════════════════════════════════════
    reg [1:0]  r1_vo;
    reg [7:0]  r1_m;
    reg signed [15:0] r1_dm;
    reg signed [19:0] r1_pa;
    reg [18:0] r1_pf;
    reg signed [31:0] r1_env;
    reg signed [31:0] r1_psi;
    reg signed [31:0] r1_hAS;
    reg signed [27:0] r1_dmt;

    reg signed [31:0] r2_env;
    reg signed [31:0] r2_hAS;
    reg [7:0]  r2_frac;

    reg signed [31:0] r3_pm;
    reg signed [15:0] r3_sn0, r3_sn1;
    reg [7:0]  r3_frac;

    reg signed [31:0] r4_pm;
    reg signed [31:0] r4_snf;

    // ★ 新增：谐波序号延迟链。原流水只把 m 带到 r1（S1 算相位要用），
    //   但 r4_pm 是 S4 的幅度，要配对它的谐波号必须再延 3 拍。
    //   纯追加，不动任何现有赋值。
    reg [7:0] r2_m, r3_m, r4_m;

    reg pv0, pv1, pv2, pv3, pv4;

    // ── S1（ROM 数据 → 插值 / hAS / dmt）───────────────────────────
    //  ★ dmt = δ·t，δ 单位 0.001 Hz；11264/2^20 = 11/1024
    //    把 t_smp×11 做成常量移位加法（11 = 8+2+1），与 16 位 dm 只乘【一次】。
    //    原来是 dm×11×t_smp 两级乘法串在相位合成前，实测关键路径 25.3 ns。
    wire signed [7:0]  e_first  = e_pos[0] ? $signed(rom_eo) : $signed(rom_ee);
    wire signed [7:0]  e_second = e_pos[0] ? $signed(rom_ee) : $signed(rom_eo);
    // ★ 插值乘法必须收窄：直接写 $signed(e_second-e_first) * $signed({16'd0,e_fr})
    //   两边都是 32 位 → 综合出 32×32 大乘法，实测关键路径 ~22 ns。
    //   差值只有 ±254（9 位）、小数只用 8 位 → 做成 23×9 就够，结果不溢出。
    wire signed [8:0]  e_d    = e_second - e_first;
    wire signed [22:0] e_dex  = {{14{e_d[8]}}, e_d};
    wire signed [12:0] e_fq   = {1'b0, e_fr[15:4]};
    wire signed [30:0] e_prod = e_dex * e_fq;
    wire signed [31:0] s1_env = e_first + ((e_prod + 31'sd2048) >>> 12);

    wire signed [15:0] p_first  = p_pos[0] ? $signed(rom_po) : $signed(rom_pe);
    wire signed [15:0] p_second = p_pos[0] ? $signed(rom_pe) : $signed(rom_po);
    wire signed [16:0] p_d    = p_second - p_first;      // Ψ ±22528 → 17 位
    wire signed [23:0] p_dex  = {{7{p_d[16]}}, p_d};
    wire signed [12:0] p_fq   = {1'b0, p_fr[15:4]};
    wire signed [30:0] p_prod = p_dex * p_fq;
    wire signed [31:0] s1_psi = p_first + ((p_prod + 31'sd2048) >>> 12);

    wire signed [15:0] s1_A   = rom_ab[15:0];
    wire signed [15:0] s1_PA  = rom_ab[31:16];
    wire signed [15:0] s1_DM  = rom_bc[15:0];
    wire signed [15:0] s1_SC  = rom_bc[31:16];
    wire signed [31:0] s1_hAS = (s1_A * s1_SC + 32'sd16384) >>> 15;
    wire [23:0]        s1_tw  = {4'd0, v_ts[dq_vo]} * 5'd11;
    wire signed [63:0] s1_dmt = ($signed({{32{s1_DM[15]}}, s1_DM})
                                * $signed({40'd0, s1_tw}) + 64'sd512) >>> 10;

    // ── S2（相位合成）────────────────────────────────────────────
    wire signed [31:0] s2_mphi = $signed({9'd0, r1_pf}) * $signed({24'd0, r1_m});
    wire signed [27:0] s2_theta = s2_mphi[27:0] + r1_dmt
                                 + (r1_psi <<< 7) + {{8{r1_pa[19]}}, r1_pa};
    wire [9:0]  s2_sin_addr = s2_theta[18:9];

    // ── S3 / S4 ──────────────────────────────────────────────────
    wire signed [31:0] s3_pm  = r2_env * r2_hAS;
    wire signed [31:0] s4_snf = r3_sn0 + (($signed(r3_sn1 - r3_sn0)
                                * $signed({24'd0, r3_frac}) + 64'sd128) >>> 8);

    // ════════════════════════════════════════════════════════════════
    //  地址（组合）—— 用当前拍要发的声部 hv
    // ════════════════════════════════════════════════════════════════
    always @(*) begin
        a_abc = {AB_AW{1'b0}};
        a_pi  = a_pi_w;
        a_pe  = {PSI_AW{1'b0}};
        a_po  = {PSI_AW{1'b0}};
        a_ee  = {ENV_AW{1'b0}};
        a_eo  = {ENV_AW{1'b0}};
        a_ph  = {PHI_AW{1'b0}};
        a_u   = v_ts[hv][19:4];
        a_sn  = s2_sin_addr;
        a_inf = inf_base + {nidx_r[hv], 2'b00};
        case (st)
        ST_PRE: begin
            a_inf = inf_base + {nidx_r[hv], 2'b00} + {6'd0, pp[1:0]};
            case (pp)
            3'd1: a_u = v_ts[hv][19:4] + 14'd1;
            3'd4: a_ph = v_fb[hv] + v_px[hv];
            3'd5: a_ph = v_fb[hv] + v_px[hv] + 15'd1;
            default: ;
            endcase
        end
        ST_HARM: begin
            a_abc = v_ab[hv] + {{(AB_AW-8){1'b0}}, hm};
            a_ee  = v_eb[hv] + a_env_off + {7'd0, a_epos[7:1]} + {15'd0, a_epos[0]};
            a_eo  = v_eb[hv] + a_env_off + {7'd0, a_epos[7:1]};
            a_pe  = v_pb[hv] + rom_pi + {7'd0, a_ppos[8:1]} + {15'd0, a_ppos[0]};
            a_po  = v_pb[hv] + rom_pi + {7'd0, a_ppos[8:1]};
        end
        default: ;
        endcase
    end

    // ════════════════════════════════════════════════════════════════
    //  累加 / 输出
    // ════════════════════════════════════════════════════════════════
    reg signed [63:0] acc;
    reg signed [15:0] smp;
    reg [NVOICE-1:0]  v_idle_r;

    wire signed [63:0] mix = acc >>> (19 + MIX_SHIFT);

    function signed [15:0] sat16; input signed [63:0] x;
        begin
            if      (x >  64'sd32767) sat16 =  16'sd32767;
            else if (x < -64'sd32768) sat16 = -16'sd32768;
            else                      sat16 = x[15:0];
        end
    endfunction

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            st <= ST_IDLE; pp <= 3'd0; hv <= 2'd0; hm <= 8'd0; dr <= 4'd0;
            cnt <= 10'd0; acc <= 64'sd0; smp <= 16'sd0; v_idle_r <= {NVOICE{1'b1}};
            pre_u0 <= 32'd0;
            phi_a <= 32'd0;
            dq_vo <= 2'd0; dq_m <= 8'd0;
            r1_vo <= 0; r1_m <= 0; r1_dm <= 0; r1_pa <= 0; r1_pf <= 0;
            r1_env <= 0; r1_psi <= 0; r1_hAS <= 0; r1_dmt <= 0;
            r2_env <= 0; r2_hAS <= 0; r2_frac <= 0;
            r3_pm <= 0; r3_sn0 <= 0; r3_sn1 <= 0; r3_frac <= 0;
            r4_pm <= 0; r4_snf <= 0;
            pv0 <= 0; pv1 <= 0; pv2 <= 0; pv3 <= 0; pv4 <= 0;
            for (i = 0; i < NVOICE; i = i + 1) begin
                v_ts[i] <= 20'd0; v_ua[i] <= 32'd0; v_pf[i] <= 19'd0;
                v_k[i]  <= 8'd0;  v_ab[i] <= 0;     v_eb[i] <= 16'd0;
                v_pb[i] <= 16'd0; v_fb[i] <= 0;     v_act[i] <= 1'b0;
                v_px[i] <= 15'd0; v_pfx[i] <= 16'd0;
                v_ep[i] <= 8'd0;  v_ef[i]  <= 16'd0;
                v_pp[i] <= 9'd0;  v_pf2[i] <= 16'd0;
                nidx_r[i] <= 5'd0;
            end
            // ★ 取表控制信号必须复位！忘了写会让它们保持 X，
            //   而 `if (v_trig[0] && !sd_pend)` 遇到 X 就永不成立
            //   → 仿真里永远不启动 DMA、永远静音（硬件复位值是 0 所以能响）
            sd_pend   <= 1'b0;
            start_tog <= 1'b0;
        end
        else begin
            cnt <= (cnt == 10'd1023) ? 10'd0 : cnt + 10'd1;

            // ── 流水推进（无条件）──────────────────────────────
            r4_pm   <= r3_pm;
            r4_snf  <= s4_snf;
            r3_pm   <= s3_pm;
            r3_sn0  <= rom_sn[15:0];
            r3_sn1  <= rom_sn[31:16];
            r3_frac <= r2_frac;
            r2_m    <= r1_m;                 // ★ 新增：谐波号延迟链
            r3_m    <= r2_m;
            r4_m    <= r3_m;
            r2_env  <= r1_env;
            r2_hAS  <= r1_hAS;
            r2_frac <= s2_theta[8:1];
            r1_vo   <= dq_vo;
            r1_m    <= dq_m;
            r1_dm   <= s1_DM;
            r1_dmt  <= s1_dmt[27:0];
            r1_pa   <= {{4{s1_PA[15]}}, s1_PA, 3'b000};   // Q0.16 → 19 位小数
            r1_pf   <= v_pf[dq_vo];
            r1_env  <= s1_env;
            r1_psi  <= s1_psi;
            r1_hAS  <= s1_hAS;
            pv0     <= (st == ST_HARM) && cur_act;
            pv1     <= pv0; pv2 <= pv1; pv3 <= pv2; pv4 <= pv3;
            dq_vo   <= hv;
            dq_m    <= hm;

            // ── 累加 ─────────────────────────────────────────────
            if (cnt == 10'd0) acc <= 64'sd0;
            else if (pv4)     acc <= acc + ($signed({{32{r4_pm[31]}}, r4_pm})
                                          * $signed({{32{r4_snf[31]}}, r4_snf}));

            // ── 每样点：计数 + 到期（★ 每个样点只加一，不是每拍）──
            if (cnt == 10'd0) begin
                for (i = 0; i < NVOICE; i = i + 1) begin
                    if (v_act[i]) begin
                        // ★ 松键即停：唢呐是吹奏乐器，松口就断气。
                        //   原来只靠 TMAX（3 s）硬切，松键后还会继续响 3 秒。
                        //   停止后由下面的 smp 一阶衰减平滑收尾，不出爆音。
                        if (!v_gate[i])                        v_act[i] <= 1'b0;
                        else if (v_ts[i] + 20'd1 >= TMAX)      v_act[i] <= 1'b0;
                        v_ts[i] <= v_ts[i] + 20'd1;
                    end
                end
            end

            // ── 触发链：note-on → 取表 → 表到位才起振 ──────────────
            //   ★ 单声部：表只有一份，必须先停旧音、再覆盖表、再起新音。
            //     所以这里只发 DMA 请求，v_act 由 dma_done_p 置位。
            if (v_trig[0] && !sd_pend) begin
                sd_note <= v_note[6:0];
                start_tog <= ~start_tog;
                sd_pend <= 1'b1;
            end
            if (dma_done_p) begin
                sd_pend <= 1'b0;
                v_act[0]  <= 1'b1;
                v_ts[0]   <= 20'd0;
                v_ua[0]   <= 32'd0;
                nidx_r[0] <= (sd_note < note_lo) ? 5'd0 :
                             (sd_note > note_hi) ? (note_hi - note_lo) :
                             (sd_note - note_lo);
            end

            // ── 调度 ─────────────────────────────────────────────
            if (cnt == 10'd0) begin
                if (any_act) begin
                    st <= ST_PRE; pp <= 3'd0; hv <= 2'd0; hm <= 8'd0;
                end
                else st <= ST_IDLE;
            end
            else begin
                case (st)
                ST_PRE: begin
                    if (!cur_act) begin
                        // 不活动的声部直接跳过
                        pp <= 3'd0;
                        if (hv == NVOICE - 1) begin st <= ST_HARM; hv <= 2'd0; hm <= 8'd0; end
                        else                  hv <= hv + 2'd1;
                    end
                    else begin
                        case (pp)
                        3'd1: begin
                                  pre_u0   <= rom_u;
                                  v_fb[hv] <= 32'd0;   // ★ 按音预取：phi 段内相对
                              end
                        3'd2: begin
                                  v_ua[hv] <= pre_u0 + (((rom_u - pre_u0) * v_ts[hv][3:0]) >> 4);
                                  v_k[hv]  <= rom_inf[31:24];     // info[4n+1]
                                  v_ab[hv] <= 0;       // ★ 按音预取：ab 段内相对
                              end
                        3'd3: begin
                                  v_eb[hv]  <= 16'd0;  // ★ 按音预取：env 段内相对
                                  // ★★ 位宽必须够！cur_up = u×(NT−1) = u×599，
                                  //    u→1 时到 599，需要 **10 位**（0..1023）。
                                  //    原来写 [40:32] 只有 9 位（0..511），
                                  //    u×599 = 512 那一刻索引从 511 回绕到 0
                                  //    → Φ 曲线从头重放、相位突跳
                                  //    → 音符最后 15%（t≈2.24 s 起）整段变成「嘟嘟」噪音。
                                  //    u=0.85476 正好对应 t=109296 样点，与实测崩点一致。
                                  v_px[hv]  <= cur_up[41:32];
                                  v_pfx[hv] <= cur_up[31:16];
                                  //  NT3−1 = 149 → 8 位够；NT2−1 = 299 → 9 位够
                                  v_ep[hv]  <= cur_ep[39:32];
                                  v_ef[hv]  <= cur_ep[31:16];
                                  v_pp[hv]  <= cur_pp[40:32];
                                  v_pf2[hv] <= cur_pp[31:16];
                              end
                        3'd4: v_pb[hv] <= 16'd0;   // ★ 按音预取：psi 段内相对
                        3'd5: phi_a <= rom_ph;
                        3'd6: begin
                                  v_pf[hv] <= (phi_a + ((($signed(rom_ph) - $signed(phi_a))
                                              * $signed({16'd0, v_pfx[hv]}) + 64'sd32768) >>> 16))
                                              & 32'h7FFFF;
                              end
                        default: ;
                        endcase
                        if (pp == NPRE - 1) begin
                            pp <= 3'd0;
                            if (hv == NVOICE - 1) begin st <= ST_HARM; hv <= 2'd0; hm <= 8'd0; end
                            else                       hv <= hv + 2'd1;
                        end
                        else pp <= pp + 3'd1;
                    end
                end
                ST_HARM: begin
                    if (cur_k == 8'd0 || hm + 8'd1 >= cur_k) begin
                        hm <= 8'd0;
                        if (hv == NVOICE - 1) st <= ST_DRAIN;
                        else                  hv <= hv + 2'd1;
                    end
                    else hm <= hm + 8'd1;
                end
                ST_DRAIN: begin
                    dr <= dr + 4'd1;
                    if (dr == 4'd5) begin
                        // ★ 力度只调音量；DMA 覆盖表期间强制静音
                        smp <= quiet ? 16'sd0
                             : sat16((mix * $signed({1'b0, v_vel[7:0]})) >>> 8);
                        st  <= ST_IDLE;
                    end
                end
                default: ;
                endcase
            end

            // ★★ 音符结束后平滑归零。
            //    TMAX 到期（3 s）/ 松键都是硬切断：v_act 一清零引擎立刻停下，
            //    而 smp 停在最后一个样点的电平上（随机直流），
            //    送出去就是「噗」一下。这里用一阶衰减收尾。
            //
            //    ★ 两个坑（都踩过）：
            //    1) 原来没加 cnt==0 门控 → 衰减跑在 50 MHz 上，
            //       16 拍 = 0.32 us 就归零，实际等于「一个样点硬切」，还是有爆音。
            //       必须按样点衰减。
            //    2) 原来是 smp − (smp>>>4)，|smp| < 16 时 >>>4 = 0，
            //       永远停在 ±15 不动 → 输出永久残留直流。
            //       加绝对值下限直接清零。
            //    1/64 每样点 ⇒ 时间常数 64 样点 ≈ 1.3 ms，降到听不见约 6 ms，
            //    既没爆音又满足「松键即停」。
            if (!any_act && smp != 16'sd0 && cnt == 10'd0) begin
                if      (smp >  16'sd32) smp <= smp - (smp >>> 6);
                else if (smp < -16'sd32) smp <= smp - (smp >>> 6);
                else                     smp <= 16'sd0;
            end

            v_idle_r <= ~act_vec;
        end
    end

    assign v_idle = v_idle_r;

    // ════════════════════════════════════════════════════════════════
    //  输出级（软限幅 + 帧对齐复用 mix_sum）
    // ════════════════════════════════════════════════════════════════
    mix_sum #(
        .NVOICE    (1),
        .IN_W      (16),
        .SUM_W     (20),
        .MIX_SHIFT (0),
        .SOFT      (SOFT)
    ) u_mix (
        .clk         (clk),
        .rst_n       (rst_n),
        .vin         (smp),
        .sample_tick (sample_tick),
        .sample_l    (sample_l),
        .sample_r    (sample_r)
    );

    // ════════════════════════════════════════════════════════════════
    //  谐波幅度监控 → HDMI「COMPONENT 64」
    //
    //  pv4 高 = 这一拍 r4_pm 是有效的「第 r4_m 个谐波幅度」。
    //  r4_pm = env × hAS，满量程约 127×4096 = 2^19，所以取 [18:11] 得 0..255。
    //  ★ 定标如果偏小/偏大，只改这一行的切片位置即可：
    //      偏小 → 改成 [20:13]    偏大（削顶）→ 改成 [16:9]
    // ════════════════════════════════════════════════════════════════
    always @(posedge clk) begin
        if (!rst_n) begin
            part_idx <= 7'd0;
            part_amp <= 8'd0;
            part_vld <= 1'b0;
        end
        else begin
            part_vld <= pv4;
            if (pv4) begin
                part_idx <= r4_m[6:0];
                part_amp <= r4_pm[31] ? 8'd0 : r4_pm[18:11];
            end
        end
    end

endmodule

`default_nettype wire
