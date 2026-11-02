//==========================================================================
//  note_alloc —— 把 8 个按键分配成 4 个声部的 note / trig / gate
//
//  ⚠️ 本模块【只管一件事】：按键 → 声部分配。不含音色、不含发声。
//     对应 pcm5102a 工程里的 poly_engine.v，但接口不同：
//     这里输出的是 MIDI 音号 + 触发脉冲 + 按住电平，
//     而不是频率字 —— 因为加法引擎每个分量都要按音号去查参数表。
//
//  ── 分配优先级（从高到低）────────────────────────────────────────
//      1. 已经松开、还在余音里的声部（v_key == FREE）→ 不打断自然衰减最好
//      2. add_voice 报 idle（包络已衰到 16bit 的 0）→ 完全静音
//      3. 轮转（round-robin）→ 最后一个选择，避免每次都抢同一个声部
//
//  ── 为什么不能省掉消抖 ───────────────────────────────────────────
//      一次机械按下会抖出几十个边沿。不消抖的话一次按键会把 4 个声部
//      瞬间全抢光，听起来像噪声。消抖在 key_scan.v 里做（8 ms）。
//
//  ── 按键布局────────────────────────────────────────────────
//      ★ 每个乐器有自己的【起点 + 音阶 + 可用键】，由 add_top 按 timbre 选择：
//        钢琴：note_base=60(C4)，key_step=0,2,4,5,7,9,11,12，8 键全可用
//        古筝：note_base=62(D4)，key_step=0,2,4,F,7,9,F,12（D 宫五声），
//              键 4(fa) / 键 7(si) 屏蔽 —— 五声音阶里没有这两个音
//      4'hF = 无效步长哨兵，该键永不发声（与 key_enable 双重保险）
//==========================================================================
`default_nettype none

module note_alloc #(
    parameter integer NKEY      = 8,
    parameter integer NVOICE    = 4
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [NKEY-1:0]          key_state,      // 1 = 按下（物理）
    // ★ 本乐器可发声的键（1 = 有对应音，0 = 本乐器音阶里没这个音）
    //   例：古筝 D 宫五声无 fa / si → 键 4、键 7 屏蔽，不占声部、不发声
    input  wire [NKEY-1:0]          key_enable,
    // ★ 音高映射（由 add_top 按 timbre 选）：
    //   note_base = 本乐器 8 键的起始 MIDI 音号
    //   key_step  = 每个键相对 note_base 的半音偏移，4 bit/键
    input  wire [6:0]               note_base,
    input  wire [NKEY*4-1:0]        key_step,
    input  wire [NKEY*8-1:0]        key_vel,        // ★ 每键力度增益 2..254
    // ★ 移调（半音，有符号）。0 = 不移调。
    //   由 add_top 按「第 9 键 + 轻击/重击第 1 键」产生，已按音域 clamp 过，
    //   所以这里直接相加不会越界。
    input  wire signed [7:0]        transpose,
    input  wire [NVOICE-1:0]        v_idle,         // 来自 add_voice

    output reg  [NVOICE*7-1:0]      v_note,         // 每个声部的 MIDI 音号
    output reg  [NVOICE-1:0]        v_trig,         // note-on 脉冲
    output reg  [NVOICE-1:0]        v_gate,         // 1 = 按住
    output reg  [NVOICE*8-1:0]      v_vel           // ★ 每声部力度增益
);

    localparam integer  IW       = $clog2(NKEY);
    // ★ 声部索引位宽：原来是写死的 [1:0]，只能覆盖 4 个声部。
    //   NVOICE=8 时 rr 只能取 0~3 → 声部 4~7 永远轮不到（轮询指针卡住）。
    localparam integer  VW       = (NVOICE <= 1) ? 1 : $clog2(NVOICE);
    localparam [IW-1:0] KEY_FREE = {IW{1'b1}};
    localparam [VW-1:0] RR_MAX   = NVOICE - 1;

    reg [IW-1:0]     v_key [0:NVOICE-1];
    // ★★ 余音保护期（治"快速拨一下爆音"）────────────────────────
    //  症状：猛快速拨一下按键就爆音（旧代码也有，不是 8 声部引入的）。
    //  机理：松键后声部【立刻】被标成 FREE，但 R_REL 要 0.3 s 才把 e1
    //        衰到 0。这时再按任意键 → is_free 优先级最高 → 抢到这个声部
    //        → 装载新音 → 正在响的余音被【一刀切断】→ 爆音。
    //  对策：松键后启动 0.34 s 计时，期间该声部【不可被抢占】。
    //        8 个声部足够，快速拨几下不会耗尽。
    //  ★★ 位宽陷阱（2026-10-30 踩过）：0.34 s @50MHz = 17,000,000 拍，
    //     需要 **25 位**（2^24 = 16,777,216 不够！）。写成 [23:0] 会被截断
    //     成 222,784 拍 = 4.5 ms，保护期等于没生效 → 猛击照样抢占 → 爆音。
    localparam [24:0] REL_TICKS = 25'd17_000_000;   // 0.34 s @50MHz
    reg [24:0]       rel_t [0:NVOICE-1];
    reg [NVOICE-1:0] rel_hold;

    // ★★ 同一键的最小重触发间隔（治"猛击时急速抖动多次触发"）──
    //  现象：像猛击钢琴键那样快速大力敲一下，就会爆音。
    //  机理：机械冲击的抖动可能让同一个键在极短时间内被多次 note-on，
    //        每一次都从满幅重新起音、和前一次的余音叠加 → 听感是"爆"。
    //  对策：每个键一个 40 ms 锁定窗，窗内同一键的再次触发直接忽略。
    //        40 ms = 25 次/秒，比钢琴最快的重复击键（约 15 次/秒）还快，
    //        不影响正常演奏。
    //  ★ 位宽：40 ms @50MHz = 2,000,000 拍，需要 22 位（2^21=2,097,152 不够
    //    会溢出到 3 倍以上，2^22=4,194,304 才够）—— 这里已经算过了。
    // ★ 位宽：120 ms @50MHz = 6,000,000 拍，需要 **23 位**
    //   （2^22 = 4,194,304 不够！原来 40 ms 用 22 位就够了，改大后必须加宽）
    localparam [22:0] RELOCK = 23'd6_000_000;       // 120 ms @50MHz
    reg [22:0] key_lock [0:NKEY-1];
    // ★★ handled 是【每个按键】一位，所以必须是 NKEY 位，不是 NVOICE 位！
    //    写成 [NVOICE-1:0] 的话，`handled[scan]` 在 scan ≥ NVOICE 时就越界了：
    //    读出来是 x、写进去被丢掉 → 【KEY[4..7] 永远分配不到声部】。
    //    症状：按 KEY[0..3] 里的一两个键有声音，再按 KEY[4..7] 完全没反应。
    //    这个 bug 躲过了之前的测试，因为那些测试只用了 KEY[0..2]。
    reg [NKEY-1:0]   handled;
    reg [IW-1:0]     scan;
    reg [VW-1:0]     rr;

    integer v, k;

    function [NVOICE-1:0] pick;                 // 取最低的置位位（独热）
        input [NVOICE-1:0] x;
        integer i;
        begin
            pick = {NVOICE{1'b0}};
            for (i = NVOICE-1; i >= 0; i = i - 1)
                if (x[i]) pick = ({{(NVOICE-1){1'b0}}, 1'b1} << i);
        end
    endfunction

    wire [NVOICE-1:0] is_free;
    genvar g;
    generate
        for (g = 0; g < NVOICE; g = g + 1) begin : g_free
            assign is_free[g] = (v_key[g] == KEY_FREE);
        end
    endgenerate
    wire [NVOICE-1:0] rr_hot  = ({{(NVOICE-1){1'b0}}, 1'b1} << rr);

    // ★ 两级可复用声部（保护期内不参与分配）
    //   idle_ok：包络已衰到 0（含从未分配过的声部）
    //   rel_ok ：已松键、但余音还在响 —— 开了延音后这才是普遍状态
    //   ★ 注意：松键时 v_key 会被置成 KEY_FREE（见下方 189 行），
    //     所以【不能】用 is_free 判断“是否在释放”，必须用 v_idle。
    wire [NVOICE-1:0] idle_ok = v_idle  & ~rel_hold;
    wire [NVOICE-1:0] rel_ok  = ~v_gate & ~v_idle & ~rel_hold;

    // ★★ 三级候选：静音 → 释放中的余音 → 丢音
    //    第三级是延音功能必需的：开了延音后余音会长期占住声部，
    //    只靠 idle 一级会在弹到第 9 个音时大量丢音。
    //    add_voice8 收到 trig 会先做 1.7 ms 淡出再装载（fading），
    //    所以抢「已在释放」的声部不会爆音，只会收掉一段已经变轻的余音。
    //    ★ 按住的键（v_gate=1）永远不抢。
    wire [NVOICE-1:0] cand     = (|idle_ok)   ? idle_ok   :
                                 (|rel_ok)    ? rel_ok    :
                                                {NVOICE{1'b0}};
    wire [NVOICE-1:0] vsel_oh  = pick(cand);

    wire [3:0] step     = key_step[ (scan*4) +: 4 ];
    // ★ 4'hF = 无效步长哨兵：该键在本乐器音阶里不存在
    wire       step_ok  = (step != 4'hF);

    // ★ 移调就加在这一处：之后 v_note 就是真实音高，
    //   add_engine8 的 v_note_off 自动跟着变，音色表自动选对，不用另做处理。
    wire signed [8:0] note_raw = $signed({2'b00, note_base})
                               + $signed({5'b00000, step})
                               + $signed({{1{transpose[7]}}, transpose});
    // 双保险：万一移调值越界也只钳到合法 MIDI 范围，绝不回绕
    wire [6:0] new_note = (note_raw < 9'sd0)   ? 7'd0   :
                          (note_raw > 9'sd127) ? 7'd127 :
                                                 note_raw[6:0];

    // ★ 只有「本乐器有这个音」的键才参与分配（音阶里没有的键按下也不响应）
    //   ★ 注意：不能把 step_ok 并进来！step_ok 属于【当前扫描的那一个键】，
    //     写进 ks 会把其它键一起屏蔽掉。step_ok 只在轮询处单独用。
    wire [NKEY-1:0] ks = key_state & key_enable;

    always @(posedge clk) begin
        if (!rst_n) begin
            handled <= {NKEY{1'b0}};
            scan    <= {IW{1'b0}};
            rr      <= {VW{1'b0}};
            v_trig  <= {NVOICE{1'b0}};
            v_gate  <= {NVOICE{1'b0}};
            v_note  <= {NVOICE{7'd60}};
            v_vel   <= {NVOICE{8'd128}};
            rel_hold <= {NVOICE{1'b0}};
            for (v = 0; v < NVOICE; v = v + 1) begin
                v_key[v] <= KEY_FREE;
                rel_t[v] <= 25'd0;
            end
            for (k = 0; k < NKEY; k = k + 1) key_lock[k] <= 23'd0;
        end
        else begin
            v_trig <= {NVOICE{1'b0}};

            // ── 力度跟随：把当前按住的那个键的力度同步给声部 ───────
            //    ★ 注意时序：分配发生在 ARMED（前触点一闭合、0 延迟），
            //      而真正力度要等后触点确认（几 ms 后）才出来。
            //      所以这里必须【持续跟随】，不能只在分配那一拍拷贝。
            //      add_voice8 的 ramp 会向 vel_gain 收敛，力度一出来就生效。
            for (v = 0; v < NVOICE; v = v + 1)
                if (v_key[v] != KEY_FREE)
                    v_vel[v*8 +: 8] <= key_vel[ v_key[v]*8 +: 8 ];

            // ── 每键锁定窗倒计时 ────────────────────────────────────
            for (k = 0; k < NKEY; k = k + 1)
                if (key_lock[k] != 23'd0) key_lock[k] <= key_lock[k] - 23'd1;

            // ── 松键：gate 拉低 + 启动余音保护期 ───────────────────
            for (v = 0; v < NVOICE; v = v + 1) begin
                if ((v_key[v] != KEY_FREE) && !ks[ v_key[v] ]) begin
                    v_gate[v]   <= 1'b0;
                    v_key[v]    <= KEY_FREE;
                    rel_hold[v] <= 1'b1;          // ★ 余音未散，暂不可抢
                    rel_t[v]    <= REL_TICKS;
                end
                else if (rel_hold[v]) begin
                    if (rel_t[v] <= 25'd1) begin
                        rel_hold[v] <= 1'b0;      // 保护期结束，可以分配了
                        rel_t[v]    <= 25'd0;
                    end
                    else
                        rel_t[v] <= rel_t[v] - 25'd1;
                end
            end

            // ── 轮询按键：每个时钟看一个键 ─────────────────────────
            //   ★ 用 ks（已屏蔽本乐器不存在的音）而不是原始 key_state
            if (ks[scan] && step_ok && !handled[scan] &&
                (key_lock[scan] == 23'd0) && (|cand)) begin
                handled[scan]  <= 1'b1;
                key_lock[scan] <= RELOCK;       // ★ 40 ms 内同一键不再触发
                for (v = 0; v < NVOICE; v = v + 1) begin
                    if (vsel_oh[v]) begin
                        v_note[v*7 +: 7] <= new_note;
                        v_key[v]         <= scan;
                        v_trig[v]        <= 1'b1;
                        v_gate[v]        <= 1'b1;
                        v_vel[v*8 +: 8]  <= key_vel[scan*8 +: 8];
                    end
                end
                rr <= (rr == RR_MAX) ? {VW{1'b0}} : rr + 1'b1;
            end
            if (!ks[scan]) handled[scan] <= 1'b0;

            scan <= scan + { {(IW-1){1'b0}}, 1'b1 };
        end
    end

endmodule

`default_nettype wire
