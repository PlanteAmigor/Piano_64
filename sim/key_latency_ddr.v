//==========================================================================
//  ddr_wrap —— DDR3 1GiB 封装（第 1 步：只做初始化，验证资源与时序）
//
//  来自 ddr_bringup（已上板验证 `DDR3 TEST OKAY!`）：
//    · IP：DDR3_Memory_Interface_Top（256 位，DQ_WIDTH=32，DDR3-800）
//    · PLL：50 MHz → 400 MHz（memory_clk），IP 内部 /4 出 clk_x1 = 100 MHz
//
//  ★ 用户接口（cmd/addr/wr_data/rd_data）跑在 clk_x1 = 100 MHz 域，
//    而系统主时钟是 50 MHz —— 跨时钟域在第 2 步处理。
//    本步先把 IP 挂上去，确认：
//      1) IOLOGIC 97/285 加进来后还够（键盘占 20 个普通 IO）
//      2) 400 MHz / 100 MHz 时钟域时序能收敛
//      3) BSRAM 再加 16 块后不超过 340
//
//  实现方式：命令口全部拉静态（不发任何读写），只观察 init_calib_complete。
//  这样综合出来的资源和最终形态基本一致，风险提前暴露。
//==========================================================================
`default_nettype none

module ddr_wrap (
    input  wire        clk,          // 50 MHz 系统时钟
    input  wire        rst_n,        // 同步于 clk

    output wire        init_done,    // DDR 校准完成（clk_x1 域直通）
    output wire        clk_x1,       // 100 MHz 用户时钟（IP 产生）
    output wire        pll_locked,   // ★ 诊断：DDR PLL 是否锁定

    // ── DDR3 MC 用户接口（全部同步于 clk_x1）────────────────────
    input  wire [2:0]   app_cmd,
    input  wire         app_en,
    input  wire [28:0]  app_addr,
    input  wire [255:0] app_wdf_data,
    input  wire         app_wdf_wren,
    input  wire         app_wdf_end,
    input  wire [31:0]  app_wdf_mask,
    input  wire         app_burst,
    output wire         app_rdy,
    output wire         wr_data_rdy,
    output wire         app_rd_data_valid,
    output wire [255:0] app_rd_data,

    // ── DDR3 物理引脚 ───────────────────────────────────────────
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

    reg clk100=0; always #5 clk100=~clk100;
    assign clk_x1=clk100;
    assign init_done=rst_n;
    assign pll_locked=1'b1;
    reg [7:0] image[0:1127967];
    initial $readmemh("work/song_checks/image_bytes.hex",image);
    reg pending=0,valid=0; reg [255:0] data=0;
    reg [28:0] saved; integer delay=0,cycle=0,requests=0,j;
    integer response_cycles=16;
    initial if($value$plusargs("DDR_DELAY=%d",response_cycles)) begin end
    // Model 100MHz DDR with refresh stalls and a bounded variable response.
    assign app_rdy=rst_n && !pending && cycle%257>=16;
    assign wr_data_rdy=app_rdy;
    assign app_rd_data_valid=valid;
    assign app_rd_data=data;
    always @(posedge clk100) begin
        cycle<=cycle+1;valid<=0;
        if(!rst_n) begin pending<=0;valid<=0;end
        else if(app_en && app_rdy) begin
            if(app_cmd!=3'b001)$fatal(1,"latency precondition: image is already loaded, no writes expected");
            if((app_addr<<2)+31>=1127968)$fatal(1,"DDR address outside real P64 image: %d",app_addr);
            saved<=app_addr;pending<=1;
            delay<=response_cycles+(requests%9);requests<=requests+1;
        end else if(pending && delay>0) delay<=delay-1;
        else if(pending) begin
            for(j=0;j<32;j=j+1)data[j*8+:8]<=image[(saved<<2)+j];
            pending<=0;valid<=1;
        end
    end
endmodule
`default_nettype wire
