//==========================================================================
//  top —— ddr_bringup 顶层：DDR3 读写自测 + UART 报告
//
//  时钟架构（完全照 Sipeed 官方 DDR3 例程）：
//      clk (V22, 50 MHz)  ──► Gowin_PLL ──► memory_clk (400 MHz) ──► DDR3 IP
//                                                                      │
//                                                          clk_out ───┴──► clk_x1 (100 MHz)
//                                                                          用户逻辑域
//  串口跑在 50 MHz 域（独立于 DDR），115200 8N1，引脚 U15。
//
//  判据：
//      串口每秒打一行 64 字节报告，
//      最终 DN=1 / OK=1 / ER=00000000 即 DDR3 读写链路完全正确。
//==========================================================================
`default_nettype none

module top (
    input  wire        clk,
    input  wire        key1_F4,
    input  wire        uart_rx,
    output wire        uart_tx,
    output wire        led_V13,

    output wire [14:0] ddr_addr,
    output wire [2:0]  ddr_bank,
    output wire        ddr_cs,
    output wire        ddr_ras,
    output wire        ddr_cas,
    output wire        ddr_we,
    output wire        ddr_ck,
    output wire        ddr_ck_n,
    output wire        ddr_cke,
    output wire        ddr_odt,
    output wire        ddr_reset_n,
    output wire [3:0]  ddr_dm,
    inout  wire [31:0] ddr_dq,
    inout  wire [3:0]  ddr_dqs,
    inout  wire [3:0]  ddr_dqs_n
);

    localparam integer DRAM_NUM = 2;
    localparam integer ADDR_W   = 29;
    localparam integer NW       = 4096;      // 测 4096 个 256bit 字 = 128 KB

    //-------------------------------------------------- 复位（50 MHz 域）
    reg [7:0] por_cnt = 8'd0;
    always @(posedge clk) if (!por_cnt[7]) por_cnt <= por_cnt + 8'd1;
    // key1_F4 片内下拉，默认 0；按下为 1 → 复位
    wire rst_n = por_cnt[7] & ~key1_F4;

    //-------------------------------------------------- PLL：50 MHz → 400 MHz
    wire memory_clk;
    wire pll_lock;
    wire pll_stop;

    Gowin_PLL u_pll (
        .lock    (pll_lock),
        .clkout0 (),
        .clkout1 (),
        .clkout2 (memory_clk),
        .clkin   (clk),
        .init_clk(clk),
        .reset   (~rst_n),
        .enclk0  (1'b1),
        .enclk1  (1'b1),
        .enclk2  (pll_stop)
    );

    //-------------------------------------------------- DDR3 MC 用户接口
    wire              app_en;
    wire [2:0]        app_cmd;
    wire [ADDR_W-1:0] app_addr;
    wire [255:0]      app_wdf_data;
    wire              app_wdf_wren;
    wire              app_wdf_end;
    wire [31:0]       app_wdf_mask;
    wire              app_burst;
    wire              app_rdy;
    wire              wr_data_rdy;
    wire              app_rd_data_valid;
    wire              app_rd_data_end;
    wire [255:0]      app_rd_data;
    wire              init_calib_complete;
    wire              ddr_err;
    wire              clk_x1;

    //-------------------------------------------------- DDR3 IP
    DDR3_Memory_Interface_Top u_ddr3 (
        .memory_clk         (memory_clk),
        .pll_stop           (pll_stop),
        .clk                (clk),
        .rst_n              (rst_n),
        .cmd_ready          (app_rdy),
        .cmd                (app_cmd),
        .cmd_en             (app_en),
        .addr               (app_addr),
        .wr_data_rdy        (wr_data_rdy),
        .wr_data            (app_wdf_data),
        .wr_data_en         (app_wdf_wren),
        .wr_data_end        (app_wdf_end),
        .wr_data_mask       (app_wdf_mask),
        .rd_data            (app_rd_data),
        .rd_data_valid      (app_rd_data_valid),
        .rd_data_end        (app_rd_data_end),
        .sr_req             (1'b0),
        .ref_req            (1'b0),
        .sr_ack             (),
        .ref_ack            (),
        .init_calib_complete(init_calib_complete),
        .clk_out            (clk_x1),
        .pll_lock           (pll_lock),
        .burst              (app_burst),
        .ddr_rst            (),
        .O_ddr_addr         (ddr_addr),
        .O_ddr_ba           (ddr_bank),
        .O_ddr_cs_n         (ddr_cs),
        .O_ddr_ras_n        (ddr_ras),
        .O_ddr_cas_n        (ddr_cas),
        .O_ddr_we_n         (ddr_we),
        .O_ddr_clk          (ddr_ck),
        .O_ddr_clk_n        (ddr_ck_n),
        .O_ddr_cke          (ddr_cke),
        .O_ddr_odt          (ddr_odt),
        .O_ddr_reset_n      (ddr_reset_n),
        .O_ddr_dqm          (ddr_dm),
        .IO_ddr_dq          (ddr_dq),
        .IO_ddr_dqs         (ddr_dqs),
        .IO_ddr_dqs_n       (ddr_dqs_n)
    );

    //-------------------------------------------------- 读写自测（100 MHz 域）
    wire        st_done;
    wire        st_ok;
    wire [31:0] st_err;
    wire [31:0] st_wr;
    wire [31:0] st_rd;

    ddr_selftest #(.ADDR_W(ADDR_W), .NW(NW)) u_test (
        .clk                (clk_x1),
        .rst                (~init_calib_complete),
        .init_calib_complete(init_calib_complete),
        .app_cmd            (app_cmd),
        .app_en             (app_en),
        .app_addr           (app_addr),
        .app_wdf_data       (app_wdf_data),
        .app_wdf_wren       (app_wdf_wren),
        .app_wdf_end        (app_wdf_end),
        .app_wdf_mask       (app_wdf_mask),
        .app_burst          (app_burst),
        .app_rdy            (app_rdy),
        .wr_data_rdy        (wr_data_rdy),
        .app_rd_data_valid  (app_rd_data_valid),
        .app_rd_data        (app_rd_data),
        .done               (st_done),
        .ok                 (st_ok),
        .err_cnt            (st_err),
        .wr_cnt             (st_wr),
        .rd_cnt             (st_rd)
    );

    //-------------------------------------------------- 状态跨到 50 MHz 域
    //  单位信号两拍同步；多位数在 done 之后已经冻结，直接采即可
    reg cal_s0, cal_s1, dn_s0, dn_s1, ok_s0, ok_s1;
    always @(posedge clk) begin
        cal_s0 <= init_calib_complete;  cal_s1 <= cal_s0;
        dn_s0  <= st_done;              dn_s1  <= dn_s0;
        ok_s0  <= st_ok;                ok_s1  <= ok_s0;
    end

    reg [31:0] wr_s, rd_s, er_s;
    always @(posedge clk) if (dn_s1) begin
        wr_s <= st_wr;
        rd_s <= st_rd;
        er_s <= st_err;
    end

    assign led_V13 = ok_s1 ? 1'b0 : 1'b1;    // 通过则点亮（低有效）

    //-------------------------------------------------- 串口发送器
    reg        send;
    wire       txbusy;
    reg  [7:0] dbyte;

    uart_tx #(.CLK_HZ(50_000_000), .BAUD(115_200)) u_tx (
        .clk   (clk),
        .rst_n (rst_n),
        .dbyte (dbyte),
        .send  (send),
        .busy  (txbusy),
        .txd   (uart_tx)
    );

    //-------------------------------------------------- 报告（每秒 64 字节）
    function [7:0] hx (input [3:0] v);
        hx = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h37 + {4'd0, v});
    endfunction

    localparam integer GAP = 25_000_000;     // 0.5 s @50MHz

    reg [7:0]  obuf [0:63];
    reg [7:0]  oidx;
    reg [1:0]  hs;
    reg [31:0] cnt;
    reg        go;

    always @(posedge clk) begin
        if (!rst_n) begin
            oidx <= 8'd0; hs <= 2'd0; cnt <= 32'd0; go <= 1'b1;
            send <= 1'b0; dbyte <= 8'h00;
        end
        else begin
            send <= 1'b0;

            if (hs == 2'd0 && !txbusy) begin
                if (go) begin
                    // 组包
                    obuf[ 0] <= 8'h0D; obuf[ 1] <= 8'h0A;
                    obuf[ 2] <= 8'h44; obuf[ 3] <= 8'h44; obuf[ 4] <= 8'h52;   // DDR
                    obuf[ 5] <= 8'h0D; obuf[ 6] <= 8'h0A;
                    obuf[ 7] <= 8'h49; obuf[ 8] <= 8'h43; obuf[ 9] <= 8'h3D;   // IC=
                    obuf[10] <= hx({3'b000, cal_s1});
                    obuf[11] <= 8'h0D; obuf[12] <= 8'h0A;
                    obuf[13] <= 8'h57; obuf[14] <= 8'h52; obuf[15] <= 8'h3D;   // WR=
                    obuf[16] <= hx(wr_s[31:28]); obuf[17] <= hx(wr_s[27:24]);
                    obuf[18] <= hx(wr_s[23:20]); obuf[19] <= hx(wr_s[19:16]);
                    obuf[20] <= hx(wr_s[15:12]); obuf[21] <= hx(wr_s[11: 8]);
                    obuf[22] <= hx(wr_s[ 7: 4]); obuf[23] <= hx(wr_s[ 3: 0]);
                    obuf[24] <= 8'h0D; obuf[25] <= 8'h0A;
                    obuf[26] <= 8'h52; obuf[27] <= 8'h44; obuf[28] <= 8'h3D;   // RD=
                    obuf[29] <= hx(rd_s[31:28]); obuf[30] <= hx(rd_s[27:24]);
                    obuf[31] <= hx(rd_s[23:20]); obuf[32] <= hx(rd_s[19:16]);
                    obuf[33] <= hx(rd_s[15:12]); obuf[34] <= hx(rd_s[11: 8]);
                    obuf[35] <= hx(rd_s[ 7: 4]); obuf[36] <= hx(rd_s[ 3: 0]);
                    obuf[37] <= 8'h0D; obuf[38] <= 8'h0A;
                    obuf[39] <= 8'h45; obuf[40] <= 8'h52; obuf[41] <= 8'h3D;   // ER=
                    obuf[42] <= hx(er_s[31:28]); obuf[43] <= hx(er_s[27:24]);
                    obuf[44] <= hx(er_s[23:20]); obuf[45] <= hx(er_s[19:16]);
                    obuf[46] <= hx(er_s[15:12]); obuf[47] <= hx(er_s[11: 8]);
                    obuf[48] <= hx(er_s[ 7: 4]); obuf[49] <= hx(er_s[ 3: 0]);
                    obuf[50] <= 8'h0D; obuf[51] <= 8'h0A;
                    obuf[52] <= 8'h44; obuf[53] <= 8'h4E; obuf[54] <= 8'h3D;   // DN=
                    obuf[55] <= hx({3'b000, dn_s1});
                    obuf[56] <= 8'h0D; obuf[57] <= 8'h0A;
                    obuf[58] <= 8'h4F; obuf[59] <= 8'h4B; obuf[60] <= 8'h3D;   // OK=
                    obuf[61] <= hx({3'b000, ok_s1});
                    obuf[62] <= 8'h0D; obuf[63] <= 8'h0A;
                    oidx <= 8'd0;
                    go   <= 1'b0;
                end
            end

            case (hs)
            2'd0: if (!go && !txbusy) begin
                      dbyte <= obuf[oidx];
                      send  <= 1'b1;
                      hs    <= 2'd1;
                  end
            2'd1: if (txbusy) hs <= 2'd2;
            2'd2: if (!txbusy) begin
                      hs <= 2'd0;
                      if (oidx == 8'd63) begin
                          oidx <= 8'd0;
                          cnt  <= 32'd0;
                      end
                      else oidx <= oidx + 8'd1;
                  end
            default: hs <= 2'd0;
            endcase

            // 间隔后重新组包
            if (!go) begin
                cnt <= cnt + 32'd1;
                if (cnt >= GAP) go <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
