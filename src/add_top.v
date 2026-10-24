//==========================================================================
//  piano64 —— 64 路加法分量钢琴，【只有按键发声模式】
//
//  与原工程（piano_twinkle_dac）完全一致的硬件：
//    · 按键：KEY[0..5]=do re mi fa sol la  KEY[7]=升八度 KEY[8]=降八度
//            KEY[6] 原为模式键，本工程只有一种模式 → 空闲不用
//    · 灯带：20 颗，只有 7 颗按键指示灯（按下亮、松开灭），其余全黑
//            第 5~11 颗（索引 4~10）：KEY[0]→索引10 … KEY[6]→索引4
//
//  去掉的：自动演奏、指导模式、音色切换、八度切换、常亮状态灯
//  分量数：每音 64 路（赛题拓展 1「单音加法分量 ≥32 路」）
//==========================================================================
`default_nettype none

module add_top #(
    parameter integer STARTUP  = 2_500_000,    // 上电静音 50 ms
    // ★ 消隐窗从 8 ms 加长到 20 ms：便宜的轻触开关抖动可达 10~20 ms，
    //   8 ms 挡不住会多出几次 key_press → 重触发 → 听感是"哒哒"噪音
    parameter integer DEBOUNCE = 1_000_000     // 按键消隐窗 20 ms
)(
    input  wire       CLOCK_50,   // 50 MHz 晶振 V22（先进 PLL）
    input  wire       RESET_n,
    input  wire [6:0] KEY,        // [0..5]=do re mi fa sol la  [6]=模式键，悬空=1 按下=0
    output wire       AUD_BCK,
    output wire       AUD_LRCK,
    output wire       AUD_DIN,
    output wire       DOUT        // WS2812
);

    localparam integer NVOICE    = 4;
    localparam integer MIX_SHIFT = 1;
    localparam [2:0]   M_FREE    = 3'd2;       // 只有这一种模式

    //======================================================================
    //  时钟：50 MHz → PLL → 全局时钟网（频率不变，只为降时钟偏斜）
    //======================================================================
    wire clk_sys, pll_lock;

    pll50 u_pll (
        .clk_in (CLOCK_50),
        .clk_out(clk_sys),
        .lock   (pll_lock)
    );

    //======================================================================
    //  复位 + 上电静音
    //======================================================================
    reg [21:0] por_cnt = 22'd0;
    always @(posedge clk_sys)
        if (por_cnt != STARTUP[21:0] - 22'd1) por_cnt <= por_cnt + 22'd1;

    wire por_n       = (por_cnt == STARTUP[21:0] - 22'd1);
    wire engine_rst_n = por_n & RESET_n & pll_lock;

    //======================================================================
    //  按键扫描（9 个引脚全接，功能见文件头）
    //======================================================================
    wire [6:0] key_state, key_press, key_release;

    key_scan #(
        .N        (7),
        .DEBOUNCE (DEBOUNCE),
        .IMMEDIATE(1)
    ) u_keys (
        .clk         (clk_sys),
        .rst_n       (engine_rst_n),
        .key_in      (KEY),
        .key_state   (key_state),
        .key_press   (key_press),
        .key_release (key_release)
    );

    wire [5:0] note_key_state = key_state[5:0];
    wire [5:0] note_key_press = key_press[5:0];

    //======================================================================
    //  模式：1=按键发声  2=指导·小星星  3=指导·欢乐颂
    //======================================================================
    localparam [1:0] MD_FREE  = 2'd1,
                     MD_TWIN  = 2'd2,
                     MD_ODE   = 2'd3;

    reg [1:0] mode;

    always @(posedge clk_sys) begin
        if (!engine_rst_n)          mode <= MD_FREE;
        else if (key_press[6])      mode <= (mode == MD_ODE) ? MD_FREE : mode + 2'd1;
    end

    //======================================================================
    //  曲谱表（MIDI 音号，范围正好是 C4~B4，对应 7 个键）
    //    小星星 42 音  欢乐颂 30 音
    //======================================================================
    reg [6:0] g_twinkle [0:41];
    reg [6:0] g_ode     [0:29];

    initial begin
        g_twinkle[ 0]=7'd60; g_twinkle[ 1]=7'd60; g_twinkle[ 2]=7'd67; g_twinkle[ 3]=7'd67;
        g_twinkle[ 4]=7'd69; g_twinkle[ 5]=7'd69; g_twinkle[ 6]=7'd67;
        g_twinkle[ 7]=7'd65; g_twinkle[ 8]=7'd65; g_twinkle[ 9]=7'd64; g_twinkle[10]=7'd64;
        g_twinkle[11]=7'd62; g_twinkle[12]=7'd62; g_twinkle[13]=7'd60;
        g_twinkle[14]=7'd67; g_twinkle[15]=7'd67; g_twinkle[16]=7'd65; g_twinkle[17]=7'd65;
        g_twinkle[18]=7'd64; g_twinkle[19]=7'd64; g_twinkle[20]=7'd62;
        g_twinkle[21]=7'd67; g_twinkle[22]=7'd67; g_twinkle[23]=7'd65; g_twinkle[24]=7'd65;
        g_twinkle[25]=7'd64; g_twinkle[26]=7'd64; g_twinkle[27]=7'd62;
        g_twinkle[28]=7'd60; g_twinkle[29]=7'd60; g_twinkle[30]=7'd67; g_twinkle[31]=7'd67;
        g_twinkle[32]=7'd69; g_twinkle[33]=7'd69; g_twinkle[34]=7'd67;
        g_twinkle[35]=7'd65; g_twinkle[36]=7'd65; g_twinkle[37]=7'd64; g_twinkle[38]=7'd64;
        g_twinkle[39]=7'd62; g_twinkle[40]=7'd62; g_twinkle[41]=7'd60;

        g_ode[ 0]=7'd64; g_ode[ 1]=7'd64; g_ode[ 2]=7'd65; g_ode[ 3]=7'd67;
        g_ode[ 4]=7'd67; g_ode[ 5]=7'd65; g_ode[ 6]=7'd64; g_ode[ 7]=7'd62;
        g_ode[ 8]=7'd60; g_ode[ 9]=7'd60; g_ode[10]=7'd62; g_ode[11]=7'd64;
        g_ode[12]=7'd64; g_ode[13]=7'd62; g_ode[14]=7'd62;
        g_ode[15]=7'd64; g_ode[16]=7'd64; g_ode[17]=7'd65; g_ode[18]=7'd67;
        g_ode[19]=7'd67; g_ode[20]=7'd65; g_ode[21]=7'd64; g_ode[22]=7'd62;
        g_ode[23]=7'd60; g_ode[24]=7'd60; g_ode[25]=7'd62; g_ode[26]=7'd64;
        g_ode[27]=7'd62; g_ode[28]=7'd60; g_ode[29]=7'd60;
    end

    //======================================================================
    //  指导：按对当前音才前进，灯带指出"当前该按"和"再下一个"
    //======================================================================
    reg [5:0] guide_step;

    wire       use_ode       = (mode == MD_ODE);
    wire       in_guide      = (mode != MD_FREE);
    wire [5:0] guide_len     = use_ode ? 6'd30 : 6'd42;
    wire [5:0] guide_step_p  = guide_step + 6'd1;
    wire [5:0] guide_step_nx = (guide_step_p >= guide_len) ? 6'd0 : guide_step_p;

    wire [6:0] guide_note  = use_ode ? g_ode[guide_step]     : g_twinkle[guide_step];
    wire [6:0] guide_note2 = use_ode ? g_ode[guide_step_nx]  : g_twinkle[guide_step_nx];

    // MIDI 音号 → 键序号（C4 D4 E4 F4 G4 A4 B4 = 60 62 64 65 67 69 71）
    function [2:0] note2key;
        input [6:0] n;
        begin
            case (n)
                7'd60:   note2key = 3'd0;   // do
                7'd62:   note2key = 3'd1;   // re
                7'd64:   note2key = 3'd2;   // mi
                7'd65:   note2key = 3'd3;   // fa
                7'd67:   note2key = 3'd4;   // sol
                7'd69:   note2key = 3'd5;   // la
                default: note2key = 3'd0;
            endcase
        end
    endfunction

    wire [2:0] guide_key  = note2key(guide_note);    // 当前该按（亮）
    wire [2:0] guide_key2 = note2key(guide_note2);   // 再下一个音（暗预告）

    // ★ 必须用"模式发生变化"判断，不能用"进入指导态"：
    //   模式2→3 都是指导态，用进入态判断会导致 step 不归零（原工程踩过）
    reg [1:0] mode_d;
    always @(posedge clk_sys) mode_d <= mode;
    wire enter_guide = in_guide && (mode != mode_d);

    always @(posedge clk_sys) begin
        if (!engine_rst_n)                    guide_step <= 6'd0;
        else if (enter_guide)                 guide_step <= 6'd0;
        else if (in_guide && note_key_press[guide_key])
            guide_step <= guide_step_nx;
    end

    //======================================================================
    //  复音分配：7 键 → 4 声部
    //======================================================================
    wire [NVOICE*7-1:0] k_note;
    wire [3:0]          v_trig, v_gate, v_idle;

    note_alloc #(
        .NKEY     (6),
        .NVOICE   (NVOICE),
        .NOTE_BASE(60),
        .KEY_STEP ({4'd9, 4'd7, 4'd5, 4'd4, 4'd2, 4'd0})
    ) u_alloc (
        .clk      (clk_sys),
        .rst_n    (engine_rst_n),
        
        .key_state(note_key_state),
        .v_idle   (v_idle),
        .v_note   (k_note),
        .v_trig   (v_trig),
        .v_gate   (v_gate)
    );

    //======================================================================
    //  加法合成引擎：128 分量/声部，4 声部共用一份参数 ROM
    //    ★ 与旧版（64 分量 × 16 级流水线）的区别见 src/add_voice8.v 文件头
    //      实测：关键路径 15.1 ns → 9.3 ns，共用 ROM 让 pROM 92 块 → 29 块
    //======================================================================
    //  音色选择（改这一个常量即可切换，参数表需同步放进工程根目录）
    //    0 = 钢琴：88 音 × 128 分量 = 11264 深 → add_param0/1/2.hex
    //    1 = 古筝：49 音 × 128 分量 =  6272 深 → gz_param0/1/2.hex
    localparam integer TIMBRE_SEL  = 0;
    localparam integer T_ROM_AW    = (TIMBRE_SEL == 1) ? 13 : 14;
    localparam integer T_ROM_DEPTH = (TIMBRE_SEL == 1) ? 6272 : 11264;
    localparam integer T_NOTE_LO   = (TIMBRE_SEL == 1) ? 38 : 21;
    localparam integer T_NOTE_HI   = (TIMBRE_SEL == 1) ? 86 : 108;

    wire               tick;
    wire signed [15:0] eng_l, eng_r;

    add_engine8 #(
        .NVOICE   (NVOICE),
        .NPART    (128),
        .ROM_AW   (T_ROM_AW),
        .ROM_DEPTH(T_ROM_DEPTH),
        .NOTE_LO  (T_NOTE_LO),
        .NOTE_HI  (T_NOTE_HI),
        .ATK      (0),
        .TIMBRE   (TIMBRE_SEL),
        .MIX_SHIFT(MIX_SHIFT)
    ) u_piano (
        .clk        (clk_sys),
        .rst_n      (engine_rst_n),
        .v_note     (k_note),
        .v_trig     (v_trig),
        .v_gate     (v_gate),
        .sample_tick(tick),
        .sample_l   (eng_l),
        .sample_r   (eng_r),
        .v_idle     (v_idle)
    );

    //======================================================================
    //  输出增益 ×4
    //    新表单音峰值 ≈1951：
    //      1 个音  →  1951×4 =  7804  = −12.5 dBFS
    //      4 个音  → 7804×4  = 31216  = −0.4 dBFS  ← 刚好不削顶
    //    ★ 原来用 ×8：4 个音 = 62432 = 满刻度的 1.9 倍 → 严重削波 → 刺耳噪音
    //======================================================================
    function signed [15:0] sat_gain;
        input signed [15:0] x;
        reg   signed [31:0] y;
        begin
            y = x <<< 2;      // ×4（原 ×8 会让 4 声部叠加削波）
            if      (y >  32'sd32767) sat_gain =  16'sd32767;
            else if (y < -32'sd32768) sat_gain = -16'sd32768;
            else                      sat_gain =  y[15:0];
        end
    endfunction

    //======================================================================
    //  灯带（布局与原工程一致）
    //======================================================================
    // ★★★ 灯带前 6 颗（索引 0~5）是坏灯（实测：第 6 颗往后完全正常）
    //     所以所有指示灯整体后移到索引 6 开始，前 6 颗永远发 0（保持黑）
    //       索引 5~10   = 6 个按键灯（KEY[5]→5 … KEY[0]→10）第 6~11 颗
    //       索引 11     = 乐器灯（白 = 钢琴）        第 12 颗
    //       索引 12     = 模式灯（红/绿/蓝）          第 13 颗
    ws2812_keyind #(
        .N_LED       (20),
        .LED_BASE    (10),          // KEY[0] → 索引 10（KEY[5] → 索引 5）
        .NKEY        (6),
        .BRIGHT_SHIFT(2),
        .TIMBRE_LED  (11),          // 乐器灯：索引 11（第 12 颗）
        .MODE_LED    (12),          // 模式灯：索引 12（第 13 颗）
        .DOT_EN      (0),
        .DIAG        (0)
    ) u_led (
        // ★★ 灯带时钟改用【CLOCK_50 直连】，和验证正常的 led_align 工程完全一致
        //    （PLL 输出 clk_sys 虽然频率相同，但相位/抖动不同，怀疑是卡死的原因）
        .clk       (CLOCK_50),
        .rst_n     (engine_rst_n),
        .key_state (note_key_state),
        .mode      ({1'b0, mode}),
        .guide_key (guide_key),
        .guide_key2(guide_key2),
        .timbre    (1'b0),          // 恒定钢琴 → 第 1 颗白
        .oct       (3'sd0),         // 本工程无八度，八度条已删
        .dout      (DOUT)
    );

    //======================================================================
    //  I2S
    //======================================================================
    pcm5102a_tx #(.DIV(16), .SLOTS(64)) u_tx (
        .clk        (clk_sys),
        .rst_n      (por_n),
        .sample_l   (sat_gain(eng_l)),
        .sample_r   (sat_gain(eng_r)),
        .sample_tick(tick),
        .bck        (AUD_BCK),
        .lrck       (AUD_LRCK),
        .din        (AUD_DIN)
    );

endmodule

`default_nettype wire
