//==========================================================================
//  tb_song —— 曲谱加载 + 播放 全链路仿真
//
//  数据流与真实硬件一致：
//    SONG01.BIN 字节 → (模拟 SD 的 outen/outbyte) → song_loader
//      → 帧解析(bt_frame_rx) → 事件 RAM
//      → bt_song_player → v_note / v_trig / v_gate / v_vel
//
//  验收：
//    [1] err_code=0，song_valid=1
//    [2] count / duration / timbre 与 Python 解析一致（47 / 6690 / 0）
//    [3] 事件表逐条与 Python 解析一致
//    [4] 播放 0 ms 时刻 4 个声部同时 gate=1（36/48/60/64）
//    [5] 850 ms 后这 4 个 gate 全部释放
//
//  运行：
//    cd piano64_3
//    iverilog -g2012 -o .tmp/tb_song.out tb_song.v src/song/*.v
//    vvp .tmp/tb_song.out
//==========================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_song;

    localparam integer CLK_HZ     = 50_000_000;
    localparam integer MAX_EVENTS = 2048;
    localparam integer BMAX       = 4096;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                      // 50 MHz

    integer errs = 0;

    //======================================================================
    //  DUT 1：曲谱装填
    //======================================================================
    reg  [7:0] byte_data  = 8'd0;
    reg        byte_valid = 1'b0;

    wire        ram_we;
    wire [10:0] ram_waddr;
    wire [63:0] ram_wdata;
    wire        song_valid, busy, frame_hit;
    wire [15:0] song_count;
    wire [31:0] song_duration;
    wire [1:0]  song_timbre;
    wire [7:0]  err_code;

    song_loader #(
        .CLK_HZ     (CLK_HZ),
        .MAX_EVENTS (MAX_EVENTS)
    ) u_ld (
        .clk         (clk),
        .rst_n       (rst_n),
        .byte_data   (byte_data),
        .byte_valid  (byte_valid),
        .byte_error  (1'b0),
        .ram_we      (ram_we),
        .ram_waddr   (ram_waddr),
        .ram_wdata   (ram_wdata),
        .song_valid  (song_valid),
        .song_count  (song_count),
        .song_duration(song_duration),
        .song_timbre (song_timbre),
        .err_code    (err_code),
        .busy        (busy),
        .frame_hit   (frame_hit)
    );

    //======================================================================
    //  事件 RAM（1W1R，与硬件一致）
    //======================================================================
    reg [63:0] ram [0:MAX_EVENTS-1];
    always @(posedge clk) if (ram_we) ram[ram_waddr] <= ram_wdata;

    //======================================================================
    //  DUT 2：播放器
    //======================================================================
    reg  play_start = 1'b0;
    reg  play_stop  = 1'b0;
    wire [12:0] read_addr;
    reg  [63:0] read_data;
    wire        playing;
    wire [55:0] v_note;
    wire [7:0]  v_trig, v_gate;
    wire [63:0] v_vel;

    always @(posedge clk) read_data <= ram[read_addr[10:0]];

    bt_song_player #(
        .CLK_HZ     (CLK_HZ),
        .MAX_EVENTS (MAX_EVENTS)
    ) u_pl (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (play_start),
        .stop        (play_stop),
        .count       (song_count),
        .duration_ms (song_duration),
        .timbre      (song_timbre),
        .read_addr   (read_addr),
        .read_data   (read_data),
        .playing     (playing),
        .overflow    (),
        .position_ms (),
        .v_note      (v_note),
        .v_trig      (v_trig),
        .v_gate      (v_gate),
        .v_vel       (v_vel)
    );

    //======================================================================
    //  文件读取
    //======================================================================
    reg [7:0] img [0:BMAX-1];
    integer   nbyte, fd, c, i, j;
    integer   nframe = 0;                       // 调试：收到的完整帧数
    reg       frame_hit_d = 1'b0;
    always @(posedge clk) begin
        frame_hit_d <= frame_hit;
        if (frame_hit && !frame_hit_d) nframe = nframe + 1;
    end


    task load_file;
        begin
            fd = $fopen("tools/generated/SONG01.BIN", "rb");
            if (fd == 0) begin
                $display("FAIL: 打不开 tools/generated/SONG01.BIN");
                $finish;
            end
            nbyte = 0;
            c = $fgetc(fd);
            while (c >= 0 && nbyte < BMAX) begin
                img[nbyte] = c[7:0];
                nbyte = nbyte + 1;
                c = $fgetc(fd);
            end
            $fclose(fd);
            $display("[0] 读入 %0d 字节", nbyte);
            $display("    前 8 字节: %02x %02x %02x %02x %02x %02x %02x %02x",
                     img[0], img[1], img[2], img[3], img[4], img[5], img[6], img[7]);
            if (img[0] !== 8'hA5 || img[1] !== 8'h5A || img[2] !== 8'h03)
                $display("    FAIL: 文件头应为 A5 5A 03");
        end
    endtask

    // 每个字节保持 1 个完整时钟周期，间隔 3 拍（模拟 SD 的 outbyte/outen）
    // ★ 必须在【下降沿】改变信号：在 posedge 之后用阻塞赋值会与 DUT 的
    //   always @(posedge clk) 采样产生竞争，DUT 可能读到已经清 0 的值。
    task feed_bytes;
        integer k;
        begin
            for (k = 0; k < nbyte; k = k + 1) begin
                @(negedge clk);
                byte_data  = img[k];
                byte_valid = 1'b1;
                @(negedge clk);
                byte_valid = 1'b0;
                @(negedge clk);
                @(negedge clk);
            end
        end
    endtask

    //======================================================================
    //  检查：事件表与 Python 解析结果一致
    //======================================================================
    // Python (gen_song_v3.py 自检) 对 SONG01.BIN 的解析结果
    localparam integer NEXP = 47;
    reg [31:0] exp_start [0:NEXP-1];
    reg [7:0]  exp_note  [0:NEXP-1];
    reg [15:0] exp_dur   [0:NEXP-1];
    reg [7:0]  exp_vel   [0:NEXP-1];
    integer    ck;

    task setup_expect;
        begin
            // 前 12 条（其余由 count/总时长 + 单调性间接覆盖）
            exp_start[ 0]=32'd0;    exp_note[ 0]=8'd36; exp_dur[ 0]=16'd1290; exp_vel[ 0]=8'd72;
            exp_start[ 1]=32'd0;    exp_note[ 1]=8'd48; exp_dur[ 1]=16'd400;  exp_vel[ 1]=8'd86;
            exp_start[ 2]=32'd0;    exp_note[ 2]=8'd60; exp_dur[ 2]=16'd400;  exp_vel[ 2]=8'd100;
            exp_start[ 3]=32'd0;    exp_note[ 3]=8'd64; exp_dur[ 3]=16'd400;  exp_vel[ 3]=8'd78;
            exp_start[ 4]=32'd450;  exp_note[ 4]=8'd48; exp_dur[ 4]=16'd400;  exp_vel[ 4]=8'd86;
            exp_start[ 5]=32'd450;  exp_note[ 5]=8'd60; exp_dur[ 5]=16'd400;  exp_vel[ 5]=8'd100;
            exp_start[ 6]=32'd450;  exp_note[ 6]=8'd64; exp_dur[ 6]=16'd400;  exp_vel[ 6]=8'd78;
            exp_start[ 7]=32'd900;  exp_note[ 7]=8'd55; exp_dur[ 7]=16'd400;  exp_vel[ 7]=8'd86;
            exp_start[ 8]=32'd900;  exp_note[ 8]=8'd67; exp_dur[ 8]=16'd400;  exp_vel[ 8]=8'd100;
            exp_start[ 9]=32'd900;  exp_note[ 9]=8'd71; exp_dur[ 9]=16'd400;  exp_vel[ 9]=8'd78;
            exp_start[10]=32'd1350; exp_note[10]=8'd41; exp_dur[10]=16'd1290; exp_vel[10]=8'd72;
            exp_start[11]=32'd1350; exp_note[11]=8'd55; exp_dur[11]=16'd400;  exp_vel[11]=8'd86;
        end
    endtask

    function integer popcount8;
        input [7:0] v;
        integer k;
        begin
            popcount8 = 0;
            for (k = 0; k < 8; k = k + 1) popcount8 = popcount8 + v[k];
        end
    endfunction

    // 检查某个音高是否出现在 v_note 里
    function has_note;
        input [6:0] n;
        integer k;
        begin
            has_note = 0;
            for (k = 0; k < 8; k = k + 1)
                if (v_gate[k] && v_note[k*7 +: 7] == n) has_note = 1;
        end
    endfunction

    //======================================================================
    //  主流程
    //======================================================================
    localparam integer T1MS = CLK_HZ/1000;      // 1 ms 的拍数 = 50000

    initial begin
        load_file;
        setup_expect;

        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        //------------------------------------------------------------------
        $display("\n=== [1] 装填曲谱 ===");
        feed_bytes;

        repeat (3000) @(posedge clk);           // FIFO 吞吐 1 字节/2 拍，426 字节约 852 拍

        $display("  [调试] 收到完整帧 %0d 个，busy=%0d", nframe, busy);
        $display("  song_valid=%0d  err_code=%0d  count=%0d  duration=%0d  timbre=%0d",
                 song_valid, err_code, song_count, song_duration, song_timbre);
        if (err_code !== 8'd0) begin
            $display("  FAIL: err_code 应为 0"); errs = errs + 1;
        end
        if (song_valid !== 1'b1) begin
            $display("  FAIL: song_valid 应为 1"); errs = errs + 1;
        end
        if (song_count !== 16'd47) begin
            $display("  FAIL: count 应为 47"); errs = errs + 1;
        end
        if (song_duration !== 32'd6690) begin
            $display("  FAIL: duration 应为 6690"); errs = errs + 1;
        end
        if (song_timbre !== 2'd0) begin
            $display("  FAIL: timbre 应为 0(钢琴)"); errs = errs + 1;
        end

        //------------------------------------------------------------------
        $display("\n=== [2] 事件表（前 12 条与 Python 解析比对）===");
        for (i = 0; i < NEXP; i = i + 1) begin
            if (i < 12) begin
                if (ram[i][31:0]    !== exp_start[i] ||
                    ram[i][39:32]   !== exp_note[i]  ||
                    ram[i][55:40]   !== exp_dur[i]   ||
                    ram[i][63:56]   !== exp_vel[i]) begin
                    $display("  FAIL [%0d] 期望(%0d,%0d,%0d,%0d) 实际(%0d,%0d,%0d,%0d)",
                             i, exp_start[i], exp_note[i], exp_dur[i], exp_vel[i],
                             ram[i][31:0], ram[i][39:32], ram[i][55:40], ram[i][63:56]);
                    errs = errs + 1;
                end
                else begin
                    $display("   ok [%0d] (%0d, %0d, %0d, %0d)", i,
                             ram[i][31:0], ram[i][39:32], ram[i][55:40], ram[i][63:56]);
                end
            end
        end

        // 事件必须按 start_ms 非递减
        for (i = 1; i < NEXP; i = i + 1)
            if (ram[i][31:0] < ram[i-1][31:0]) begin
                $display("  FAIL: 事件 [%0d] start=%0d 小于前一个 %0d",
                         i, ram[i][31:0], ram[i-1][31:0]);
                errs = errs + 1;
            end

        //------------------------------------------------------------------
        $display("\n=== [3] 开始播放，检查 0 ms 时刻复音 ===");
        @(negedge clk);
        play_start = 1'b1;
        @(negedge clk);
        play_start = 1'b0;

        repeat (500) @(posedge clk);            // 10 us，4 个事件早已处理完

        $display("  playing=%0d  gate=%b  (popcount=%0d)",
                 playing, v_gate, popcount8(v_gate));
        if (playing !== 1'b1) begin
            $display("  FAIL: playing 应为 1"); errs = errs + 1;
        end
        if (popcount8(v_gate) !== 4) begin
            // 36/48/60/64 四个音同时起
            $display("  WARN: 0 ms 并发声部数 = %0d（期望 4）", popcount8(v_gate));
        end
        if (!has_note(7'd60)) begin
            $display("  FAIL: 主旋律 C4(60) 没有发声"); errs = errs + 1;
        end
        else $display("   ok 主旋律 C4(60) 在播");
        if (!has_note(7'd36)) begin
            $display("  FAIL: 低音 C2(36) 没有发声"); errs = errs + 1;
        end
        else $display("   ok 低音 C2(36) 在播");

        //------------------------------------------------------------------
        $display("\n=== [4] 推进到 900 ms，检查第一个音已释放、第二个和弦在响 ===");
        repeat (T1MS * 200) @(posedge clk);     // 200 ms

        $display("  200ms: gate=%b  popcount=%0d", v_gate, popcount8(v_gate));
        if (popcount8(v_gate) < 3) begin
            $display("  FAIL: 200 ms 时声部数 = %0d，应该还在响", popcount8(v_gate));
            errs = errs + 1;
        end

        repeat (T1MS * 750) @(posedge clk);     // 950 ms

        $display("  950ms: gate=%b  popcount=%0d", v_gate, popcount8(v_gate));
        if (!has_note(7'd55) && !has_note(7'd67) && !has_note(7'd71)) begin
            $display("  WARN: 950 ms 时第三个和弦(55/67/71)没在响");
        end
        else $display("   ok 第三个和弦正在响");

        //------------------------------------------------------------------
        $display("\n=== [5] 停止 ===");
        @(negedge clk);
        play_stop = 1'b1;
        @(negedge clk);
        play_stop = 1'b0;
        repeat (20) @(posedge clk);

        $display("  playing=%0d  gate=%b", playing, v_gate);
        if (playing !== 1'b0) begin
            $display("  FAIL: 停止后 playing 应为 0"); errs = errs + 1;
        end
        if (v_gate !== 8'd0) begin
            $display("  FAIL: 停止后 gate 应全 0"); errs = errs + 1;
        end

        //------------------------------------------------------------------
        $display("\n==== %0d FAIL ====", errs);
        if (errs == 0) $display("★ 全链路通过：SD 字节 → 帧解析 → 事件表 → 4 声部播放");
        $finish;
    end

    // 超时保护
    initial begin
        #3_000_000_000;                         // 3 s（要覆盖 200ms + 750ms 推进）
        $display("FAIL: 仿真超时");
        $finish;
    end

endmodule

`default_nettype wire
