//==========================================================================
//  note_alloc —— 把 8 个按键分配成 4 个声部的 note / trig / gate
//
//  ⚠️ 本模块【只管一件事】：按键 → 声部分配。不含音色、不含发声。
//     对应 pcm5102a 工程里的 poly_engine.v，但接口不同：
//     这里输出的是 MIDI 音号 + 触发脉冲 + 按住电平，
//     而不是频率字 —— 因为加法引擎每个分量都要按音号去查参数表。
//
//  ── 分配优先级（从高到低）────────────────────────────────────────
//      1. 未被按住且 idle 的声部
//      2. 已松开的余音声部（优先轮转指针），先淡出再换表
//      3. 全被按住时等待松键；绝不抢仍被按住的音
//
//  ── 为什么不能省掉消抖 ───────────────────────────────────────────
//      一次机械按下会抖出几十个边沿。不消抖的话一次按键会把 4 个声部
//      瞬间全抢光，听起来像噪声。演奏键独立稳定确认在 key_scan.v 完成。
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

    localparam integer  IW       = (NKEY <= 1) ? 1 : $clog2(NKEY);
    // ★ 声部索引位宽：原来是写死的 [1:0]，只能覆盖 4 个声部。
    //   NVOICE=8 时 rr 只能取 0~3 → 声部 4~7 永远轮不到（轮询指针卡住）。
    localparam integer  VW       = (NVOICE <= 1) ? 1 : $clog2(NVOICE);
    // Ownership must represent NKEY distinct keys plus an unowned value.
    // With eight keys, a 3-bit 7 sentinel collides with the last real key and
    // prevents its gate from ever releasing.
    localparam integer KW = (NKEY <= 1) ? 1 : $clog2(NKEY + 1);
    localparam [KW-1:0] KEY_FREE = {KW{1'b1}};
    localparam [VW-1:0] RR_MAX   = NVOICE - 1;

    reg [KW-1:0]     v_key [0:NVOICE-1];
    // Debounced state owns the retrigger policy: one trigger per held key,
    // rearmed only by a confirmed release. No fixed 120ms lockout.
    // Released voices can be reused immediately; the engine fades them with
    // their OLD cache before allowing DMA to replace their parameters.
    // ★★ handled 是【每个按键】一位，所以必须是 NKEY 位，不是 NVOICE 位！
    //    写成 [NVOICE-1:0] 的话，`handled[scan]` 在 scan ≥ NVOICE 时就越界了：
    //    读出来是 x、写进去被丢掉 → 【KEY[4..7] 永远分配不到声部】。
    //    症状：按 KEY[0..3] 里的一两个键有声音，再按 KEY[4..7] 完全没反应。
    //    这个 bug 躲过了之前的测试，因为那些测试只用了 KEY[0..2]。
    reg [NKEY-1:0]   handled;
    reg [IW-1:0]     scan;
    reg [VW-1:0]     rr;

    integer v;

    function [NVOICE-1:0] pick;                 // 取最低的置位位（独热）
        input [NVOICE-1:0] x;
        integer i;
        begin
            pick = {NVOICE{1'b0}};
            for (i = NVOICE-1; i >= 0; i = i - 1)
                if (x[i]) pick = ({{(NVOICE-1){1'b0}}, 1'b1} << i);
        end
    endfunction

    // A newly assigned voice may still report idle until DMA/load finishes.
    // Gate reserves it immediately, preventing a chord from overwriting it.
    wire [NVOICE-1:0] idle_ok = ~v_gate & v_idle;
    wire [NVOICE-1:0] rel_ok = ~v_gate & ~v_idle;
    wire [NVOICE-1:0] cand = (|idle_ok) ? idle_ok : rel_ok;
    // Rotate released tails; never steal any key that is still held.
    wire [NVOICE-1:0] rr_hot = ({{(NVOICE-1){1'b0}}, 1'b1} << rr);
    wire [NVOICE-1:0] vsel_oh = (|idle_ok) ? pick(idle_ok) :
        ((|(rel_ok & rr_hot)) ? rr_hot : pick(rel_ok));

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
            for (v = 0; v < NVOICE; v = v + 1) begin
                v_key[v] <= KEY_FREE;
            end
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
                    v_vel[v*8 +: 8] <= key_vel[ v_key[v][IW-1:0]*8 +: 8 ];

            // Confirmed release drops gate immediately and rearms this key.
            for (v = 0; v < NVOICE; v = v + 1) begin
                if ((v_key[v] != KEY_FREE) && !ks[v_key[v][IW-1:0]]) begin
                    v_gate[v] <= 1'b0;
                    v_key[v] <= KEY_FREE;
                end
            end

            // ── 轮询按键：每个时钟看一个键 ─────────────────────────
            //   ★ 用 ks（已屏蔽本乐器不存在的音）而不是原始 key_state
            if (ks[scan] && step_ok && !handled[scan] &&
                (|cand)) begin
                handled[scan]  <= 1'b1;
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

            scan <= (scan == NKEY-1) ? 0 : scan + 1'b1;
        end
    end

endmodule

`default_nettype wire
