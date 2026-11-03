//==========================================================================
//  opt_feat —— 从逐帧原始差分里提取「力度 / 摆动」特征
//
//  为什么必须用【逐帧原始】而不是 4 点平滑：4 点平均等效延迟 48 ms，
//  顿音（30–80 ms）和 6 Hz 颤音（167 ms 周期）都会被抹平。
//
//  ── 输出 ────────────────────────────────────────────────────────
//    rho_raw   = Σ(六路 diff)        当前帧的总反射强度（码值和）
//    rho_dc    = 两级 1 阶 IIR 后的慢基线  ≈ 手的高度 → 力度
//    rho_ac    = rho_raw − rho_dc    摆动分量
//    ac_env    = |rho_ac| 的包络      摆动幅度（判 G3 颤音 / G4 花舌 用）
//    half_period = rho_ac 过零（带死区）之间隔了多少帧
//                  83.3 Hz 下：10 帧 = 8.3 Hz，5 帧 = 16.7 Hz
//
//  ── 为什么两级 IIR ──────────────────────────────────────────────
//    单级 τ=2^3=8 帧（96 ms）在 6 Hz 只衰减 −11 dB，颤音会漏成音量抖动。
//    两级串接 → −23 dB（残留 7%），听不出来。代价是力度路径多 ~70 ms 延迟，
//    而力度本来就该限速，无所谓。
//
//  ── 定点 ────────────────────────────────────────────────────────
//    单路 diff 是 18 位有符号（±262143），六路求和 ±1572858 → 24 位够。
//    实际量程：单路最大 65535 码 → 六路最大 393210。
//==========================================================================
`default_nettype none

module opt_feat #(
    parameter integer NCH        = 6,
    parameter integer LP_SHIFT   = 3,     // 慢基线 τ = 2^3 = 8 帧 ≈ 96 ms
    parameter integer ENV_SHIFT  = 2,     // 包络   τ = 2^2 = 4 帧 ≈ 48 ms
    parameter integer AC_DB      = 256    // 过零死区（码值和）
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  frame_valid,
    input  wire [NCH*18-1:0]     raw_flat,     // 逐帧原始 diff（不是 4 点平滑）

    output reg  signed [23:0]    rho_raw,
    output reg  signed [23:0]    rho_dc,
    output reg  signed [23:0]    rho_ac,
    output reg  signed [23:0]    ac_env,
    output reg  [15:0]           half_period,
    output reg  [15:0]           frame_cnt
);

    //----------------------------------------------------------------------
    // 六路求和
    //----------------------------------------------------------------------
    wire signed [23:0] s0 = $signed(raw_flat[18*0 +: 18]);
    wire signed [23:0] s1 = $signed(raw_flat[18*1 +: 18]);
    wire signed [23:0] s2 = $signed(raw_flat[18*2 +: 18]);
    wire signed [23:0] s3 = $signed(raw_flat[18*3 +: 18]);
    wire signed [23:0] s4 = $signed(raw_flat[18*4 +: 18]);
    wire signed [23:0] s5 = $signed(raw_flat[18*5 +: 18]);
    wire signed [23:0] sum6 = s0 + s1 + s2 + s3 + s4 + s5;

    //----------------------------------------------------------------------
    // 慢基线（两级 1 阶 IIR） + 摆动分量
    //----------------------------------------------------------------------
    reg  signed [23:0] dc1, dc2;

    wire signed [23:0] dc1_n = dc1 + ((sum6 - dc1) >>> LP_SHIFT);
    wire signed [23:0] dc2_n = dc2 + ((dc1 - dc2) >>> LP_SHIFT);
    wire signed [23:0] ac_n  = sum6 - dc2;

    // |ac| —— 用条件取反，避免 $signed 混合
    wire signed [23:0] aca_n = (ac_n < 24'sd0) ? (-ac_n) : ac_n;
    wire signed [23:0] env_n = ac_env + ((aca_n - ac_env) >>> ENV_SHIFT);

    //----------------------------------------------------------------------
    // 过零检测（带死区，避免噪声来回抖）
    //----------------------------------------------------------------------
    reg        pos;
    reg [15:0] cnt;
    reg [15:0] hp_n;
    reg        pos_n;
    reg [15:0] cnt_n;

    always @(*) begin
        hp_n  = half_period;
        pos_n = pos;
        cnt_n = (cnt == 16'd65535) ? 16'd65535 : cnt + 16'd1;
        if (ac_n > AC_DB) begin
            if (!pos) begin hp_n = cnt; cnt_n = 16'd0; pos_n = 1'b1; end
        end else if (ac_n < -AC_DB) begin
            if (pos)  begin hp_n = cnt; cnt_n = 16'd0; pos_n = 1'b0; end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            rho_raw     <= 24'sd0;
            rho_dc      <= 24'sd0;
            rho_ac      <= 24'sd0;
            ac_env      <= 24'sd0;
            half_period <= 16'd0;
            frame_cnt   <= 16'd0;
            dc1         <= 24'sd0;
            dc2         <= 24'sd0;
            pos         <= 1'b0;
            cnt         <= 16'd0;
        end else if (frame_valid) begin
            rho_raw     <= sum6;
            dc1         <= dc1_n;
            dc2         <= dc2_n;
            rho_dc      <= dc2_n;
            rho_ac      <= ac_n;
            ac_env      <= (env_n < 24'sd0) ? 24'sd0 : env_n;
            half_period <= hp_n;
            pos         <= pos_n;
            cnt         <= cnt_n;
            frame_cnt   <= (frame_cnt == 16'd65535) ? 16'd65535 : frame_cnt + 16'd1;
        end
    end

endmodule

`default_nettype wire
