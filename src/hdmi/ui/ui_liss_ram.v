//==========================================================================
//  ui_liss_ram —— 相图（李萨如）位图 256×256，按 16 位字存
//
//  4096 word × 16 bit：一个 word = 一行里的 16 个像素
//      addr = row*16 + (x>>4)，bit = x&15
//
//  写口只有一个 always 块（★ 数组不能多块驱动，否则综合器报多驱动）：
//    · 场消隐期间：逐字清零（4096 拍 @75 MHz = 54 us，消隐 550 us，够）
//    · 有效显示期间：每个样点打一个点（读-改-写，3 拍）
//  读口：扫描时读一个 word，按 bit 选像素，2×2 上采样
//==========================================================================
`default_nettype none

module ui_liss_ram (
    input  wire        clk,
    input  wire        rst_n,

    // ── 打点（与 clk 同域）──────────────────────────────────────
    input  wire        plot,        // 单拍：本拍要打一个点
    input  wire [7:0]  plot_x,      // 0..255
    input  wire [7:0]  plot_y,      // 0..255

    // ── 清零（场消隐）────────────────────────────────────────────
    input  wire        clr_en,      // 1 = 启动一次清零扫描
    output reg         clr_done,

    // ── 读口（扫描）──────────────────────────────────────────────
    input  wire [11:0] raddr,
    output reg  [15:0] rdata
);
    reg [15:0] m [0:4095];

    // ── 打点状态机 ───────────────────────────────────────────────
    localparam [1:0] P_IDLE = 2'd0, P_RD = 2'd1, P_WR = 2'd2;
    reg [1:0]  pst;
    reg [11:0] p_addr;
    reg [4:0]  p_bit;
    reg [15:0] p_dat;

    // ── 清零扫描 ─────────────────────────────────────────────────
    reg [11:0] c_addr;
    reg        c_run;

    // 单 always 块驱动 m
    always @(posedge clk) begin
        if (!rst_n) begin
            pst      <= P_IDLE;
            p_addr   <= 12'd0;
            p_bit    <= 5'd0;
            p_dat    <= 16'd0;
            c_run    <= 1'b0;
            c_addr   <= 12'd0;
            clr_done <= 1'b0;
            rdata    <= 16'd0;
        end
        else begin
            clr_done <= 1'b0;
            rdata    <= m[raddr];              // 读口

            if (clr_en) begin
                c_run  <= 1'b1;
                c_addr <= 12'd0;
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
                case (pst)
                P_IDLE: if (plot) begin
                    p_addr <= {plot_y[7:0], 4'd0} + {8'd0, plot_x[7:4]};
                    p_bit  <= {1'b0, plot_x[3:0]};
                    pst    <= P_RD;
                end
                P_RD: begin
                    p_dat <= m[p_addr];
                    pst   <= P_WR;
                end
                default: begin                 // P_WR
                    m[p_addr] <= p_dat | (16'd1 << p_bit);
                    pst       <= P_IDLE;
                end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
