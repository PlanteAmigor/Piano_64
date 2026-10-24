//==========================================================================
//  add_voice8 —— 8 级流水线加法声部（128 分量 / 声部）
//
//  这是 add_voice.v（16 级 / 64 分量）的替代版本，改动原因与效果：
//
//  ── 为什么 8 级而不是 16 级 ──────────────────────────────────────
//    原设计每分量分到 16 拍，但其中 s=7/8/9 三级是【纯打拍、零运算】
//    （模态模型 w≡1，双指数插值退化成直通）。实测删掉它们并把三个乘法
//    并行到同一级之后，关键路径从 15.1 ns 降到 9.3 ns，反而更宽松。
//    于是每分量只需 8 拍 → 分量数可以翻倍到 128（1024 / 8 = 128）。
//
//  ── 三个乘法并行（关键优化）──────────────────────────────────────
//        s=4:  itp = ds × fr      ‖ dec_raw = e1[31:8] × R1 ‖ amp_er = amp×er
//    原设计把 56 位衰减乘法 → 加法 → 打拍 → 减法串成一条长链，是瓶颈。
//
//  ── 时间表（s = cnt[2:0]，每分量 8 拍）───────────────────────────
//        s=0  参数 ROM / 状态 RAM 采样（组合地址 = {note, p}）
//        s=1  ph_n = ph + inc；laddr = ph_n[31:22]
//        s=2  sw_r <= 正弦表输出
//        s=3  ds = sw_hi − sw_lo；fr = ph_n[21:12]；sv0 = sw_lo
//        s=4  itp = ds×fr  ‖  dec_raw = e1[31:8]×R1  ‖  amp_er = (amp×er)>>16
//        s=5  sv = sv0 + itp_s；dec1 = (dec_raw+round)>>24
//        s=6  pr = sv × amp_er
//        s=7  acc += pr；e1n = e1 − dec1；状态写回
//
//  ── 相位错开（配合 add_engine8 的共用 ROM）────────────────────────
//    参数 ROM 改为端口输入，本声部通过 rom_addr/rom_req 提出读请求。
//    4 个声部的计数器初值 = G × PH_SHIFT（PH_SHIFT = 每分量拍数 / 声部数
//    = 8/4 = 2），于是 s 的相位依次错开 2 拍：
//        t%8=0 → s=(0,2,4,6)  只有 g0 在 s=0（发地址）
//        t%8=1 → s=(1,3,5,7)  只有 g0 在 s=1（收数据）
//    任意时刻至多一个声部处于 s==1 ⇒ ROM 数据可以【直接广播】，
//    不需要 tag 寄存器来判断数据归属。
//
//  ── ★★ 位选在 Verilog 里永远无符号，下面一律套 $signed() ──────────
//==========================================================================
`default_nettype none

module add_voice8 #(
    parameter integer G         = 0,        // 声部索引 0..NVOICE-1
    parameter integer NVOICE    = 4,
    parameter integer ROM_AW    = 14,       // 钢琴 88×128=11264 → 14 位；古筝 49×128=6272 → 13 位
    parameter integer NPART     = 128,
    parameter integer NOTE_LO   = 21,
    parameter integer NOTE_HI   = 108,
    parameter integer ATK       = 0
)(
    input  wire                clk,
    input  wire                rst_n,

    input  wire [6:0]          note,
    input  wire                trig,
    input  wire                gate,

    // ── 共用参数 ROM 接口 ──────────────────────────────────────────
    input  wire [31:0]         rd0,          // bank0 = inc
    input  wire [31:0]         rd1,          // bank1 = R1
    input  wire [31:0]         rd2,          // bank2 = {a16, phi8}
    output wire [ROM_AW-1:0]   rom_addr,
    output wire                rom_req,

    output reg  signed [15:0]  sample,       // 本声部在本样点的和（保持到下一个样点）
    output reg                 idle
);

    localparam [6:0] NLO = NOTE_LO[6:0];
    localparam [6:0] NHI = NOTE_HI[6:0];
    localparam [6:0] P_LAST = NPART - 1;
    // 相位错开量 = 每分量拍数 / 声部数 = (1024/NPART)/NVOICE
    localparam integer PH_SHIFT = (1024 / NPART) / NVOICE;

    // ════════════════════════════════════════════════════════════════
    //  本地计数器：初值 = G × PH_SHIFT，使各声部相位错开
    // ════════════════════════════════════════════════════════════════
    reg [9:0] cnt;
    wire [6:0] p = cnt[9:3];
    wire [2:0] s = cnt[2:0];

    always @(posedge clk) begin
        if (!rst_n) cnt <= G * PH_SHIFT;
        else        cnt <= cnt + 10'd1;
    end

    // ════════════════════════════════════════════════════════════════
    //  ROM 请求：s==0 时索要本分量的参数
    // ════════════════════════════════════════════════════════════════
    wire [6:0] note_c = (note < NLO) ? NLO : (note > NHI) ? NHI : note;
    assign rom_addr = { (note_c - NLO), p };
    assign rom_req  = (s == 3'd0);

    // ════════════════════════════════════════════════════════════════
    //  正弦表（每声部一份）
    // ════════════════════════════════════════════════════════════════
    reg  [9:0]  laddr;
    wire [31:0] sw_raw;
    add_sine_lut u_sine (.clk(clk), .addr(laddr), .dout(sw_raw));

    // ════════════════════════════════════════════════════════════════
    //  逐分量状态 RAM（相位 / 包络 / 起音），各声部独立
    // ════════════════════════════════════════════════════════════════
    reg [31:0] st_ph [0:NPART-1];
    reg [31:0] st_e1 [0:NPART-1];
    reg [31:0] st_er [0:NPART-1];

    reg [31:0] ph_q, e1_q, er_q;
    reg        st_we;
    reg [6:0]  st_wa;
    reg [31:0] st_wp, st_w1, st_wr;
    reg        clr;

    // ★ 仅仿真用：st_* 综合后是 BSRAM，上电内容未定义。真实硬件读出随机
    //   0/1，会被 loading 覆盖、acc 每样点清零，所以无害；但 iverilog 读出 X，
    //   而 X 在算术里会【永久传播】（X+1=X），导致仿真永远出不了声。
    `ifdef SIM_INIT
    integer si;
    initial begin
        for (si = 0; si < NPART; si = si + 1) begin
            st_ph[si] = 32'd0;
            st_e1[si] = 32'd0;
            st_er[si] = 32'd0;
        end
    end
    `endif

    always @(posedge clk) begin
        if (!rst_n) begin
            ph_q <= 32'd0; e1_q <= 32'd0; er_q <= 32'd0;
        end
        else begin
            ph_q <= st_ph[p];
            e1_q <= st_e1[p];
            er_q <= st_er[p];

            if (clr) begin
                st_ph[p] <= 32'd0;
                st_e1[p] <= 32'd0;
                st_er[p] <= 32'd0;
            end
            else if (st_we) begin
                st_ph[st_wa] <= st_wp;
                st_e1[st_wa] <= st_w1;
                st_er[st_wa] <= st_wr;
            end
        end
    end

    // ════════════════════════════════════════════════════════════════
    //  流水线寄存器（8 级）
    // ════════════════════════════════════════════════════════════════
    reg  [31:0] inc_r, R1_r, phi8_r, a16_r;
    reg  [31:0] ph_n;
    reg  [31:0] sw_r;
    reg  signed [17:0] ds;
    reg  [9:0]  fr;
    reg  signed [17:0] sv0;
    reg  signed [28:0] itp;
    reg  signed [17:0] sv;
    reg  [55:0] dec_raw;
    reg  [31:0] dec1;
    reg  [17:0] amp_er;
    reg  signed [34:0] pr;
    reg  signed [23:0] acc;
    reg  [31:0] e1n, ern;

    reg        pending, loading, ready;
    reg [6:0]  load_cnt;

    localparam [31:0] R_REL = 32'd293000;      // 松键：固定快释放（0.30 s）
    reg               gate_r;
    always @(posedge clk) gate_r <= gate;
    wire              rel    = ~gate_r;
    wire [31:0]       R1_eff = rel ? R_REL : R1_r;

    wire signed [17:0] itp_s = $signed(itp[27:10]);
    wire signed [23:0] pr_s  = $signed(pr[34:16]);
    wire [16:0]        amp   = e1_q[31:16];

    wire [55:0] dpr1 = e1_q[31:8] * R1_eff;                  // 24 × 32
    wire [32:0] rem  = 33'h1_0000_0000 - {1'b0, er_q};
    wire [49:0] dprr = rem[32:8] * {1'b0, 24'd1};            // 起音：Rr 固定 1
    wire [26:0] dcdr = (dprr + 50'h00_800000) >> 24;
    wire [33:0] pa_c = amp * {1'b0, er_q[31:16]};

    always @(posedge clk) begin
        if (!rst_n) begin
            inc_r <= 32'd0; R1_r <= 32'd0; phi8_r <= 32'd0; a16_r <= 32'd0;
            ph_n <= 32'd0; sw_r <= 32'd0; ds <= 18'sd0; fr <= 10'd0;
            sv0 <= 18'sd0; itp <= 29'sd0; sv <= 18'sd0;
            dec_raw <= 56'd0; dec1 <= 32'd0; amp_er <= 18'd0;
            pr <= 35'sd0; acc <= 24'sd0; e1n <= 32'd0; ern <= 32'd0;
            st_we <= 1'b0; st_wa <= 7'd0;
            st_wp <= 32'd0; st_w1 <= 32'd0; st_wr <= 32'd0;
            laddr <= 10'd0;
            sample <= 16'sd0;
            pending <= 1'b0; loading <= 1'b0; load_cnt <= 7'd0;
            clr <= 1'b1; ready <= 1'b0; idle <= 1'b1;
        end
        else begin
            st_we <= 1'b0;

            if (clr && (cnt == 10'd1023)) clr <= 1'b0;

            // ── note-on：等样点边界再装载 ─────────────────────────
            if (trig) pending <= 1'b1;

            if (pending && (cnt == 10'd0)) begin
                pending  <= 1'b0;
                loading  <= 1'b1;
                load_cnt <= 7'd0;
            end
            else if (loading && (s == 3'd7)) begin
                if (load_cnt == P_LAST) begin
                    loading <= 1'b0;
                    ready   <= 1'b1;
                end
                else
                    load_cnt <= load_cnt + 7'd1;
            end

            case (s)
                // ★ s==1：ROM 数据是上一拍（本声部 s==0）发出的地址读出的，
                //   此刻总线上只有本声部处于 s==1，直接采样即可。
                // ★★ ph_n 必须用【当前】ROM 输出 rd0，不能用刚打拍的 inc_r
                //    （非阻塞赋值下 inc_r 在这一拍还是上一个分量的值）
                3'd1: begin
                    inc_r  <= rd0;
                    R1_r   <= rd1;
                    phi8_r <= {24'd0, rd2[15:8]};
                    a16_r  <= {16'd0, rd2[31:16]};
                    ph_n   <= ph_q + rd0;
                    laddr  <= (ph_q + rd0) >> 22;
                end
                3'd2:  sw_r <= sw_raw;
                3'd3: begin
                    ds  <= $signed(sw_r[31:16]) - $signed(sw_r[15:0]);
                    fr  <= ph_n[21:12];
                    sv0 <= $signed(sw_r[15:0]);
                end
                // ★ 三个乘法在这一级并行，互不串联（这是关键路径缩短的原因）
                3'd4: begin
                    itp     <= ds * $signed({1'b0, fr});
                    dec_raw <= dpr1;
                    amp_er  <= pa_c[31:16];
                end
                3'd5: begin
                    sv   <= sv0 + itp_s;
                    dec1 <= (dec_raw + 56'h00_800000) >> 24;
                end
                3'd6:  pr <= sv * $signed({1'b0, amp_er});
                3'd7: begin
                    e1n <= e1_q - dec1;
                    ern <= ATK ? (er_q + {5'b0, dcdr}) : 32'hFFFF_FFFF;
                    st_we <= 1'b1;
                    st_wa <= p;
                    if (loading) begin
                        st_wp <= { phi8_r[7:0], 24'd0 };
                        st_w1 <= { a16_r[15:0], 16'd0 };
                        st_wr <= 32'd0;
                    end
                    else begin
                        st_wp <= ph_n;
                        st_w1 <= e1n;
                        st_wr <= ern;
                    end
                end
                default: ;
            endcase

            if (cnt == 10'd1023) begin
                // 最后一个分量的 pr 在本拍（s=7）刚好有效，直接并进输出
                sample <= (loading || !ready) ? 16'sd0 : sat16(acc + pr_s);
                acc    <= 24'sd0;
            end
            else if ((s == 3'd7) && !loading && ready)
                acc <= acc + pr_s;

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
