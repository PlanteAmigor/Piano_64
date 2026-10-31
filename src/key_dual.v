//==========================================================================
//  key_dual —— 双触点（一前一后）按键状态机：去抖 + 力度
//
//  为什么需要它：
//    单触点 + "稳定 N ms 就认"的去抖有多不可靠，Jack Ganssle 实测过 18 种
//    开关（ganssle.com/debouncing.htm）：
//      · 平均抖动 1.56 ms，常见最大 6.2 ms
//      · 极端案例：抬起时抖动 157 ms
//      · 最致命的一条：抬起过程会先"稳定成高电平 81 ms"，再"稳定低 42 ms"，
//        最后才回到真正的高电平 —— 任何基于"稳定时间"的去抖都会被骗，
//        产生一次假的 抬起→按下→抬起，于是同一个音被触发两次 → 爆音。
//
//  双触点怎么解：
//    真钢琴/电子琴就是双触点。按下时"前触点先闭合、后触点后闭合"，
//    抬起时"前先断、后后断"。于是：
//      · 只有【两个触点都闭合】才算真正按下
//      · 只有【两个触点都断开】并持续 T_RELEASE 才算真正抬起
//      · "前断开、后闭合"这个中间态 = 手指还在行程中，绝不 note-off
//        这一条正好把 Ganssle 那 81 ms 的假高电平挡在外面
//
//  力度怎么来：
//    t1 = 前触点闭合时刻  → 【立即】置 key_state=1 发 note-on（0 延迟）
//    t2 = 后触点闭合时刻  → Δt = t2 − t1 → 力度
//    Δt 越小 = 击键越快 = 力度越大。Δt 只有在几 ms 量级，而 add_voice8 的
//    淡入是 5.24 ms —— 淡入还没结束力度就出来了，正好赶上。
//
//  状态转移：
//    IDLE ──前闭合──> ARMED ──后闭合──> PRESS ──前断开──> REL ──两触点
//      ^                 │                                   都断开 20ms
//      └──超时(20ms)─────┘                                        │
//        （假触发，取消）                                          v
//                                                                IDLE
//
//  ★ 位宽注意：T_CONFIRM/T_RELEASE = 1,000,000 拍需要 20 位
//    （2^19 = 524,288 不够）—— 这个坑在 note_alloc 里已经踩过一次。
//==========================================================================
`default_nettype none

module key_dual #(
    parameter integer N         = 9,
    // ★ T_CONFIRM = 50 ms（2,500,000 拍）。
    //   实测 Δt 落在 5~27 ms，50 ms 足够覆盖正常按键；
    //   超过 50 ms 还没等到第二触点 = 手指没压到底 = 轻按（力度给 48）。
    //   ★ 这只能影响【力度何时确定】，不影响触发延迟（key_state
    //     在 ARMED 就置 1，仍然是 0 延迟）。
    parameter integer T_CONFIRM = 2_500_000,   // 50 ms
    // ★ T_RELEASE 从 20 ms 加到 60 ms：
    //   Ganssle 实测机械开关松开抖动平均 1.56 ms，但坏开关能到 157 ms。
    //   60 ms 能挡住大多数脏抖动，又不至于让音符拖得太长。
    parameter integer T_RELEASE = 3_000_000,   // 60 ms
    // ★ FALLBACK = 1：另一个触点 T_CONFIRM 内没来，也当作按下
    parameter integer FALLBACK  = 1
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire [N-1:0]       key_f,       // 前触点（先闭合），低有效，片内上拉
    input  wire [N-1:0]       key_b,       // 后触点（后闭合），低有效

    output reg  [N-1:0]       key_state,   // 1 = 按下（ARMED 起就为 1，0 延迟）
    output reg  [N*8-1:0]     key_vel      // 每键 8 位起音增益 2..254（128=未测完）
);

    // ── 全局自由计时器：用于测 Δt ──────────────────────────────────
    reg [31:0] gtick;
    always @(posedge clk) begin
        if (!rst_n) gtick <= 32'd0;
        else        gtick <= gtick + 32'd1;
    end

    localparam [1:0] ST_IDLE  = 2'd0,
                     ST_ARMED = 2'd1,
                     ST_PRESS = 2'd2,
                     ST_REL   = 2'd3;

    // ── Δt → 力度增益（2..254）──★ 按实测标定（2026-10-31）──────────
    //   实测（用户按键 + 灯带读数反推）：
    //     超级猛击  Δt ≈ 5~10 ms
    //     轻按      Δt ≈ 21~27 ms
    //   所以真实工作区就在 5~27 ms，映射必须落在这里，否则全挤在一头。
    //
    //   映射：Δt ≤ 5 ms → 最强；之后每 8192 拍（164 µs）减 1 档
    //     Δt =  5 ms  → 254（最强）
    //     Δt = 10 ms  → 194
    //     Δt = 15 ms  → 132
    //     Δt = 20 ms  →  72
    //     Δt = 27 ms  →   2（最弱）
    function [7:0] vel_from;
        input [31:0] d;
        reg   [31:0] q;
        begin
            if (d <= 32'd250_000) q = 32'd0;              // ≤ 5 ms：满力度
            else                  q = (d - 32'd250_000) >> 13;
            if (q >= 32'd126) vel_from = 8'd2;            // 最轻
            else              vel_from = {1'b0, (7'd127 - q[6:0])} << 1;
        end
    endfunction

    genvar g;
    generate
    for (g = 0; g < N; g = g + 1) begin : g_kd

        // ── 2-FF 同步（异步输入）──────────────────────────────────
        reg f_s0, f_s1, b_s0, b_s1;
        always @(posedge clk) begin
            f_s0 <= key_f[g];
            b_s0 <= key_b[g];
            f_s1 <= f_s0;
            b_s1 <= b_s0;
        end
        wire f_raw = ~f_s1;        // 1 = 前触点闭合
        wire b_raw = ~b_s1;        // 1 = 后触点闭合

        reg [1:0]  st;
        reg [31:0] t1;             // 第一个闭合的触点时刻
        reg [22:0] tmr;            // ★ 23 位：T_CONFIRM=5,000,000 需要 23 位（2^22=4,194,304 不够）
        reg        f_first;        // ★ 1 = 前触点先闭合（顺序自适应）

        always @(posedge clk) begin
            if (!rst_n) begin
                st   <= ST_IDLE;
                t1   <= 32'd0;
                tmr  <= 23'd0;
                f_first <= 1'b1;
                key_state[g] <= 1'b0;
                key_vel[g*8 +: 8] <= 8'd128;       // 默认中等力度
            end
            else case (st)

                // ── 待机：等【任意】触点闭合 ───────────────────────
                //  ★ 顺序自适应：不假设一定是前触点先闭合。
                //    实物上哪一排靠外、哪个先接触，与 PCB 摆放有关，
                //    这里记下"谁先闭合"，无论哪种顺序 Δt 都能正确测到。
                ST_IDLE: begin
                    key_state[g] <= 1'b0;
                    if (f_raw || b_raw) begin
                        st      <= ST_ARMED;
                        key_state[g] <= 1'b1;      // ★ 立即响应（0 延迟）
                        t1      <= gtick;
                        f_first <= f_raw;          // 记下哪个先闭合
                        tmr     <= 23'd0;
                    end
                end

                // ── 已触发，等【另一个】触点确认力度 ───────────────
                ST_ARMED: begin
                    tmr <= tmr + 23'd1;
                    if (f_first ? b_raw : f_raw) begin
                        st <= ST_PRESS;
                        key_vel[g*8 +: 8] <= vel_from(gtick - t1);
                    end
                    else if (tmr >= T_CONFIRM[22:0]) begin
                        if (FALLBACK) begin
                            // ★ 第二个触点一直不来 = 手指没压到底 = 轻按
                            //   所以力度要给【小】值，而不是默认 128，
                            //   否则会出现“轻按比慢按到底还响”的倒挂。
                            st <= ST_PRESS;
                            key_vel[g*8 +: 8] <= 8'd48;      // 很轻（约 1 颗灯）
                        end
                        else begin
                            st <= ST_IDLE;
                            key_state[g] <= 1'b0;
                            key_vel[g*8 +: 8] <= 8'd128;
                        end
                    end
                end

                // ── 确认按下：两触点都闭合 ─────────────────────────
                //  任意一个断开就进抬起观察（不管哪个先断）
                ST_PRESS: begin
                    if (!f_raw || !b_raw) begin
                        st  <= ST_REL;
                        tmr <= 23'd0;
                    end
                end

                // ── 抬起观察：必须【两个触点都断开】才计时 ─────────
                //   ★ "前断开、后闭合" = 手指还在行程中，不是抬起，
                //     计数器清零重来 —— 这就是挡住 81 ms 假高电平的关键
                ST_REL: begin
                    if (f_raw || b_raw) begin
                        st  <= ST_PRESS;           // 抖动回按（任一触点又闭合）
                        tmr <= 23'd0;
                    end
                    else begin
                        tmr <= tmr + 23'd1;
                        if (tmr >= T_RELEASE[22:0]) begin
                            st <= ST_IDLE;
                            key_state[g] <= 1'b0;  // ★ 确认抬起
                        end
                    end
                end

                default: st <= ST_IDLE;
            endcase
        end
    end
    endgenerate

endmodule

`default_nettype wire
