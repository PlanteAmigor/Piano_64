//==========================================================================
//  ddr_param_dma —— note-on 时从 DDR3 把一个音的 128 个分量灌进声部 cache
//
//  取代原来的 param_dma（从 BSRAM 源表取数）。数据源变成 DDR 后，
//  源表 ROM（钢琴 57 + 古筝 33 ≈ 90 块 BSRAM）可以全部释放。
//
//  ── DDR 镜像格式 v2（对应该模块）──────────────────────────────
//      每个 256 位字装 2 个完整分量，每分量 16 字节 {d0, d1, d2, 0}
//      → 一个音 = 128 分量 ÷ 2 = 64 个 256 位字
//      所以一拍 DDR 读回来正好对应 2 个 cache 条目，纯顺序流，
//      不需要跨拍拼接、不需要中间缓冲。
//
//  ── 时钟域 ──────────────────────────────────────────────────
//      本模块整体跑在 clk = clk_x1（100 MHz，DDR MC 用户域）。
//      它直接写 param_cache 的写口（cache 是双时钟 SDP BSRAM，
//      写口 100 MHz、读口 50 MHz），因此不需要跨时钟 FIFO。
//      与 50 MHz 引擎之间只传两个信号：
//          start_tog : 启动（翻转信号，调用方已两拍同步到 clk）
//          done_tog  : 完成（翻转信号，调用方自行两拍同步回 clk50）
//      base_addr 在 start_tog 翻转前就稳定，直接采样即可。
//
//  ── 为什么一次只发一条读命令 ────────────────────────────────
//      单条流水：命令 ~8 拍延迟 + 2 拍写 cache ≈ 10 拍/beat，
//      64 beat ≈ 640 拍 = 6.4 µs/音。8 个音串行 = 51 µs，
//      远小于钢琴起音可辨阈值（约 5 ms），完全够用。
//      换来的是状态机极简、绝无拥塞与数据丢失风险
//      （之前 SD→DDR 加载器在写队列握手上的坑就是"并发"带来的）。
//==========================================================================
`default_nettype none

module ddr_param_dma #(
    parameter integer WORDS_PER_NOTE = 64,   // 每音的 256 位字数
    parameter integer ADDR_SHIFT     = 3     // word → DDR 地址单位（×8）
)(
    input  wire         clk,            // clk_x1 = 100 MHz
    input  wire         rst_n,

    // ── 与 50 MHz 引擎的跨域握手 ──────────────────────────────
    input  wire         start_tog,      // 已同步到 clk 的翻转信号
    input  wire [28:0]  base_addr,      // 该音在 DDR 的起始 word 地址（装载期间稳定）
    output reg          done_tog,       // 完成后翻转
    output wire         busy,

    // ── param_cache 写口（clk）────────────────────────────────
    output reg          we,
    output reg  [6:0]   waddr,
    output reg  [95:0]  wdata,

    // ── DDR 用户口（clk）──────────────────────────────────────
    output reg  [2:0]   app_cmd,
    output reg          app_en,
    output reg  [28:0]  app_addr,
    input  wire         app_rdy,
    input  wire         app_rd_data_valid,
    input  wire [255:0] app_rd_data
);

    localparam [2:0]
        S_IDLE = 3'd0,
        S_CMD  = 3'd1,      // 等命令被接受
        S_WAIT = 3'd2,      // 等读数据回来
        S_W0   = 3'd3,      // 写分量 2w
        S_W1   = 3'd4;      // 写分量 2w+1

    reg [2:0]   st;
    reg         start_prev;
    reg [28:0]  base_q;
    reg [5:0]   w;              // 已收 beat 数 0..WORDS_PER_NOTE-1
    reg [255:0] beat;

    assign busy = (st != S_IDLE);

    // start_tog 上升/下降沿都算一次启动
    wire go = (start_tog != start_prev);

    always @(posedge clk) begin
        if (!rst_n) begin
            st         <= S_IDLE;
            start_prev <= 1'b0;
            base_q     <= 29'd0;
            w          <= 6'd0;
            beat       <= 256'd0;
            we         <= 1'b0;
            waddr      <= 7'd0;
            wdata      <= 96'd0;
            done_tog   <= 1'b0;
            app_cmd    <= 3'b001;
            app_en     <= 1'b0;
            app_addr   <= 29'd0;
        end
        else begin
            start_prev <= start_tog;

            case (st)

            //──────────────────────────────── 空闲，等启动
            S_IDLE: begin
                we <= 1'b0;
                if (go) begin
                    base_q   <= base_addr;
                    w        <= 6'd0;
                    app_cmd  <= 3'b001;                        // 读
                    app_addr <= base_addr << ADDR_SHIFT;
                    app_en   <= 1'b1;
                    st       <= S_CMD;
                end
            end

            //──────────────────────────────── 等命令握手
            S_CMD: begin
                if (app_rdy) begin
                    app_en <= 1'b0;
                    st     <= S_WAIT;
                end
            end

            //──────────────────────────────── 等读数据，锁存整拍
            S_WAIT: begin
                if (app_rd_data_valid) begin
                    beat  <= app_rd_data;
                    waddr <= {w, 1'b0};                        // 分量 2w
                    wdata <= app_rd_data[95:0];                // {d2,d1,d0}
                    we    <= 1'b1;                             // 下一拍写入
                    st    <= S_W0;
                end
            end

            //──────────────────────────────── 写分量 2w，接着写 2w+1
            S_W0: begin
                waddr <= {w, 1'b1};                            // 分量 2w+1
                wdata <= beat[223:128];                        // 第二个 16 字节段的 {d2,d1,d0}
                we    <= 1'b1;
                st    <= S_W1;
            end

            //──────────────────────────────── 收尾 / 发下一条
            S_W1: begin
                we <= 1'b0;
                if (w == WORDS_PER_NOTE[5:0] - 6'd1) begin
                    done_tog <= ~done_tog;
                    st       <= S_IDLE;
                end
                else begin
                    w        <= w + 6'd1;
                    app_cmd  <= 3'b001;
                    app_addr <= (base_q + {{23{1'b0}}, w} + 29'd1) << ADDR_SHIFT;
                    app_en   <= 1'b1;
                    st       <= S_CMD;
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
