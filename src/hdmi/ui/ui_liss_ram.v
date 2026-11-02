//==========================================================================
//  ui_liss_ram —— 相图（李萨如）帧存 256×256，【4 bit 强度/像素】
//
//  16384 word × 16 bit：一个 word = 一行里的 4 个像素（4 个 nibble）
//      addr = row*64 + (x>>2)，nibble = x&3
//
//  为什么是 4 bit 而不是 1 bit：这是「数字荧光屏」的核心。
//    · 打点 = 该像素强度 +1（饱和到 15）
//    · 每帧整屏强度 -1（饱和到 0）
//    于是「停留时间」自动变成亮度：
//      稳定轨迹每个周期都被扫一遍 → 很快累到 15 级 → 刺眼
//      瞬态垃圾（限幅跳变、起始杂散）只被扫过一次 → 一直是 1 级 → 很暗
//      并且不管是什么，15 帧内衰减干净
//    ★ 这一步是「瞬时状态下画面更清晰」的关键，比滤波直接得多：
//      滤波改的是【形状】，荧光改的是【权重】。
//
//  写口只有一个 always 块（★ 数组不能多块驱动，否则综合器报多驱动）：
//    · 全清：16384 拍（218 us），仅上电用
//    · 衰减：16384 字 × 2 拍（读+写）= 32768 拍 = 437 us，每帧一次
//            （720p 每帧消隐 328650 拍 = 4.4 ms，余量 10 倍）
//    · 打点：Bresenham 连线，每像素 3 拍读-改-写
//  读口：扫描时读一个 word，按 nibble 选像素强度
//==========================================================================
`default_nettype none

module ui_liss_ram (
    input  wire        clk,
    input  wire        rst_n,

    // ── 打点（与 clk 同域）──────────────────────────────────────
    input  wire        plot,        // 单拍：本拍有一个新样点
    input  wire [7:0]  plot_x,      // 0..255
    input  wire [7:0]  plot_y,      // 0..255

    // ── 全清（仅上电用）─────────────────────────────────────────
    input  wire        clr_en,
    output reg         clr_done,

    // ── 荧光衰减：每帧给一个单拍脉冲，整屏强度 -decay_step ──────
    input  wire        decay_req,
    input  wire [3:0]  decay_step,  // 每帧衰减量 1..15（15 = 每帧清空）
    input  wire [3:0]  ink_step,    // 每次打点增量 1..15（15 = 直接写满）
    output reg         decay_busy,

    // ── 读口（扫描）：一个 word = 4 个像素 ───────────────────────
    input  wire [13:0] raddr,
    output reg  [15:0] rdata
);
    reg [15:0] m [0:16383];

    localparam [13:0] LAST_A = 14'd16383;

    // ── 4 位饱和减 / 饱和加 ─────────────────────────────────────
    function [15:0] dec16;                  // 4 个 nibble 各自饱和 -step
        input [15:0] w;
        input [3:0]  s;
        begin
            dec16[3:0]   = (w[3:0]   >= s) ? (w[3:0]   - s) : 4'd0;
            dec16[7:4]   = (w[7:4]   >= s) ? (w[7:4]   - s) : 4'd0;
            dec16[11:8]  = (w[11:8]  >= s) ? (w[11:8]  - s) : 4'd0;
            dec16[15:12] = (w[15:12] >= s) ? (w[15:12] - s) : 4'd0;
        end
    endfunction

    function [15:0] inc16;                  // sel 号 nibble 饱和 +step
        input [15:0] w;
        input [1:0]  sel;
        input [3:0]  s;
        reg   [15:0] sh;
        reg   [4:0]  n2;
        begin
            sh = w >> {sel, 2'b00};         // 把要改的 nibble 移到低 4 位
            n2 = {1'b0, sh[3:0]} + {1'b0, s};
            if (n2 > 5'd15) n2 = 5'd15;     // 饱和到 15
            inc16 = (w & ~(16'h000F << {sel, 2'b00}))
                  | ({12'd0, n2[3:0]} << {sel, 2'b00});
        end
    endfunction

    // ── 画笔 ─────────────────────────────────────────────────────
    reg [7:0]  pen_x, pen_y;       // 上一个已画到的像素
    reg        pen_vld;            // 全清后第一个点是孤立点，不能连线
    reg [7:0]  cur_x, cur_y;       // Bresenham 当前像素
    reg [7:0]  tgt_x, tgt_y;
    reg [7:0]  adx, ady;
    reg signed [10:0] berr;
    reg        sx, sy;

    // ── 待画点缓冲（1 深度）──────────────────────────────────────
    reg        pend;
    reg [7:0]  pdx, pdy;

    // ── 打点状态机 ───────────────────────────────────────────────
    localparam [1:0] S_IDLE = 2'd0, S_ADDR = 2'd1,
                     S_RD   = 2'd2, S_WR   = 2'd3;
    reg [1:0]  st;
    reg [1:0]  p_sel;

    // ── 全清 / 衰减扫描 ──────────────────────────────────────────
    localparam [1:0] D_ADDR = 2'd0, D_READ = 2'd1, D_WRITE = 2'd2;
    reg [13:0] c_addr, d_addr;
    reg        c_run,  d_run;
    reg [1:0]  d_ph;

    // ── Bresenham 组合逻辑 ───────────────────────────────────────
    //   ★ berr 在同一拍要减一次加一次，写成两次非阻塞赋值会丢掉前一次，
    //     所以先算出 berr_n 再一次性赋值。
    wire signed [11:0] berr12 = $signed(berr);
    wire signed [11:0] e2     = berr12 <<< 1;
    wire signed [11:0] adx_s  = {4'b0000, adx};
    wire signed [11:0] ady_s  = {4'b0000, ady};
    wire        do_x = (e2 > -ady_s);
    wire        do_y = (e2 <  adx_s);
    wire signed [11:0] berr_n = berr12
                              - (do_x ? ady_s : 12'sd0)
                              + (do_y ? adx_s : 12'sd0);
    wire        at_tgt = (cur_x == tgt_x) && (cur_y == tgt_y);

    wire        busy  = c_run || clr_en || d_run || decay_req;
    wire        start = (st == S_IDLE) && pend && !busy;

    // 新段方向 / 距离（画笔 → 待画点）
    wire [7:0] ndx = (pdx > pen_x) ? (pdx - pen_x) : (pen_x - pdx);
    wire [7:0] ndy = (pdy > pen_y) ? (pdy - pen_y) : (pen_y - pdy);

    // ★ 段长上限：超过就断笔，只画目标点。
    //   否则一次跳变（限幅、起始杂散）会拉出一条横跨整个画面的长直线，
    //   看起来就是"扇形发散"。
    //   ★★ 上限从 24 放宽到 64：钢琴/古筝有 128 个分量，波形起伏快，
    //      相邻样点经常跳 >24 px，24 的上限会把大量线砍成孤立点，
    //      结果是曲线不清晰 + 点被打上次数少 → 很暗。
    //      现在瞬态垃圾已经由「荧光衰减 + 触发后静默 10 ms」管住，
    //      不需要靠断笔来防了。
    //   每样点有 1536 拍、每像素 3 拍 → 理论上可画 512 px，64 很安全。
    wire        seg_ok = (ndx <= 8'd64) && (ndy <= 8'd64);

    // ══════════════════════════════════════════════════════════════
    //  存储接口：★ 严格两个读表达式 + 一个写表达式
    //
    //  Gowin BSRAM 是双口，但综合器的推断器非常挑：只要出现第三个
    //  地址表达式，它就放弃 RAM 推断、把整块变成寄存器
    //      ERROR (IF0008) The number(262144) of DFF ... exceeds the limit
    //  所以这里固定成：
    //      A 口：只读  m[raddr]                —— 显示扫描
    //      B 口：读 m[b_addr] 并写 m[b_addr]   —— 打点 / 衰减 / 全清 三合一
    //  三个写者互斥（优先级 全清 > 衰减 > 打点），所以共用一个写表达式。
    // ══════════════════════════════════════════════════════════════
    reg  [13:0] b_ra, b_wa;         // B 口独立的读/写地址
    reg  [15:0] b_q;                // B 口读出，1 拍后有效

    // 单 always 块驱动 m
    always @(posedge clk) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            pen_x    <= 8'd0;   pen_y <= 8'd0;   pen_vld <= 1'b0;
            cur_x    <= 8'd0;   cur_y <= 8'd0;
            tgt_x    <= 8'd0;   tgt_y <= 8'd0;
            adx      <= 8'd0;   ady   <= 8'd0;
            berr     <= 11'sd0;
            sx       <= 1'b1;   sy    <= 1'b1;
            pend     <= 1'b0;   pdx   <= 8'd0;   pdy <= 8'd0;
            b_ra     <= 14'd0;  b_wa  <= 14'd0;  b_q   <= 16'd0;
            p_sel    <= 2'd0;
            c_run    <= 1'b0;   c_addr <= 14'd0;
            d_run    <= 1'b0;   d_addr <= 14'd0; d_ph <= 2'd0;
            clr_done <= 1'b0;
            rdata    <= 16'd0;
        end
        else begin
            clr_done   <= 1'b0;
            decay_busy <= d_run;

            // ── A 口：显示扇描（只读）───────────────────
            //   ★ B 口的读必须【放在分支里】且与写分支互斥。
            //     写成无条件 b_q <= m[b_addr] 会跟同拍的写撞车，
            //     综合器推出 WRITE_MODE = 2'b10 →
            //         ERROR (PA2122) Not support ... 'm_m_0_0_s'(DPB)
            rdata <= m[raddr];

            // ── 待画点缓冲：新点覆盖旧点 ─────────────────────────
            if (plot && !busy) begin
                pend <= 1'b1;
                pdx  <= plot_x;
                pdy  <= plot_y;
            end
            else if (start) pend <= 1'b0;

            if (clr_en) begin
                c_run   <= 1'b1;
                c_addr  <= 14'd0;
                b_wa    <= 14'd0;
                st      <= S_IDLE;
                pen_vld <= 1'b0;
            end
            // ── ① 全清（最高优先级，1 拍/字）────────────────────
            else if (c_run) begin
                m[b_wa] <= 16'd0;
                c_addr  <= c_addr + 14'd1;
                b_wa    <= c_addr + 14'd1;
                if (c_addr == LAST_A) begin
                    c_run    <= 1'b0;
                    clr_done <= 1'b1;
                end
            end
            // ── ② 荧光衰减（3 拍/字：置地址 → 读 → 写）──────────
            else if (decay_req || d_run) begin
                if (!d_run) begin
                    d_run  <= 1'b1;
                    d_addr <= 14'd0;
                    d_ph   <= D_ADDR;
                end
                else case (d_ph)
                D_ADDR: begin
                    b_ra <= d_addr;
                    d_ph <= D_READ;
                end
                D_READ: begin
                    b_q  <= m[b_ra];
                    b_wa <= d_addr;
                    d_ph <= D_WRITE;
                end
                default: begin                       // D_WRITE
                    m[b_wa] <= dec16(b_q, decay_step);   // 每个 nibble 饱和 -step
                    if (d_addr == LAST_A) d_run <= 1'b0;
                    else begin
                        d_addr <= d_addr + 14'd1;
                        d_ph   <= D_ADDR;
                    end
                end
                endcase
            end
            // ── ③ 打点 ──────────────────────────────────────────
            else begin
                case (st)
                S_IDLE: if (pend) begin
                    if (!pen_vld) begin
                        // 全清后第一个点：只画一个像素，不从 (0,0) 连线
                        cur_x <= pdx;  cur_y <= pdy;
                        tgt_x <= pdx;  tgt_y <= pdy;
                        adx   <= 8'd0; ady   <= 8'd0;
                        sx    <= 1'b1; sy    <= 1'b1;
                        berr  <= 11'sd0;
                    end
                    else begin
                        // 段太长 → 断笔，直接跳到目标点画一个孤立点
                        cur_x <= seg_ok ? pen_x : pdx;
                        cur_y <= seg_ok ? pen_y : pdy;
                        tgt_x <= pdx;   tgt_y <= pdy;
                        adx   <= seg_ok ? ndx : 8'd0;
                        ady   <= seg_ok ? ndy : 8'd0;
                        sx    <= (pdx >= pen_x);
                        sy    <= (pdy >= pen_y);
                        berr  <= seg_ok ? ($signed({3'b000, ndx}) -
                                           $signed({3'b000, ndy})) : 11'sd0;
                    end
                    st <= S_ADDR;
                end
                S_ADDR: begin
                    b_ra   <= {cur_y, 6'd0} + {8'd0, cur_x[7:2]};
                    b_wa   <= {cur_y, 6'd0} + {8'd0, cur_x[7:2]};
                    p_sel  <= cur_x[1:0];
                    st     <= S_RD;
                end
                S_RD: begin
                    b_q <= m[b_ra];            // b_q 在 S_WR 那一拍有效
                    st  <= S_WR;
                end
                default: begin                 // S_WR
                    m[b_wa] <= inc16(b_q, p_sel, ink_step);
                    pen_x     <= cur_x;
                    pen_y     <= cur_y;
                    pen_vld   <= 1'b1;
                    if (at_tgt) st <= S_IDLE;
                    else begin
                        berr  <= berr_n;
                        cur_x <= do_x ? (sx ? cur_x + 8'd1 : cur_x - 8'd1)
                                      : cur_x;
                        cur_y <= do_y ? (sy ? cur_y + 8'd1 : cur_y - 8'd1)
                                      : cur_y;
                        st    <= S_ADDR;
                    end
                end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
