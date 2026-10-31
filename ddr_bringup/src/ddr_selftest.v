//==========================================================================
//  ddr_selftest —— DDR3 读写自测（跑在 clk_x1 = 100 MHz 用户时钟域）
//
//  做什么：
//      1. 等 init_calib_complete
//      2. 从地址 0 起连续写 NW 个 256 位字，图案由字序号决定（与位置强相关）
//      3. 连续读回 NW 个字，逐个比对
//      4. 报告：读回字数、错误数、OK/FAIL
//
//  为什么图案要跟序号强相关：
//      如果写进去是常数，地址线错位也照样"通过"。这里每个字的 4 个 32 位段
//      分别是 i 的不同字节和反码，只要地址错一个字立刻对不上。
//
//  ── Gowin DDR3 MC 用户接口协议（照官方 ddrtest.v 的用法）──────────────
//      写：app_cmd=3'b000，app_en 与 app_addr 同拍；数据走独立通道
//          app_wdf_wren / app_wdf_data / app_wdf_end
//      读：app_cmd=3'b001，app_en 与 app_addr 同拍；数据回 app_rd_data_valid
//      app_en        = cmd_valid && app_rdy     （组合，保证只发一次）
//      app_wdf_wren  = wdf_valid && wr_data_rdy
//      app_wdf_mask  恒 0（不屏蔽字节）
//      app_burst     恒 0（单拍传输）
//==========================================================================
`default_nettype none

module ddr_selftest #(
    parameter integer ADDR_W = 29,
    parameter integer NW     = 4096        // 测多少个 256bit 字（4096 × 32B = 128 KB）
)(
    input  wire              clk,          // clk_x1 = 100 MHz
    input  wire              rst,          // 高有效
    input  wire              init_calib_complete,

    // ── DDR3 MC 用户接口
    output wire [2:0]        app_cmd,
    output wire              app_en,
    output wire [ADDR_W-1:0] app_addr,
    output wire [255:0]      app_wdf_data,
    output wire              app_wdf_wren,
    output wire              app_wdf_end,
    output wire [31:0]       app_wdf_mask,
    output wire              app_burst,
    input  wire              app_rdy,
    input  wire              wr_data_rdy,
    input  wire              app_rd_data_valid,
    input  wire [255:0]      app_rd_data,

    // ── 结果
    output reg               done,
    output reg               ok,
    output reg  [31:0]       err_cnt,
    output reg  [31:0]       wr_cnt,
    output reg  [31:0]       rd_cnt
);

//---------------------------------------------------------------- 图案
//  ★★★ v2：每个 32 位 lane 内容都不同 ★★★
//  原来写的是 { w, w, w, w, w, w, w, w }（8 个 lane 完全相同），
//  **lane 之间的错位/交换完全测不出来** —— 这正是 piano64 的 SD→DDR 加载器
//  在板上校验和永远不对、而这里却报 OKAY 的原因。
//  现在 dword0..7 = 8*i+0 .. 8*i+7，整片 DDR 是一条线性 dword 序列，
//  任何一个 lane 错位、任何 beat 边界错位都会立刻被抓到。
function [255:0] pat (input [31:0] i);
    reg [31:0] base;
    begin
        base = i * 32'd8;
        pat  = { base + 32'd7, base + 32'd6, base + 32'd5, base + 32'd4,
                 base + 32'd3, base + 32'd2, base + 32'd1, base + 32'd0 };
    end
endfunction

//---------------------------------------------------------------- 状态机
localparam [2:0]
    S_IDLE  = 3'd0,      // 等校准
    S_WRQ   = 3'd1,      // 发写命令
    S_WRW   = 3'd2,      // 等写命令和写数据都被接受
    S_RDQ   = 3'd3,      // 发读命令
    S_RDW   = 3'd4,      // 等读命令被接受
    S_RDC   = 3'd5,      // 等读数据并比对
    S_DONE  = 3'd6;

reg [2:0]  st;
reg [31:0] i;            // 写/读进度

reg              cmd_valid;
reg              cmd_is_wr;
reg [ADDR_W-1:0] cmd_addr;
reg              cmd_sent;

reg              wdf_valid;
reg [255:0]      wdf_data;
reg              wdf_sent;

//---------------------------------------------------------------- 命令/数据通道
assign app_en       = cmd_valid && app_rdy;
assign app_cmd      = cmd_is_wr ? 3'b000 : 3'b001;
assign app_addr     = cmd_addr;

assign app_wdf_wren = wdf_valid && wr_data_rdy;
assign app_wdf_end  = app_wdf_wren;
assign app_wdf_data = wdf_data;
assign app_wdf_mask = 32'd0;
assign app_burst    = 1'b0;

//---------------------------------------------------------------- 主逻辑
always @(posedge clk) begin
    if (rst) begin
        st        <= S_IDLE;
        i         <= 32'd0;
        cmd_valid <= 1'b0;
        cmd_is_wr <= 1'b0;
        cmd_addr  <= {ADDR_W{1'b0}};
        cmd_sent  <= 1'b0;
        wdf_valid <= 1'b0;
        wdf_data  <= 256'd0;
        wdf_sent  <= 1'b0;
        done      <= 1'b0;
        ok        <= 1'b0;
        err_cnt   <= 32'd0;
        wr_cnt    <= 32'd0;
        rd_cnt    <= 32'd0;
    end
    else begin
        case (st)

        //------------------------------------------------ 等 DDR 校准完成
        S_IDLE: begin
            if (init_calib_complete) begin
                i <= 32'd0;
                st <= S_WRQ;
            end
        end

        //------------------------------------------------ 发写命令 + 写数据
        S_WRQ: begin
            cmd_valid <= 1'b1;
            cmd_is_wr <= 1'b1;
            cmd_addr  <= i[ADDR_W-1:0];
            cmd_sent  <= 1'b0;
            wdf_valid <= 1'b1;
            wdf_data  <= pat(i);
            wdf_sent  <= 1'b0;
            st        <= S_WRW;
        end

        S_WRW: begin
            // app_en / app_wdf_wren 是组合输出，在本拍就有效
            if (app_en) begin
                cmd_valid <= 1'b0;
                cmd_sent  <= 1'b1;
            end
            if (app_wdf_wren) begin
                wdf_valid <= 1'b0;
                wdf_sent  <= 1'b1;
            end

            if ((cmd_sent || app_en) && (wdf_sent || app_wdf_wren)) begin
                wr_cnt <= wr_cnt + 32'd1;
                if (i == NW - 1) begin
                    i  <= 32'd0;
                    st <= S_RDQ;
                end
                else begin
                    i  <= i + 32'd1;
                    st <= S_WRQ;
                end
            end
        end

        //------------------------------------------------ 发读命令
        S_RDQ: begin
            cmd_valid <= 1'b1;
            cmd_is_wr <= 1'b0;
            cmd_addr  <= i[ADDR_W-1:0];
            st        <= S_RDW;
        end

        S_RDW: begin
            if (app_en) begin
                cmd_valid <= 1'b0;
                if (i == NW - 1) st <= S_RDC;     // 命令发完，等数据回来
                else begin
                    i  <= i + 32'd1;
                    st <= S_RDQ;
                end
            end
        end

        //------------------------------------------------ 收读数据并比对
        S_RDC: begin
            if (app_rd_data_valid) begin
                rd_cnt <= rd_cnt + 32'd1;
                if (app_rd_data !== pat(rd_cnt))
                    err_cnt <= err_cnt + 32'd1;
                if (rd_cnt == NW - 1) begin
                    ok   <= (err_cnt == 32'd0);
                    done <= 1'b1;
                    st   <= S_DONE;
                end
            end
        end

        S_DONE: begin end

        default: st <= S_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
