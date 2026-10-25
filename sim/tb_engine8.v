//==========================================================================
//  tb_engine8 —— 128 分量钢琴引擎（add_engine8 / add_voice8）功能验证
//
//  目的：验证 note-on 装载阶段把参数表写进状态 RAM 时【槽位与表行是否对齐】。
//
//  做法：触发 MIDI 60（表地址基址 = (60-21)*128 = 4992）后，
//        等装载结束，把声部 0 的 st_ph / st_e1 逐个和 ROM 里的表对比。
//        正确的对应关系：
//            st_e1[p] 应等于 { a16 , 16'd0 }   a16  = m2[4992+p][31:16]
//            st_ph[p] 应等于 { phi8, 24'd0 }   phi8 = m2[4992+p][15:8]
//
//  用法（必须在工程根目录跑，因为 $readmemh 是相对路径）：
//      iverilog -g2012 -DSIM_INIT -o /path/tb8.vvp -s tb_engine8 \
//          src/add_engine8.v src/add_voice8.v src/mix_sum.v \
//          src/add_param_rom.v src/add_sine_lut.v sim/tb_engine8.v
//      vvp /path/tb8.vvp
//==========================================================================
`default_nettype none

module tb_engine8;

    localparam integer NVOICE = 4;
    localparam integer NPART  = 128;
    localparam integer NOTE   = 60;
    localparam integer NLO    = 21;
    localparam integer BASE   = (NOTE - NLO) * NPART;   // 4992

    reg clk = 1'b0;
    always #10 clk = ~clk;                              // 50 MHz

    reg rst_n = 1'b0;

    reg  [NVOICE*7-1:0] v_note;
    reg  [NVOICE-1:0]   v_trig, v_gate;
    reg                 sample_tick;
    wire signed [15:0]  sample_l, sample_r;
    wire [NVOICE-1:0]   v_idle;

    // 4 个声部都设成 NOTE，只有 0 号被触发
    initial begin
        v_note = {(NVOICE*7){1'b0}};
        v_note[0*7 +: 7] = NOTE[6:0];
        v_note[1*7 +: 7] = NOTE[6:0];
        v_note[2*7 +: 7] = NOTE[6:0];
        v_note[3*7 +: 7] = NOTE[6:0];
    end

    add_engine8 #(
        .NVOICE   (NVOICE),
        .NPART    (NPART),
        .ROM_AW   (14),
        .ROM_DEPTH(11264),
        .NOTE_LO  (NLO),
        .NOTE_HI  (108),
        .ATK      (0),
        .TIMBRE   (0),
        .MIX_SHIFT(1),
        .SOFT     (1)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .v_note     (v_note),
        .v_trig     (v_trig),
        .v_gate     (v_gate),
        .sample_tick(sample_tick),
        .sample_l   (sample_l),
        .sample_r   (sample_r),
        .v_idle     (v_idle)
    );

    // ── sample_tick：每 1024 拍一次（与整机 DIV*SLOTS 一致）──────────
    reg [9:0] st_cnt = 10'd0;
    always @(posedge clk) begin
        st_cnt <= st_cnt + 10'd1;
        sample_tick <= (st_cnt == 10'd1023);
    end

    // ── 状态 RAM 逐项检查 ─────────────────────────────────────────
    integer k, bad_e1, bad_ph, bad_n;
    reg [31:0] exp_e1, exp_ph, got_e1, got_ph;

    task check_ram;
        begin
            bad_e1 = 0; bad_ph = 0; bad_n = 0;
            $display("---- st_e1 / st_ph  vs  参数表（基址 %0d）----", BASE);
            for (k = 0; k < NPART; k = k + 1) begin
                exp_e1 = {dut.g_pfrom.u_rom.m2[BASE + k][31:16], 16'd0};
                exp_ph = {dut.g_pfrom.u_rom.m2[BASE + k][15:8],  24'd0};
                got_e1 = dut.g_voice[0].u_v.st_e1[k];
                got_ph = dut.g_voice[0].u_v.st_ph[k];
                if (got_e1 !== exp_e1) begin
                    bad_e1 = bad_e1 + 1;
                    if (bad_e1 <= 8)
                        $display("  槽位 p=%3d  st_e1 = %08h  期望 %08h  (差 %0d)",
                                 k, got_e1, exp_e1,
                                 find_src(got_e1));
                end
                if (got_ph !== exp_ph) begin
                    bad_ph = bad_ph + 1;
                    if (bad_ph <= 8)
                        $display("  槽位 p=%3d  st_ph = %08h  期望 %08h",
                                 k, got_ph, exp_ph);
                end
            end
            $display("---- 结果：st_e1 错 %0d/%0d，st_ph 错 %0d/%0d ----",
                     bad_e1, NPART, bad_ph, NPART);
        end
    endtask

    // 反查：某个 a16 值在表里是不是别的行（判断是否"错位"）
    integer q;
    function integer find_src;
        input [31:0] v;
        begin
            find_src = -1;
            for (q = 0; q < NPART; q = q + 1)
                if (find_src == -1 && {dut.g_pfrom.u_rom.m2[BASE+q][31:16],16'd0} === v)
                    find_src = q;
        end
    endfunction

    // ── 主流程 ────────────────────────────────────────────────────
    integer n, nz, maxabs, first_nz;
    integer prev;   // 上一相邻样点差，用于判断"是否平滑"

    initial begin
        v_trig = 0; v_gate = 0;
        $dumpfile("tb_engine8.vcd");
        $dumpvars(0, tb_engine8);

        #200 rst_n = 1'b1;

        // 让计数器跑满一个完整样点，稳定下来
        repeat (2100) @(posedge clk);

        // ── note-on ──
        @(posedge clk) v_trig[0] <= 1'b1;
        @(posedge clk) v_trig[0] <= 1'b0;
        @(posedge clk) v_gate[0] <= 1'b1;

        // 装载需要 128 个分量 × 8 拍 = 1024 拍，等一个半样点
        repeat (1600) @(posedge clk);
        check_ram;

        // ── 收集 800 个输出样点 ──
        n = 0; nz = 0; maxabs = 0; first_nz = -1; prev = 0;
        $display("---- sample_l 前 800 点统计 ----");
        while (n < 800) begin
            @(posedge clk);
            if (sample_tick) begin
                if (sample_l !== 16'sd0) begin
                    nz = nz + 1;
                    if (first_nz < 0) first_nz = n;
                    if ((sample_l > 0 ? sample_l : -sample_l) > maxabs)
                        maxabs = (sample_l > 0 ? sample_l : -sample_l);
                end
                if (n < 24) $display("  n=%0d  sample_l=%0d", n, sample_l);
                n = n + 1;
            end
        end
        $display("  非零样点 %0d/800，首个非零 n=%0d，峰值 |x|=%0d",
                 nz, first_nz, maxabs);
        $display("  （参考：钢琴单音峰值约 1951×MIX_SHIFT 前，软限幅后应 <32767）");
        $finish;
    end

    // 超时保护
    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
