//==========================================================================
//  param_cache —— 每个声部独占的"当前音"参数缓存（128 分量 × 3 bank）
//
//  这是总架构文档里 BSRAM 层的「② 各声部当前音参数缓存」。
//
//  为什么每声部一份而不是共用大表：
//    · 共用大表时，8 个声部必须相位错开（PH_SHIFT≥1）才能抢同一个读口，
//      于是 NVOICE ≤ 8 被死锁住。
//    · 每声部独占后，各声部可以同相位、同时读，PH_SHIFT 这条约束消失。
//    · BSRAM 用量：128×96bit = 12 Kbit → 1 块/声部，8 声部 = 8 块，
//      相比共用大表（钢琴 57 + 古筝 33 = 90 块）省下 82 块。
//
//  ★ 2026-10-31 改为【双时钟】：
//      写口 = clk_x1（100 MHz，DDR 用户域）—— ddr_param_dma 直接从 DDR 灌进来
//      读口 = 引擎时钟（50 MHz）—— 声部按分量号取参数
//    Gowin BSRAM 的 SDPB（简单双口）本来就支持读写各用独立时钟，代价为零。
//    这样【不需要】跨时钟 FIFO：8 个声部如果各配一组 96 位异步 FIFO，
//    要多花约 24 块 BSRAM。
//
//  ★ 写读可能撞同一地址：DMA 只在装载期写，此时声部读到旧数据无害。
//    数据一致性由"装载完成才 trig"保证（done 后才发 v_trig）。
//==========================================================================
`default_nettype none

module param_cache #(
    parameter integer NPART = 128
)(
    input  wire                wclk,       // 写时钟（DDR 侧，100 MHz）
    input  wire                rclk,       // 读时钟（引擎侧，50 MHz）

    // ── 写端口（DDR 取表 DMA 用）──────────────────────────────
    input  wire                we,
    input  wire [6:0]          waddr,      // 分量号 0..NPART-1
    input  wire [95:0]         wdata,      // {d2, d1, d0}

    // ── 读端口（声部用，同步读，1 拍延迟）────────────────────
    input  wire [6:0]          raddr,
    output reg  [31:0]         d0,
    output reg  [31:0]         d1,
    output reg  [31:0]         d2
);

    reg [95:0] mem [0:NPART-1];

    // ★ 仅仿真：上电内容未定义会让 iverilog 读 X 并永久传播
    `ifdef SIM_INIT
    integer i;
    initial for (i = 0; i < NPART; i = i + 1) mem[i] = 96'd0;
    `endif

    always @(posedge wclk) begin
        if (we) mem[waddr] <= wdata;
    end

    always @(posedge rclk) begin
        {d2, d1, d0} <= mem[raddr];
    end

endmodule

`default_nettype wire
