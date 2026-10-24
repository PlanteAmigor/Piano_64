//==========================================================================
//  add_voice —— 一个【加法合成】声部：NPART 个正弦分量，逐分量独立频率/幅度/包络
//
//  ⚠️ 本模块【只管一件事】：给定一个 MIDI 音号，把它所有分量的和算出来。
//     不含按键、不含声部分配、不含 I2S。
//
//  ── 合成模型（两种音色共用，靠 ATK 参数开关起音项）─────────────
//      s(t) = Σ_n A_n(t)·sin(2π·f_n·t + φ_n)
//      A_n(t) = (1 − e^(−t/τ_rn))^ATK · a_n·[ w_n·e^(−t/τ1n) + (1−w_n)·e^(−t/τ2n) ]
//               └──── 起音上升 ────┘
//        · 钢琴：τ_rn 全填 0 → 起音项恒为 1（等于没有），和以前完全一样
//        · 古筝：τ_rn 逐泛音不同（2.7 ms ~ 149 ms）——拨弦后弦要几个周期才建立振动，
//                低音弦的基频要十几毫秒才起来，高次泛音快得多。
//                少了这一项，古筝听起来就是「电子琴」，一点不「铮铮」。
//      ATK 是编译期开关。★ 关掉它时 τ_r 的乘法/状态会被综合器整个裁掉，
//      钢琴音色不花这份资源。
//
//  ── 时分复用：为什么一个声部只要一套乘法器 ───────────────────────
//      50 MHz ÷ 48828.125 Hz = 【1024 个主时钟 / 输出样点】
//      32 个分量 → 每个分量分到 32 拍，而它只需要约 18 拍。
//
//  ── 时间表（s = cnt[4:0]）────────────────────────────────────────
//      s=0  地址 = p（参数 ROM + 状态 RAM 同时读）
//      s=1  数据有效：ph_n = ph + inc，laddr = ph_n[31:22]
//      s=2  正弦 ROM 采样 laddr            s=3  sw <= {s1,s0}
//      s=4  ds = s1−s0，fr = ph_n[21:12]   s=5  itp = ds×fr
//      s=6  sv = s0 + itp_s；amp1/amp2_r = e[31:16]
//      s=7  dif = amp1−amp2_r                s=8  wt = dif×w8
//      s=9  amp = amp2_r + wt_s
//      s=10 pa  = amp × er_hi              s=11 amp_r = pa>>16   ★起音项
//      s=12 pr  = sv × amp_r
//      s=13 acc += pr_s；dec1/dec2/der
//      s=14 e1n/e2n/ern                    s=15 组装状态写数据
//      （16 写回） s=17..31 空
//
//  ── 包络的定点格式（32bit，满刻度 2^32）──────────────────────────
//      衰减： env ← env − ((env[31:8]·R  + 2^23) >> 24)     R=round(2^32/(τ·fs))
//      起音： er  ← er  + (((2^32−er)[31:8]·Rr + 2^23) >> 24)
//      ★ env 必须 32 位：R 只有 21 位有效，16 位包络下慢衰减的速率量化
//        误差有 4%，4 秒后幅度偏 −47 dBFS。32 位后最差 −118 dBFS。
//
//  ── 装载：必须对齐到样点周期开头（cnt==0）────────────────────────
//      否则 32 个槽横跨两个样点周期，靠前的分量比靠后的多走一整个样点的相位。
//
//  ── ★★ 位选（part-select）在 Verilog 里永远是无符号的！───────────
//      下面所有切片都套了 $signed()。漏掉的话负值会变成大正数，
//      症状是输出恒为饱和值 32767，而且每次仿真结果还不一样。
//==========================================================================
`default_nettype none

module add_voice #(
    parameter integer ROM_AW  = 13,        // 参数 ROM 地址宽度（88 音 × 64 分量 = 5632 → 13 位）
    parameter integer NPART   = 64,        // 分量数（50MHz 下的物理上限：1024/16 = 64）
    parameter integer NOTE_LO = 36,        // 音域下限（古筝 36，钢琴 21）
    parameter integer NOTE_HI = 88,        // 音域上限
    parameter integer ATK     = 1,         // 1 = 启用起音上升项（古筝）
    parameter integer TIMBRE  = 1,         // 1 = 古筝  0 = 钢琴（选哪张 ROM）
    parameter integer ROM_DEPTH = 1696
)(
    input  wire                clk,
    input  wire                rst_n,

    input  wire [6:0]          note,
    input  wire                trig,
    input  wire                gate,

    output reg  signed [15:0]  sample,
    output reg                 idle
);

    localparam [6:0] NLO = NOTE_LO[6:0];
    localparam [6:0] NHI = NOTE_HI[6:0];
    localparam [5:0] P_LAST = NPART - 1;

    // ════════════════════════════════════════════════════════════════
    //  时钟节拍：1024 拍 = 一个输出样点
    // ════════════════════════════════════════════════════════════════
    reg [9:0] cnt;
    // ★ NPART=64：每分量 16 拍（1024/64），流水线正好 16 级，零余量
    wire [5:0] p = cnt[9:4];
    wire [3:0] s = cnt[3:0];

    always @(posedge clk) begin
        if (!rst_n) cnt <= 10'd0;
        else        cnt <= cnt + 10'd1;
    end

    // ════════════════════════════════════════════════════════════════
    //  参数 ROM：地址 = (note − NOTE_LO) × 32 + p
    // ════════════════════════════════════════════════════════════════
    wire [6:0] note_c = (note < NLO) ? NLO : (note > NHI) ? NHI : note;
    wire [ROM_AW-1:0] rom_addr = { (note_c - NLO), p };

    // ★ 不能用文件名参数（iverilog 不支持），改成两份 ROM 模块 + generate 选
    wire [31:0] pd0, pd1, pd2;
    generate
    if (TIMBRE == 1) begin : g_gzrom
        guzheng_param_rom #(.ADDR_W(ROM_AW), .DEPTH(ROM_DEPTH)) u_param (
            .clk(clk), .addr(rom_addr),
            .d0(pd0), .d1(pd1), .d2(pd2));
    end
    else begin : g_pfrom
        piano_param_rom #(.ADDR_W(ROM_AW), .DEPTH(ROM_DEPTH)) u_param (
            .clk(clk), .addr(rom_addr),
            .d0(pd0), .d1(pd1), .d2(pd2));
    end
    endgenerate

    // bank0 = inc   bank1 = R1（满 32 位）   bank2 = {a16, phi8, 8'b0}
    // ★★ 模态模型 w ≡ 1：w8 恒 255 只用 e1，所以 R2/Rr 都不需要存。
    //    R2 直接绑成 R1 的低 24 位 → e2 恒等于 e1 → dif=0 → amp=amp1。
    wire [31:0] inc  = pd0;
    wire [31:0] R1   = pd1;
    wire [7:0]  phi8 = pd2[15:8];
    wire [15:0] a16  = pd2[31:16];
    wire [24:0] Rr   = 25'd1;           // ATK=0，起音项不用

    // ════════════════════════════════════════════════════════════════
    //  正弦表
    // ════════════════════════════════════════════════════════════════
    reg  [9:0]  laddr;
    wire [31:0] sw_raw;
    add_sine_lut u_sine (.clk(clk), .addr(laddr), .dout(sw_raw));

    // ════════════════════════════════════════════════════════════════
    //  逐分量状态 RAM：32 项 × {phase, env1, env2, env_rise}
    // ════════════════════════════════════════════════════════════════
    reg [31:0] st_ph [0:NPART-1];
    reg [31:0] st_e1 [0:NPART-1];
    reg [31:0] st_er [0:NPART-1];

    reg [31:0] ph_q, e1_q, er_q;
    reg        st_we;
    reg [5:0]  st_wa;
    reg [31:0] st_wp, st_w1, st_wr;
    reg        clr;

    always @(posedge clk) begin
        if (!rst_n) begin
            ph_q <= 32'd0; e1_q <= 32'd0; er_q <= 32'd0;
        end
        else begin
            ph_q <= st_ph[p];
            e1_q <= st_e1[p];
            er_q <= st_er[p];

            if (clr) begin
                st_ph[cnt[5:0]] <= 32'd0;
                st_e1[cnt[5:0]] <= 32'd0;
                st_er[cnt[5:0]] <= 32'd0;
            end
            else if (st_we) begin
                st_ph[st_wa] <= st_wp;
                st_e1[st_wa] <= st_w1;
                st_er[st_wa] <= st_wr;
            end
        end
    end

    // ════════════════════════════════════════════════════════════════
    //  流水线寄存器
    // ════════════════════════════════════════════════════════════════
    reg  [31:0] ph_n;
    reg  [31:0] sw;
    reg  signed [17:0] ds;
    reg  [9:0]  fr;
    reg  signed [28:0] itp;
    reg  signed [17:0] sv;
    reg  [16:0] amp1, amp1_r, amp2_r;
    reg  [16:0] amp;
    reg  [33:0] pa;                    // amp × er_hi
    reg  [15:0] ampr;                  // 起音项乘完的幅度
    reg  signed [34:0] pr;
    reg  signed [23:0] acc;
    reg  [31:0] dec1;
    reg  [26:0] der;
    reg  [31:0] e1n, ern;

    reg        pending, loading, ready;
    reg [5:0]  load_cnt;

    localparam [31:0] R_REL = 32'd293000;   // 松开：固定快释放（0.30 s）
    // ★★ 时序：gate 在 add_top 里由 song_on(←mode) 多路选择而来，
    //    不打断的话「mode → song_on → v_gate → rel → R1_eff(32位mux) →
    //    24×32 乘法器 → 56 位加法 → 包络」是一条长组合链（实测 −9.2 ns）。
    //    gate 本来就在样点边界变化，打一拍无影响。
    reg               gate_r;
    always @(posedge clk) gate_r <= gate;
    wire              rel    = ~gate_r;
    wire [31:0]       R1_eff = rel ? R_REL : R1;

    // ── 位宽对齐的中间量（★ 一律套 $signed，位选是无符号的！）──────
    wire signed [17:0] itp_s = $signed(itp[27:10]);   // = (itp >>> 10)
    wire signed [23:0] pr_s  = $signed(pr[34:16]);    // = (pr  >>> 16)

    // 衰减量 dec = round(env[31:8]·R / 2^24)
    wire [55:0] dpr1 = e1_q[31:8] * R1_eff;     // 24 × 32 = 56 位
    wire [31:0] dcd1 = (dpr1 + 56'h00_800000) >> 24;

    // ★ 起音：er ← er + (2^32 − er)·Rr/2^32
    wire [32:0] rem  = 33'h1_0000_0000 - {1'b0, er_q};        // 2^32 − er
    wire [49:0] dprr = rem[32:8] * Rr;                        // 25×25
    wire [26:0] dcdr = (dprr + 50'h00_800000) >> 24;

    // 起音项 ampr = amp × er / 2^16（只取 er 的高 16 位，精度足够）
    wire [33:0] pa_c  = amp * {1'b0, er_q[31:16]};
    wire [15:0] ampr_c = pa_c[31:16];

    always @(posedge clk) begin
        if (!rst_n) begin
            ph_n <= 32'd0; sw <= 32'd0; ds <= 18'sd0; fr <= 10'd0;
            itp <= 29'sd0; sv <= 18'sd0; amp1 <= 17'd0; amp2_r <= 17'd0;
            amp <= 17'd0; pa <= 34'd0;
            ampr <= 16'd0; pr <= 35'sd0;
            acc <= 24'sd0; dec1 <= 25'd0; der <= 27'd0;
            e1n <= 32'd0; ern <= 32'd0;
            st_we <= 1'b0; st_wa <= 6'd0;
            st_wp <= 32'd0; st_w1 <= 32'd0; st_wr <= 32'd0;
            laddr <= 10'd0;
            sample <= 16'sd0;
            pending <= 1'b0; loading <= 1'b0; load_cnt <= 6'd0;
            clr <= 1'b1; ready <= 1'b0; idle <= 1'b1;
        end
        else begin
            st_we <= 1'b0;

            if (clr && (cnt[3:0] == 4'd15)) clr <= 1'b0;

            // ── note-on：等周期边界再装载 ─────────────────────────
            if (trig) pending <= 1'b1;

            if (pending && (cnt == 10'd0)) begin
                pending  <= 1'b0;
                loading  <= 1'b1;
                load_cnt <= 6'd0;
            end
            else if (loading && (s == 4'd15)) begin      // 每分量一次，一个样点内载完
                if (load_cnt == P_LAST) begin
                    loading <= 1'b0;
                    ready   <= 1'b1;
                end
                else
                    load_cnt <= load_cnt + 6'd1;
            end

            case (s)
                4'd1: begin
                    ph_n  <= ph_q + inc;
                    laddr <= (ph_q + inc) >> 22;
                end
                4'd3:  sw <= sw_raw;
                4'd4: begin
                    ds <= $signed(sw[31:16]) - $signed(sw[15:0]);
                    fr <= ph_n[21:12];
                end
                4'd5:  itp <= ds * $signed({1'b0, fr});
                4'd6: begin
                    sv   <= $signed(sw[15:0]) + itp_s;
                    amp1 <= e1_q[31:16];
                end
                // ★ w≡1 → 直接用 amp1，原来的 dif/wt/加法三级改成直通打拍
                4'd7:  amp1_r <= amp1;
                4'd8:  amp2_r <= amp1_r;
                4'd9:  amp   <= amp2_r;
                4'd10: pa  <= ATK ? pa_c : {1'b0, amp, 16'd0};
                4'd11: ampr <= ATK ? ampr_c : amp[15:0];
                4'd12: pr  <= sv * $signed({1'b0, ampr});
                4'd13: begin
                    dec1 <= dcd1;
                    der  <= ATK ? dcdr : 27'd0;
                end
                4'd14: begin
                    e1n <= e1_q - dec1;
                    ern <= ATK ? (er_q + {5'b0, der}) : 32'hFFFF_FFFF;
                end
                4'd15: begin
                    st_we <= 1'b1;
                    st_wa <= p;
                    if (loading) begin
                        st_wp <= { phi8, 24'd0 };
                        st_w1 <= { a16, 16'd0 };
                        st_wr <= ATK ? 32'd0 : 32'hFFFF_FFFF;   // 起音从 0 开始
                    end
                    else begin
                        st_wp <= ph_n;
                        st_w1 <= e1n;
                        st_wr <= ern;
                    end
                end
                default: ;
            endcase

            if ((s == 4'd13) && !loading && ready)
                acc <= acc + pr_s;

            if (cnt == 10'd1023) begin
                sample <= (loading || !ready) ? 16'sd0 : sat16(acc);
                acc    <= 24'sd0;
            end

            idle <= (e1_q[31:16] == 16'd0);
        end
    end

    function signed [15:0] sat16; input signed [23:0] x;
        begin
            if      (x >  24'sd32767) sat16 =  16'sd32767;
            else if (x < -24'sd32768) sat16 = -16'sd32768;
            else                      sat16 = x[15:0];
        end
    endfunction

endmodule

`default_nettype wire
