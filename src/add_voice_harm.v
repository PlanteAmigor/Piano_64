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
//  ── 时间表（每谐波 16 拍，s = 0..15）────────────────────────────
//      s : 组合地址           | 本拍可用的 rd（上一拍地址的数据）
//      ------------------------------------------------------------
//      0 : A[m]               | —
//      1 : phi_a[m]           | A[m]
//      2 : dm[m]              | phi_a[m]
//      3 : env_scale[m]       | dm[m]
//      4 : psi_idx[m]         | env_scale[m]
//      5 : Ψ_base(rd)         | psi_idx[m]
//      6 : Ψ_base+1           | Ψ[m][i0]
//      7 : Env_base           | Ψ[m][i1]
//      8 : Env_base+1         | Env[m][j0]
//      9 : (空闲)             | Env[m][j1]
//      10: 插值 Ψ、Env
//      11: 算 A×scale，相位对齐
//      12: sin[Θ高10位]        |
//      13: sin[+1]            | sin(i)
//      14: —                  | sin(i+1)
//      15: 插值 + 累加
//
//  ── 幅度缩放 ─────────────────────────────────────────────────────
//      hAS   = A × env_scale / 2^15          （Q4.13）
//      p     = (env_int8 × hAS) / 2^15
//      acc  += p × sin_int16
//      ⇒ acc = y_true × 127 × 2^13 = y_true × 1,040,384
//      ⇒ sample = acc >>> 20    ★ 第一版误写成 28，输出恒 0
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
    reg [ROM_AW-1:0] psi_a0, env_a0;      // 表读基址锁存

    reg signed [31:0] hA, hPA, hDM, hSC, hPI;
    reg signed [31:0] psi0, psi1, env0, env1, sn0, sn1;
    reg signed [31:0] hAS;
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

    // ── 相位合成 Θ（19 位小数）────────────────────────────────────
    wire signed [63:0] dmt_full = (hDM * $signed({44'd0, t_smp})) * 64'sd11264;
    wire signed [63:0] dmt      = (dmt_full + 64'sd524288) >>> 20;
    wire signed [37:0] mphi     = $signed({1'b0, Phi[18:0]}) * $signed({30'd0, m});
    wire signed [37:0] theta    = mphi + dmt[37:0] + psi0 + hPA;

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
            3'd2: rom_a = off_PHI + pidx;
            3'd3: rom_a = off_PHI + pidx + 10'd1;
            default: rom_a = off_PHI;
            endcase
        end
        ST_HARM: begin
            case (s)
            4'd0: rom_a = off_A  + m;
            4'd1: rom_a = off_PA + m;
            4'd2: rom_a = off_DM + m;
            4'd3: rom_a = off_SC + m;
            4'd4: rom_a = off_PI + m;
            // s=5：用【本拍的 rd】（就是 psi_idx）算 Ψ 基址
            4'd5: rom_a = (rd[15:0] == 16'hFFFF) ? off_PSI
                        : off_PSI + rd[15:0] * NT2 + psi_pos;
            4'd6: rom_a = psi_a0 + 10'd1;
            4'd7: rom_a = env_a0;
            4'd8: rom_a = env_a0 + 10'd1;
            default: rom_a = off_A + m;
            endcase
        end
        default: rom_a = off_A;
        endcase
    end
    assign rom_addr = rom_a;

    assign u_addr   = u_i[U_AW-1:0];
    assign sin_addr = theta[18:9];

    // ════════════════════════════════════════════════════════════════
    //  主时序
    // ════════════════════════════════════════════════════════════════
    always @(posedge clk) begin
        if (!rst_n) begin
            cnt <= 10'd0; t_smp <= 20'd0; u_acc <= 32'd0; Phi <= 32'd0;
            st <= ST_IDLE; m <= 8'd0; s <= 4'd0; pre <= 3'd0;
            base <= {ROM_AW{1'b0}}; K <= 8'd0; npsi <= 8'd0;
            u0 <= 32'd0; u1 <= 32'd0;
            psi_a0 <= {ROM_AW{1'b0}}; env_a0 <= {ROM_AW{1'b0}};
            hA <= 0; hPA <= 0; hDM <= 0; hSC <= 0; hPI <= 0;
            psi0 <= 0; psi1 <= 0; env0 <= 0; env1 <= 0; sn0 <= 0; sn1 <= 0;
            hAS <= 0; acc <= 64'sd0; sample <= 16'sd0;
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
            // ══ 前置：u 表 2 读 → 插值 → Φ 表 2 读 → 插值 ═════════
            ST_PRE: begin
                case (pre)
                3'd1: u0 <= u_rd;               // u[i0]（pre=0 时地址已为 u_i）
                3'd2: begin
                          u1    <= u_rd;        // u[i0+1]
                          u_acc <= u0 + (((u1 - u0) >> 4) * u_fr);
                      end
                3'd3: Phi <= rd;                // Φ[i0]
                3'd4: begin
                          Phi <= Phi + (((rd - Phi) >> 8) * pfrac[31:24]);
                          st  <= ST_HARM;
                          m   <= 8'd0;
                          s   <= 4'd0;
                      end
                default: ;
                endcase
                pre <= pre + 3'd1;
            end
            // ══ 谐波循环 ═══════════════════════════════════════════
            ST_HARM: begin
                s <= s + 4'd1;
                case (s)
                4'd1: hA  <= sx16(rd[15:0]);                 // A
                4'd2: hPA <= sx16(rd[15:0]);                 // phi_a
                4'd3: hDM <= sx16(rd[15:0]);                 // dm
                4'd4: hSC <= {16'd0, rd[15:0]};              // env_scale
                4'd5: begin
                          hPI   <= {16'd0, rd[15:0]};        // psi_idx
                          psi_a0 <= (rd[15:0] == 16'hFFFF)
                                  ? off_PSI
                                  : off_PSI + rd[15:0] * NT2 + psi_pos;
                          env_a0 <= off_ENV + m * NT3 + env_pos;
                      end
                4'd6: psi0 <= sx16(rd[15:0]);                // Ψ i0
                4'd7: psi1 <= sx16(rd[15:0]);                // Ψ i1
                4'd8: env0 <= sx8(rd[7:0]);                  // Env j0
                4'd9: env1 <= sx8(rd[7:0]);                  // Env j1
                4'd10: begin
                          psi0 <= psi0 + (((psi1 - psi0) >> 8) * psi_fr[31:24]);
                          env0 <= env0 + (((env1 - env0) >> 8) * env_fr[31:24]);
                      end
                4'd11: begin
                          hAS  <= (hA * hSC) >>> 15;         // A × scale
                          hPA  <= hPA <<< 3;                 // Q0.16 → 19 位小数
                          psi0 <= psi0 <<< 7;                // Q3.12 → 19 位小数
                      end
                4'd13: sn0 <= sx16(sin_rd);                  // sin(i)
                4'd14: sn1 <= sx16(sin_rd);                  // sin(i+1)
                4'd15: begin
                          sn0 <= sn0 + (((sn1 - sn0) >> 4) * theta[8:5]);
                          acc <= acc + (((env0 * hAS) >>> 15) * sn0);
                          m   <= m + 8'd1;
                          s   <= 4'd0;
                          if (m + 8'd1 >= K) st <= ST_OUT;
                      end
                default: ;
                endcase
            end
            // ══ 输出 ═══════════════════════════════════════════════
            ST_OUT: begin
                sample <= sat16(acc >>> 20);
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
