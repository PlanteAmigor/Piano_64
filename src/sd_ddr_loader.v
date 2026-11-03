//==========================================================================
//  sd_ddr_loader —— 上电把 SD 卡上的 P64.BIN 灌进 DDR3，再整片读回校验
//
//  《总架构.md》§6「上电加载流程」：
//      SD 初始化 → FAT32 找 P64.BIN → 字节流 → 拼 256 位字 → 写 DDR
//      → 读回复算校验和 → 与文件头比对 → 置 load_ok
//
//  ═══════════════ 为什么必须拆两个时钟域 ═══════════════
//  DDR3 MC 用户口同步于 clk_x1（Gowin IP 产生，100 MHz）—— ddr_bringup 的
//  自测就是在 clk_x1 上跑的，`DDR3 TEST OKAY!` 已验证。
//  但 sd_file_list_reader 的 FAT32 簇链计算里有一段【组合乘法】
//  （综合网表里的 mult_18965），实测在 100 MHz 下
//      SETUP = −6.175 ns（路径 19.9 ns vs 周期 10 ns）
//  它在 sd_bringup 里能跑，是因为那边整个设计就是 50 MHz。
//
//  所以本模块一分为二：
//      ┌─ 50 MHz 域（CLOCK_50）：SD 栈 + FAT 状态机 + 字节入 FIFO
//      │      见 sd_async_fifo.v —— 深度 256、8 位宽、1 块 BSRAM
//      └─ 100 MHz 域（clk_x1）：出 FIFO → 拼 256 位 → 写 DDR → 读回校验 → 串口
//
//  跨域信号：
//      数据：sd_async_fifo（格雷码指针，标准异步 FIFO）
//      控制：end_tog（单 bit 翻转信号，2 拍同步）
//            nfiles / file_no / found（在 end_tog 之前早就稳定，直接采）
//
//  ═══════════════ 镜像格式 ═══════════════
//  由 tools/make_ddr_image.py 生成，见该文件头注释。
//      word 0   = 32 字节文件头（magic "P64I"、total_words、checksum、
//                                 piano_base_word/lo、gz_base_word/lo）
//      word 1.. = 平面排布参数表（每音 3 bank × 16 word）
//
//  字节序：wrev 把 32 字节倒序接出，使「文件第 0 字节」落在
//      app_wdf_data[7:0]，即 DDR 该 word 的最低地址字节。
//
//  串口输出（115200 8N1，跑在 clk_x1 域）：
//      \r\nLD NF=xx FN=xxx BY=xxxxxxxx WD=xxxxxxxx CK=xxxxxxxx OV=xx OK=x\r\n
//    NF 根目录文件总数  FN P64.BIN 的 1 起编号  BY 字节数
//    WD 写进 DDR 的字数 CK 读回算出的校验和   OV 溢出计数  OK 1=全对
//==========================================================================
`default_nettype none

module sd_ddr_loader #(
    parameter integer CLK50_HZ  = 50_000_000,
    parameter integer CLK100_HZ = 100_000_000,
    parameter integer BOOT_MS   = 300,
    parameter [31:0]  MAX_BYTES = 32'd1_280_000,
    // ★ 版本号：每次改加载器就 +1，横幅会打出来。
    //   板子经常“配置假死”（烧了但 FPGA 还跑旧码流）——
    //   靠这个数立刻能分辨“代码没生效”还是“代码生效但逻辑不对”。
    parameter integer VER       = 9,
    // ★ DDR 命令地址步长（每个 256 位 beat 前进多少个 addr 单位）
    //   ★★ 实测 + 参数推导确定：必须 = 8 ★★
    //   gwmc_param.v: nCK_PER_CLK=4, DQ_WIDTH=32, APP_DATA_WIDTH=256,
    //                 BANK_WIDTH=3, ROW_WIDTH=15, COL_WIDTH=10
    //   地址位宽 = 3+15+10 = 28 → 2^28 个单位；内存 1 GiB = 2^30 B
    //   ⇒ 每个 addr 单位 = 4 字节（一个 32 位 DRAM 字）
    //   一个 256 位 beat = 8 个 32 位字 ⇒ addr 每拍 +8
    //   （步长 1 时 8 倍重叠，后写盖前写 → 校验和永远错，现象是"某个 dword
    //     在两个地址都读到"，正是我们实测到的 HT==D1）
    parameter integer ADDR_SHIFT  = 3   // addr 每拍前进 2^3 = 8 个单位
)(
    // ── 时钟 / 复位 ──
    input  wire         clk50,           // CLOCK_50
    input  wire         clk100,          // clk_x1（DDR MC 用户域）
    input  wire         arst_n,          // 异步低有效复位（内部各域自行同步）

    input  wire         calib_done,      // init_calib_complete（clk100 域）

    // ★ 诊断：DDR PLL 锁定 / 上电复位完成 / 板载复位按钮
    input  wire         dbg_pll,
    input  wire         dbg_por_n,
    input  wire         dbg_reset_n,

    // ── SD 卡（1-bit 模式，clk50 域）──
    output wire         sd_clk,
    inout  wire         sd_cmd,
    input  wire         sd_dat0,

    // ── DDR3 MC 用户口（clk100 域）──
    output wire [2:0]   app_cmd,
    output wire         app_en,
    output wire [28:0]  app_addr,
    output wire [255:0] app_wdf_data,
    output wire         app_wdf_wren,
    output wire         app_wdf_end,
    output wire [31:0]  app_wdf_mask,
    output wire         app_burst,
    input  wire         app_rdy,
    input  wire         wr_data_rdy,
    input  wire         app_rd_data_valid,
    input  wire [255:0] app_rd_data,

    // ── 结果（clk100 域）──
    output reg          load_done,
    output reg          load_ok,
    output reg  [3:0]   stage,
    output reg  [31:0]  nbytes,
    output reg  [31:0]  nwords,
    output reg  [31:0]  err_ov,
    output reg  [11:0]  nfiles,
    output reg  [11:0]  file_no,

    // ── 串口（clk100 域）──
    output wire         uart_txd,
    // Song catalog/read interface, entirely in clk50. Request is a toggle;
    // request_index is held stable until transfer_end changes.
    input wire song_request,
    input wire [3:0] song_request_index,
    output reg [4:0] song_file_count,
    output reg [127:0] song_ids,
    output reg song_catalog_done,
    output reg song_busy,
    output wire [7:0] song_byte,
    output wire song_byte_valid,
    output reg song_begin,
    output reg song_end,
    output reg song_error,
    input wire store_request,output reg store_grant
);

//==========================================================================
//  第 0 部分：两个域的复位（异步置位、同步释放）
//==========================================================================
reg [1:0] r50s, r100s;
always @(posedge clk50)  r50s  <= {r50s[0],  ~arst_n};
always @(posedge clk100) r100s <= {r100s[0], ~arst_n};
wire rst50  = r50s[1];
wire rst100 = r100s[1];

// 等 DDR 校准完成后，100 MHz 域才允许干活
wire rst100_go = rst100 | ~calib_done;

//==========================================================================
//  第 1 部分：50 MHz 域 —— SD 栈 + FAT 状态机 + 入 FIFO
//==========================================================================
localparam [3:0]
    P_BOOT   = 3'd0,
    P_LS_RST = 3'd1,
    P_LS_RUN = 3'd2,
    P_RD_RST = 3'd3,
    P_RD_RUN = 3'd4,
    P_DONE   = 3'd5,
    P_SLS_RST = 3'd6, P_SLS_RUN = 3'd7,
    P_SRD_RST = 4'd8, P_SRD_RUN = 4'd9, P_PARK=4'd10, P_STORE=4'd11;


localparam integer BOOTD50 = CLK50_HZ / 1000 * BOOT_MS;
localparam [31:0]  TMO_LS50 = 32'd30_000_000;    // 列目录超时 0.6 s
localparam [31:0]  TMO_RD50 = 32'd200_000_000;   // 读文件超时 4 s

reg         f_rstn;
reg         f_op;
reg  [11:0] f_num;
wire [2:0]  f_done;
wire [1:0]  fs_type;
wire        f_found;
wire [7:0]  lname [0:51];
wire [7:0]  lnamelen;
wire [11:0] lfilenum;
wire        ln_en;
wire        o_en;
wire [7:0]  o_byte;

sd_file_list_reader #(
    .CLK_DIV  (3'd1),        // 50 MHz → sdclk 12.5 MHz
    .SIMULATE (0)
) u_f (
    .rstn                 (f_rstn),
    .clk                  (clk50),
    .sdclk                (sd_clk),
    .sdcmd                (sd_cmd),
    .sddat0               (sd_dat0),
    .op                   (f_op),
    .read_file            (f_num),
    .done                 (f_done),
    .card_stat            (),
    .card_type            (),
    .filesystem_type      (fs_type),
    .file_found           (f_found),
    .list_name            (lname),
    .list_namelen         (lnamelen),
    .list_file_num        (lfilenum),
    .list_en              (ln_en),
    .outen                (o_en),
    .outbyte              (o_byte),
    .debug_read_done      (),
    .debug_read_sector_no (),
    .debug_filesystem_state ()
);

// "P64.BIN"
wire is_p64 = (lname[0] == 8'h50) && (lname[1] == 8'h36) && (lname[2] == 8'h34) &&
              (lname[3] == 8'h2E) && (lname[4] == 8'h42) && (lname[5] == 8'h49) &&
              (lname[6] == 8'h4E) &&
              ((lname[7] == 8'h00) || (lname[7] == 8'h20));

// 本拍（list_en 与命中同拍）就算找到 —— 用于规避非阻塞读后写
wire found_hit = ln_en && is_p64 && (p_file_no == 12'hFFF);

reg [3:0]  pst;
reg [31:0] pcnt;
reg [11:0] p_nfiles, p_file_no;
reg        p_found;
reg        end_tog;              // 生产结束翻转信号
reg [31:0] p_bytes;
reg        win;
reg [7:0]  wdata;

// ★★ 100 MHz 侧就绪握手：只有它进了读取状态，50 MHz 侧才能开始吐字节。
//    否则 FIFO（深度 256）会被写爆，且早到的字节会被当成“已消费”丢掉。
reg        rd_ready;
reg [1:0]  rdy_s;

wire       wfull;
wire [7:0] rdata;
wire       rinc, rinc_d, rempty;
reg        fifo_ren;             // 只有 S_READ 期间才允许弹出（消费者控制）

sd_async_fifo #(.AW(8)) u_fifo (
    .wclk  (clk50),
    .wrst  (rst50),
    .win   (win),
    .wdata (wdata),
    .wfull (wfull),
    .rclk  (clk100),
    .rrst  (rst100_go),
    .ren   (fifo_ren),
    .rdata (rdata),
    .rinc  (rinc),
    .rinc_d(rinc_d),
    .rempty(rempty)
);

// Reuse the proven SD host after P64 verification. Song traffic never
// asserts win and therefore cannot enter the DDR image FIFO.
reg [11:0] song_numbers[0:15];
reg [1:0] load_ok_s, request_s;
reg request_seen;
// Reader returns the full filename: SONGxx.BIN is ten characters.
wire is_song_bin = lnamelen == 10 &&
    lname[0]=="S" && lname[1]=="O" && lname[2]=="N" && lname[3]=="G" &&
    lname[4]>="0" && lname[4]<="9" && lname[5]>="0" && lname[5]<="9" &&
    lname[6]=="." && lname[7]=="B" && lname[8]=="I" && lname[9]=="N";
assign song_byte = o_byte;
assign song_byte_valid = (pst == P_SRD_RUN) && o_en;

always @(posedge clk50) begin
    if (rst50) begin
        pst       <= P_BOOT;
        load_ok_s <= 0; request_s <= 0; request_seen <= 0;
        song_file_count <= 0; song_ids <= 0; song_catalog_done <= 0;
        store_grant <= 0;
        song_busy <= 0; song_begin <= 0; song_end <= 0; song_error <= 0;
        pcnt      <= 32'd0;
        f_rstn    <= 1'b0;
        f_op      <= 1'b0;
        f_num     <= 12'd0;
        p_nfiles  <= 12'd0;
        p_file_no <= 12'hFFF;
        p_found   <= 1'b0;
        end_tog   <= 1'b0;
        p_bytes   <= 32'd0;
        win       <= 1'b0;
        wdata     <= 8'd0;
        rdy_s     <= 2'd0;
    end
    else begin
        win <= 1'b0;
        load_ok_s <= {load_ok_s[0], load_ok};
        request_s <= {request_s[0], song_request};
        rdy_s <= {rdy_s[0], rd_ready};    // 100MHz 就绪信号同步进来

        case (pst)

        P_BOOT: begin
            f_rstn <= 1'b0;
            if (pcnt >= BOOTD50[31:0]) begin
                pcnt <= 32'd0;
                pst  <= P_LS_RST;
            end
            else pcnt <= pcnt + 32'd1;
        end

        P_LS_RST: begin
            f_rstn <= 1'b0;
            f_op   <= 1'b0;
            if (pcnt >= 32'd31) begin
                pcnt      <= 32'd0;
                p_nfiles  <= 12'd0;
                p_file_no <= 12'hFFF;
                pst       <= P_LS_RUN;
            end
            else pcnt <= pcnt + 32'd1;
        end

        P_LS_RUN: begin
            f_rstn <= 1'b1;
            f_op   <= 1'b0;
            pcnt   <= pcnt + 32'd1;

            if (ln_en) begin
                p_nfiles <= p_nfiles + 12'd1;
                if (is_p64 && (p_file_no == 12'hFFF)) begin
                    p_file_no <= lfilenum;
                    p_found   <= 1'b1;      // ★ 命中当场置位
                end
            end

            if (f_done != 3'd0 || (pcnt >= TMO_LS50)) begin
                pcnt    <= 32'd0;
                end_tog <= ~end_tog;
                // ★★ 这里【不能】写 `p_found <= (p_file_no != 12'hFFF)`：
                //    若 list_en 与 done 同一拍（仿真桩就是），p_file_no 本拍才
                //    被非阻塞赋值，读到的还是旧值 12'hFFF → p_found 永远 0
                //    → 判成“没找到” → 一个字节都不读（BY=0）。
                //    用组合的 found_hit 兜住同拍命中。
                pst     <= (p_found | found_hit) ? P_RD_RST : P_DONE;
            end
        end

        P_RD_RST: begin
            f_rstn <= 1'b0;
            f_op   <= 1'b1;
            f_num  <= p_file_no;
            // ★ 额外等 100MHz 侧就绪（横幅发完、FIFO 即将被读），
            //   否则早到的字节会在 FIFO 里溢出或被丢弃
            if ((pcnt >= 32'd31) && rdy_s[1]) begin
                pcnt    <= 32'd0;
                p_bytes <= 32'd0;
                pst     <= P_RD_RUN;
            end
            else pcnt <= pcnt + 32'd1;
        end

        P_RD_RUN: begin
            f_rstn <= 1'b1;
            f_op   <= 1'b1;
            pcnt   <= pcnt + 32'd1;

            if (o_en && (p_bytes < MAX_BYTES)) begin
                p_bytes <= p_bytes + 32'd1;
                win     <= 1'b1;
                wdata   <= o_byte;
            end

            if (f_done != 3'd0 || (pcnt >= TMO_RD50)) begin
                pcnt    <= 32'd0;
                end_tog <= ~end_tog;
                pst     <= P_DONE;
            end
        end

        P_DONE: begin
            f_rstn <= 1'b1;
            if(store_request && load_ok_s[1] && song_catalog_done)begin
                if(!sd_clk)begin f_rstn<=0;song_catalog_done<=0;pcnt<=0;pst<=P_PARK;end
            end else if (load_ok_s[1] && !song_catalog_done) begin
                pcnt <= 0;
                song_file_count <= 0;
                song_ids <= 0;
                pst <= P_SLS_RST;
            end else if (song_catalog_done && request_s[1] != request_seen) begin
                request_seen <= request_s[1];
                song_error <= 0;
                song_begin <= ~song_begin;
                if ({1'b0,song_request_index} < song_file_count) begin
                    f_num <= song_numbers[song_request_index];
                    song_busy <= 1;
                    pcnt <= 0;
                    pst <= P_SRD_RST;
                end else begin
                    song_error <= 1;
                    song_end <= ~song_end;
                end
            end
        end
        P_PARK:begin
            f_rstn<=0;
            if(!sd_clk)begin store_grant<=1;pst<=P_STORE;end
        end
        P_STORE:begin
            f_rstn<=0;
            if(!store_request)begin
                store_grant<=0;pcnt<=0;song_file_count<=0;song_ids<=0;pst<=P_SLS_RST;
            end
        end
        P_SLS_RST: begin
            f_rstn <= 0; f_op <= 0;
            if (pcnt == 31) begin pcnt <= 0; pst <= P_SLS_RUN; end
            else pcnt <= pcnt + 1'b1;
        end
        P_SLS_RUN: begin
            f_rstn <= 1; f_op <= 0;
            pcnt <= pcnt + 1'b1;
            if (ln_en && is_song_bin && song_file_count < 16) begin
                song_numbers[song_file_count[3:0]] <= lfilenum;
                song_ids[song_file_count[3:0]*8 +: 8] <= {lname[4][3:0],lname[5][3:0]};
                song_file_count <= song_file_count + 1'b1;
            end
            if (f_done != 0 || pcnt >= TMO_LS50) begin
                song_catalog_done <= 1;
                song_error <= (pcnt >= TMO_LS50);
                pst <= P_DONE;
            end
        end
        P_SRD_RST: begin
            f_rstn <= 0; f_op <= 1;
            if (pcnt == 31) begin pcnt <= 0; pst <= P_SRD_RUN; end
            else pcnt <= pcnt + 1'b1;
        end
        P_SRD_RUN: begin
            f_rstn <= 1; f_op <= 1;
            pcnt <= pcnt + 1'b1;
            if (f_done != 0 || pcnt >= TMO_RD50) begin
                song_error <= !f_found || pcnt >= TMO_RD50;
                song_busy <= 0;
                song_end <= ~song_end;
                pst <= P_DONE;
            end
        end

        default: pst <= P_BOOT;
        endcase
    end
end

//==========================================================================
//  第 2 部分：100 MHz 域 —— 出 FIFO → 拼 256 位 → 写 DDR → 校验 → 报告
//==========================================================================
//  end_tog 双拍同步
reg [2:0] end_sync;
always @(posedge clk100) end_sync <= {end_sync[1:0], end_tog};

//  nfiles / file_no / found：在 end_tog 之前早就稳定，直接采（总线慢变量）
reg [11:0] nfiles_q, file_no_q;
reg        found_q;
always @(posedge clk100) begin
    nfiles_q  <= p_nfiles;
    file_no_q <= p_file_no;
    found_q   <= p_found;
end

localparam [3:0]
    S_WAIT   = 4'd0,
    S_READ   = 4'd1,
    S_FLUSH  = 4'd2,
    S_V_RD   = 4'd3,
    S_REPORT = 4'd4,
    S_SEND   = 4'd5,
    S_STAY   = 4'd6,
    // ★ 横幅状态【不受 DDR 校准门控】：上电立刻发 "P64RST C=x"，
    //   用来区分三件事：① 串口/引脚/clk_x1 频率 ② DDR 校准过没过 ③ 加载逻辑
    //   等等，DDR 校准没过时它会每 0.5 s 重发一次，方便反复观察。
    S_BANNER = 4'd7,
    S_BWATT  = 4'd8,
    S_V_INIT = 4'd9;

reg [255:0] wbuf;
reg [4:0]   bidx;
reg [28:0]  waddr;
// ★★ 入队必须用【字组装完成那一拍】的地址。
//    曾经在同一个边沿既拉 enq_req 又把 waddr+1，下一拍入队时地址已经是自增后的，
//    结果整片数据整体错位一格（BY/WD 都对，但 DDR 地址 0 是垃圾 → 校验必错）。
reg [28:0]  enq_addr;

wire [255:0] wrev = {
    wbuf[  7:  0], wbuf[ 15:  8], wbuf[ 23: 16], wbuf[ 31: 24],
    wbuf[ 39: 32], wbuf[ 47: 40], wbuf[ 55: 48], wbuf[ 63: 56],
    wbuf[ 71: 64], wbuf[ 79: 72], wbuf[ 87: 80], wbuf[ 95: 88],
    wbuf[103: 96], wbuf[111:104], wbuf[119:112], wbuf[127:120],
    wbuf[135:128], wbuf[143:136], wbuf[151:144], wbuf[159:152],
    wbuf[167:160], wbuf[175:168], wbuf[183:176], wbuf[191:184],
    wbuf[199:192], wbuf[207:200], wbuf[215:208], wbuf[223:216],
    wbuf[231:224], wbuf[239:232], wbuf[247:240], wbuf[255:248]
};

// 写队列（2 深）
reg          q0_v, q1_v;
reg [255:0]  q0_d, q1_d;
reg [28:0]   q0_a, q1_a;
reg          enq_req;
reg          queue_pop;

// 命令通道
reg          wr_cmd_req, rd_cmd_req;
reg [28:0]   wr_cmd_addr, rd_cmd_addr;
wire         cmd_valid = wr_cmd_req | rd_cmd_req;
assign app_en   = cmd_valid && app_rdy;
assign app_cmd  = wr_cmd_req ? 3'b000 : 3'b001;
assign app_addr = wr_cmd_req ? wr_cmd_addr : rd_cmd_addr;

reg          wdf_valid;
reg [255:0]  wdf_data;
assign app_wdf_wren = wdf_valid && wr_data_rdy;
assign app_wdf_end  = app_wdf_wren;
assign app_wdf_data = wdf_data;
assign app_wdf_mask = 32'd0;
assign app_burst    = 1'b0;

function [31:0] sum256;
    input [255:0] w;
    integer k;
    reg [31:0] s;
    begin
        s = 32'd0;
        for (k = 0; k < 8; k = k + 1)
            s = s + w[k*32 +: 32];
        sum256 = s;
    end
endfunction

// 串口
reg  [7:0]  obuf [0:127];
reg  [6:0]  oidx;
reg         send;
wire        txbusy;
reg  [7:0]  dbyte;

uart_tx #(.CLK_HZ(CLK100_HZ), .BAUD(115_200)) u_tx (
    .clk   (clk100),
    // ★ 只用 rst100，不门控 DDR 校准 —— 否则校准不过时上电横幅也发不出来，
    //   就永远分不清"串口坏了"还是"DDR 校准没过"
    .rst_n (~rst100),
    .dbyte (dbyte),
    .send  (send),
    .busy  (txbusy),
    .txd   (uart_txd)
);

function [7:0] hx (input [3:0] v);
    hx = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h37 + {4'd0, v});
endfunction

reg [3:0]  st;
reg [31:0] cnt;
reg        end_seen, end_prev;
reg [1:0]  end_cnt;             // end_tog 边沿计数：1=列目录完  2=读完
reg [31:0] drain;
reg [31:0] wcnt, rcnt;
wire [31:0] wcnt_inc /* synthesis syn_keep=1 */;
wire [31:0] cnt_inc /* synthesis syn_keep=1 */;
wire [3:0] wcnt_full /* synthesis syn_keep=1 */;
wire [3:0] cnt_full /* synthesis syn_keep=1 */;
generate for(genvar vc=0;vc<4;vc=vc+1)begin:g_other_verify_counters
    assign wcnt_full[vc]=&wcnt[vc*8+:8];assign cnt_full[vc]=&cnt[vc*8+:8];
    if(vc==0)begin
        assign wcnt_inc[vc*8+:8]=wcnt[vc*8+:8]+8'd1;
        assign cnt_inc[vc*8+:8]=cnt[vc*8+:8]+8'd1;
    end else begin
        assign wcnt_inc[vc*8+:8]=wcnt[vc*8+:8]+{7'd0,(&wcnt_full[vc-1:0])};
        assign cnt_inc[vc*8+:8]=cnt[vc*8+:8]+{7'd0,(&cnt_full[vc-1:0])};
    end
end endgenerate
// ★ 倒计数：把「wcnt != nwords」「rcnt == nwords」这两个 32 位比较从 CE 路径上拿掉。
//   nwords 是 32 位寄存器，wcnt 每次发出读命令都变，这个比较直接驱动
//   大量 CE，合并 HDMI 后实测 DATA DELAY 11.25 ns（约束 10 ns），
//   SETUP −1.532 ns。改成 rem_w != 0 / rem_r == 0 后只剩一个 32 输入
//   归约或，深度从「32 位减法/比较器」降到 3 级 LUT。
reg [31:0] rem_w, rem_r;        // 还没发的读命令数 / 还没收回的数据数
// Keep the byte predicates as physical nets: without these boundaries the
// mapper refactors saturation and prefix borrows into a serial LUT chain.
wire [3:0] rem_r_byte_zero /* synthesis syn_keep=1 */;
wire [3:0] rem_r_borrow /* synthesis syn_keep=1 */;
wire rem_r_zero /* synthesis syn_keep=1 */;
wire [31:0] rem_r_dec /* synthesis syn_keep=1 */;
assign rem_r_zero=&rem_r_byte_zero;
assign rem_r_borrow[0]=1'b1;
assign rem_r_borrow[1]=rem_r_byte_zero[0];
assign rem_r_borrow[2]=rem_r_byte_zero[0]&rem_r_byte_zero[1];
assign rem_r_borrow[3]=rem_r_byte_zero[0]&rem_r_byte_zero[1]&rem_r_byte_zero[2];
genvar rb;
generate for(rb=0;rb<4;rb=rb+1)begin:g_read_remaining
    assign rem_r_byte_zero[rb]=~|rem_r[rb*8+:8];
    assign rem_r_dec[rb*8+:8]=rem_r[rb*8+:8]-{7'd0,rem_r_borrow[rb]};
end endgenerate
// Byte-sliced counters avoid 32-bit carry chains in the 100 MHz domain.
wire [3:0] rcnt_full /* synthesis syn_keep=1 */;
wire [3:0] rem_w_empty /* synthesis syn_keep=1 */;
wire [31:0] rcnt_inc /* synthesis syn_keep=1 */;
wire [31:0] rem_w_dec /* synthesis syn_keep=1 */;
generate for(genvar cb=0;cb<4;cb=cb+1)begin:g_verify_counters
    assign rcnt_full[cb]=&rcnt[cb*8+:8];
    assign rem_w_empty[cb]=~|rem_w[cb*8+:8];
    if(cb==0)begin
        assign rcnt_inc[cb*8+:8]=rcnt[cb*8+:8]+8'd1;
        assign rem_w_dec[cb*8+:8]=rem_w[cb*8+:8]-8'd1;
    end else begin
        assign rcnt_inc[cb*8+:8]=rcnt[cb*8+:8]+{7'd0,(&rcnt_full[cb-1:0])};
        assign rem_w_dec[cb*8+:8]=rem_w[cb*8+:8]-{7'd0,(&rem_w_empty[cb-1:0])};
    end
end endgenerate
reg [5:0]  ostd;                // 已发未回的读命令数（代替 wcnt-rcnt 的 32 位减法）

// ★ DDR 读数据在本模块打一拍（理由见下面「读数据收回」那段注释）
reg [255:0] rd_v;
reg         rdv_d;
reg [1:0]  vph;                 // 校验发命令节拍分频
// ★ 发命令预判（提前一拍算好）
//   原来在 vph==3 那一拍组合计算
//       !rd_cmd_req && (rem_w != 32'd0) && (ostd < 6'd16)
//   其中 rem_w != 0 是 32 输入 OR 归约，加上后面两级 AND 直接顶到
//   ostd 的 CE/D 上，100 MHz 下实测 9.925 ns（SETUP −0.015 ns，
//   而且每次重新布线就在 0~2 处之间反复）。
//   rem_w 只在 vph==3 发命令时才变，所以 vph==2 看到的 rem_w
//   与 vph==3 做决定时完全一致 —— 提前一拍算到寄存器里语义等价。
reg issue_nxt,verify_has_words;
always @(posedge clk100)begin
    if(rst100)begin issue_nxt<=0;verify_has_words<=0;end
    else begin
        verify_has_words<=rem_w!=0;
        issue_nxt<=vph==2 && !rd_cmd_req && verify_has_words && ostd<16;
    end
end
reg [31:0] hdr_total, hdr_chk, chk_v;
reg [31:0] dbg_d0, dbg_d1;   // 读回 addr=1 的前两个 32 位字（诊断用）
reg        v_ok;

// 串口发送：obuf[oidx] 共 olen 字节，发完跳到 ret_st
reg [6:0]  olen;
reg [3:0]  ret_st;
reg [1:0]  sphase;          // 0=发 send  1=等 busy 拉高  2=等 busy 落下
wire [26:0] bwait_inc /* synthesis syn_keep=1 */;
wire [2:0] bwait_full /* synthesis syn_keep=1 */;
assign bwait_full[0]=&bwait[7:0];
assign bwait_full[1]=&bwait[15:8];
assign bwait_full[2]=&bwait[23:16];
assign bwait_inc[7:0]=bwait[7:0]+8'd1;
assign bwait_inc[15:8]=bwait[15:8]+{7'd0,bwait_full[0]};
assign bwait_inc[23:16]=bwait[23:16]+{7'd0,(&bwait_full[1:0])};
assign bwait_inc[26:24]=bwait[26:24]+{2'd0,(&bwait_full)};
reg [26:0] bwait;           // 等 DDR 校准时横幅重发计时

// ★ DDR 读数据打一拍（纯扇入，无逻辑）。Gowin 会把 rd_v 放到 DDR IP 输出
//   寄存器旁边，后面的 sum256 加法树就从 rd_v 出发，不再跨芯片走 256 位。
//
//   ★★ 这里的流水对齐必须严格 1 拍对 1 拍：
//        rd_v  <= app_rd_data        每拍【无条件】采样
//        rdv_d <= app_rd_data_valid  延迟 1 拍的有效标志
//     两件事发生在【同一个】时钟沿，所以第 t 拍的 data 和第 t 拍的 valid
//     在 t+1 拍同时到达，严格对齐。
//
//   踩过的坑：第一版写成
//        if (app_rd_data_valid) rd_v <= app_rd_data;   // 被 valid 门控
//        vld_sr <= {vld_sr[0], app_rd_data_valid};
//        wire rdv = vld_sr[1];                          // 延迟了 2 拍
//     结果是「1 拍的数据 + 2 拍的 valid」—— 连续 valid 时 rd_v 会被后一拍
//     覆盖掉，头部字段直接读到垃圾。上板现象：
//        LD BY=00113620 W=000089B1 R=000089B1 HT=5FF4FC00 ... OK=0
//     HT 本该是字数 0x89B1，实际是 5FF4FC00，校验必然不过。
always @(posedge clk100) begin
    if (rst100) begin
        rdv_d <= 1'b0;
    end
    else begin
        rd_v  <= app_rd_data;         // 无条件采样，连续 beat 也不会错位
        rdv_d <= app_rd_data_valid;   // 与之严格同步延迟 1 拍
    end
end
wire rdv = rdv_d;

// Pipelined checksum tree: one 32-bit adder per stage at 100 MHz.
reg [31:0] chk_pair[0:3], chk_half[0:1], chk_word;
reg [2:0] chk_valid;
reg verify_drained, verify_match, verify_timeout;
integer ci;
always @(posedge clk100) begin
    if(rst100) begin
        chk_valid<=0;verify_drained<=0;verify_match<=0;verify_timeout<=0;
        chk_word<=0;for(ci=0;ci<4;ci=ci+1) chk_pair[ci]<=0;
        chk_half[0]<=0;chk_half[1]<=0;
    end else begin
        for(ci=0;ci<4;ci=ci+1)
            chk_pair[ci]<=rd_v[ci*64+:32]+rd_v[ci*64+32+:32];
        chk_half[0]<=chk_pair[0]+chk_pair[1];chk_half[1]<=chk_pair[2]+chk_pair[3];
        chk_word<=chk_half[0]+chk_half[1];
        chk_valid<={chk_valid[1:0],rdv && rcnt!=0 && st==S_V_RD};
        verify_drained<=st==S_V_RD && rcnt!=0 && rem_r_zero && !rd_cmd_req && !rdv && chk_valid==0;
        verify_match<=(chk_v==hdr_chk) && (hdr_total==nwords);
        verify_timeout<=cnt>=32'd400_000_000;
    end
end

always @(posedge clk100) begin
    // ★ 这里只用 rst100（不门控 DDR 校准），否则校准不过就连横幅都发不出来
    if (rst100) begin
        st         <= S_BANNER;
        olen       <= 7'd0;
        ret_st     <= S_BWATT;
        sphase     <= 2'd0;
        bwait      <= 27'd0;
        cnt        <= 32'd0;
        wbuf       <= 256'd0;
        bidx       <= 5'd0;
        waddr      <= 29'd0;
        enq_addr   <= 29'd0;
        nbytes     <= 32'd0;
        nwords     <= 32'd0;
        err_ov     <= 32'd0;
        nfiles     <= 12'd0;
        file_no    <= 12'hFFF;
        q0_v       <= 1'b0;   q1_v <= 1'b0;
        q0_d       <= 256'd0; q1_d <= 256'd0;queue_pop<=0;
        q0_a       <= 29'd0;  q1_a <= 29'd0;
        enq_req    <= 1'b0;
        wr_cmd_req <= 1'b0;
        rd_cmd_req <= 1'b0;
        wr_cmd_addr<= 29'd0;
        rd_cmd_addr<= 29'd0;
        wdf_valid  <= 1'b0;
        wdf_data   <= 256'd0;
        end_seen   <= 1'b0;
        end_prev   <= 1'b0;
        end_cnt    <= 2'd0;
        ostd       <= 6'd0;
        vph        <= 2'd0;

        drain      <= 32'd0;
        wcnt       <= 32'd0;
        rcnt       <= 32'd0;
        rem_w      <= 32'd0;
        rem_r      <= 32'd0;
        hdr_total  <= 32'd0;
        hdr_chk    <= 32'd0;
        chk_v      <= 32'd0;
        dbg_d0     <= 32'd0;
        dbg_d1     <= 32'd0;
        v_ok       <= 1'b0;
        load_done  <= 1'b0;
        load_ok    <= 1'b0;
        stage      <= S_BANNER;
        send       <= 1'b0;
        dbyte      <= 8'h00;
        oidx       <= 7'd0;
        fifo_ren   <= 1'b0;
        rd_ready   <= 1'b0;
    end
    else begin
        send <= 1'b0;queue_pop<=0;

        // 只在收字节阶段允许弹出 FIFO
        fifo_ren <= (st == S_READ);
        // ★ 只有 100MHz 侧【真正进入 S_READ】后才允许 50MHz 侧开始吐字节。
        //   不能提前到 S_WAIT —— S_WAIT 期间可能正在发心跳横幅（2 ms），
        //   那段时间产生的字节会在 FIFO 里堆满溢出。
        if (st == S_READ) rd_ready <= 1'b1;

        //============================================ end_tog 边沿检测
        //  边沿 1 = 50MHz 侧列目录结束（此时【还没开始读字节】）
        //  边沿 2 = 50MHz 侧文件读完
        //  ★ 曾经只用一个 end_seen 标志，导致列目录一结束就进 S_READ，
        //    那时第一个字节还没出来，被 drain 超时误判成“读完了” → BY=0。
        end_prev <= end_sync[1];
        if (end_sync[1] != end_prev) begin
            end_seen <= 1'b1;
            end_cnt  <= end_cnt + 2'd1;
        end

        // 状态输出（给 50MHz 侧/调试用）
        nfiles  <= nfiles_q;
        file_no <= file_no_q;

        //============================================ 入队（晚一拍，wrev 才有效）
        if(enq_req)enq_req<=0;
        if(queue_pop)begin
            // Registered dequeue breaks DDR ready -> 256-bit queue mux.
            // A simultaneous new word replaces the vacated head/tail.
            q0_v<=q1_v || enq_req;
            q0_d<=q1_v?q1_d:wrev;q0_a<=q1_v?q1_a:enq_addr;
            q1_v<=q1_v && enq_req;
            if(enq_req)begin q1_d<=wrev;q1_a<=enq_addr;end
            nwords<=nwords+32'd1;
        end else if(enq_req)begin
            if(!q0_v)begin q0_v<=1;q0_d<=wrev;q0_a<=enq_addr;end
            else if(!q1_v)begin q1_v<=1;q1_d<=wrev;q1_a<=enq_addr;end
            else err_ov<=err_ov+32'd1;
        end

        //============================================ 写字：命令 + 数据
        if (!queue_pop && !wr_cmd_req && !wdf_valid && q0_v) begin
            wr_cmd_req  <= 1'b1;
            wr_cmd_addr <= q0_a;
            wdf_valid   <= 1'b1;
            wdf_data    <= q0_d;
        end
        else if (wr_cmd_req || wdf_valid) begin
            if (app_en && wr_cmd_req)      wr_cmd_req <= 1'b0;
            if (app_wdf_wren && wdf_valid) wdf_valid  <= 1'b0;

            if ((!wr_cmd_req || (app_en && wr_cmd_req)) &&
                (!wdf_valid  || (app_wdf_wren && wdf_valid))) begin
                queue_pop<=1'b1;
            end
        end

        //============================================ 读命令握手
        if (rd_cmd_req && app_en) rd_cmd_req <= 1'b0;

        //============================================ 读数据收回
        //
        //  ★★ app_rd_data 必须先打一拍再用！
        //    原来是 app_rd_data 直接进 sum256（8 个 32 位字的三级加法树）
        //    再加到 chk_v，整条路径从 DDR 控制器内部的 phy_rd_data_dly_75
        //    寄存器出发 —— 那个寄存器在 DDR IP 的固定布局区里，离 u_ld
        //    很远，256 位总线横跨大半个芯片。合并 HDMI 后实测 10.264 ns
        //    （约束 10 ns），SETUP −0.347 ns，6 个违规端点全是这一条。
        //    先搬进本模块的 rd_v 寄存器（纯扇入，无逻辑），后面加法树
        //    就从 rd_v 出发，变成同一区域内的寄存到寄存。
        //    代价：数据晚 1 拍，所以 rcnt/ostd 计数也跟着挪到 vld 沿上，
        //    相对顺序不变。
        if (rdv) begin
            if (rcnt == 32'd0) begin
                // ★ 头部字段位置（见 tools/make_ddr_image.py）：
                //    dword0 [31:0]   = magic "P64I"
                //    dword1 [63:32]  = ver | n_inst | 保留
                //    dword2 [95:64]  = total_words   ← 曾误取 [63:32]
                //    dword3 [127:96] = checksum      ← 曾误取 [95:64]
                hdr_total <= rd_v[95:64];
                hdr_chk   <= rd_v[127:96];
            end

            if (rcnt == 32'd1) begin
                dbg_d0 <= rd_v[31:0];
                dbg_d1 <= rd_v[63:32];
            end
            rcnt <= rcnt_inc;
            if (!rem_r_zero) rem_r <= rem_r_dec;
            if (ostd != 6'd0) ostd <= ostd - 6'd1;
        end

        if(chk_valid[2]) chk_v<=chk_v+chk_word;

        //============================================ 主流程
        case (st)

        //------------------------------------------ 上电横幅（不受校准门控）
        //  格式：\r\nP64 vN C=x L=x P=x R=x\r\n
        //    vN = 版本号  C = init_calib_complete  L = DDR PLL lock
        //    P = por_n（clk_sys 上电复位完成）  R = RESET_n（板载按钮）
        S_BANNER: begin
            stage  <= S_BANNER;
            obuf[ 0] <= 8'h0D; obuf[ 1] <= 8'h0A;
            obuf[ 2] <= 8'h50; obuf[ 3] <= 8'h36; obuf[ 4] <= 8'h34;   // "P64"
            obuf[ 5] <= 8'h20; obuf[ 6] <= 8'h76;                     // " v"
            obuf[ 7] <= 8'h30 + VER[3:0];
            obuf[ 8] <= 8'h20;                                        // " "
            obuf[ 9] <= 8'h43; obuf[10] <= 8'h3D;                     // "C="
            obuf[11] <= calib_done  ? 8'h31 : 8'h30;
            obuf[12] <= 8'h20; obuf[13] <= 8'h4C; obuf[14] <= 8'h3D;   // " L="
            obuf[15] <= dbg_pll     ? 8'h31 : 8'h30;
            obuf[16] <= 8'h20; obuf[17] <= 8'h50; obuf[18] <= 8'h3D;   // " P="
            obuf[19] <= dbg_por_n   ? 8'h31 : 8'h30;
            obuf[20] <= 8'h20; obuf[21] <= 8'h52; obuf[22] <= 8'h3D;   // " R="
            obuf[23] <= dbg_reset_n ? 8'h31 : 8'h30;
            obuf[24] <= 8'h20; obuf[25] <= 8'h53; obuf[26] <= 8'h3D;   // " S="
            obuf[27] <= 8'h30;   // stage 只有 4 位，高位固定 0
            obuf[28] <= hx(stage[3:0]);
            obuf[29] <= 8'h0D; obuf[30] <= 8'h0A;
            olen     <= 7'd31;
            oidx     <= 7'd0;
            sphase   <= 2'd0;
            // ★ ret_st 由各个跳转点自己设，不在这里写死
            st       <= S_SEND;
        end

        //------------------------------------------ 等校准；没过就每 0.5 s 重发横幅
        S_BWATT: begin
            stage <= S_BWATT;
            if (calib_done) begin
                bwait <= 27'd0;
                st    <= S_WAIT;
            end
            else if (bwait >= 27'd50_000_000) begin
                bwait  <= 27'd0;
                ret_st <= S_BWATT;
                st     <= S_BANNER;
            end
            else bwait <= bwait_inc;
        end

        // 等 DDR 校准 + 等 50MHz 侧给结论（边沿 1）
        //  期间每 0.5 s 发一次横幅 ── 板子卡住时也能看到心跳和阶段
        S_WAIT: begin
            stage <= S_WAIT;
            if ((end_cnt >= 2'd1) && !found_q) begin
                v_ok      <= 1'b0;
                load_done <= 1'b1;
                st        <= S_REPORT;
            end
            else if (end_cnt >= 2'd1) st <= S_READ;
            else if (bwait >= 27'd50_000_000) begin
                bwait  <= 27'd0;
                ret_st <= S_WAIT;
                st     <= S_BANNER;
            end
            else bwait <= bwait_inc;
        end

        // 持续出队 → 拼字 → 写 DDR
        S_READ: begin
            stage <= S_READ;
            cnt   <= cnt_inc;

            if (rinc_d) begin
                nbytes <= nbytes + 32'd1;
                wbuf   <= {wbuf[247:0], rdata};
                drain  <= 32'd0;
                if (bidx == 5'd31) begin
                    bidx     <= 5'd0;
                    enq_addr <= waddr;      // ★ 先锁存地址，再自增
                    waddr    <= waddr + (29'd1 << ADDR_SHIFT);
                    enq_req  <= 1'b1;
                end
                else bidx <= bidx + 5'd1;
            end
            else if (rempty) begin
                // 只有在【边沿 2（文件读完）】之后才允许收工，
                // 且连续空 1024 拍（10 µs）才能确定 FIFO 真的排空了
                if (end_cnt >= 2'd2) begin
                    if (drain >= 32'd1024) st <= S_FLUSH;
                    else drain <= drain + 32'd1;
                end
                else drain <= 32'd0;
            end

            if (cnt >= 32'd400_000_000) st <= S_FLUSH;    // 4 s 兜底
        end

        // 补零写最后一个残缺字 + 等写队列排空
        S_FLUSH: begin
            stage <= S_FLUSH;
            if (bidx != 5'd0) begin
                bidx     <= 5'd0;
                enq_addr <= waddr;          // ★ 同样先锁存
                waddr    <= waddr + (29'd1 << ADDR_SHIFT);
                enq_req  <= 1'b1;
            end
            else if (!q0_v && !q1_v && !wr_cmd_req && !wdf_valid && !enq_req && !queue_pop)
                st<=S_V_INIT;
        end
        // The completed write/drain decision never gates 32-bit counter loads.
        S_V_INIT:begin
            cnt<=0;wcnt<=0;rcnt<=0;rem_w<=nwords;rem_r<=nwords;chk_v<=0;
            st<=S_V_RD;
        end

        // 读回校验：发命令 + 收数据
        //  ★ 曾经写 `(wcnt - rcnt) < 32`，32 位减法 + 比较组合太深，
        //    实测 SETUP = −0.144 ns。改用 6 位 ostd 计数器，且每 4 拍才发一次。
        S_V_RD: begin
            stage <= S_V_RD;
            cnt   <= cnt_inc;
            vph   <= vph + 2'd1;

            if (nwords == 32'd0) begin
                v_ok      <= 1'b0;
                load_done <= 1'b1;
                st        <= S_REPORT;
            end
            else begin
                // ★ 预判：vph==2 时算好，vph==3 直接用寄存器值


                if (vph == 2'd3) begin
                    if (issue_nxt) begin
                        rd_cmd_req  <= 1'b1;
                        rd_cmd_addr <= wcnt[28:0] << ADDR_SHIFT;   // 常量移位，避免综合出真乘法器
                        wcnt        <= wcnt_inc;
                        rem_w       <= rem_w_dec;
                        ostd        <= ostd + 6'd1;
                    end
                end

                if (verify_drained) begin
                    v_ok      <= verify_match;
                    load_done <= 1'b1;
                    st        <= S_REPORT;
                end
                else if (verify_timeout) begin
                    v_ok      <= 1'b0;
                    load_done <= 1'b1;
                    st        <= S_REPORT;
                end
            end
        end

        // 生成报告（v4：增加读回诊断字段）
        S_REPORT: begin
            stage <= S_REPORT;
            obuf[ 0] <= 8'h0D; obuf[ 1] <= 8'h0A;
            obuf[ 2] <= 8'h4C; obuf[ 3] <= 8'h44; obuf[ 4] <= 8'h20;   // "LD "
            obuf[ 5] <= 8'h42; obuf[ 6] <= 8'h59; obuf[ 7] <= 8'h3D;   // "BY="
            obuf[ 8] <= hx(nbytes[31:28]); obuf[ 9] <= hx(nbytes[27:24]);
            obuf[10] <= hx(nbytes[23:20]); obuf[11] <= hx(nbytes[19:16]);
            obuf[12] <= hx(nbytes[15:12]); obuf[13] <= hx(nbytes[11: 8]);
            obuf[14] <= hx(nbytes[ 7: 4]); obuf[15] <= hx(nbytes[ 3: 0]);
            obuf[16] <= 8'h20; obuf[17] <= 8'h57; obuf[18] <= 8'h3D;   // " W="
            obuf[19] <= hx(nwords[31:28]); obuf[20] <= hx(nwords[27:24]);
            obuf[21] <= hx(nwords[23:20]); obuf[22] <= hx(nwords[19:16]);
            obuf[23] <= hx(nwords[15:12]); obuf[24] <= hx(nwords[11: 8]);
            obuf[25] <= hx(nwords[ 7: 4]); obuf[26] <= hx(nwords[ 3: 0]);
            obuf[27] <= 8'h20; obuf[28] <= 8'h52; obuf[29] <= 8'h3D;   // " R="
            obuf[30] <= hx(rcnt[31:28]); obuf[31] <= hx(rcnt[27:24]);
            obuf[32] <= hx(rcnt[23:20]); obuf[33] <= hx(rcnt[19:16]);
            obuf[34] <= hx(rcnt[15:12]); obuf[35] <= hx(rcnt[11: 8]);
            obuf[36] <= hx(rcnt[ 7: 4]); obuf[37] <= hx(rcnt[ 3: 0]);
            obuf[38] <= 8'h20; obuf[39] <= 8'h48; obuf[40] <= 8'h54;   // " HT="
            obuf[41] <= 8'h3D;
            obuf[42] <= hx(hdr_total[31:28]); obuf[43] <= hx(hdr_total[27:24]);
            obuf[44] <= hx(hdr_total[23:20]); obuf[45] <= hx(hdr_total[19:16]);
            obuf[46] <= hx(hdr_total[15:12]); obuf[47] <= hx(hdr_total[11: 8]);
            obuf[48] <= hx(hdr_total[ 7: 4]); obuf[49] <= hx(hdr_total[ 3: 0]);
            obuf[50] <= 8'h20; obuf[51] <= 8'h44; obuf[52] <= 8'h30;   // " D0="
            obuf[53] <= 8'h3D;
            obuf[54] <= hx(dbg_d0[31:28]); obuf[55] <= hx(dbg_d0[27:24]);
            obuf[56] <= hx(dbg_d0[23:20]); obuf[57] <= hx(dbg_d0[19:16]);
            obuf[58] <= hx(dbg_d0[15:12]); obuf[59] <= hx(dbg_d0[11: 8]);
            obuf[60] <= hx(dbg_d0[ 7: 4]); obuf[61] <= hx(dbg_d0[ 3: 0]);
            obuf[62] <= 8'h20; obuf[63] <= 8'h44; obuf[64] <= 8'h31;   // " D1="
            obuf[65] <= 8'h3D;
            obuf[66] <= hx(dbg_d1[31:28]); obuf[67] <= hx(dbg_d1[27:24]);
            obuf[68] <= hx(dbg_d1[23:20]); obuf[69] <= hx(dbg_d1[19:16]);
            obuf[70] <= hx(dbg_d1[15:12]); obuf[71] <= hx(dbg_d1[11: 8]);
            obuf[72] <= hx(dbg_d1[ 7: 4]); obuf[73] <= hx(dbg_d1[ 3: 0]);
            obuf[74] <= 8'h20; obuf[75] <= 8'h43; obuf[76] <= 8'h4B;   // " CK="
            obuf[77] <= 8'h3D;
            obuf[78] <= hx(chk_v[31:28]); obuf[79] <= hx(chk_v[27:24]);
            obuf[80] <= hx(chk_v[23:20]); obuf[81] <= hx(chk_v[19:16]);
            obuf[82] <= hx(chk_v[15:12]); obuf[83] <= hx(chk_v[11: 8]);
            obuf[84] <= hx(chk_v[ 7: 4]); obuf[85] <= hx(chk_v[ 3: 0]);
            obuf[86] <= 8'h20; obuf[87] <= 8'h4F; obuf[88] <= 8'h4B;   // " OK="
            obuf[89] <= 8'h3D;
            obuf[90] <= v_ok ? 8'h31 : 8'h30;
            obuf[91] <= 8'h0D; obuf[92] <= 8'h0A;

            load_ok <= v_ok;
            oidx    <= 7'd0;
            olen    <= 7'd93;
            sphase  <= 2'd0;
            ret_st  <= S_STAY;
            st      <= S_SEND;
        end

        //------------------------------------------ 串口吐字节（正确握手）
        //  ★ 坑：uart_tx 的 busy 是【下一拍】才拉高的。
        //    如果只判 `!txbusy` 就发下一个，会连发两次 → 每个字节省略一个
        //    （sd_bringup 的 uart_probe 第一版就是这个 bug）。
        //    必须三段式：发 send → 等 busy 变 1 → 等 busy 变 0 → 下一个字节。
        S_SEND: begin
            stage <= S_SEND;
            case (sphase)
            2'd0: if (!txbusy) begin
                      dbyte  <= obuf[oidx];
                      send   <= 1'b1;
                      sphase <= 2'd1;
                  end
            2'd1: if (txbusy) sphase <= 2'd2;
            2'd2: if (!txbusy) begin
                      sphase <= 2'd0;
                      if ((oidx + 7'd1) >= olen) st <= ret_st;
                      else oidx <= oidx + 7'd1;
                  end
            default: sphase <= 2'd0;
            endcase
        end

        S_STAY: begin
            stage <= S_STAY;
            // 加载完也每 0.5 s 发一次横幅当心跳，方便随时确认版本
            if (bwait >= 27'd50_000_000) begin
                bwait  <= 27'd0;
                ret_st <= S_STAY;
                st     <= S_BANNER;
            end
            else bwait <= bwait_inc;
        end

        default: st <= S_BANNER;
        endcase
    end
end

endmodule

`default_nettype wire
