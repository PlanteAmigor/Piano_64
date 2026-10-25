//==========================================================================
//  add_voice_harm —— 谐波表驱动的加法声部（笛子 / 唢呐）
//
//      s(t) = Σ_{m=1..K} env_m(t) · A_m · sin(2π·Θ_m(t) + phi_m)
//      Θ_m(t) = m·Φ(u(t)) + δ_m·t + Ψ_m(u(t)) + phi_m
//      env_m(t) = EnvTab_m(u(t)) · env_scale_m / 127     ← 起振项已预乘
//      u(t) = (1−α)·t/D + α·ln(1+t/T0)/ln(1+D/T0)        α=0.6 T0=0.06 D=3s
//
//  ── ★★ 关键：地址必须是【组合】的 ────────────────────────────────
//     BSRAM 是同步读：地址在 T 拍有效 → 数据在 T+1 拍出来。
//     第一版把 rom_addr 写成 output reg，在 s=0 的时钟沿才更新，
//     等于地址比数据晚一拍，整条流水线错位，输出全是 x。
//     （原 add_voice8.v 的 rom_addr 就是组合信号，这一点不能省。）
//
//  ── 定点格式（与 tools/npz2hex_harm.py 严格对应）──────────────────
//      Φ      Q13.19  32 bit 无符号
//      Ψ      Q3.12   16 bit 有符号
//      A      Q3.13   16 bit 有符号
//      phi_a  Q0.16   16 bit 有符号（圈，±0.5）
//      δ      0.001Hz 16 bit 有符号
//      env_scale Q1.15 16 bit 无符号
//      env    int8，真实值 = int8/127 × scale
//
//  ── 时间表 ──────────────────────────────────────────────────────
//  ST_PRE（8 拍，pre = 0..7）——u 表 2 读 + Φ 表 4 读（Φ 是 32 位，分两个 16 位块）
//      pre : 组合地址              | 本拍 rd = 上一拍地址的数据
//      ------------------------------------------------------------
//      0   : u[u_i]                | —
//      1   : u[u_i+1]              | u[u_i]      → u0
//      2   : —                     | u[u_i+1]    → 算 u_acc（必须用本拍 rd）
//      3   : Φ_lo[i0]              | —
//      4   : Φ_hi[i0]              | Φ_lo[i0]    → phi_lo
//      5   : Φ_lo[i0+1]            | Φ_hi[i0]    → phi_hi
//      6   : Φ_hi[i0+1]            | Φ_lo[i0+1]  → phi_lo1
//      7   : —                     | Φ_hi[i0+1]  → 算 Phi = {hi,lo} + 插值
//
//  ST_HARM（每谐波 16 拍，s = 0..15）——9 拍表读 + 1 拍插值 + 6 拍乘法流水
//      s : 组合地址           | 本拍可用的 rd（上一拍地址的数据）
//      ------------------------------------------------------------
//      0 : Env 基址           | —                （env_a0 是组合地址）
//      1 : Env 基址+1         | Env[j0]          → env0(raw)
//      2 : A[m]               | Env[j1]          → env1(raw)
//      3 : phi_a[m]           | A[m]             → hA
//      4 : dm[m]              | phi_a[m]         → hPA（顺手 <<3）
//      5 : env_scale[m]       | dm[m]            → hDM
//      6 : psi_idx[m]         | env_scale[m]     → hSC
//      7 : Ψ 基址(用本拍 rd)   | psi_idx[m]       → hPI, psi_a0
//      8 : Ψ 基址+1           | Ψ[m][i0]         → psi0(raw)
//      9 : —                  | Ψ[m][i1]         → psi1(raw)；同时 Env 插值
//      10: —                  |                  Ψ 插值并 <<7 对齐 19 位小数
//      11: —                  |                  hAS = A × scale      乘法1
//      12: sin[sa]            |                  sn0                    —
//      13: sin[sa+1]          |                  sn1；pm = env0×hAS    乘法2
//      14: —                  |                  snf = 正弦插值         乘法3
//      15: —                  |                  acc += pm×snf         乘法4
//
//  ★ 每拍最多一个乘法。写成 acc += env0*hAS*sn0 是两级大乘法串在一拍，
//    50 MHz 下必然违例，所以 pm 提前到 s=13、正弦插值放 s=14、累加放 s=15。
//
//  → 一样点 = 2 (HEAD) + 8 (PRE) + 16K + 1 (OUT) = 11 + 16K 拍，K ≤ 63 才能 < 1024
//
//  ── 幅度缩放 ─────────────────────────────────────────────────────
//      hAS   = A × env_scale / 2^15              （Q3.13）
//      acc  += env_int8 × hAS × sin_int16        （64 位，不做中间截断！）
//      ⇒ acc = Σ env·A·sin × 127·2^13·32767；输出取 acc >>> 20
//        （精确值应除 127·2^13 = 1040384，与 2^20 差 0.79%，-0.07 dB 可忽略）
//
//  ── ★★ 插值三条铁律（每一条都踩过，别改）─────────────────────────
//      1) 先乘后移：((b−a)>>n)*fr 会在 |b−a| < 2^n 时恒为 0
//      2) 必须 $signed()：part-select 是无符号的，混进表达式会把整个式子
//         提升成无符号，>> 变逻辑右移，负差值变成 0x00FFFFFF
//         （症状：env0 = 16777215，acc 直接奔到 1e11，比期望大 1000 倍）
//      3) 右移用 >>>（算术），不要用 >>
//      4) 四舍五入（+半个 LSB），floor 会带 −0.5 LSB 偏置，实测差 6 dB
//
//  ── 其他踩过的坑 ──────────────────────────────────
//      • Φ 表是 32 位 Q13.19，按【两个 16 位块】存（前 NT 字低半字、后 NT 字高半字）。
//        只读低半字会把 0.15 圈/表点的增量截断，相位差 10°+（Phi 16613 vs 18759）
//      • psi_idx = 0xFFFF 表示该谐波无 Ψ，必须输出 0，不能去读 Ψ 第 0 行
//      • u_acc 在 pre=2 算完，Φ 地址最早只能从 pre=3 开始用
//      • 正弦表插值要 sin_addr = sa+1（s=13 那一拍），否则 sn1==sn0 等于不插值
//==========================================================================
`default_nettype none

module add_voice_harm #(
    parameter integer ROM_AW = 19,
    parameter integer NT     = 600,
    parameter integer NT2    = 300,
    parameter integer NT3    = 150,
    parameter integer NOTE_LO = 67,
    parameter integer NOTE_HI = 91,
    parameter integer U_AW   = 14
)(
    input  wire                clk,
    input  wire                rst_n,

    input  wire [6:0]          note,
    input  wire                trig,
    input  wire                gate,

    input  wire [31:0]         rd,
    output wire [ROM_AW-1:0]   rom_addr,      // ★ 组合输出

    input  wire [31:0]         u_rd,
    output wire [U_AW-1:0]     u_addr,        // ★ 组合输出

    input  wire [15:0]         sin_rd,
    output wire [9:0]          sin_addr,      // ★ 组合输出

    input  wire [ROM_AW-1:0]   base_rd,

    output reg  signed [15:0]  sample,
    output reg                 sample_valid,
    output reg                 idle
);

    localparam [6:0] NLO = NOTE_LO[6:0];
    localparam [6:0] NHI = NOTE_HI[6:0];

    function signed [31:0] sx16; input [15:0] v;
        begin sx16 = {{16{v[15]}}, v}; end
    endfunction
    function signed [31:0] sx8; input [7:0] v;
        begin sx8 = {{24{v[7]}}, v}; end
    endfunction

    // ════════════════════════════════════════════════════════════════
    //  状态
    // ════════════════════════════════════════════════════════════════
    reg [9:0]  cnt;
    reg [19:0] t_smp;
    reg [31:0] u_acc;
    reg [31:0] Phi;

    wire [15:0] u_i  = t_smp[19:4];
    wire [3:0]  u_fr = t_smp[3:0];

    reg [ROM_AW-1:0] base;
    reg [7:0]  K, npsi;

    localparam [2:0] ST_IDLE = 3'd0,
                     ST_HEAD = 3'd1,
                     ST_PRE  = 3'd2,
                     ST_HARM = 3'd3,
                     ST_OUT  = 3'd4;

    reg [2:0] st;
    reg [7:0] m;
    reg [3:0] s;
    reg [2:0] pre;
    reg       ready, pending;

    reg [31:0] u0, u1;
    reg [ROM_AW-1:0] psi_a0;              // Ψ 表读基址锁存（需要在 s=7 用）
    reg [15:0] phi_lo, phi_hi, phi_lo1;   // Φ 是 32 位、分低/高两个 16 位块存

    reg signed [31:0] hA, hPA, hDM, hSC, hPI;
    reg signed [31:0] psi0, psi1, env0, env1, sn0, sn1;
    reg signed [31:0] hAS;
    reg signed [37:0] dmt;    // δ·t 的相位贡献（19 位小数）
    reg signed [37:0] mphi;   // m·Φ（19 位小数）
    // ★ 三级流水拆开乘法，每拍最多一个乘法（否则两级大乘法串在一拍里，
    //   50 MHz 下必然违例）：s=11 hAS=A×scale → s=13 pm=env0×hAS
    //   → s=14 snf=正弦插值 → s=15 acc += pm×snf
    reg signed [31:0] pm;
    reg signed [31:0] snf;
    reg signed [63:0] acc;

    // ── 分区偏移 ───────────────────────────────────────────────────
    wire [ROM_AW-1:0] off_A   = base + 2;
    wire [ROM_AW-1:0] off_PA  = base + 2 + K;
    wire [ROM_AW-1:0] off_DM  = base + 2 + 2 * K;
    wire [ROM_AW-1:0] off_SC  = base + 2 + 3 * K;
    wire [ROM_AW-1:0] off_PI  = base + 2 + 4 * K;
    wire [ROM_AW-1:0] off_PHI = base + 2 + 5 * K;
    wire [ROM_AW-1:0] off_PSI = off_PHI + 2 * NT;
    wire [ROM_AW-1:0] off_ENV = off_PSI + npsi * NT2;

    // ── 插值坐标 ───────────────────────────────────────────────────
    wire [63:0] uprod    = {32'd0, u_acc} * (NT  - 1);
    wire [9:0]  pidx     = uprod[40:32];
    wire [31:0] pfrac    = uprod[31:0];

    wire [63:0] psiprod  = {32'd0, u_acc} * (NT2 - 1);
    wire [8:0]  psi_pos  = psiprod[40:32];
    wire [31:0] psi_fr   = psiprod[31:0];

    wire [63:0] envprod  = {32'd0, u_acc} * (NT3 - 1);
    wire [7:0]  env_pos  = envprod[39:32];
    wire [31:0] env_fr   = envprod[31:0];

    // Env 区的字地址只依赖 m 和 env_pos，可以直接组合出来，
    // 所以 ST_HARM 的第 0/1 拍就能去读 Env，省出两拍给后面的乘法流水
    wire [ROM_AW-1:0] env_a0 = off_ENV + m * NT3 + env_pos;

    // ── Φ 插值（★ Φ 是 32 位无符号 Q13.19，表里按【两个 16 位块】存：
    //    前 NT 字是低半字，后 NT 字是高半字。只读低字会把 0.15 圈/表点的增量
    //    截断成 low16 的差，相位直接错 10°以上（实测 Phi 16613 vs 18759）
    //    ——所以 ST_PRE 要读 4 次：lo[i0] hi[i0] lo[i0+1] hi[i0+1]
    wire [31:0]        phi_b   = {phi_hi,  phi_lo};
    wire [31:0]        phi_n   = {rd[15:0], phi_lo1};
    wire [31:0]        phi_d   = phi_n - phi_b;     // Φ 单调递增，差值恒正
    wire signed [63:0] phi_mul = $signed({32'd0, phi_d}) * $signed({48'd0, pfrac[31:16]});
    wire signed [63:0] phi_inc = (phi_mul + 64'sd32768) >>> 16;

    // ── 相位合成 Θ（19 位小数）────────────────────────────────────
    //  ★ dmt = δ·t，δ 单位 0.001 Hz。turns = hDM·0.001·t_smp/FS
    //    11264/2^20 = 11/1024 ⇒ dmt = hDM·11·t_smp / 1024
    //    —— 原来写成 (hDM*t_smp)*11264，是两个 64 位大乘法串在一拍，
    //       实测关键路径 38 ns。这里拆成“先乘 11（移位加法）”再用寄存器寄存。
    wire signed [31:0] hdm11 = hDM * 32'sd11;
    wire signed [51:0] dmt_m = ($signed({{20{hdm11[31]}}, hdm11}) * $signed({32'd0, t_smp})
                                + 52'sd512) >>> 10;
    // mphi 在 s=0 就算好（Phi 整个样点不变、m 本拍已更新），不用每拍算
    wire signed [37:0] mphi_w  = $signed({1'b0, Phi[18:0]}) * $signed({30'd0, m});
    wire signed [37:0] theta    = mphi + dmt + psi0 + hPA;

    // ════════════════════════════════════════════════════════════════
    //  组合地址逻辑（★ 这是正确性关键）
    // ════════════════════════════════════════════════════════════════
    reg [ROM_AW-1:0] rom_a;
    always @(*) begin
        rom_a = off_A;
        case (st)
        ST_HEAD: rom_a = base_rd;
        ST_PRE: begin
            case (pre)
            3'd3: rom_a = off_PHI + pidx;
            3'd4: rom_a = off_PHI + NT + pidx;
            3'd5: rom_a = off_PHI + pidx + 10'd1;
            3'd6: rom_a = off_PHI + NT + pidx + 10'd1;
            default: rom_a = off_PHI;
            endcase
        end
        ST_HARM: begin
            case (s)
            4'd0: rom_a = env_a0;
            4'd1: rom_a = env_a0 + 10'd1;
            4'd2: rom_a = off_A  + m;
            4'd3: rom_a = off_PA + m;
            4'd4: rom_a = off_DM + m;
            4'd5: rom_a = off_SC + m;
            4'd6: rom_a = off_PI + m;
            // s=7：用【本拍的 rd】（就是 psi_idx）算 Ψ 基址
            4'd7: rom_a = (rd[15:0] == 16'hFFFF) ? off_PSI
                        : off_PSI + rd[15:0] * NT2 + psi_pos;
            4'd8: rom_a = psi_a0 + 10'd1;
            default: rom_a = off_A + m;
            endcase
        end
        default: rom_a = off_A;
        endcase
    end
    assign rom_addr = rom_a;

    // ★ u 表要读相邻两点：pre=0 读 u_i，pre>=1 读 u_i+1
    //   第一版一直是 u_i，导致 u0==u1、插值恒 0，u_acc 卡死在第一个表点
    assign u_addr   = u_i[U_AW-1:0] + ((pre == 3'd0) ? {U_AW{1'b0}} : {{(U_AW-1){1'b0}}, 1'b1});
    assign sin_addr = theta[18:9] + ((s == 4'd12) ? 10'd1 : 10'd0);

    // ════════════════════════════════════════════════════════════════
    //  主时序
    // ════════════════════════════════════════════════════════════════
    always @(posedge clk) begin
        if (!rst_n) begin
            cnt <= 10'd0; t_smp <= 20'd0; u_acc <= 32'd0; Phi <= 32'd0;
            st <= ST_IDLE; m <= 8'd0; s <= 4'd0; pre <= 3'd0;
            base <= {ROM_AW{1'b0}}; K <= 8'd0; npsi <= 8'd0;
            u0 <= 32'd0; u1 <= 32'd0;
            psi_a0 <= {ROM_AW{1'b0}};
            hA <= 0; hPA <= 0; hDM <= 0; hSC <= 0; hPI <= 0;
            psi0 <= 0; psi1 <= 0; env0 <= 0; env1 <= 0; sn0 <= 0; sn1 <= 0;
            phi_lo <= 16'd0; phi_hi <= 16'd0; phi_lo1 <= 16'd0;
            hAS <= 0; pm <= 0; snf <= 0; acc <= 64'sd0; sample <= 16'sd0;
            dmt <= 0; mphi <= 0;
            ready <= 1'b0; pending <= 1'b0; idle <= 1'b1; sample_valid <= 1'b0;
        end
        else begin
            cnt <= (cnt == 10'd1023) ? 10'd0 : cnt + 10'd1;
            sample_valid <= 1'b0;

            if (trig) pending <= 1'b1;

            if (pending && (cnt == 10'd0)) begin
                pending <= 1'b0;
                ready   <= 1'b0;
                base    <= base_rd;
                st      <= ST_HEAD;
                pre     <= 3'd0;
                t_smp   <= 20'd0;
                u_acc   <= 32'd0;
                acc     <= 64'sd0;
            end

            case (st)
            // ══ 表头（★ 必须两拍：同步 ROM 发地址后下一拍数据才有效）══
            ST_HEAD: begin
                if (pre == 3'd0) begin
                    pre <= 3'd1;            // 第一拍：rom_addr 已组合为 base_rd
                end
                else begin
                    K    <= rd[7:0];        // 第二拍：rd = ptab[base+0]
                    npsi <= rd[15:8];
                    st   <= ST_PRE;
                    pre  <= 3'd0;
                end
            end
            // ══ 前置：u 表 2 读 → 插值 → Φ 表 4 读（低/高 × i0/i1）→ 插值 ══
            //  pre: 0 读 u[i0] | 1 锁 u0、读 u[i0+1] | 2 算 u_acc
            //       3 读 lo[i0] | 4 锁 lo、读 hi[i0] | 5 锁 hi、读 lo[i0+1]
            //       6 锁 lo1、读 hi[i0+1] | 7 算 Phi
            ST_PRE: begin
                case (pre)
                3'd1: u0 <= u_rd;               // u[i0]（pre=0 时地址已为 u_i）
                3'd2: begin
                          // ★ 直接用本拍的 u_rd（=u[i0+1]）算插值：
                          //   写成 u1 <= u_rd; u_acc <= ...u1... 时 u1 还是旧值
                          u1    <= u_rd;
                          u_acc <= u0 + (((u_rd - u0) * u_fr) >> 4);
                      end
                3'd4: phi_lo  <= rd[15:0];      // Φ 低半字[i0]
                3'd5: phi_hi  <= rd[15:0];      // Φ 高半字[i0]
                3'd6: phi_lo1 <= rd[15:0];      // Φ 低半字[i0+1]（高半字在本拍 rd）
                3'd7: begin
                          Phi <= phi_b + phi_inc[31:0];
                          st  <= ST_HARM;
                          m   <= 8'd0;
                          s   <= 4'd0;
                      end
                default: ;
                endcase
                pre <= pre + 3'd1;
            end
            // ══ 谐波循环（16 拍：9 拍表读 + 1 拍算插值 + 6 拍乘法流水）══
            //  s : 组合地址                | 本拍 rd
            //  0 : Env 基址                | —
            //  1 : Env 基址+1              | Env[j0]
            //  2 : A[m]                    | Env[j1]
            //  3 : phi_a[m]                | A
            //  4 : dm[m]                   | phi_a
            //  5 : env_scale[m]            | dm
            //  6 : psi_idx[m]              | env_scale
            //  7 : Ψ 基址（用本拍 rd）      | psi_idx
            //  8 : Ψ 基址+1                | Ψ[i0]
            //  9 : —                       | Ψ[i0+1]       ← 同时做 Env 插值
            //  10: —                       |              ← Ψ 插值 + 相位对齐
            //  11: —                       |              ← hAS = A×scale
            //  12: sin[sa]                 |              ← sn0
            //  13: sin[sa+1]               |              ← sn1 + pm = env0×hAS
            //  14: —                       |              ← snf = 正弦插值
            //  15: —                       |              ← acc += pm×snf
            ST_HARM: begin
                s <= s + 4'd1;
                case (s)
                4'd0: mphi <= mphi_w;                        // 乘法：m×Φ（本谐波只算一次）
                4'd1: env0 <= sx8(rd[7:0]);                  // Env j0
                4'd2: env1 <= sx8(rd[7:0]);                  // Env j1
                4'd3: hA  <= sx16(rd[15:0]);                 // A
                4'd4: hPA <= sx16(rd[15:0]) <<< 3;           // phi_a：Q0.16 → 19 位小数
                4'd5: hDM <= sx16(rd[15:0]);                 // dm
                4'd6: hSC <= {16'd0, rd[15:0]};              // env_scale
                4'd7: begin                                   // psi_idx
                          hPI    <= {16'd0, rd[15:0]};
                          psi_a0 <= (rd[15:0] == 16'hFFFF)
                                  ? off_PSI
                                  : off_PSI + rd[15:0] * NT2 + psi_pos;
                          dmt    <= dmt_m;                      // δ·t（hDM 在 s=5 锁好）
                      end
                4'd8: psi0 <= (hPI == 32'hFFFF) ? 32'sd0 : sx16(rd[15:0]);   // Ψ i0
                4'd9: begin
                          psi1 <= (hPI == 32'hFFFF) ? 32'sd0 : sx16(rd[15:0]); // Ψ i1
                          // Env 插值（env0/env1 在 s=1/s=2 就锁好了）
                          // ★★ 三个坑：先乘后移 / 必须 $signed（part-select 无符号会把
                          //    整个表达式变无符号，>> 成逻辑右移，负差值变 0x00FFFFFF）/
                          //    四舍五入（floor 有 −0.5 LSB 偏置，实测差 6 dB）
                          env0 <= env0 + (($signed(env1 - env0) * $signed({16'd0, env_fr[31:16]}) + 64'sd32768) >>> 16);
                      end
                4'd10: psi0 <= (psi0 + (($signed(psi1 - psi0) * $signed({16'd0, psi_fr[31:16]}) + 64'sd32768) >>> 16)) <<< 7;
                4'd11: hAS  <= (hA * hSC + 32'sd16384) >>> 15;   // 乘法 1：A × scale
                4'd12: sn0  <= sx16(sin_rd);                     // sin(sa)
                4'd13: begin
                          sn1 <= sx16(sin_rd);                   // sin(sa+1)
                          pm  <= env0 * hAS;                     // 乘法 2：env0 × hAS
                      end
                4'd14: snf <= sn0 + (($signed(sn1 - sn0) * $signed({24'd0, theta[8:1]}) + 64'sd128) >>> 8);  // 乘法 3
                4'd15: begin
                          acc <= acc + ($signed({{32{pm[31]}}, pm}) * $signed({{32{snf[31]}}, snf}));  // 乘法 4
                          m   <= m + 8'd1;
                          s   <= 4'd0;
                          if (m + 8'd1 >= K) st <= ST_OUT;
                      end
                default: ;
                endcase
            end
            // ══ 输出 ═══════════════════════════════════════════════
            //  ★ 定标推导（p = env0·hAS 不做中间截断）：
            //     hA 的 q 是 Q4.11（SC_A=4096，因为 suona 最大 A=6.83，Q3.13 会削顶）
            //     hAS = hA×hSC/2^15 = A·scale·4096
            //     acc = Σ env0·hAS·sn0
            //         = Σ (127·env_true/scale)·(A·scale·4096)·(32767·sin)
            //         = 127·4096·32767 · Σ env_true·A·sin
            //     ⇒ sample = 32767·signal = acc/(127·4096) = acc / 520192
            //     2^19 = 524288，差 0.79%（-0.07 dB），直接>>>19
            ST_OUT: begin
                sample <= sat16(acc >>> 19);
                sample_valid <= 1'b1;
                acc    <= 64'sd0;
                t_smp  <= t_smp + 20'd1;
                ready  <= 1'b1;
                pre    <= 3'd0;
                st     <= ST_PRE;
                if (t_smp >= 20'd146400) begin
                    ready <= 1'b0;
                    st    <= ST_IDLE;
                end
            end
            default: ;
            endcase

            idle <= ~ready;
        end
    end

    function signed [15:0] sat16; input signed [63:0] x;
        begin
            if      (x >  64'sd32767) sat16 =  16'sd32767;
            else if (x < -64'sd32768) sat16 = -16'sd32768;
            else                      sat16 = x[15:0];
        end
    endfunction

endmodule

`default_nettype wire
