// Persistence plot RAM. Defaults retain the legacy 128x128/4-bit interface.
// Native 1080p uses 256x256 with 2-bit intensities (eight pixels/word).
// All plotting, clear and decay writes share the same RAM port.
`default_nettype none

module ui_liss_ram #(parameter integer COORD_BITS=7, PIXEL_BITS=4, PACK_BITS=PIXEL_BITS==2?3:2, RAM_AW=2*COORD_BITS-PACK_BITS) (
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
    input  wire [RAM_AW-1:0] raddr,
    output reg  [15:0] rdata
);

    localparam [RAM_AW-1:0] LAST_A = (1<<RAM_AW)-1;

    // 输入坐标 0..255 → 帧存坐标 0..127（折扣）
    wire [7:0] px7 = COORD_BITS==8 ? plot_x : {1'b0, plot_x[7:1]};
    wire [7:0] py7 = COORD_BITS==8 ? plot_y : {1'b0, plot_y[7:1]};

    // ── 4 位饱和减 / 饱和加 ─────────────────────────────────────
    function [15:0] dec16;
        input [15:0] w;input [3:0] step;
        integer i;reg [PIXEL_BITS-1:0] v;
        begin
            for(i=0;i<16/PIXEL_BITS;i=i+1)begin
                v=w[i*PIXEL_BITS+:PIXEL_BITS];
                dec16[i*PIXEL_BITS+:PIXEL_BITS]=v>=step?v-step:0;
            end
        end
    endfunction
    function [15:0] inc16;
        input [15:0] w;input [PACK_BITS-1:0] sel;input [3:0] step;
        reg [4:0] v;integer i;
        begin
            inc16=w;
            for(i=0;i<16/PIXEL_BITS;i=i+1)if(sel==i)begin
                v={1'b0,w[i*PIXEL_BITS+:PIXEL_BITS]}+step;
                inc16[i*PIXEL_BITS+:PIXEL_BITS]=v>((1<<PIXEL_BITS)-1)?{PIXEL_BITS{1'b1}}:v[PIXEL_BITS-1:0];
            end
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
    localparam [2:0] S_IDLE=0,S_ADDR=1,S_RD=2,S_WR=3,S_PRE=4,S_BEGIN=5;
    reg [2:0] st;
    reg line_ok,step_x,step_y;
    reg signed [10:0] neg_ady,err_x,err_y_add;
    reg [PACK_BITS-1:0] p_sel;

    // ── 全清 / 衰减扫描 ──────────────────────────────────────────
    localparam [1:0] D_ADDR = 2'd0, D_READ = 2'd1, D_WRITE = 2'd2;
    reg [RAM_AW-1:0] c_addr, d_addr;
    reg        c_run,  d_run;
    reg [1:0]  d_ph;

    // Compare directions in S_ADDR, subtract in S_RD, add in S_WR.
    // The error recurrence spans existing RAM access cycles without changing
    // the set of pixels. Negative dy is prepared once per segment.
    wire signed [11:0] berr12=$signed(berr);
    wire signed [11:0] e2=berr12<<<1;
    wire signed [11:0] adx_s={4'b0000,adx};
    wire do_x=e2>$signed(neg_ady);
    wire do_y=e2<adx_s;
    reg at_tgt;
    reg clear_last,decay_last;

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
    //   ★ 帧存缩到 128×128 后，同样 32 px 相当于原来的 64 px，阈值同比减半。

    // The scan port reads each pixel. The drawing port alternates reads and
    // queued writes at one registered address, allowing a true dual-port RAM.
    reg  [RAM_AW-1:0] b_wa;         // Address retained from read through write preparation
    reg  [15:0] b_q;                // B 口读出，1 拍后有效

    // Queue every write before the physical RAM port. All three producers
    // share one short registered write interface, including clear and decay.
    reg mem_we /* synthesis syn_preserve=1 */;
    reg [RAM_AW-1:0] mem_addr /* synthesis syn_preserve=1 */;
    reg mem_re /* synthesis syn_preserve=1 */;
    reg [15:0] mem_wd /* synthesis syn_preserve=1 */;
    reg clear_finished;
    // Use an explicit normal-mode DPB on the target device. The portable
    // branch has identical synchronous read latency and is checked against
    // Gowin's primitive model with UI_VENDOR_RAM_SIM.
`ifdef UI_VENDOR_RAM_SIM
    localparam USE_DPB=1;
`else
    // Gowin does not predefine SYNTHESIS. translate_off selects the portable
    // memory only in functional simulation; hardware always uses the DPBs.
    localparam USE_DPB=1
    // synthesis translate_off
        && 0
    // synthesis translate_on
        ;
`endif
    generate if(USE_DPB)begin:g_dpb
        localparam BANK_BITS=RAM_AW-10, BANKS=1<<BANK_BITS;
        wire [15:0] scan_q[0:BANKS-1],draw_q[0:BANKS-1];
        reg [BANK_BITS-1:0] scan_bank,draw_bank;
        always @(posedge clk)begin
            if(!rst_n)begin scan_bank<=0;draw_bank<=0;end
            else begin
                scan_bank<=raddr[RAM_AW-1:10];
                if(mem_re)draw_bank<=mem_addr[RAM_AW-1:10];
            end
        end
        always @(*)begin rdata=scan_q[scan_bank];b_q=draw_q[draw_bank];end
        for(genvar bank=0;bank<BANKS;bank=bank+1)begin:g_bank
            DPB #(.READ_MODE0(1'b0),.READ_MODE1(1'b0),
                .WRITE_MODE0(2'b00),.WRITE_MODE1(2'b00),
                .BIT_WIDTH_0(16),.BIT_WIDTH_1(16),
                .BLK_SEL_0(3'b000),.BLK_SEL_1(3'b000),.RESET_MODE("SYNC")) u_ram(
                .CLKA(clk),.CLKB(clk),.OCEA(1'b1),.OCEB(1'b1),
                .CEA(raddr[RAM_AW-1:10]==bank),
                .CEB((mem_re || mem_we) && mem_addr[RAM_AW-1:10]==bank),
                .RESETA(!rst_n),.RESETB(!rst_n),.WREA(1'b0),.WREB(mem_we),
                .BLKSELA(3'b000),.BLKSELB(3'b000),
                .ADA({raddr[9:0],4'b0000}),.ADB({mem_addr[9:0],4'b0011}),
                .DIA(16'd0),.DIB(mem_wd),.DOA(scan_q[bank]),.DOB(draw_q[bank]));
        end
    end else begin:g_behavioral
        reg [15:0] m[0:(1<<RAM_AW)-1];
        always @(posedge clk)begin
            if(!rst_n)begin rdata<=0;b_q<=0;end
            else begin
                rdata<=m[raddr];
                if(mem_we)m[mem_addr]<=mem_wd;
                else if(mem_re)b_q<=m[mem_addr];
            end
        end
    end endgenerate

    // FSM prepares RAM transactions; completion follows the actual commit.
    always @(posedge clk) begin
        if (!rst_n) begin
            mem_we<=0;mem_re<=0;mem_addr<=0;mem_wd<=0;clear_finished<=0;decay_busy<=0;at_tgt<=0;clear_last<=0;decay_last<=0;
            st       <= S_IDLE;
            pen_x    <= 8'd0;   pen_y <= 8'd0;   pen_vld <= 1'b0;
            cur_x    <= 8'd0;   cur_y <= 8'd0;
            tgt_x    <= 8'd0;   tgt_y <= 8'd0;
            adx      <= 8'd0;   ady   <= 8'd0;
            berr     <= 11'sd0;
            line_ok<=0;step_x<=0;step_y<=0;neg_ady<=0;err_x<=0;err_y_add<=0;
            sx       <= 1'b1;   sy    <= 1'b1;
            pend     <= 1'b0;   pdx   <= 8'd0;   pdy <= 8'd0;
            b_wa  <= 12'd0;
            p_sel    <= 2'd0;
            c_run    <= 1'b0;   c_addr <= 12'd0;
            d_run    <= 1'b0;   d_addr <= 12'd0; d_ph <= 2'd0;
            clr_done <= 1'b0;

        end
        else begin
            mem_we<=0;mem_re<=0;clear_finished<=0;
            clr_done <= clear_finished;
            decay_busy <= d_run;

            // ── 待画点缓冲：新点覆盖旧点 ─────────────────────────
            if (plot && !busy) begin
                pend <= 1'b1;
                pdx  <= px7;
                pdy  <= py7;
            end
            else if (start) pend <= 1'b0;

            if (clr_en) begin
                c_run   <= 1'b1;clear_last<=0;
                c_addr  <= 12'd0;
                b_wa    <= 12'd0;
                st      <= S_IDLE;
                pen_vld <= 1'b0;
            end
            // ── ① 全清（最高优先级，1 拍/字）────────────────────
            else if (c_run) begin
                mem_we<=1;mem_addr<=b_wa;mem_wd<=16'd0;
                c_addr  <= c_addr + 12'd1;
                b_wa    <= c_addr + 12'd1;
                clear_last<=c_addr==LAST_A-1;
                if (clear_last) begin
                    c_run    <= 1'b0;
                    clear_finished <= 1'b1;
                end
            end
            // ── ② 荧光衰减（3 拍/字：置地址 → 读 → 写）──────────
            else if (decay_req || d_run) begin
                if (!d_run) begin
                    d_run  <= 1'b1;
                    d_addr <= 12'd0;
                    d_ph   <= D_ADDR;
                end
                else case (d_ph)
                D_ADDR: begin
                    decay_last<=d_addr==LAST_A;
                    mem_addr<=d_addr;mem_re<=1;
                    d_ph <= D_READ;
                end
                D_READ: begin

                    b_wa <= d_addr;
                    d_ph <= D_WRITE;
                end
                default: begin                       // D_WRITE
                    mem_we<=1;mem_addr<=b_wa;mem_wd<=dec16(b_q, decay_step);   // 每个 nibble 饱和 -step
                    if (decay_last) d_run <= 1'b0;
                    else begin
                        d_addr <= d_addr + 12'd1;
                        d_ph   <= D_ADDR;
                    end
                end
                endcase
            end
            // ── ③ 打点 ──────────────────────────────────────────
            else begin
                case (st)
                S_IDLE: if (pend) begin
                    // Capture the segment before deciding whether to connect.
                    tgt_x<=pdx;tgt_y<=pdy;adx<=ndx;ady<=ndy;
                    sx<=(pdx>=pen_x);sy<=(pdy>=pen_y);st<=S_PRE;
                end
                S_PRE: begin
                    line_ok<=pen_vld && adx<=(COORD_BITS==8?64:32) && ady<=(COORD_BITS==8?64:32);
                    berr<=$signed({3'b000,adx})-$signed({3'b000,ady});
                    st<=S_BEGIN;
                end
                S_BEGIN: begin
                    cur_x<=line_ok?pen_x:tgt_x;cur_y<=line_ok?pen_y:tgt_y;
                    adx<=line_ok?adx:0;ady<=line_ok?ady:0;
                    berr<=line_ok?berr:0;
                    neg_ady<=line_ok?-$signed({3'b000,ady}):0;
                    st<=S_ADDR;
                end
                S_ADDR: begin
                    at_tgt<=(cur_x==tgt_x) && (cur_y==tgt_y);
                    step_x<=do_x;step_y<=do_y;
                    // addr = y*32 + (x>>2)；cur_y / cur_x 均为 0..127

                    mem_addr<={cur_y[COORD_BITS-1:0], cur_x[COORD_BITS-1:PACK_BITS]};mem_re<=1;
                    b_wa   <= {cur_y[COORD_BITS-1:0], cur_x[COORD_BITS-1:PACK_BITS]};
                    p_sel  <= cur_x[PACK_BITS-1:0];
                    st     <= S_RD;
                end
                S_RD: begin
                    err_x<=berr-(step_x?$signed({3'b000,ady}):11'sd0);
                    err_y_add<=step_y?$signed({3'b000,adx}):11'sd0;
            // b_q 在 S_WR 那一拍有效
                    st  <= S_WR;
                end
                default: begin                 // S_WR
                    mem_we<=1;mem_addr<=b_wa;mem_wd<=inc16(b_q, p_sel, ink_step);
                    pen_x     <= cur_x;
                    pen_y     <= cur_y;
                    pen_vld   <= 1'b1;
                    if (at_tgt) st <= S_IDLE;
                    else begin
                        berr  <= err_x+err_y_add;
                        cur_x <= step_x ? (sx ? cur_x + 8'd1 : cur_x - 8'd1)
                                      : cur_x;
                        cur_y <= step_y ? (sy ? cur_y + 8'd1 : cur_y - 8'd1)
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
