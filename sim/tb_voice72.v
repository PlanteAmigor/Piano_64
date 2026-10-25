//==========================================================================
//  tb_voice_harm —— 谐波声部 RTL 基准测试
//
//  把 RTL 输出逐样点写到 voice_harm_out.txt，由 tools/cmp_harm_sim.py
//  与 Python 参考模型（同一张表的浮点重建）对比 SNR。
//
//  用法（在工程根目录）：
//    iverilog -g2012 -o sim/harm.vvp -s tb_voice_harm \
//        src/add_voice_harm.v sim/tb_voice_harm.v
//    vvp sim/harm.vvp
//==========================================================================
`timescale 1ns/1ps

module tb_voice_harm;

    localparam integer NPC   = 16384;        // 只仿真这么多样点（够看起振段）
    localparam integer MIDI  = 72;
    localparam integer NLO   = 67;

    reg clk = 1'b0, rst_n = 1'b0;
    always #10 clk = ~clk;                  // 50 MHz

    reg [6:0] note = MIDI;
    reg       trig = 1'b0;
    reg       gate = 1'b1;

    // ── 参数表（260730 字）────────────────────────────────────────
    reg [31:0] ptab [0:262143];
    initial $readmemh("harm_tab/dizi_param.hex", ptab);

    reg [18:0] paddr;
    reg [31:0] prd;
    always @(posedge clk) prd <= ptab[paddr];

    // ── 音基址表 ───────────────────────────────────────────────────
    reg [31:0] btab [0:27];
    initial $readmemh("harm_tab/dizi_base.hex", btab);
    wire [18:0] base_rd = btab[note - NLO][18:0];

    // ── u 表 ──────────────────────────────────────────────────────
    reg [31:0] utab [0:16383];    initial $readmemh("harm_tab/harm_u.hex", utab);
    reg [13:0] uaddr;
    reg [31:0] urd;
    always @(posedge clk) urd <= utab[uaddr];

    // ── 正弦表 ────────────────────────────────────────────────────
    reg [15:0] stab [0:1023];
    initial $readmemh("harm_tab/harm_sin.hex", stab);
    reg [9:0]  saddr;
    reg [15:0] srd;
    always @(posedge clk) srd <= stab[saddr];

    // ── 被测模块 ──────────────────────────────────────────────────
    wire signed [15:0] smp;
    wire               svalid, idle;

    add_voice_harm #(
        .ROM_AW (19), .NT(600), .NT2(300), .NT3(150),
        .NOTE_LO(NLO), .NOTE_HI(91), .U_AW(14)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .note(note), .trig(trig), .gate(gate),
        .rd(prd), .rom_addr(paddr),
        .u_rd(urd), .u_addr(uaddr),
        .sin_rd(srd), .sin_addr(saddr),
        .base_rd(base_rd),
        .sample(smp), .sample_valid(svalid), .idle(idle)
    );

    // ── 采集 ──────────────────────────────────────────────────────
    integer fd, n;
    initial begin
        fd = $fopen("harm_sim_out.txt", "w");
        n  = 0;
    end

    always @(posedge clk) begin
        if (rst_n && svalid) begin
            $fwrite(fd, "%0d\n", smp);
            if (n < 0)
                $display("smp[%0d]=%0d acc=%0h env0=%0d hAS=%0d sn0=%0d theta=%0h",
                         n, smp, dut.acc, dut.env0, dut.hAS, dut.sn0, dut.theta);
            n = n + 1;
        end
    end

    // ── 调试：打印状态跳转 ──────────────────────────────────
    integer cyc = 0;
    always @(posedge clk) if (rst_n) cyc <= cyc + 1;

    reg [2:0] st_d = 3'd0;
    integer   ntr = 0;
    always @(posedge clk) begin
        st_d <= dut.st;
        if (rst_n && (dut.st !== st_d) && (ntr < 60)) begin
            ntr <= ntr + 1;
            $display("st %0d->%0d @cyc=%0d cnt=%0d m=%0d s=%0d pre=%0d K=%0d base=%0d paddr=%0d prd=%08h",
                     st_d, dut.st, cyc, dut.cnt, dut.m, dut.s, dut.pre,
                     dut.K, dut.base, paddr, prd);
        end
        // 盯住 cnt 回绕区
        if (rst_n && cyc > 1015 && cyc < 1040)
            $display("  · cyc=%0d cnt=%0d pending=%b st=%0d trig=%b",
                     cyc, dut.cnt, dut.pending, dut.st, trig);
        // 盯住触发时刻
        if (cyc < 0)
            $display("  > cyc=%0d trig=%b rst_n=%b pending=%b cnt=%0d st=%0d",
                     cyc, trig, rst_n, dut.pending, dut.cnt, dut.st);
    end
    // ── 调试：打印第一个谐波的 16 拍 ──────────────────────
    integer dbg2 = 0;
    always @(posedge clk) begin
        if (rst_n && dut.st == 3'd3 && dut.m == 8'd0 && dbg2 < 0) begin
            dbg2 <= dbg2 + 1;
            $display("s=%2d rom_a=%5d rd=%08h | hA=%6d hPA=%6d hDM=%6d hSC=%6d hPI=%5d psi0=%6d psi1=%6d env0=%6d env1=%6d sn0=%6d hAS=%6d",
                     dut.s, dut.rom_addr, prd,
                     dut.hA, dut.hPA, dut.hDM, dut.hSC, dut.hPI,
                     dut.psi0, dut.psi1, dut.env0, dut.env1, dut.sn0, dut.hAS);
        end
    end

    // ── 调试：打印每个样点结束的 acc ──────────────────────
    integer nout = 0;
    always @(posedge clk) begin
        if (rst_n && dut.st == 3'd4 && nout < 24) begin
            nout <= nout + 1;
            $display("OUT#%0d acc=%0h  (acc>>>20)=%0d  t_smp=%0d cnt=%0d u=%08h u_fr=%0d",
                     nout, dut.acc, $signed(dut.acc) >>> 20,
                     dut.t_smp, dut.cnt, dut.u_acc, dut.u_fr);
        end
    end

    // ── 激励 ──────────────────────────────────────────────────────
    initial begin
        $display("### TB start @%0t", $time);
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        $display("### rst released @cyc=%0d", cyc);
        repeat (3) @(posedge clk);
        // ★ trig 必须保持 >1 拍：testbench 的赋值与 RTL 的采样在同一个
        //   时钟沿上竞争，只高 1 拍会被 RTL 采成 0（实测踩过）
        trig = 1'b1;
        $display("### trig=1 @cyc=%0d", cyc);
        repeat (3) @(posedge clk);
        trig = 1'b0;
        $display("### trig=0 @cyc=%0d", cyc);

        // 等到采够 NPC 个样点（每样点 1024 拍，留余量）
        wait (n >= NPC);
        repeat (10) @(posedge clk);

        $fclose(fd);
        $display("");
        $display("=================================================");
        $display("  采集样点 %0d / 目标 %0d", n, NPC);
        $display("  仿真周期 %0d", cyc);
        if (n < NPC) $display("  WARN 采到的样点少于目标");
        else         $display("  OK  写入 harm_sim_out.txt");
        $display("=================================================");
        $finish;
    end

    // 超时保护
    initial begin
        #(NPC * 1024 * 20 * 3);        // 3 倍余量
        $display("TIMEOUT: cyc=%0d n=%0d", cyc, n);
        $fclose(fd);
        $finish;
    end

endmodule
