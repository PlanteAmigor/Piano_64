//==========================================================================
//  ui_liss_ram —— 相图（李萨如）位图 256×256，按 16 位字存
//
//  4096 word × 16 bit：一个 word = 一行里的 16 个像素
//      addr = row*16 + (x>>4)，bit = x&15
//
//  写口只有一个 always 块（★ 数组不能多块驱动，否则综合器报多驱动）：
//    · 清零：逐字清零（4096 拍 @75 MHz = 55 us）
//    · 打点：Bresenham 连线，相邻两个样点之间的像素全部点亮
//            （每像素 3 拍读-改-写；两个样点之间有 1536 拍，够画 500 px）
//  读口：扫描时读一个 word，按 bit 选像素
//
//  ★ 为什么必须连线：48828 Hz 的样点打到 212 px 的窗口上，相邻两点
//    在高音区能差十几个像素，只打点看起来就是"一堆散点"。连上线之后
//    才是曲线。
//==========================================================================
`default_nettype none

module ui_liss_ram (
    input  wire        clk,
    input  wire        rst_n,

    // ── 打点（与 clk 同域）──────────────────────────────────────
    input  wire        plot,        // 单拍：本拍有一个新样点
    input  wire [7:0]  plot_x,      // 0..255
    input  wire [7:0]  plot_y,      // 0..255

    // ── 清零 ─────────────────────────────────────────────────────
    input  wire        clr_en,      // 1 = 启动一次清零扫描
    output reg         clr_done,

    // ── 读口（扫描）──────────────────────────────────────────────
    input  wire [11:0] raddr,
    output reg  [15:0] rdata
);
    reg [15:0] m [0:4095];

    // ── 画笔 ─────────────────────────────────────────────────────
    reg [7:0]  pen_x, pen_y;       // 上一个已画到的像素
    reg        pen_vld;            // 清零后第一个点是孤立点，不能连线
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
    reg [11:0] p_addr;
    reg [4:0]  p_bit;
    reg [15:0] p_dat;

    // ── 清零扫描 ─────────────────────────────────────────────────
    reg [11:0] c_addr;
    reg        c_run;

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

    wire        busy  = c_run || clr_en;
    wire        start = (st == S_IDLE) && pend && !busy;

    // 新段方向 / 距离（画笔 → 待画点）
    wire [7:0] ndx = (pdx > pen_x) ? (pdx - pen_x) : (pen_x - pdx);
    wire [7:0] ndy = (pdy > pen_y) ? (pdy - pen_y) : (pen_y - pdy);

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
            p_addr   <= 12'd0;  p_bit <= 5'd0;   p_dat <= 16'd0;
            c_run    <= 1'b0;   c_addr <= 12'd0;
            clr_done <= 1'b0;
            rdata    <= 16'd0;
        end
        else begin
            clr_done <= 1'b0;
            rdata    <= m[raddr];              // 读口

            // ── 待画点缓冲：新点覆盖旧点 ─────────────────────────
            if (plot && !busy) begin
                pend <= 1'b1;
                pdx  <= plot_x;
                pdy  <= plot_y;
            end
            else if (start) pend <= 1'b0;

            if (clr_en) begin
                c_run   <= 1'b1;
                c_addr  <= 12'd0;
                st      <= S_IDLE;
                pen_vld <= 1'b0;
            end
            else if (c_run) begin
                m[c_addr] <= 16'd0;            // 清零优先
                c_addr    <= c_addr + 12'd1;
                if (c_addr == 12'd4095) begin
                    c_run    <= 1'b0;
                    clr_done <= 1'b1;
                end
            end
            else begin
                case (st)
                S_IDLE: if (pend) begin
                    if (!pen_vld) begin
                        // 清零后第一个点：只画一个像素，不从 (0,0) 连线
                        cur_x <= pdx;  cur_y <= pdy;
                        tgt_x <= pdx;  tgt_y <= pdy;
                        adx   <= 8'd0; ady   <= 8'd0;
                        sx    <= 1'b1; sy    <= 1'b1;
                        berr  <= 11'sd0;
                    end
                    else begin
                        cur_x <= pen_x; cur_y <= pen_y;
                        tgt_x <= pdx;   tgt_y <= pdy;
                        adx   <= ndx;   ady   <= ndy;
                        sx    <= (pdx >= pen_x);
                        sy    <= (pdy >= pen_y);
                        berr  <= $signed({3'b000, ndx}) -
                                 $signed({3'b000, ndy});
                    end
                    st <= S_ADDR;
                end
                S_ADDR: begin
                    p_addr <= {cur_y, 4'd0} + {8'd0, cur_x[7:4]};
                    p_bit  <= {1'b0, cur_x[3:0]};
                    st     <= S_RD;
                end
                S_RD: begin
                    p_dat <= m[p_addr];
                    st    <= S_WR;
                end
                default: begin                 // S_WR
                    // 写 2 像素宽。p_bit==15 时高位溢出丢弃，退化成
                    // 1 px，概率 1/16，无影响。
                    m[p_addr] <= p_dat | (16'd3 << p_bit);
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
