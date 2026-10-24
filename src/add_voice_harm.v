//==========================================================================
//  add_voice_harm —— 谐波表驱动的加法声部（笛子 / 唢呐）
//
//      s(t) = Σ_{m=1..K} env_m(t) · A_m · sin(2π·Θ_m(t) + phi_m)
//      Θ_m(t) = m·Φ(u(t)) + δ_m·t + Ψ_m(u(t))
//      env_m(t) = EnvTab_m(u(t)) · env_scale_m / 127     ← 起振项已预乘进表
//      u(t) = (1−α)·t/D + α·ln(1+t/T0)/ln(1+D/T0)        α=0.6 T0=0.06 D=3s
//
//  ── 定点格式（与 tools/npz2hex_harm.py 严格对应）──────────────────
//      Φ      Q13.19  32 bit 无符号（绝对值；只用低 19 位做 m·Φ，整数部分无关）
//      Ψ      Q3.12   16 bit 有符号
//      A      Q3.13   16 bit 有符号
//      phi_a  Q0.16   16 bit 有符号（圈，±0.5）
//      δ      0.001Hz 16 bit 有符号
//      env_scale Q1.15 16 bit 无符号
//      env    int8（−127..127），真实值 = int8/127 × scale
//
//  ── 幅度缩放推导 ─────────────────────────────────────────────────
//      env_true = h_env/127 × (h_SC/2^15)
//      A_true   = h_A/2^13
//      sin_true = h_sin/2^15
//      hAS      = h_A × h_SC / 2^15           （Q4.13，env_true×A_true = h_env×hAS/(127×2^13)）
//      p        = (h_env × hAS)/2^15
//      acc     += p × h_sin
//      ⇒ acc = Σ env_true·A_true·sin_true × (127 × 2^28)
//      ⇒ sample = acc / (127 × 2^28) = acc >>> 35   （2^35/127 = 2.704e8 ≈ 127×2^28=3.407e10？
//         ★ 这里不能用近似，见 SOUT 的说明：直接除 3.407e10 用移位不精确，
//           所以缩放系数取 2^28，输出 acc >>> 28，再在顶层统一乘系数。）
//
//  ── 时间分配（每样点 1024 拍）────────────────────────────────────
//      启动 1 拍（读表头）+ 前置 5 拍（u 2 读、Φ 2 读、插值）
//      谐波循环：每谐波 16 拍 × K（K 最大 62 → 992）
//      合计最坏 1 + 5 + 992 = 998 < 1024 ✓
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
    output reg  [ROM_AW-1:0]   rom_addr,

    input  wire [31:0]         u_rd,
    output reg  [U_AW-1:0]     u_addr,

    input  wire [15:0]         sin_rd,
    output reg  [9:0]          sin_addr,

    input  wire [ROM_AW-1:0]   base_rd,

    output reg  signed [15:0]  sample,
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
    //  节拍与全局状态
    // ════════════════════════════════════════════════════════════════
    reg [9:0]  cnt;
    reg [19:0] t_smp;
    reg [31:0] u_acc;
    reg [31:0] Phi;

    wire [15:0] u_i  = t_smp[19:4];
    wire [3:0]  u_fr = t_smp[3:0];

    // ════════════════════════════════════════════════════════════════
    //  表头与分区偏移
    // ════════════════════════════════════════════════════════════════
    reg [ROM_AW-1:0] base;
    reg [7:0]  K, npsi;

    wire [ROM_AW-1:0] off_A   = base + 2;
    wire [ROM_AW-1:0] off_PA  = base + 2 + K;
    wire [ROM_AW-1:0] off_DM  = base + 2 + 2 * K;
    wire [ROM_AW-1:0] off_SC  = base + 2 + 3 * K;
    wire [ROM_AW-1:0] off_PI  = base + 2 + 4 * K;
    wire [ROM_AW-1:0] off_PHI = base + 2 + 5 * K;
    wire [ROM_AW-1:0] off_PSI = off_PHI + 2 * NT;
    wire [ROM_AW-1:0] off_ENV = off_PSI + npsi * NT2;

    // ════════════════════════════════════════════════════════════════
    //  状态机
    // ════════════════════════════════════════════════════════════════
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

    reg signed [31:0] hA, hPA, hDM, hSC, hPI;
    reg signed [31:0] psi0, psi1, env0, env1, sn0, sn1;
    reg signed [31:0] hAS;
    reg signed [63:0] acc;

    // 插值坐标（u × (T-1)，用 64 位中间量）
    wire [63:0] uprod    = {32'd0, u_acc} * (NT  - 1);
    wire [9:0]  pidx     = uprod[40:32];
    wire [31:0] pfrac    = uprod[31:0];

    wire [63:0] psiprod  = {32'd0, u_acc} * (NT2 - 1);
    wire [8:0]  psi_idx9 = psiprod[40:32];
    wire [31:0] psi_fr   = psiprod[31:0];

    wire [63:0] envprod  = {32'd0, u_acc} * (NT3 - 1);
    wire [7:0]  env_idx8 = envprod[39:32];
    wire [31:0] env_fr   = envprod[31:0];

    // ══════════════════════════════════════════════════════════
    //  ★ 相位合成  Θ = m·Φ + δ_m·t + Ψ_m + phi_m   （单位：圈，19 位小数）
    // ══════════════════════════════════════════════════════════
    //  δ 的单位是 0.001 Hz，t_smp 是样点序号：
    //      δ_Hz × t_s  = δ × 0.001 × t_smp / FS           （圈）
    //      换算到 19 位小数（×2^19）：
    //      = δ × t_smp × 0.001 × 2^19 / FS
    //      = δ × t_smp × 0.010738
    //      用 ×11264 >>20 实现（11264/2^20 = 0.010742，误差 0.04%）
    wire signed [63:0] dmt_full = (hDM * $signed({44'd0, t_smp})) * 64'sd11264;
    wire signed [63:0] dmt      = (dmt_full + 64'sd524288) >>> 20;

    // m·Φ：Φ 只取低 19 位（小数），×m 后再取低 19 位；整数部分与相位无关
    wire signed [37:0] mphi = $signed({1'b0, Phi[18:0]}) * $signed({30'd0, m});

    // 各项对齐到 19 位小数后相加
    //    mphi : 19 + 6 = 25 位（已经带 19 位小数）
    //    dmt  : 已 ×2^19
    //    psi0 : 在 s=11 左移 7 位（Q3.12 → 19 位小数）
    //    hPA  : 在 s=11 左移 3 位（Q0.16 → 19 位小数）
    wire signed [37:0] theta = mphi + dmt[37:0] + psi0 + hPA;

    always @(posedge clk) begin
        if (!rst_n) begin
            cnt <= 10'd0; t_smp <= 20'd0; u_acc <= 32'd0; Phi <= 32'd0;
            st <= ST_IDLE; m <= 8'd0; s <= 4'd0; pre <= 3'd0;
            base <= {ROM_AW{1'b0}}; K <= 8'd0; npsi <= 8'd0;
            rom_addr <= {ROM_AW{1'b0}}; u_addr <= {U_AW{1'b0}}; sin_addr <= 10'd0;
            u0 <= 32'd0; u1 <= 32'd0;
            hA <= 0; hPA <= 0; hDM <= 0; hSC <= 0; hPI <= 0;
            psi0 <= 0; psi1 <= 0; env0 <= 0; env1 <= 0; sn0 <= 0; sn1 <= 0;
            hAS <= 0; acc <= 64'sd0; sample <= 16'sd0;
            ready <= 1'b0; pending <= 1'b0; idle <= 1'b1;
        end
        else begin
            cnt <= (cnt == 10'd1023) ? 10'd0 : cnt + 10'd1;

            if (trig) pending <= 1'b1;

            // ── 样点边界触发新一轮 ─────────────────────────────────
            if (pending && (cnt == 10'd0)) begin
                pending  <= 1'b0;
                ready    <= 1'b0;
                base     <= base_rd;
                rom_addr <= base_rd;
                st       <= ST_HEAD;
                t_smp    <= 20'd0;
                u_acc    <= 32'd0;
                acc      <= 64'sd0;
            end

            case (st)
            // ══ 表头：base+0 = {K, npsi} ═══════════════════════════
            ST_HEAD: begin
                K    <= rd[7:0];
                npsi <= rd[15:8];
                st   <= ST_PRE;
                pre  <= 3'd0;
            end
            // ══ 前置：u 表 2 读 → 插值 → Φ 表 2 读 → 插值 ═════════
            ST_PRE: begin
                case (pre)
                3'd0: u_addr  <= u_i;
                3'd1: begin
                          u0     <= u_rd;
                          u_addr <= u_i + 16'd1;
                      end
                3'd2: begin
                          u1    <= u_rd;
                          // u = u0 + (u1 − u0) × frac/16
                          u_acc <= u0 + (((u1 - u0) >> 4) * u_fr);
                          rom_addr <= off_PHI + pidx;
                      end
                3'd3: begin
                          Phi      <= rd;
                          rom_addr <= off_PHI + pidx + 10'd1;
                      end
                3'd4: begin
                          // Φ 插值（先用高位近似，精度见文件头）
                          Phi <= Phi + (((rd - Phi) >> 8) * pfrac[31:24]);
                          st  <= ST_HARM;
                          m   <= 8'd0;
                          s   <= 4'd0;
                      end
                default: st <= ST_HARM;
                endcase
                pre <= pre + 3'd1;
            end
            // ══ 谐波循环：16 拍/谐波 ═══════════════════════════════
            ST_HARM: begin
                s <= s + 4'd1;
                case (s)
                4'd0: rom_addr <= off_A  + m;
                4'd1: begin hA  <= sx16(rd[15:0]);  rom_addr <= off_PA + m; end
                4'd2: begin hPA <= sx16(rd[15:0]);  rom_addr <= off_DM + m; end
                4'd3: begin hDM <= sx16(rd[15:0]);  rom_addr <= off_SC + m; end
                4'd4: begin hSC <= {16'd0, rd[15:0]}; rom_addr <= off_PI + m; end
                4'd5: begin
                          hPI <= {16'd0, rd[15:0]};
                          rom_addr <= (rd[15:0] == 16'hFFFF)
                                    ? off_PSI
                                    : off_PSI + rd[15:0] * NT2 + psi_idx9;
                      end
                4'd6: begin psi0 <= sx16(rd[15:0]); rom_addr <= rom_addr + 10'd1; end
                4'd7: begin
                          psi1 <= sx16(rd[15:0]);
                          rom_addr <= off_ENV + m * NT3 + env_idx8;
                      end
                4'd8: begin env0 <= sx8(rd[7:0]);  rom_addr <= rom_addr + 10'd1; end
                4'd9: env1 <= sx8(rd[7:0]);
                4'd10: begin
                          psi0 <= psi0 + (((psi1 - psi0) >> 8) * psi_fr[31:24]);
                          env0 <= env0 + (((env1 - env0) >> 8) * env_fr[31:24]);
                      end
                4'd11: begin
                          hAS  <= (hA * hSC) >>> 15;   // A × env_scale
                          hPA  <= hPA <<< 3;           // Q0.16 → 19 位小数
                          psi0 <= psi0 <<< 7;          // Q3.12 → 19 位小数
                      end
                4'd12: sin_addr <= theta[18:9];
                4'd13: begin sn0 <= sx16(sin_rd); sin_addr <= sin_addr + 10'd1; end
                4'd14: sn1 <= sx16(sin_rd);
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
            // ══ 输出 ══════════════════════════════════════════════
            ST_OUT: begin
                sample <= sat16(acc >>> 28);
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
