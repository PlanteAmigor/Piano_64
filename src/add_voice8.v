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
    input  wire                sustain,      // ★ 1 = 延音：松键后按自然衰减率继续响

    // ── 本声部的参数 cache 接口（每声部独占一份，读延迟 1 拍）──────
    input  wire [31:0]         rd0,          // bank0 = inc
    input  wire [31:0]         rd1,          // bank1 = R1
    input  wire [31:0]         rd2,          // bank2 = {a16, phi8}
    input  wire [6:0]          note_off,     // 保留（旧接口，现由 DMA 使用）
    input  wire [7:0]          vel_gain,     // ★ 力度增益 2..254（来自双触点 Δt）
    output wire [6:0]          rom_addr,     // ★ 改成“分量号 p”：cache 里就是本音的数据

    output reg  signed [15:0]  sample,       // 本声部在本样点的和（保持到下一个样点）
    output reg                 idle,

    // ── 分量幅度监控（给 HDMI「COMPONENT 64」柱图用）──────────────
    //    在 s==6 这一拍采样 amp_er（此时它持有第 p 个分量的实时幅度，
    //    含包络衰减与力度）。每个分量每样点输出一次单拍脉冲。
    //    ★ 与控制逻辑无关，纯观察口，接不接不影响音质。
    output reg  [6:0]          part_idx,      // 当前分量号 0..NPART-1
    output reg  [7:0]          part_amp,      // 该分量的实时幅度（0..255）
    output reg                 part_vld       // part_idx/part_amp 有效
);

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
    // ★★ 架构变更（2026-10-31）：每声部有自己的 cache，地址就是分量号 p。
    //    不再需要 {note_off, p} 拼全局地址，也不再需要 rom_req 多路器
    //    （各声部同相位同时读也不会抢口，PH_SHIFT 约束消失）。
    assign rom_addr = p;

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

    reg        pending, loading, ready;
    reg        fading;                     // ★ 1 = 正在为抢占做淡出
    reg [6:0]  load_cnt;

    // ★★ note-on 淡入（attack ramp）───────────────────────────────
    //  问题：装载时 st_w1 <= {a16, 16'd0} 是【硬跳变】——不管声部当时
    //        e1 是多少，起音一律从满幅开始。快速连按时，新音从满幅起音
    //        和前一次的余音叠加 → 幅度阶跃 → 爆音（实测"10 出 1"）。
    //  对策：装载完成后的前 256 个样点，输出幅度乘 0..255/256 线性上升。
    //        256 样点 @48828 Hz = 5.24 ms，听不到延迟，但能彻底消除阶跃。
    //  参考：jt5232_eg.v（MSM5232，JOTEGO）也是靠"包络值连续不重置"
    //        避免 click，只是它用 RC 指数，这里用更快的线性斜坡。
    //  注意：淡入不影响触发延迟（note-on 到第一个到样点的延迟不变）
    reg [7:0]  ramp;

    // ★ ramp 的下一值用 9 位算，避免 254+2 在 8 位里回绕成 0（见下方用法处）
    wire [8:0] ramp_nx = {1'b0, ramp} + 9'd2;

    localparam [31:0] R_REL = 32'd293000;      // 松键、无延音：固定快释放（0.30 s）
    // ★ 延音档的衰减上限：τ = 2^32/(R·fs) ≈ 1.5 s
    //   高音区、古筝的 R1_r 本身就大（衰减快），延音档下几乎听不出区别，
    //   所以松键时给它一个上限 —— 保证每个音至少能拖 1.5 s。
    //   R1_r 更小的（低音，自然衰减更慢）保留原值，可以拖得更久。
    localparam [31:0] R_SUS_MAX = 32'd58635;
    reg               gate_r;
    always @(posedge clk) gate_r <= gate;
    wire              rel    = ~gate_r;
    // 延音（= 延音踏板踩下）：松键后制音器不落下，弦按【自己的自然衰减率】
    //   R1_r 继续振动。R1_r 来自采样分析，每个音各不相同（低音慢、高音快），
    //   所以低音拖得久、高音收得快 —— 和真钢琴一致。
    // 不踩踏板时用固定的 R_REL（0.30 s）= 制音器落下的快收。
    // ★ 只有【松键后】才改衰减率；按住期间始终用采样自带的 R1_r。
    wire [31:0] R_rel_eff = sustain ? ((R1_r > R_SUS_MAX) ? R_SUS_MAX : R1_r)
                                    : R_REL;
    wire [31:0] R1_eff    = rel ? R_rel_eff : R1_r;

    wire signed [17:0] itp_s = $signed(itp[27:10]);
    wire signed [23:0] pr_s  = $signed(pr[34:16]);
    wire [16:0]        amp   = e1_q[31:16];

    // ════════════════════════════════════════════════════════════════
    //  分量幅度监控
    //    amp_er 在 s==4 打拍，s==5/6/7 持有第 p 个分量的实时幅度
    //    （s==6 正是 pr <= sv * amp_er 用的同一个值）。
    //    这里在 s==6 采一次，得到「分量号 + 8 位幅度」的单拍脉冲。
    //    ★ 装载中/未就绪时不发，避免把旧包络当成新音显示。
    // ════════════════════════════════════════════════════════════════
    wire part_ce = (s == 3'd6) && ready && !loading;

    always @(posedge clk) begin
        if (!rst_n) begin
            part_idx <= 7'd0;
            part_amp <= 8'd0;
            part_vld <= 1'b0;
        end
        else begin
            part_vld <= part_ce;
            if (part_ce) begin
                part_idx <= p;
                part_amp <= amp_er[15:8];
            end
        end
    end

    wire [55:0] dpr1 = e1_q[31:8] * R1_eff;                  // 24 × 32
    wire [32:0] rem  = 33'h1_0000_0000 - {1'b0, er_q};
    wire [49:0] dprr = rem[32:8] * {1'b0, 24'd1};            // 起音：Rr 固定 1
    wire [26:0] dcdr = (dprr + 50'h00_800000) >> 24;
    wire [33:0] pa_c = amp * {1'b0, er_q[31:16]};

    always @(posedge clk) begin
        if (!rst_n) begin
            inc_r <= 32'd0; R1_r <= 32'd0; phi8_r <= 32'd0; a16_r <= 32'd0;
            ph_n <= 32'd0; ds <= 18'sd0; fr <= 10'd0;
            sv0 <= 18'sd0; itp <= 29'sd0; sv <= 18'sd0;
            dec_raw <= 56'd0; dec1 <= 32'd0; amp_er <= 18'd0;
            pr <= 35'sd0; acc <= 24'sd0;
            st_we <= 1'b0; st_wa <= 7'd0;
            st_wp <= 32'd0; st_w1 <= 32'd0; st_wr <= 32'd0;
            laddr <= 10'd0;
            sample <= 16'sd0;
            pending <= 1'b0; loading <= 1'b0; load_cnt <= 7'd0;
            clr <= 1'b1; ready <= 1'b0; idle <= 1'b1;
            ramp <= 8'd0; fading <= 1'b0;
        end
        else begin
            st_we <= 1'b0;

            if (clr && (cnt == 10'd1023)) clr <= 1'b0;

            // ── note-on：等样点边界再装载 ─────────────────────────
            //    ★★ 高优先：如果本声部【正在响】（ready=1），不能直接装载。
            //      直接装载会让 sample 从当前值跳到 0 → 阶跃 → 爆音。
            //      所以先进入 fading，用 1.7 ms 淡到 0，再装载。
            //      这就是"快速连弹/猛击不爆音"的关键 —— 任何情况下 sample 连续。
            if (trig && !loading && !fading) pending <= 1'b1;

            // 正在响的声部收到 note-on → 先淡出
            if (pending && ready && !loading && !fading && (cnt == 10'd0))
                fading <= 1'b1;

            // 空闲声部收到 note-on → 直接装载
            if (pending && !ready && !loading && !fading && (cnt == 10'd0)) begin
                pending  <= 1'b0;
                loading  <= 1'b1;
                load_cnt <= 7'd0;
            end
            else if (pending && ready && !loading && !fading) begin
                // 已在 fading，保持 pending，由输出级在淡出完成时接手
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
                3'd2: begin end       // laddr 在这一拍送到正弦表，下一拍输出有效
                3'd3: begin
                    // ★★ 必须用【当拍】的 sw_raw，不能用打过一拍的 sw_r！
                    //    正弦表是同步读：s==1 给的 laddr 在 s==3 这拍才出现在
                    //    dout 上。如果在 s==2 就 sw_r <= sw_raw，采到的是
                    //    【上一个分量】的地址（s==1 时 laddr 还是旧的），
                    //    结果每个分量都在用邻居的频率 → 音高/音色全错。
                    ds  <= $signed(sw_raw[31:16]) - $signed(sw_raw[15:0]);
                    fr  <= ph_n[21:12];
                    sv0 <= $signed(sw_raw[15:0]);
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
                    // ★★ 回写值必须用【当拍】的组合值：
                    //    e1_q 在 s==7 就是本分量的值，dec1 在 s==5 已打拍，
                    //    dcdr 是 er_q 的组合函数。
                    //    【曾经的 bug】这里写成
                    //        e1n <= e1_q - dec1;   ...   st_w1 <= e1n;
                    //    e1n 是非阻塞赋值，与本拍 st_w1 同一时钟沿更新，
                    //    所以 st_w1 采到的是【上一个分量】的 e1n，
                    //    回写整整晚一个分量 → 每播一个样点幅度在槽位间错位 +1，
                    //    分量幅度随机跳变 → 输出听起来是噪声（实测峰值顶到
                    //    削顶、与理想波形相关系数 0.02）。
                    st_we <= 1'b1;
                    st_wa <= p;
                    if (loading) begin
                        st_wp <= { phi8_r[7:0], 24'd0 };
                        st_w1 <= { a16_r[15:0], 16'd0 };
                        st_wr <= 32'd0;
                    end
                    else begin
                        st_wp <= ph_n;
                        st_w1 <= e1_q - dec1;
                        st_wr <= ATK ? (er_q + {5'b0, dcdr}) : 32'hFFFF_FFFF;
                    end
                end
                default: ;
            endcase

            if (cnt == 10'd1023) begin
                // 最后一个分量的 pr 在本拍（s=7）刚好有效，直接并进输出
                if (loading || !ready) begin
                    sample <= 16'sd0;
                    ramp   <= 8'd0;                 // 装载中/未就绪：淡入重新开始
                end
                else if (fading) begin
                    // ★ 抢占淡出：1.7 ms 降到 0，然后才开始装载
                    sample <= sat16r(acc + pr_s, ramp);
                    if (ramp <= 8'd3) begin
                        ramp     <= 8'd0;
                        fading   <= 1'b0;
                        pending  <= 1'b0;
                        loading  <= 1'b1;           // 接到装载流程
                        load_cnt <= 7'd0;
                    end
                    else
                        ramp <= ramp - 8'd3;
                end
                else begin
                    // ★ 力度控制淡入终值：ramp 向 vel_gain 收敛
                    //   淡入 +2（2.6 ms），超过目标则 -1 缓慢下降
                    //   （ARMED 先用 128，后触点确认后更新为真实力度，
                    //    轻按会在几 ms 内降到目标值，听感是轻微渐弱，不爆音）
                    //
                    // ★★ ramp 只有 8 位，绝不能写 ramp + 8'd2：
                    //    vel_gain = 255 时 ramp=254 → 254<255 → 256 截断成 **0**，
                    //    然后又 +2/+2 爬回 254 再溢出 → ramp 在 0↔254 间锯龄，
                    //    周期 128 个样点 = **381 Hz 锯齿噪声**。
                    //    手指贴近光敏管时 opt_vel 饱和到 255 就会触发（实测：
                    //    钢琴/古筝有噪声，唢呐/笛子没有——后者不走 ramp）。
                    //    键盘力度上限是 254，所以以前从未暴露。
                    if (ramp < vel_gain)
                        ramp <= (ramp_nx >= {1'b0, vel_gain}) ? vel_gain
                                                              : ramp_nx[7:0];
                    else if (ramp > vel_gain)
                        ramp <= ramp - 8'd1;
                    sample <= sat16r(acc + pr_s, ramp);
                end
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

    // 带淡入增益的饱和：先把 24 位和乘 0..255 再右移 8 位，再饱和到 16 位
    function signed [15:0] sat16r; input signed [23:0] x; input [7:0] g;
        reg signed [31:0] y;
        begin
            y = (x * $signed({1'b0, g})) >>> 8;
            if      (y >  32'sd32767) sat16r =  16'sd32767;
            else if (y < -32'sd32768) sat16r = -16'sd32768;
            else                      sat16r =  y[15:0];
        end
    endfunction

endmodule

`default_nettype wire
