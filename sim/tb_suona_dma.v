//==========================================================================
//  tb_suona_dma —— 验证按音取表：从 DDR 镜像搬进 BSRAM 的内容与源表一致
//
//  做法：
//    1. .tmp/simpd/p64_full.hex 由 P64.BIN 生成（每行 256 位）
//    2. 行为级 DDR 模型按 app_addr>>3 取字
//    3. 让 suona_dma 搬某个音，等 done
//    4. 导出 8 个 BSRAM 缓冲到文件，主机侧与源 hex 逐元素比对
//
//  跑法（工程根目录）：
//    iverilog -g2012 -o ../.tmp/simpd/tb_suona_dma.vvp -s tb_suona_dma \
//        src/suona_dma.v sim/tb_suona_dma.v
//    vvp ../.tmp/simpd/tb_suona_dma.vvp
//==========================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_suona_dma;

    localparam integer NOTE       = 71;      // 取最大那个音（K=49）
    localparam integer NOTE_LO    = 69;
    localparam integer SUONA_BASE = 8769;
    localparam integer DESC_OFF   = 2;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5.0 clk = ~clk;                   // 100 MHz

    //------------------------------------------------ DDR 模型
    localparam integer DMEM = 32768;
    reg [255:0] MEM [0:DMEM-1];
    initial $readmemh("../.tmp/simpd/p64_full.hex", MEM);

    reg         m_busy = 1'b0;
    reg [4:0]   m_cnt  = 5'd0;
    reg [28:0]  m_addr = 29'd0;
    reg         m_valid = 1'b0;
    reg [255:0] m_data  = 256'd0;

    wire [2:0]   app_cmd;
    wire         app_en;
    wire [28:0]  app_addr;
    wire         app_rdy = ~m_busy;
    wire         app_rd_data_valid = m_valid;
    wire [255:0] app_rd_data = m_data;

    always @(posedge clk) begin
        m_valid <= 1'b0;
        if (app_en && app_rdy) begin
            m_busy <= 1'b1;
            m_addr <= app_addr;
            m_cnt  <= 5'd0;
        end
        else if (m_busy) begin
            m_cnt <= m_cnt + 5'd1;
            if (m_cnt == 5'd5) begin
                // ★ app_addr 是字节地址（单位 4 字节），MEM 是 256 位字
                //   app_addr >> 3 = 字索引
                m_data  <= MEM[m_addr[16:3]];
                m_valid <= 1'b1;
                m_busy  <= 1'b0;
            end
        end
    end

    //------------------------------------------------ DUT
    reg         start = 1'b0;
    wire        busy, done;
    reg  [6:0]  note = NOTE[6:0];

    wire ab_we, bc_we, pi_we, ee_we, eo_we, pe_we, po_we, ph_we;
    wire [5:0]  ab_a, bc_a, pi_a;
    wire [31:0] ab_d, bc_d, ph_d;
    wire [15:0] pi_d, pe_d, po_d;
    wire [12:0] ee_a, eo_a;
    wire [11:0] pe_a, po_a;
    wire [9:0]  ph_a;
    wire [7:0]  ee_d, eo_d;

    suona_dma #(
        .NOTE_LO    (NOTE_LO),
        .SUONA_BASE (SUONA_BASE),
        .DESC_OFF   (DESC_OFF)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .note(note), .start(start), .busy(busy), .done(done),
        .ab_we(ab_we), .ab_a(ab_a), .ab_d(ab_d),
        .bc_we(bc_we), .bc_a(bc_a), .bc_d(bc_d),
        .pi_we(pi_we), .pi_a(pi_a), .pi_d(pi_d),
        .ee_we(ee_we), .ee_a(ee_a), .ee_d(ee_d),
        .eo_we(eo_we), .eo_a(eo_a), .eo_d(eo_d),
        .pe_we(pe_we), .pe_a(pe_a), .pe_d(pe_d),
        .po_we(po_we), .po_a(po_a), .po_d(po_d),
        .ph_we(ph_we), .ph_a(ph_a), .ph_d(ph_d),
        .app_cmd(app_cmd), .app_en(app_en), .app_addr(app_addr),
        .app_rdy(app_rdy),
        .app_rd_data_valid(app_rd_data_valid),
        .app_rd_data(app_rd_data)
    );

    //------------------------------------------------ BSRAM 缓冲
    reg [31:0] buf_ab [0:63];
    reg [31:0] buf_bc [0:63];
    reg [15:0] buf_pi [0:63];
    reg [7:0]  buf_ee [0:8191];
    reg [7:0]  buf_eo [0:8191];
    reg [15:0] buf_pe [0:4095];
    reg [15:0] buf_po [0:4095];
    reg [31:0] buf_ph [0:1023];

    always @(posedge clk) begin
        if (ab_we) buf_ab[ab_a] <= ab_d;
        if (bc_we) buf_bc[bc_a] <= bc_d;
        if (pi_we) buf_pi[pi_a] <= pi_d;
        if (ee_we) buf_ee[ee_a] <= ee_d;
        if (eo_we) buf_eo[eo_a] <= eo_d;
        if (pe_we) buf_pe[pe_a] <= pe_d;
        if (po_we) buf_po[po_a] <= po_d;
        if (ph_we) buf_ph[ph_a] <= ph_d;
    end

    //------------------------------------------------ 激励
    integer f, i;

    // 超时保护：卡住时打印内部状态，避免无限等待
    initial begin
        #2000000;   // 2 ms 仿真时间
        $display("TIMEOUT  st=%0d seg=%0d wptr=%0d seg_n=%0d beat_cnt=%0d",
                 dut.st, dut.seg, dut.wptr, dut.seg_n, dut.beat_cnt);
        $display("         d_k=%0d cmd_addr=%0d en=%b rdy=%b valid=%b busy=%b",
                 dut.d_k, dut.cmd_addr, app_en, app_rdy, app_rd_data_valid, busy);
        $finish;
    end

    initial begin
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // ★ 必须在【下降沿】改 start：如果跟着 @(posedge clk) 赋值，
        //   赋值落在上升沿的 delta 周期里，DUT 可能已采样到旧值，
        //   下一拍 start 又被清零 → 脉冲永远看不到（实测卡死在这里）。
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait (done === 1'b1);
        repeat (10) @(posedge clk);

        f = $fopen("suona_dma_dump.txt", "w");
        for (i = 0; i < 64;  i = i + 1) $fwrite(f, "ab %0d %08x\n", i, buf_ab[i]);
        for (i = 0; i < 64;  i = i + 1) $fwrite(f, "bc %0d %08x\n", i, buf_bc[i]);
        for (i = 0; i < 64;  i = i + 1) $fwrite(f, "pi %0d %04x\n", i, buf_pi[i]);
        for (i = 0; i < 8192; i = i + 1) $fwrite(f, "ee %0d %02x\n", i, buf_ee[i]);
        for (i = 0; i < 8192; i = i + 1) $fwrite(f, "eo %0d %02x\n", i, buf_eo[i]);
        for (i = 0; i < 4096; i = i + 1) $fwrite(f, "pe %0d %04x\n", i, buf_pe[i]);
        for (i = 0; i < 4096; i = i + 1) $fwrite(f, "po %0d %04x\n", i, buf_po[i]);
        for (i = 0; i < 1024; i = i + 1) $fwrite(f, "ph %0d %08x\n", i, buf_ph[i]);
        $fclose(f);

        $display("SUONA-DMA done: note=%0d busy=%b", note, busy);
        $finish;
    end

endmodule

`default_nettype wire
