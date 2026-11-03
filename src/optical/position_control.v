//==========================================================================
//  position_control —— 两维位置 → 演奏控制量
//
//  输入：x（横向质心，Q8 cm）、rho_dc（慢基线，反射总强度）
//  输出：bend（音分，±200）、vel（力度 0..255）
//
//  ── 弯音 ────────────────────────────────────────────────────────
//    实测有效范围 x ∈ [2.2, 12.6] cm，中心 7.4 cm，半宽 5.2 cm。
//    半宽对应 ±200 音分（±2 半音）：
//        200 / 5.2cm / 256 = 0.1503 音分 / Q8-LSB
//        0.1503 ≈ 77/512 = 0.15039   →  bend = (x − 1894) × 77 >>> 9
//    ⚠️ 无效帧时【保持】上一个 x，不能归零 —— 否则手到边缘音高会突然跳回中间。
//
//  ── 力度 ────────────────────────────────────────────────────────
//    rho_dc 实测：无手 ≈ 2100，手最近 ≈ 12000 码。
//    留 5500 做「起音」门限（低于它视为太远、力度 0）
//        vel = clamp((rho_dc − 5500) >>> 5, 0, 255)
//    满量程在 rho_dc ≈ 13660，实际手最近只到 ~12000 → vel ≈ 200，
//    留一点余量给更近的手。
//
//  ── 限速 ────────────────────────────────────────────────────────
//    两个量都按帧限速（83.3 Hz）：
//      bend ±8 音分/帧 = 664 音分/s      200 音分约 0.3 s 到
//      vel  ±6 /帧     = 500 /s          避免手抖导致音量爆跳
//    音频侧还会再做一次一阶 IIR 平滑，这里只是防止单帧野值。
//==========================================================================
`default_nettype none

module position_control (
    input  wire              clk,
    input  wire              rst_n,

    input  wire              frame_valid,
    input  wire [15:0]       x_q8,
    input  wire              x_valid,
    input  wire signed [23:0] rho_dc,
    input  wire signed [23:0] rho_raw,    // 逐帧原始差分（G7/G8 必须用它）
    input  wire signed [23:0] rho_ac,     // rho_raw − rho_dc（opt_feat）
    input  wire signed [23:0] ac_env,     // |rho_ac| 的包络（opt_feat）
    input  wire [15:0]       half_period, // rho_ac 两次过零之间的帧数

    output reg  signed [15:0] bend,     // 音分，±700
    output wire        [7:0]  vel,      // 0..255
    output wire        [15:0] bend_q14, // 音高比 Q2.14（16384 = 不弯）
    output wire               trem_en,  // G5 指颤：检测到左右大幅快速摇手
    output wire               vib_en,   // G3 颤音：检测到上下轻摇
    output reg                art_pulse,// G7 顿音/吐音（单帧脉冲）
    output wire               stop_hold, // G8 急停（电平：手抽走期间一直为 1）
    output reg                hand_on   // 手是否在传感器上方（即时，用于“有手才响”）
);

    localparam signed [16:0] X_CENTER = 17'sd1894;   // 7.40 cm
    // ★ 力度门限（实测标定，见 calib/opt_calib.csv，1 mV ≈ 6.55 ADC 码）：
    //     手拿开       Σ ≈ 2068 码
    //     10 cm 高     Σ ≈ 7251 码
    //      4 cm 高     Σ ≈ 9491 码
    //      2 cm 高     Σ ≈ 20724 码
    //      1 cm 高     Σ ≈ 28420 码
    //   旧值 4000 + >>5 的问题是：1 cm 与 2 cm 全部饱和到 255，
    //   4~10 cm 又只从 171 变到 101（4.5 dB）→ 抬落听不出变化。
    //   新值 >>7：1 cm→190，2 cm→130，4 cm→42，10 cm→25（17.6 dB 动态）
    localparam signed [23:0] V_BASE   = 24'sd4000;
    localparam signed [15:0] B_LIM    = 16'sd700;
    // 限速 20 音分/帧：0→700 用 35 帧 ≈ 420 ms。
    // 试过 40：反应快但把 x 的残余抖动放大成音高颤噪（唢呐听得出来），改回 20。
    localparam signed [15:0] B_SLEW   = 16'sd20;
    localparam        [7:0]  V_SLEW   = 8'd8;

    //----------------------------------------------------------------------
    // x 保持（无效帧不更新）
    //----------------------------------------------------------------------
    //  ★★ 一阶低通（指数滑动平均）：acc = acc − acc/8 + x，稳态 acc = 8x
    //     τ ≈ 8 帧 ≈ 96 ms。用累加器实现，**不需要符号扩展和钳位**，
    //     比 signed 差分写法省很多 LUT（后者把布局器挤到了 126 条违例）。
    //     原来是无条件直通 x_hold <= x_q8：质心在 83 Hz 帧间的抖动会原样
    //     变成音高抖动（135 音分/cm 下 ±0.2 cm 就是 ±27 音分），听感就是沙哑。
    //     τ=48 ms（>>2）仍能听到沙沙声，改用 96 ms；手部动作远慢于这个带宽。
    reg [17:0] x_acc;                       // 8 × x（最大 8×3840 = 30720 < 2^18）
    reg [15:0] x_last;                      // 最近一次【有效】的 x_q8

    //  ★★ 低通必须【每帧】跑，不能只在 x_valid 时跑。
    //     x_valid 是稀疏的（den 刚过门限时断断续续），若只在有效帧滤波，
    //     累加器一次只走 1/8，几帧才等到一个有效帧 → 实际收敛慢 8 倍以上，
    //     表现为「左右完全没反应」。
    //     改成：有效帧锁存 x_last，每个帧都用 x_last 滤波 → 恒定 8 帧收敛。
    always @(posedge clk) begin
        if (!rst_n)                      x_last <= 16'd1894;
        else if (frame_valid && x_valid) x_last <= x_q8;
    end

    //======================================================================
    //  G5 指颤检测：左右大幅快速摇手
    //
    //  ★ 必须从【原始】质心 x_last 取抖动，不能从 x_hold 取：
    //     x_hold 已被 96 ms 低通（截止 1.7 Hz），6 Hz 摇手会被衰减 3.6 倍。
    //  ★ x_dc 用更慢的低通（τ = 32 帧 ≈ 384 ms，截止 0.41 Hz）得到
    //     “手停在哪里”，x_ac = x_last − x_dc 就是摇动分量。
    //  ★ 判据用【过零间隔】：6 Hz 摇手相邻过零约 7 帧。
    //     间隔落在 5~20 帧（2.1~8.3 Hz）且幅度 > 1.5 cm 才算。
    //     单向滑音只会产生一次过零，间隔远大于 20 帧 → 不会误触发。
    //======================================================================
    reg [17:0] xd_acc;                  // 32 × x_dc
    reg        xa_prev;
    reg [5:0]  xa_gap;                  // 距上次过零的帧数（63 = 很久没动）
    reg [5:0]  xa_gap_l;                // 上一次的过零间隔

    wire [15:0]        x_dc = xd_acc[17:5];
    wire signed [17:0] xac  = $signed({2'b00, x_last}) - $signed({2'b00, x_dc});
    wire               xac_big = (xac > 18'sd384) || (xac < -18'sd384);   // 1.5 cm
    wire               xa_sgn  = xac[17];

    always @(posedge clk) begin
        if (!rst_n) begin
            xd_acc   <= (18'd1894 << 5);
            xa_prev  <= 1'b0;
            xa_gap   <= 6'd63;
            xa_gap_l <= 6'd63;
        end else if (frame_valid) begin
            xd_acc <= xd_acc - (xd_acc >> 5) + {2'b00, x_last};
            if (xa_gap != 6'd63) xa_gap <= xa_gap + 6'd1;
            if (xac_big && (xa_sgn != xa_prev)) begin
                xa_prev  <= xa_sgn;
                xa_gap_l <= xa_gap;
                xa_gap   <= 6'd0;
            end
        end
    end

    // 两次过零间隔在 5~20 帧，且下一次过零没迟到 → 正在摇
    // ★ 这里只能 assign，不能再写 `wire trem_en = ...`：
    //   端口表里已经声明过这个 net，重复声明在 Gowin 里只给 WARN
    //   然后当成【无驱动】处理（EX3671/EX1998），iverilog 直接报错。
    assign trem_en = (xa_gap_l >= 6'd5) && (xa_gap_l <= 6'd20) && (xa_gap <= 6'd24);

    // 横向正在移动中（|x 快分量| > 1 cm）：滑音/指颤期间，
    // 纵向的顿音/急停判定要禁用（见 G7/G8 处说明）
    // ★ 阈值取 256（1 cm）而不是 xac_big 的 384：横向扫动时 x_dc 滞后，
    //   |xac| 一般在 300~600，用 256 更稳地把它识别为"正在滑音"。
    wire lateral_mv = (xac > 18'sd256) || (xac < -18'sd256);

    //======================================================================
    //  G3 颤音检测：上下轻摇
    //
    //  信号全部来自 opt_feat（它本来就是为这个算的）：
    //    rho_ac      = rho_raw − rho_dc
    //    ac_env      = |rho_ac| 的包络（τ=4 帧 ≈ 48 ms）
    //    half_period = rho_ac 两次过零之间的帧数（带 256 码值死区）
    //
    //  频率窗口：4~8 Hz ⇒ 半周期 = 83.3/(2f) = 5.2~10.4 帧 ⇒ 取 [5, 11]
    //  幅度门限：ac_env > rho_dc/8（摆动幅度 > 12.5%）
    //
    //  ★ half_period 是「最后一次过零的间隔」，停手后不会自己归零，
    //    所以靠 ac_env 快速衰减（τ=4 帧）来收尾。
    //  ★ 与 G5 指颤互斥：左右大幅摇手优先级更高。
    //======================================================================
    wire signed [23:0] vib_thr = rho_dc >>> 3;
    wire vib_amp  = (ac_env > vib_thr) && (rho_dc > 24'sd4000);
    wire vib_rate = (half_period >= 16'd5) && (half_period <= 16'd11);
    // 总开关：门限是估的（串口挂了没法实测 ac_env），现场如果误触发就改 0
    localparam integer G3_EN = 1;

    // ★★ 必须加迟滞保持：ac_env 是 |rho_ac| 的低通（τ=4 帧），
    //    而 |rho_ac| 每个半周期都要掉到 0 → 包络跟着掉，5 Hz 时
    //    每 8 帧里有 2~3 帧 ac_env < 门限 → vib_en 断续（实测占空比只有 67%）。
    //    保持 16 帧（0.19 s）：停手后 ac_env 在 ~1 帧内就掉下去，
    //    所以 16 帧只影响收尾，不影响判定。
    reg [4:0] vib_hold;
    always @(posedge clk) begin
        if (!rst_n)                    vib_hold <= 5'd0;
        else if (!frame_valid)         vib_hold <= vib_hold;
        else if (vib_amp && vib_rate)  vib_hold <= 5'd16;
        else if (vib_hold != 5'd0)     vib_hold <= vib_hold - 5'd1;
    end

    assign vib_en = G3_EN && (vib_hold != 5'd0) && !trem_en;

    //======================================================================
    //  手在不在（用于“有手才响”）—— 必须用【即时】rho_raw
    //
    //  ★★ 不能用 opt_vel（它源自 rho_dc，两级低通 τ≈96 ms）：
    //     手抽走后 rho_raw 在 1 帧（12 ms）内就掉到无手电平（2068），
    //     而 rho_dc 要 300~400 ms 才跟上。用 opt_vel 判会有 200~400 ms
    //     的空窗：急停先静音，rho_ac 恢复后静音解除但 rho_dc 还虚高
    //     → 声音“回光返照”响一下，然后才真的掉下去。
    //
    //  定标：无手 ρ≈2068±88，10 cm≈7251。取 3500（16σ 以上，很安全）。
    //  连续 3 帧（36 ms）低于门限才判“手走了”，防单帧毛刺。
    //======================================================================
    localparam signed [23:0] HAND_TH = 24'sd3400;
    reg [3:0] hand_cnt;

    // ★★ 手离开的判定必须【慢】（16 帧 = 192 ms），并且横向/指颤运动期间不判：
    //    横向扫手时手会部分移出传感器阵列，rho_raw 短暂掉到 3400 以下。
    //    原来只 3 帧去抖 → hand_on 掉下来又回来 → 83 Hz 级别的 chopping，
    //    进混响后变成一大片噪声，听感同时像"卡顿"（实测就是这个）。
    //    急停不依赖 hand_on（由 stop_hold 的 rho_ac 判据即时触发），
    //    所以这里放慢到 192 ms 不影响急停手感。
    wire hand_keep = (rho_raw > HAND_TH) || lateral_mv || trem_en;

    always @(posedge clk) begin
        if (!rst_n) begin
            hand_cnt <= 4'd0;
            hand_on  <= 1'b0;
        end else if (frame_valid) begin
            if (hand_keep) begin
                hand_cnt <= 4'd0;
                hand_on  <= 1'b1;
            end else if (hand_cnt != 4'd15) begin
                hand_cnt <= hand_cnt + 4'd1;
            end else begin
                hand_on  <= 1'b0;
            end
        end
    end

    //======================================================================
    //  G7 顿音/吐音  +  G8 急停：ρ 的快速瞬态
    //
    //  ★★ 必须用 rho_raw（逐帧原始差分），不能用 rho_dc：
    //     rho_dc 是两级 IIR（τ≈96 ms），30~80 ms 的顿音会被完全抹平。
    //
    //  ★ 阈值按实测标定定（ρ 每 cm 的变化量）：
    //      1→2 cm  7696 码/cm      ← 近距离非常敏感
    //      2→4 cm  5616 码/cm
    //      4→10cm   373 码/cm      ← 远距离迟钝 20 倍
    //    所以手贴很近时信号反而最大，不需要担心触发不到。
    //    真正的限制是物理空间（已贴 1 cm 时压不下去），因此判据同时接受
    //    【先压后抬】和【先抬后压】两种极性顺序。
    //
    //  ★ 判据用【两帧平均差分】压噪声（rho_raw 噪声 σ≈88 码）：
    //      dv = (rho_raw[n] − rho_raw[n−2]) / 2
    //======================================================================
    // ★ 阈值 1200 而不是 700：5 Hz 颤音（幅度 20%）本身就有
    //    1898×2π×5/83.3 ≈ 716 码/帧 的变化，阈值太低会把颤音当成顿音。
    //    ✓ 远处顿音（8→5 cm，3 帧）≈ 1722 码/帧，仍有足够余量
    //    ✓ 近处顿音（2→1 cm，3 帧）≈ 2565 码/帧
    localparam signed [24:0] DV_HI = 25'sd1200;      // 码/帧

    reg signed [23:0] rr_p, rr_p2;
    always @(posedge clk) begin
        if (!rst_n) begin
            rr_p  <= 24'sd0;
            rr_p2 <= 24'sd0;
        end else if (frame_valid) begin
            rr_p  <= rho_raw;
            rr_p2 <= rr_p;
        end
    end

    wire signed [24:0] dv = ($signed({rho_raw[23], rho_raw})
                           - $signed({rr_p2[23], rr_p2})) >>> 1;
    wire dv_up = (dv >  DV_HI);
    wire dv_dn = (dv < -DV_HI);

    // ★★ G8 急停改成【相对量】判据：rho_raw 跌到慢基线以下 25% → 手真的抽走了
    //
    //   为什么不用单帧斜率：真实的「快速抬手」大约要 100 ms，
    //   摊到每帧只有 ~950 码，低于「能挡住 5 Hz 颤音（716 码/帧）」所必需的
    //   1200 → 现场永远触发不了（这就是第一次实测的问题）。
    //   而相对量自动适应远近：
    //     5 Hz 颤音 幅度 20%  → rho_ac 最低 −0.20·rho_dc，打不到 −0.25·rho_dc ✓
    //     手真的抽走          → rho_ac 能到 −0.8·rho_dc 以下 ✓
    //     ★ 阈值取 0.3125·rho_dc（=1/4+1/16，两次移位相加）：
    //       颤音幅度最大 30% → rho_ac 最低 −0.30·rho_dc，仍在门限之外 ✓
    //       手真的抽走 → rho_ac 能到 −0.58·rho_dc 以下 ✓
    wire signed [23:0] stop_thr = -((rho_dc >>> 2) + (rho_dc >>> 4));
    // ★ 输出【电平】而不是脉冲：手拿开后慢基线还会拖很久，
    //   用固定时长的静音会出现“声音回光返照”（57 ms 后音量又回来）。
    //   电平持续期间引擎一直静音，手真正回来（rho_ac 回到基线附近）才放开。
    assign stop_hold = (rho_ac < stop_thr) && (rho_dc > 24'sd3000)
                    && (vib_hold == 5'd0) && !trem_en && !lateral_mv;

    // 最近 6 帧内是否出现过反向大变化
    reg [2:0] up_tmr, dn_tmr;

    always @(posedge clk) begin
        if (!rst_n) begin
            up_tmr     <= 3'd0;
            dn_tmr     <= 3'd0;
            art_pulse  <= 1'b0;
        end else if (frame_valid) begin
            art_pulse  <= 1'b0;
            if (up_tmr != 3'd0) up_tmr <= up_tmr - 3'd1;
            if (dn_tmr != 3'd0) dn_tmr <= dn_tmr - 3'd1;

            // ★ 摇手（G3 颤音 / G5 指颤）或横向快速移动期间禁止顿音：
            //   上下轻摇本身就在快速改变 rho，不屏蔽会被当成一串顿音。
            //   ★★ 横向快速扫动（滑音）时必须也屏蔽：手会部分移出传感器阵列，
            //      ρ 随之起伏 → 被当成一串顿音/急停 → 引擎反复 mute_fast，
            //      古筝余音长，chatter 特别刺耳（实测现场就是这样）。
            if (vib_hold != 5'd0 || trem_en || lateral_mv) begin
                art_pulse  <= 1'b0;
                up_tmr     <= 3'd0;
                dn_tmr     <= 3'd0;
            end else begin
                if (dv_up) begin
                    if (dn_tmr != 3'd0) art_pulse <= 1'b1;   // 先压后抬（或先抬后压）
                    up_tmr <= 3'd6;
                end
                if (dv_dn) begin
                    if (up_tmr != 3'd0) art_pulse <= 1'b1;   // 反向回来 → 顿音
                    dn_tmr <= 3'd6;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n)         x_acc <= (18'd1894 << 3);
        // ★ 指颤期间冻结基准音高：摇手本身会把 x 拉来拉去，
        //   不冻结的话基准音高会跟着摇（±3 cm 摇幅 = ±400 音分），
        //   和引擎里的 ±200 音分颤音叠在一起 → 又乱又过头。
        else if (frame_valid && !trem_en)
            x_acc <= x_acc - (x_acc >> 3) + {2'b00, x_last};
    end

    wire [15:0] x_hold = x_acc[17:3];

    //----------------------------------------------------------------------
    // 弯音目标
    //----------------------------------------------------------------------
    wire signed [16:0] dx  = $signed({1'b0, x_hold}) - X_CENTER;

    // ★★★ 中央死区（中立区）：手放在中间 1.5 cm 内音高就是原音，
    //   在这个位置可以【只调音量】（左右手抖不会跑调）。
    //
    //   为什么必须有：可用跨度只有 2.2–12.6 cm（±5.2 cm），
    //   原来是纯线性 135 音分/cm —— 手抖 1 mm 就是 13 音分，
    //   想安静地只改力度根本站不住。
    //
    //   标定（Q8 = 256/cm）：
    //     死区 ±384（1.5 cm）→ 音分 0
    //     剩下 5.2−1.5 = 3.7 cm 走完 700 音分
    //     → 系数 378/512 = 0.7383 音分/Q8-LSB = 189 音分/cm
    //     （比原来 135 更陡，但中间多了一段完全稳的区）
    //   验算：|dx|=1331（5.2 cm）→ (1331−384)×378/512 = 699 音分 ✓
    localparam signed [16:0] BEND_DZ = 17'sd384;
    // 死区内 → 0；区外 → 扣掉死区半宽（三路比较，不做 abs/取反，少两级 LUT）
    wire signed [16:0] dxs = (dx >  BEND_DZ) ? (dx - BEND_DZ) :
                             (dx < -BEND_DZ) ? (dx + BEND_DZ) : 17'sd0;
    wire signed [23:0] dxm = dxs * 24'sd378;
    // ★ 打一拍：x_acc → 死区 → 乘法 → 移位 → 钳位 → bend 实测 19.8 ns（20 ns 超边缘）
    //   多 1 帧（12 ms）延迟对滑音无影响 —— 后面还有 B_SLEW 限速，本来就要几百 ms
    reg signed [23:0] bq_r;
    always @(posedge clk) begin
        if (!rst_n)           bq_r <= 24'sd0;
        else if (frame_valid) bq_r <= dxm >>> 9;
    end
    wire signed [23:0] bq = bq_r;

    // ★ 三个分支都必须是 signed，否则整条表达式退化成无符号比较
    //
    // ==================================================================
    //  【临时诊断开关】DIAG_RHO_BEND = 1 时，弯音改由 rho（手的高度）驱动，
    //  不再看 x。目的是把「引擎弯音通路」和「x 质心」两件事分开：
    //    · 上下抬手 → 音高跟着滑 = 引擎+接线正常 ⇒ 问题在 x_q8
    //    · 上下抬手 → 音高仍不动    = 引擎/接线有问题
    //  音量已经证明 rho_dc 随手高度变化，所以这个测试是可靠的。
    //  ★ 2026-11-03 结论：已经用它 + add_top 的 DIAG_FORCE_BEND 二分出真因
    //    —— 引擎里是把弯音比乘在【已回绕的相位】上，导致音高不变只变噪。
    //    已改成乘在相位增量上（见 add_engine_harm.v），恢复正常分支。
    // ==================================================================
    localparam integer DIAG_RHO_BEND = 0;

    wire signed [23:0] bq_rho = ((rho_dc - 24'sd14000) * 24'sd51) >>> 9;
    wire signed [23:0] bq_sel = DIAG_RHO_BEND ? bq_rho : bq;

    wire signed [15:0] b_tgt = (bq_sel >  B_LIM) ?  B_LIM :
                               (bq_sel < -B_LIM) ? -B_LIM :
                               $signed(bq_sel[15:0]);

    //----------------------------------------------------------------------
    // 力度目标
    //----------------------------------------------------------------------
    wire signed [23:0] vq = rho_dc - V_BASE;
    wire        [23:0] vs = (vq <= 24'sd0) ? 24'd0 : vq;
    wire        [18:0] vsh = vs >>> 6;          // ★ >>6：见上面 V_BASE 的标定表
    wire        [7:0]  v_tgt = (vsh > 19'd255) ? 8'd255 : vsh[7:0];

    //----------------------------------------------------------------------
    //  限速 + 低通 + 输出
    //----------------------------------------------------------------------
    //  ★ vel 同样用累加器一阶低通：acc = acc − acc/8 + v_tgt，稳态 acc = 8×v_tgt
    //     τ ≈ 8 帧 ≈ 96 ms。限速（±V_SLEW）只能压「变化速度」，压不住
    //     「来回摆动」，rho_dc 的残余噪声仍会让音量几十 Hz 地摆 → 沙沙声。
    reg [11:0] v_acc;                       // 8 × v_tgt（最大 8×255 = 2040 < 2^12）

    assign vel = v_acc[11:3];

    always @(posedge clk) begin
        if (!rst_n) begin
            bend  <= 16'sd0;
            v_acc <= 12'd0;
        end else if (frame_valid) begin
            // ---- bend：限速（保留，保证滑音不瞬跳）----
            if      (b_tgt > bend + B_SLEW) bend <= bend + B_SLEW;
            else if (b_tgt < bend - B_SLEW) bend <= bend - B_SLEW;
            else                            bend <= b_tgt;

            // ---- vel：一阶低通 ----
            v_acc <= v_acc - (v_acc >> 3) + {4'd0, v_tgt};
        end
    end

    //======================================================================
    //  音分 → 音高比 Q2.14 = 2^(cent/1200)，每 64 音分一段线性插值
    //
    //  ★ 必须用真指数：线性近似 16384+cent*9 在 ±200 音分只差 3 音分，
    //     但到 ±700 就偏 90 音分（6% 频率），±1200 偏 240 音分 —— 跑调。
    //     64 音分一段的分段线性误差 < 1 音分。
    //======================================================================
    function [15:0] tab_p;          // 2^(+k*64/1200) × 16384
        input [3:0] k;
        case (k)
            4'd0:  tab_p = 16'd16384;
            4'd1:  tab_p = 16'd17001;
            4'd2:  tab_p = 16'd17644;
            4'd3:  tab_p = 16'd18307;
            4'd4:  tab_p = 16'd18996;
            4'd5:  tab_p = 16'd19716;
            4'd6:  tab_p = 16'd20464;
            4'd7:  tab_p = 16'd21248;
            4'd8:  tab_p = 16'd22051;
            4'd9:  tab_p = 16'd22887;
            4'd10: tab_p = 16'd23757;
            4'd11: tab_p = 16'd24659;
            4'd12: tab_p = 16'd25590;
            4'd13: tab_p = 16'd26494;
            4'd14: tab_p = 16'd27493;
            default: tab_p = 16'd28526;
        endcase
    endfunction

    function [15:0] tab_n;          // 2^(-k*64/1200) × 16384
        input [3:0] k;
        case (k)
            4'd0:  tab_n = 16'd16384;
            4'd1:  tab_n = 16'd15793;
            4'd2:  tab_n = 16'd15214;
            4'd3:  tab_n = 16'd14660;
            4'd4:  tab_n = 16'd14130;
            4'd5:  tab_n = 16'd13615;
            4'd6:  tab_n = 16'd13120;
            4'd7:  tab_n = 16'd12643;
            4'd8:  tab_n = 16'd12185;
            4'd9:  tab_n = 16'd11742;
            4'd10: tab_n = 16'd11315;
            4'd11: tab_n = 16'd10902;
            4'd12: tab_n = 16'd10506;
            4'd13: tab_n = 16'd10132;
            4'd14: tab_n = 16'd9765;
            default: tab_n = 16'd9411;
        endcase
    endfunction

    // 绝对值（|bend| ≤ 768，低 11 位够）
    wire [10:0] b_mag = bend[15] ? (11'd0 - bend[10:0]) : bend[10:0];

    // ── 第一级：拆出段号/余数先打一拍 ─────────────────────────────────
    //   取表 + 17×6 乘法 + 相加是一条长组合链，直接接在限速寄存器后面
    //   会把它顶到 20 ns 边上（实测把 BSRAM 95% 的布局挤到 18 条违例）。
    //   拆成两级后每级只有 mux/乘法，余量充足；延迟 2 拍 = 40 ns，与帧率无关。
    reg [3:0] r_idx;
    reg [5:0] r_frac;
    reg       r_neg;

    always @(posedge clk) begin
        if (!rst_n) begin
            r_idx  <= 4'd0;
            r_frac <= 6'd0;
            r_neg  <= 1'b0;
        end else begin
            r_idx  <= b_mag[10:6];      // 64 音分一段
            r_frac <= b_mag[5:0];
            r_neg  <= bend[15];
        end
    end

    // ── 第二级：查表 + 线性插值 ───────────────────────────────────────
    wire [15:0] tp0 = tab_p(r_idx);
    wire [15:0] tp1 = tab_p(r_idx + 4'd1);
    wire [16:0] tpr = tp1 - tp0;
    wire [15:0] ratio_p = tp0 + ((tpr * r_frac) >> 6);

    wire [15:0] tn0 = tab_n(r_idx);
    wire [15:0] tn1 = tab_n(r_idx + 4'd1);
    wire [16:0] tnr = tn0 - tn1;            // 递减，取正
    wire [15:0] ratio_n = tn0 - ((tnr * r_frac) >> 6);

    reg [15:0] bend_q14_r;
    always @(posedge clk) begin
        if (!rst_n) bend_q14_r <= 16'd16384;
        else        bend_q14_r <= r_neg ? ratio_n : ratio_p;
    end

    assign bend_q14 = bend_q14_r;

endmodule

`default_nettype wire
