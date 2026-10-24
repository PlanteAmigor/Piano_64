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
//  ── 按键布局（改这一行就能换音阶，别的模块一律不动）─────────────
//      KEY_STEP：每个键相对 NOTE_BASE 的半音偏移，4bit/键（0..15）
//      默认 = 0,2,4,5,7,9,11,12 → 大调音阶 do re mi fa sol la si do
//==========================================================================
`default_nettype none

module note_alloc #(
    parameter integer NKEY      = 8,
    parameter integer NVOICE    = 4,
    parameter integer NOTE_BASE = 60,               // C4 = MIDI 60
    parameter [NKEY*4-1:0] KEY_STEP = {4'd12, 4'd11, 4'd9, 4'd7, 4'd5, 4'd4, 4'd2, 4'd0}
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [NKEY-1:0]          key_state,      // 1 = 按下
    input  wire [NVOICE-1:0]        v_idle,         // 来自 add_voice

    output reg  [NVOICE*7-1:0]      v_note,         // 每个声部的 MIDI 音号
    output reg  [NVOICE-1:0]        v_trig,         // note-on 脉冲
    output reg  [NVOICE-1:0]        v_gate          // 1 = 按住
);

    localparam integer  IW       = $clog2(NKEY);
    localparam [IW-1:0] KEY_FREE = {IW{1'b1}};
    localparam [1:0]    RR_MAX   = NVOICE - 1;

    reg [IW-1:0]     v_key [0:NVOICE-1];
    // ★★ handled 是【每个按键】一位，所以必须是 NKEY 位，不是 NVOICE 位！
    //    写成 [NVOICE-1:0] 的话，`handled[scan]` 在 scan ≥ NVOICE 时就越界了：
    //    读出来是 x、写进去被丢掉 → 【KEY[4..7] 永远分配不到声部】。
    //    症状：按 KEY[0..3] 里的一两个键有声音，再按 KEY[4..7] 完全没反应。
    //    这个 bug 躲过了之前的测试，因为那些测试只用了 KEY[0..2]。
    reg [NKEY-1:0]   handled;
    reg [IW-1:0]     scan;
    reg [1:0]        rr;

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

    wire [NVOICE-1:0] is_free;
    genvar g;
    generate
        for (g = 0; g < NVOICE; g = g + 1) begin : g_free
            assign is_free[g] = (v_key[g] == KEY_FREE);
        end
    endgenerate
    wire [NVOICE-1:0] rr_hot  = ({{(NVOICE-1){1'b0}}, 1'b1} << rr);

    wire [NVOICE-1:0] cand     = (|is_free)   ? is_free   :
                                 (|(~v_idle)) ? (~v_idle) :
                                                 rr_hot;
    wire [NVOICE-1:0] vsel_oh  = pick(cand);

    wire [3:0] step     = KEY_STEP[ (scan*4) +: 4 ];
    wire [6:0] new_note = NOTE_BASE[6:0] + {3'b000, step};

    always @(posedge clk) begin
        if (!rst_n) begin
            handled <= {NKEY{1'b0}};
            scan    <= {IW{1'b0}};
            rr      <= 2'd0;
            v_trig  <= {NVOICE{1'b0}};
            v_gate  <= {NVOICE{1'b0}};
            v_note  <= {NVOICE{7'd60}};
            for (v = 0; v < NVOICE; v = v + 1) v_key[v] <= KEY_FREE;
        end
        else begin
            v_trig <= {NVOICE{1'b0}};

            // ── 松键：gate 拉低，声部标记为空闲（余音继续自然衰减）──
            for (v = 0; v < NVOICE; v = v + 1) begin
                if ((v_key[v] != KEY_FREE) && !key_state[ v_key[v] ]) begin
                    v_gate[v] <= 1'b0;
                    v_key[v]  <= KEY_FREE;
                end
            end

            // ── 轮询按键：每个时钟看一个键 ─────────────────────────
            if (key_state[scan] && !handled[scan]) begin
                handled[scan] <= 1'b1;
                for (v = 0; v < NVOICE; v = v + 1) begin
                    if (vsel_oh[v]) begin
                        v_note[v*7 +: 7] <= new_note;
                        v_key[v]         <= scan;
                        v_trig[v]        <= 1'b1;
                        v_gate[v]        <= 1'b1;
                    end
                end
                rr <= (rr == RR_MAX) ? 2'd0 : rr + 2'd1;
            end
            if (!key_state[scan]) handled[scan] <= 1'b0;

            scan <= scan + { {(IW-1){1'b0}}, 1'b1 };
        end
    end

endmodule

`default_nettype wire
