//==========================================================================
//  sd_async_fifo —— 8 位宽、双时钟（写 50 MHz / 读 100 MHz）异步 FIFO
//
//  为什么需要它：
//      sd_file_list_reader（FAT32 簇链计算里有组合乘法 mul）在 50 MHz 下
//      勉强收敛（sd_bringup 实测 0 违例），但在 clk_x1 = 100 MHz 域
//      实测 SETUP = **−6.175 ns**（路径 19.9 ns vs 周期 10 ns）。
//      所以 SD 栈必须留在 50 MHz，而 DDR3 MC 用户口必须跑 clk_x1。
//      中间就要一个跨时钟 FIFO —— 就是本模块。
//
//  位宽 8 位、深度 256：
//      生产速率 12.5 MHz sdclk / 8 = 1.56 MB/s；
//      消费速率 100 MHz（远大于生产）→ FIFO 永远近乎空，深度 256 绰绰有余。
//      256×8 = 2048 bit，Gowin 会推断成 1 块 BSRAM（SDP：写口 wclk、读口 rclk）。
//
//  实现是 Cummings 标准异步 FIFO：
//      指针用格雷码，跨域只同步格雷码（每次只变 1 位 → 不会采到错误中间值）。
//      空：rgray == 同步过来的 wgray
//      满：wgray == {~(同步来的 rgray 高 2 位), 其余位}
//
//  ★ 读口有 1 拍延迟：rdata 在 rinc 有效后下一拍才出来。
//    消费方用法：rinc = ~rempty（每拍只要有数据就弹），
//                用 rinc_d（= rinc 打一拍）作为 rdata 的有效标志。
//==========================================================================
`default_nettype none

module sd_async_fifo #(
    parameter integer AW = 8                 // 深度 = 2**AW
)(
    // ── 写侧 ──
    input  wire       wclk,
    input  wire       wrst,                  // 高有效，同步于 wclk
    input  wire       win,
    input  wire [7:0] wdata,
    output wire       wfull,

    // ── 读侧 ──
    input  wire       rclk,
    input  wire       rrst,                  // 高有效，同步于 rclk
    input  wire       ren,                   // ★ 消费者读使能
    output reg  [7:0] rdata,
    output wire       rinc,                  // 读使能 & 非空
    output reg        rinc_d,                // rdata 有效标志（rinc 打一拍）
    output wire       rempty
);

localparam integer DEPTH = 1 << AW;

reg [7:0]  mem [0:DEPTH-1];

reg [AW:0] wbin,  wgray;
reg [AW:0] rbin,  rgray;
reg [AW:0] rgray_w1, rgray_w2;               // 读指针同步到写域
reg [AW:0] wgray_r1, wgray_r2;               // 写指针同步到读域

wire [AW:0] wbin_nxt  = wbin + {{AW{1'b0}}, (win & ~wfull)};
wire [AW:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
wire [AW:0] rbin_nxt  = rbin + {{AW{1'b0}}, (rinc & ~rempty)};
wire [AW:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

assign wfull  = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
assign rempty = (rgray == wgray_r2);
//  ★★ 曾经写成 `rinc = ~rempty`（读指针自由运行），后果很严重：
//     100 MHz 侧还没进入读取状态（比如上电横幅要发 2 ms）时，
//     那段时间已经写进 FIFO 的字节会被【直接弹掉丢弃】——
//     实测文件头 32 字节就这样丢了，校验和永远不对。
//     所以弹出必须由消费者用 ren 控制。
assign rinc   = ren & ~rempty;

//---------------------------------------------------------------- 写侧
always @(posedge wclk) begin
    if (wrst) begin
        wbin     <= {(AW+1){1'b0}};
        wgray    <= {(AW+1){1'b0}};
        rgray_w1 <= {(AW+1){1'b0}};
        rgray_w2 <= {(AW+1){1'b0}};
    end
    else begin
        wbin     <= wbin_nxt;
        wgray    <= wgray_nxt;
        rgray_w1 <= rgray;
        rgray_w2 <= rgray_w1;
    end
end

always @(posedge wclk) begin
    if (win && !wfull) mem[wbin[AW-1:0]] <= wdata;
end

//---------------------------------------------------------------- 读侧
always @(posedge rclk) begin
    if (rrst) begin
        rbin      <= {(AW+1){1'b0}};
        rgray     <= {(AW+1){1'b0}};
        wgray_r1  <= {(AW+1){1'b0}};
        wgray_r2  <= {(AW+1){1'b0}};
        rdata     <= 8'd0;
        rinc_d    <= 1'b0;
    end
    else begin
        rbin      <= rbin_nxt;
        rgray     <= rgray_nxt;
        wgray_r1  <= wgray;
        wgray_r2  <= wgray_r1;
        rinc_d    <= rinc;
        if (rinc) rdata <= mem[rbin[AW-1:0]];
    end
end

endmodule

`default_nettype wire
