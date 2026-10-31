//==========================================================================
//  tb_engine_ddr —— 验证 add_engine8 在 USE_DDR=1 下装进 cache 的
//                   参数与 BSRAM 源表【逐分量完全一致】
//
//  为什么需要这个 tb：
//    tb_ddr_param_dma 单独验证了 ddr_param_dma 本体，但没覆盖
//    add_engine8 里的集成层 —— base_addr 计算（note_off×64 + 乐器基址）、
//    start_tog 跨时钟域、dma_note_off 锁存、DDR 口 mux。
//    这些出错时症状就是「音高音色都不对」。
//
//  做法：
//    1. 触发 note 60（钢琴），等 DMA 完成、voice 收到 trig
//    2. 把 u_ddr.g_voice[0].u_cache.mem[0..127] 导出成 cache_eng_ddr.txt
//       （每行 24 个十六进制字符 = 96 位，按 {d2,d1,d0} 打印）
//    3. 主机侧 Python 与 add_param0/1/2.hex 的 word (60-21)*128+p 比对
//
//  跑法（工程根目录）：
//    iverilog -g2012 -DSIM_INIT -o ../.tmp/simpd/tb_eng_ddr.vvp \
//        -s tb_engine_ddr \
//        src/add_engine8.v src/add_voice8.v src/mix_sum.v \
//        src/add_param_rom.v src/add_sine_lut.v \
//        src/param_cache.v src/param_dma.v src/ddr_param_dma.v \
//        sim/tb_engine_ddr.v
//    vvp ../.tmp/simpd/tb_eng_ddr.vvp
//==========================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_engine_ddr;

    localparam integer NOTE       = 60;
    localparam integer PIANO_BASE = 1;
    localparam integer WORDS_NOTE = 64;
    localparam integer ADDR_SHIFT = 3;

    //------------------------------------------------ 时钟
    reg clk    = 1'b0;      // 引擎 50 MHz
    reg clk100 = 1'b0;      // DDR 用户域 100 MHz
    always #10   clk    = ~clk;
    always #5.0  clk100 = ~clk100;

    reg rst_n = 1'b0;       // 引擎域复位
    reg rst100_n = 1'b0;    // DDR 域复位

    //------------------------------------------------ DDR 模型
    localparam integer DMEM = 16384;
    reg [255:0] MEM [0:DMEM-1];

    initial $readmemh("../.tmp/simpd/p64_v2.hex", MEM);

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

    always @(posedge clk100) begin
        m_valid <= 1'b0;
        if (app_en && app_rdy) begin
            m_busy <= 1'b1;
            m_addr <= app_addr;
            m_cnt  <= 5'd0;
        end
        else if (m_busy) begin
            m_cnt <= m_cnt + 5'd1;
            if (m_cnt == 5'd6) begin       // 6 拍后返回数据
                // ★ app_addr 是【字节地址】（ADDR_SHIFT=3），MEM 是 256 位字
                //   数组，所以必须右移 3 位取字索引。漏掉会让基址变成 8 倍。
                m_data  <= MEM[m_addr[16:3]];
                m_valid <= 1'b1;
                m_busy  <= 1'b0;
            end
        end
    end

    //------------------------------------------------ DUT
    reg  [6:0]  v_note;
    reg         v_trig;
    reg  [7:0]  v_vel;
    reg         sample_tick;
    wire signed [15:0] sample_l, sample_r;
    wire [0:0]  v_idle;
    wire        timbre = 1'b0;      // 钢琴

    add_engine8 #(
        .NVOICE     (1),
        .NPART      (128),
        .ROM_AW     (14),
        .ROM_DEPTH  (11264),
        .NOTE_LO    (21),
        .NOTE_HI    (108),
        .ATK        (0),
        .MIX_SHIFT  (0),
        .USE_DDR    (1),
        .PIANO_BASE (PIANO_BASE),
        .GZ_BASE    (5633),
        .WORDS_NOTE (WORDS_NOTE),
        .ADDR_SHIFT (ADDR_SHIFT)
    ) u_ddr (
        .clk        (clk),
        .rst_n      (rst_n),
        .timbre     (timbre),
        .v_note     (v_note),
        .v_trig     (v_trig),
        .v_gate     (1'b1),
        .v_vel      (v_vel),
        .sample_tick(sample_tick),
        .sample_l   (sample_l),
        .sample_r   (sample_r),
        .v_idle     (v_idle),
        .clk100     (clk100),
        .rst100_n   (rst100_n),
        .app_cmd    (app_cmd),
        .app_en     (app_en),
        .app_addr   (app_addr),
        .app_rdy    (app_rdy),
        .app_rd_data_valid (app_rd_data_valid),
        .app_rd_data       (app_rd_data)
    );

    //------------------------------------------------ 激励
    integer i;
    integer fcache;

    initial begin
        v_note       = NOTE[6:0];
        v_trig       = 1'b0;
        v_vel        = 8'd200;
        sample_tick  = 1'b0;

        #200 rst_n = 1'b1;
        #100 rst100_n = 1'b1;

        // note-on 脉冲
        #500 v_trig = 1'b1;
        #40  v_trig = 1'b0;

        // 等 DMA + 装载完成：1 个音 64 字，串行每字约 8 拍 @100 MHz，
        // 加跨域同步余量，给 60 us 足够
        #60000;

        // 再等一段时间让引擎跑起来（确认装载后确实能出声）
        repeat (2000) @(posedge clk);

        // 导出 cache
        fcache = $fopen("cache_eng_ddr.txt", "w");
        for (i = 0; i < 128; i = i + 1)
            $fwrite(fcache, "%06x%06x\n",
                    u_ddr.g_voice[0].u_cache.mem[i][95:48],
                    u_ddr.g_voice[0].u_cache.mem[i][47:0]);
        $fclose(fcache);

        $display("ENG-DDR done: v_idle=%b ready=%b sample=%0d",
                 v_idle[0], u_ddr.g_voice[0].u_v.ready, sample_l);
        $finish;
    end

endmodule

`default_nettype wire
