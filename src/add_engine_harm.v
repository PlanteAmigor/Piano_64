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
    parameter integer NOTE_LO   = 67,
    parameter integer NOTE_HI   = 91,
    parameter integer TIMBRE    = 2,        // 2 = 笛子  3 = 唢呐
    parameter integer MIX_SHIFT = 2,        // 输出再右移几位（4 声部取 2 = /4）
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

    localparam integer AB_AW   = 11;
    localparam integer PSI_AW  = 16;
    localparam integer ENV_AW  = 16;
    localparam integer PHI_AW  = 15;
    localparam integer INFO_AW = 7;

    localparam integer NT  = 600;           // Φ 表点数
    localparam integer NT2 = 300;           // Ψ 表点数
    localparam integer NT3 = 150;           // Env 表点数
    localparam integer PSI_E = 151;
    localparam integer ENV_E = 76;
    localparam integer NPRE  = 6;
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

    generate
        if (TIMBRE == 2) begin : g_dizi
            harm_rom_dizi u_rom (
                .clk(clk),
                .abc_a(a_abc), .pi_a(a_pi),
                .ab_d(rom_ab), .bc_d(rom_bc), .pi_d(rom_pi),
                .pe_a(a_pe), .po_a(a_po), .pe_d(rom_pe), .po_d(rom_po),
                .ee_a(a_ee), .eo_a(a_eo), .ee_d(rom_ee), .eo_d(rom_eo),
                .ph_a(a_ph), .ph_d(rom_ph),
                .u_a(a_u), .u_d(rom_u),
                .sn_a(a_sn), .sn_d(rom_sn),
                .inf_a(a_inf), .inf_d(rom_inf)
            );
        end
        else begin : g_suona
            harm_rom_suona u_rom (
                .clk(clk),
                .abc_a(a_abc), .pi_a(a_pi),
                .ab_d(rom_ab), .bc_d(rom_bc), .pi_d(rom_pi),
                .pe_a(a_pe), .po_a(a_po), .pe_d(rom_pe), .po_d(rom_po),
                .ee_a(a_ee), .eo_a(a_eo), .ee_d(rom_ee), .eo_d(rom_eo),
                .ph_a(a_ph), .ph_d(rom_ph),
                .u_a(a_u), .u_d(rom_u),
                .sn_a(a_sn), .sn_d(rom_sn),
                .inf_a(a_inf), .inf_d(rom_inf)
            );
        end
    endgenerate

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
    wire [63:0] cur_up = {32'd0, cur_ua} * (NT - 1);
    wire [9:0]  cur_px = cur_up[40:32];
    wire [31:0] cur_pf = cur_up[31:0];

    // 地址侧的位置（当前拍要发的声部 = hv）
    wire [63:0] a_ep   = {32'd0, cur_ua} * (NT3 - 1);
    wire [7:0]  a_epos = a_ep[39:32];
    wire [63:0] a_pp   = {32'd0, cur_ua} * (NT2 - 1);
    wire [8:0]  a_ppos = a_pp[40:32];

    // 数据侧的位置（上一拍发出去的那一项 = dq_vo）
    // ★ psi_off 直接用【本拍的 rom_pi】：a_pi 在上一拍发的是 ab+hm+1，
    //   而本拍 hm 已经 +1 了，所以 rom_pi 正好对应当前谐波的 psi_off。
    //   原来用寄存的 dq_pi 会晚一拍，读到上一谐波的行号（实测 4 声部完全对不上）。
    reg  [1:0]  dq_vo;
    reg  [7:0]  dq_m;

    wire [31:0] hua   = v_ua[dq_vo];
    wire [63:0] h_ep  = {32'd0, hua} * (NT3 - 1);
    wire [7:0]  e_pos = h_ep[39:32];
    wire [31:0] e_fr  = h_ep[31:0];
    wire [63:0] h_pp  = {32'd0, hua} * (NT2 - 1);
    wire [8:0]  p_pos = h_pp[40:32];
    wire [31:0] p_fr  = h_pp[31:0];

    wire [15:0] a_env_off = {8'd0, hm} * ENV_E;

    // ★ psi_off 要提前一拍取（Ψ 的地址靠它）。提前量必须按【下一拍真正要发的
    //   (声部, 谐波)】算 —— 直接写 ab[hv]+hm+1 在“跳不活动声部”时会算错，
    //   切声部的第一拍会拿到上一声部的行号（实测多声部全错）。
    reg  [1:0]  nx_vo;
    reg  [7:0]  nx_hm;
    reg         nx_found;
    integer jj;
    always @(*) begin
        nx_vo = hv; nx_hm = 8'd0;
        if (st == ST_HARM) begin
            if (cur_k != 8'd0 && hm + 8'd1 < cur_k) begin
                nx_vo = hv; nx_hm = hm + 8'd1;
            end
            else begin
                nx_found = 1'b0;
                for (jj = 1; jj <= NVOICE; jj = jj + 1) begin
                    if (!nx_found && v_act[(hv + jj[1:0]) & 2'h3]
                                  && v_k[(hv + jj[1:0]) & 2'h3] != 8'd0) begin
                        nx_vo = (hv + jj[1:0]) & 2'h3;
                        nx_hm = 8'd0;
                        nx_found = 1'b1;
                    end
                end
            end
        end
        else begin
            nx_found = 1'b0;
            for (jj = 0; jj < NVOICE; jj = jj + 1) begin
                if (!nx_found && v_act[jj[1:0]] && v_k[jj[1:0]] != 8'd0) begin
                    nx_vo = jj[1:0]; nx_hm = 8'd0; nx_found = 1'b1;
                end
            end
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

    reg signed [31:0] r2_env;
    reg signed [31:0] r2_hAS;
    reg [7:0]  r2_frac;

    reg signed [31:0] r3_pm;
    reg signed [15:0] r3_sn0, r3_sn1;
    reg [7:0]  r3_frac;

    reg signed [31:0] r4_pm;
    reg signed [31:0] r4_snf;

    reg pv0, pv1, pv2, pv3, pv4;

    // ── S1（ROM 数据 → 插值 / hAS）────────────────────────────────
    wire signed [7:0]  e_first  = e_pos[0] ? $signed(rom_eo) : $signed(rom_ee);
    wire signed [7:0]  e_second = e_pos[0] ? $signed(rom_ee) : $signed(rom_eo);
    wire signed [31:0] s1_env   = e_first + (($signed(e_second - e_first)
                                   * $signed({16'd0, e_fr[31:16]}) + 64'sd32768) >>> 16);

    wire signed [15:0] p_first  = p_pos[0] ? $signed(rom_po) : $signed(rom_pe);
    wire signed [15:0] p_second = p_pos[0] ? $signed(rom_pe) : $signed(rom_po);
    wire signed [31:0] s1_psi   = p_first + (($signed(p_second - p_first)
                                   * $signed({16'd0, p_fr[31:16]}) + 64'sd32768) >>> 16);

    wire signed [15:0] s1_A   = rom_ab[15:0];
    wire signed [15:0] s1_PA  = rom_ab[31:16];
    wire signed [15:0] s1_DM  = rom_bc[15:0];
    wire signed [15:0] s1_SC  = rom_bc[31:16];
    wire signed [31:0] s1_hAS = (s1_A * s1_SC + 32'sd16384) >>> 15;

    // ── S2（相位合成）────────────────────────────────────────────
    wire signed [31:0] s2_mphi = $signed({9'd0, r1_pf}) * $signed({24'd0, r1_m});
    wire signed [31:0] s2_dm11 = $signed({{16{r1_dm[15]}}, r1_dm}) * 32'sd11;
    wire signed [63:0] s2_dmt  = ($signed({{32{s2_dm11[31]}}, s2_dm11})
                                 * $signed({32'd0, v_ts[r1_vo]}) + 64'sd512) >>> 10;
    wire signed [27:0] s2_theta = s2_mphi[27:0] + s2_dmt[27:0]
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
        a_inf = {nidx_r[hv], 2'b00};
        case (st)
        ST_PRE: begin
            a_inf = {nidx_r[hv], 2'b00} + {5'd0, pp[1:0]};
            case (pp)
            3'd1: a_u = v_ts[hv][19:4] + 14'd1;
            3'd3: a_ph = v_fb[hv] + cur_px;
            3'd4: a_ph = v_fb[hv] + cur_px + 15'd1;
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
            r1_env <= 0; r1_psi <= 0; r1_hAS <= 0;
            r2_env <= 0; r2_hAS <= 0; r2_frac <= 0;
            r3_pm <= 0; r3_sn0 <= 0; r3_sn1 <= 0; r3_frac <= 0;
            r4_pm <= 0; r4_snf <= 0;
            pv0 <= 0; pv1 <= 0; pv2 <= 0; pv3 <= 0; pv4 <= 0;
            for (i = 0; i < NVOICE; i = i + 1) begin
                v_ts[i] <= 20'd0; v_ua[i] <= 32'd0; v_pf[i] <= 19'd0;
                v_k[i]  <= 8'd0;  v_ab[i] <= 0;     v_eb[i] <= 16'd0;
                v_pb[i] <= 16'd0; v_fb[i] <= 0;     v_act[i] <= 1'b0;
                nidx_r[i] <= 5'd0;
            end
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
            r2_env  <= r1_env;
            r2_hAS  <= r1_hAS;
            r2_frac <= s2_theta[8:1];
            r1_vo   <= dq_vo;
            r1_m    <= dq_m;
            r1_dm   <= s1_DM;
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
                        if (v_ts[i] + 20'd1 >= TMAX) v_act[i] <= 1'b0;
                        v_ts[i] <= v_ts[i] + 20'd1;
                    end
                end
            end

            // ── 触发（随时响应，放在后面 —— 同块内后写优先）────────
            for (i = 0; i < NVOICE; i = i + 1) begin
                if (v_trig[i]) begin
                    v_act[i]  <= 1'b1;
                    v_ts[i]   <= 20'd0;
                    v_ua[i]   <= 32'd0;
                    nidx_r[i] <= (v_note[i*7 +: 7] < NOTE_LO) ? 5'd0 :
                                 (v_note[i*7 +: 7] > NOTE_HI) ? (NOTE_HI - NOTE_LO) :
                                 (v_note[i*7 +: 7] - NOTE_LO);
                end
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
                                  v_fb[hv] <= rom_inf[14:0];      // info[4n+0] = phi_base
                              end
                        3'd2: begin
                                  v_ua[hv] <= pre_u0 + (((rom_u - pre_u0) * v_ts[hv][3:0]) >> 4);
                                  v_k[hv]  <= rom_inf[31:24];     // info[4n+1]
                                  v_ab[hv] <= rom_inf[15:0];
                              end
                        3'd3: v_eb[hv] <= rom_inf[15:0];          // info[4n+2] = env_base
                        3'd4: begin v_pb[hv] <= rom_inf[15:0]; phi_a <= rom_ph; end
                        3'd5: begin
                                  v_pf[hv] <= (phi_a + ((($signed(rom_ph) - $signed(phi_a))
                                              * $signed({16'd0, cur_pf[31:16]}) + 64'sd32768) >>> 16))
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
                        smp <= sat16(mix);
                        st  <= ST_IDLE;
                    end
                end
                default: ;
                endcase
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

endmodule

`default_nettype wire
