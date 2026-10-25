//==========================================================================
//  tb_engine8_chk —— 只验证「note-on 装载阶段 槽位 ↔ 表行」的对应关系
//
//  思路：不靠反复读状态 RAM（会被正常播放覆盖），而是【监听装载期的每一次写】
//        —— st_we && loading 时，把 (st_wa, st_w1, st_wp) 记下来，
//        最后逐条和参数表比对。
//
//  正确的对应关系（基址 BASE = (note-NOTE_LO)*NPART）：
//        写到槽位 q 的 st_w1 应 = { m2[BASE+q][31:16] , 16'd0 }   （a16）
//        写到槽位 q 的 st_wp 应 = { m2[BASE+q][15:8]  , 24'd0 }   （phi8）
//
//  用法（工程根目录）：
//      iverilog -g2012 -DSIM_INIT -o tb8c.vvp -s tb_engine8_chk \
//          src/add_engine8.v src/add_voice8.v src/mix_sum.v \
//          src/add_param_rom.v src/add_sine_lut.v sim/tb_engine8_chk.v
//      vvp tb8c.vvp
//==========================================================================
`default_nettype none

module tb_engine8_chk;

    localparam integer NVOICE = 4;
    localparam integer NPART  = 128;
    localparam integer NOTE   = 60;
    localparam integer NLO    = 21;
    localparam integer BASE   = (NOTE - NLO) * NPART;

    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg rst_n = 1'b0;

    reg  [NVOICE*7-1:0] v_note;
    reg  [NVOICE-1:0]   v_trig, v_gate;
    reg                 sample_tick;
    wire signed [15:0]  sample_l, sample_r;
    wire [NVOICE-1:0]   v_idle;

    initial begin
        v_note = {(NVOICE*7){1'b0}};
        v_note[0*7 +: 7] = NOTE[6:0];
        v_note[1*7 +: 7] = NOTE[6:0];
        v_note[2*7 +: 7] = NOTE[6:0];
        v_note[3*7 +: 7] = NOTE[6:0];
    end

    add_engine8 #(
        .NVOICE(NVOICE), .NPART(NPART), .ROM_AW(14), .ROM_DEPTH(11264),
        .NOTE_LO(NLO), .NOTE_HI(108), .ATK(0), .TIMBRE(0),
        .MIX_SHIFT(1), .SOFT(1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .v_note(v_note), .v_trig(v_trig), .v_gate(v_gate),
        .sample_tick(sample_tick),
        .sample_l(sample_l), .sample_r(sample_r), .v_idle(v_idle)
    );

    reg [9:0] st_cnt = 10'd0;
    always @(posedge clk) begin
        st_cnt <= st_cnt + 10'd1;
        sample_tick <= (st_cnt == 10'd1023);
    end

    // ── 装载期写操作监听 ─────────────────────────────────────────
    reg [6:0]  wr_slot [0:NPART-1];
    reg [31:0] wr_e1   [0:NPART-1];
    reg [31:0] wr_ph   [0:NPART-1];
    reg        wr_hit  [0:NPART-1];
    integer    nwr = 0;
    integer    i;

    initial for (i = 0; i < NPART; i = i + 1) wr_hit[i] = 1'b0;

    always @(posedge clk) begin
        if (dut.g_voice[0].u_v.st_we && dut.g_voice[0].u_v.loading) begin
            wr_slot[nwr] = dut.g_voice[0].u_v.st_wa;
            wr_e1  [nwr] = dut.g_voice[0].u_v.st_w1;
            wr_ph  [nwr] = dut.g_voice[0].u_v.st_wp;
            wr_hit [dut.g_voice[0].u_v.st_wa] = 1'b1;
            if (nwr < NPART) nwr = nwr + 1;
        end
    end

    integer k, bad, miss, dup;
    reg [31:0] exp_e1, exp_ph;

    task report;
        begin
            $display("---- 装载期共写入 %0d 次（应为 %0d）----", nwr, NPART);
            bad = 0; miss = 0; dup = 0;
            for (k = 0; k < NPART; k = k + 1) begin
                if (!wr_hit[k]) begin
                    miss = miss + 1;
                    if (miss <= 6) $display("  ★槽位 %3d 从未被写过", k);
                end
            end
            for (k = 0; k < nwr && k < NPART; k = k + 1) begin
                exp_e1 = {dut.g_pfrom.u_rom.m2[BASE + k][31:16], 16'd0};
                exp_ph = {dut.g_pfrom.u_rom.m2[BASE + k][15:8],  24'd0};
                if (wr_slot[k] !== k) begin
                    dup = dup + 1;
                    if (dup <= 6)
                        $display("  第 %3d 次写入落在槽位 %3d（期望 %3d）", k, wr_slot[k], k);
                end
                if (wr_e1[k] !== exp_e1) begin
                    bad = bad + 1;
                    if (bad <= 8)
                        $display("  槽位 %3d  st_e1=%08h  期望 %08h", k, wr_e1[k], exp_e1);
                end
            end
            $display("---- 槽位错序 %0d，漏写 %0d，a16 错 %0d / %0d ----",
                     dup, miss, bad, nwr);
        end
    endtask

    integer n, nz, maxabs;
    initial begin
        v_trig = 0; v_gate = 0;
        #200 rst_n = 1'b1;
        repeat (2100) @(posedge clk);

        @(posedge clk) v_trig[0] <= 1'b1;
        @(posedge clk) v_trig[0] <= 1'b0;
        @(posedge clk) v_gate[0] <= 1'b1;

        // 等装载真正开始，再等它结束
        wait (dut.g_voice[0].u_v.loading === 1'b1);
        $display("[t=%0t] loading 上升", $time);
        wait (dut.g_voice[0].u_v.loading === 1'b0);
        $display("[t=%0t] loading 结束，ready=%b", $time, dut.g_voice[0].u_v.ready);
        repeat (4) @(posedge clk);
        report;

        // 再跑一段，看输出像不像钢琴（周期性 / 平滑）
        n = 0; nz = 0; maxabs = 0;
        while (n < 200) begin
            @(posedge clk);
            if (sample_tick) begin
                if (sample_l !== 16'sd0) nz = nz + 1;
                if ((sample_l > 0 ? sample_l : -sample_l) > maxabs)
                    maxabs = (sample_l > 0 ? sample_l : -sample_l);
                n = n + 1;
            end
        end
        $display("---- 后 200 样点：非零 %0d，峰值 |x| = %0d ----", nz, maxabs);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
