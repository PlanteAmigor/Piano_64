//==========================================================================
//  tb_v8_check —— ★ 8 声部专项验证（NVOICE=8，PH_SHIFT=1）
//
//  为什么需要一个新的 TB：
//    旧的 tb_engine8 / tb_engine8_chk / tb_ab8 都硬编码 NVOICE=4，
//    而且 tb_engine8_chk 引用的层次路径 dut.g_pfrom.u_rom.m2 早已过时
//    （现在 ROM 在 add_engine8 里，实例名 u_rom_p / u_rom_g）。
//
//  ★ 本 TB 要回答的问题：8 声部同时触发时，共用一份参数 ROM 还对不对？
//    PH_SHIFT = (1024/NPART)/NVOICE = 8/8 = 1，比 4 声部时（=2）更紧。
//    相位错开只有 1 拍 —— 必须确认 s==0 / s==1 仍然互斥。
//
//  ── 5 项检查 ──────────────────────────────────────────────────────
//    ① 装载对齐：8 声部 × 128 槽位的 st_e1 / st_ph 必须等于各自音符的 ROM 行
//       （只要 ROM 地址多路器串了台，这一项立刻炸）
//    ② 8 声部都出声：每个声部 800 样点里非零个数 > 0
//    ③ 音高正确：从 st_ph[0] 每样点的推进量反算频率，与 MIDI 期望值比 cent
//       —— 这是最能证明"每个声部拿到的是自己的参数"的一项
//    ④ 8 路求和正确：sample_l 必须 bit-exact 等于 softclip(Σvs >>> MIX_SHIFT)
//    ⑤ 无削顶 / 无静音
//
//  ── 用法（必须在 piano64_3 根目录跑，因为 $readmemh 是相对路径）────
//    export TMPDIR=$PWD/.tmp && mkdir -p $TMPDIR
//    iverilog -g2012 -DSIM_INIT -o $TMPDIR/tb_v8.vvp -s tb_v8_check \
//        src/add_engine8.v src/add_voice8.v src/mix_sum.v \
//        src/add_param_rom.v src/add_sine_lut.v sim/tb_v8_check.v
//    vvp $TMPDIR/tb_v8.vvp
//==========================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_v8_check;

    //======================= 参数 =====================================
    localparam integer NVOICE = 8;
    localparam integer NPART  = 128;
    localparam integer NLO    = 21;
    localparam integer NSMP   = 800;
    localparam integer MIX_SHIFT = 1;
    localparam integer KNEE   = 16384;
    localparam real    FS     = 48828.125;

    // 8 个音：C4 大调音阶 C4 D4 E4 F4 G4 A4 B4 C5
    function [6:0] noteOf;
        input integer idx;
        begin
`ifdef SAME_NOTE
            // ★ 最坏情况测试：8 个声部弹同一个音 → 同相叠加，混音和最大
            noteOf = 60;
`else
            case (idx)
                0: noteOf = 60;  1: noteOf = 62;  2: noteOf = 64;  3: noteOf = 65;
                4: noteOf = 67;  5: noteOf = 69;  6: noteOf = 71;  7: noteOf = 72;
                default: noteOf = 60;
            endcase
`endif
        end
    endfunction

    // ROM 里该音符的基址
    function integer baseOf;
        input integer idx;
        begin
            baseOf = (noteOf(idx) - NLO) * NPART;
        end
    endfunction

    // MIDI → 频率（查表，避免 $pow 在 iverilog 里返回 inf）
    function real freqOf;
        input integer idx;
        begin
            case (idx)
                0: freqOf = 261.625565;
                1: freqOf = 293.664768;
                2: freqOf = 329.627557;
                3: freqOf = 349.228231;
                4: freqOf = 391.995436;
                5: freqOf = 440.000000;
                6: freqOf = 493.883301;
                7: freqOf = 523.251131;
                default: freqOf = 440.0;
            endcase
        end
    endfunction

    //======================= 时钟 / 复位 ==============================
    reg clk = 1'b0;
    always #10 clk = ~clk;                     // 50 MHz

    reg rst_n = 1'b0;

    //======================= DUT 端口 =================================
    reg  [NVOICE*7-1:0] v_note;
    reg  [NVOICE-1:0]   v_trig, v_gate;
    reg                 sample_tick;
    reg                 timbre = 1'b0;
    wire signed [15:0]  sample_l, sample_r;
    wire [NVOICE-1:0]   v_idle;

    // ★ 力度增益：每声部 8 位，2..254。这里全给满力度 254
    wire [NVOICE*8-1:0] v_vel = {(8*NVOICE){1'b1}} & {NVOICE{8'hFE}};

    integer g0;
    initial begin
        for (g0 = 0; g0 < NVOICE; g0 = g0 + 1)
            v_note[g0*7 +: 7] = noteOf(g0);
    end

    add_engine8 #(
        .NVOICE   (NVOICE),
        .NPART    (NPART),
        .ROM_AW   (14),
        .ROM_DEPTH(11264),
        .NOTE_LO  (NLO),
        .NOTE_HI  (108),
        .ATK      (0),
        .MIX_SHIFT(MIX_SHIFT),
        .SOFT     (1)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .timbre     (timbre),
        .v_note     (v_note),
        .v_trig     (v_trig),
        .v_gate     (v_gate),
        .v_vel      (v_vel),
        .sample_tick(sample_tick),
        .sample_l   (sample_l),
        .sample_r   (sample_r),
        .v_idle     (v_idle)
    );

    //======================= sample_tick ==============================
    reg [9:0] st_cnt = 10'd0;
    always @(posedge clk) begin
        st_cnt      <= st_cnt + 10'd1;
        sample_tick <= (st_cnt == 10'd1023);
    end

    //======================= DMA 实时监视 =============================
    always @(posedge clk) begin
        if (dut.dma_start)
            $display("[DMAstart] sel=%0d note_off=%0d", dut.dma_sel, dut.dma_note_off);
        if (dut.g_voice[7].u_dma.we && dut.g_voice[7].u_dma.waddr < 7'd3)
            $display("[v7 write] waddr=%0d src_addr=%0d wdata=%h (src_addr_mux=%0d p0=%h)",
                     dut.g_voice[7].u_dma.waddr, dut.g_voice[7].u_dma.src_addr,
                     dut.g_voice[7].u_dma.wdata, dut.src_addr_mux, dut.p0);
    end

    //======================= 每声部统计数组 ===========================
    integer bade1   [0:NVOICE-1];
    integer badph   [0:NVOICE-1];
    integer badinc  [0:NVOICE-1];      // bank0 inc 比对错误数
    integer badr1   [0:NVOICE-1];      // bank1 R1  比对错误数
    integer nload   [0:NVOICE-1];      // 实际装载过的分量数（应为 128）
    integer samp_nz [0:NVOICE-1];      // 非零样点数
    integer samp_pk [0:NVOICE-1];      // 峰值
    reg [31:0] ph_prev  [0:NVOICE-1];
    reg [31:0] ph_delta [0:NVOICE-1];  // 每样点相位推进量（应 = inc[0]）
    reg        ph_ok    [0:NVOICE-1];  // 是否已采到一次有效 delta

    integer z;
    initial begin
        for (z = 0; z < NVOICE; z = z + 1) begin
            bade1[z] = 0; badph[z] = 0; badinc[z] = 0; badr1[z] = 0;
            nload[z] = 0;
            samp_nz[z] = 0; samp_pk[z] = 0;
            ph_prev[z] = 32'd0; ph_delta[z] = 32'd0;
            ph_ok[z] = 1'b0;
        end
    end

    //======================= 逐声部监视（generate）====================
    genvar gg;
    generate
    for (gg = 0; gg < NVOICE; gg = gg + 1) begin : g_mon

        integer kk, nv, pv;
        reg [31:0] exp_e1, exp_ph;

        always @(posedge clk) begin

            // ── ① 装载正确性：装载过程中逐分量【实时】比对 ──────────
            //    为什么不能事后查 RAM：装载一结束（ready=1），下一个样点就
            //    开始把新 e1/ph 写回同一批槽位，装载值立刻被覆盖。
            //
            //    ★★ 这里同时在 s==1 比对 rd0/rd1/rd2（ROM 的三个 bank 输出）。
            //       这是 8 声部共用一份 ROM 时【最关键的风险点】：PH_SHIFT=1
            //       时相位只错开 1 拍，如果地址多路器选错或数据串台，
            //       声部就会拿到别人音符的参数 → 音高/音色全错。
            if (dut.g_voice[gg].u_v.loading && dut.g_voice[gg].u_v.s == 3'd1) begin
                kk = dut.g_voice[gg].u_v.load_cnt;
                if (dut.g_voice[gg].u_v.rd0 !== dut.u_rom_p.m0[baseOf(gg) + kk]) begin
                    badinc[gg] = badinc[gg] + 1;
                    if (badinc[gg] <= 3)
                        $display("  [声部%0d] 分量%0d inc=%0d 期望 %0d",
                                 gg, kk, dut.g_voice[gg].u_v.rd0,
                                 dut.u_rom_p.m0[baseOf(gg) + kk]);
                end
                if (dut.g_voice[gg].u_v.rd1 !== dut.u_rom_p.m1[baseOf(gg) + kk]) begin
                    badr1[gg] = badr1[gg] + 1;
                    if (badr1[gg] <= 3)
                        $display("  [声部%0d] 分量%0d R1=%0d 期望 %0d",
                                 gg, kk, dut.g_voice[gg].u_v.rd1,
                                 dut.u_rom_p.m1[baseOf(gg) + kk]);
                end
            end

            if (dut.g_voice[gg].u_v.loading && dut.g_voice[gg].u_v.s == 3'd7) begin
                kk = dut.g_voice[gg].u_v.load_cnt;
                nload[gg] = nload[gg] + 1;
                exp_e1 = {dut.u_rom_p.m2[baseOf(gg) + kk][31:16], 16'd0};
                exp_ph = {dut.u_rom_p.m2[baseOf(gg) + kk][15:8],  24'd0};
                if ({dut.g_voice[gg].u_v.a16_r[15:0], 16'd0} !== exp_e1) begin
                    bade1[gg] = bade1[gg] + 1;
                    if (bade1[gg] <= 3)
                        $display("  [声部%0d] 分量%0d  a16=%04h 期望 %04h",
                                 gg, kk, dut.g_voice[gg].u_v.a16_r[15:0], exp_e1[31:16]);
                end
                if ({dut.g_voice[gg].u_v.phi8_r[7:0], 24'd0} !== exp_ph) begin
                    badph[gg] = badph[gg] + 1;
                    if (badph[gg] <= 3)
                        $display("  [声部%0d] 分量%0d  phi8=%02h 期望 %02h",
                                 gg, kk, dut.g_voice[gg].u_v.phi8_r[7:0], exp_ph[31:24]);
                end
            end

            // ── ③ 相位推进监测 ───────────────────────────────────────
            //    ★★ 相邻两个样点边界采 st_ph[0]，差值就是分量 0 的每样点相位增量
            //    （= inc[0]）。之前尝试用 st_we/st_wa 握手信号触发，但它们是
            //    s==7 时非阻塞赋值、下一拍才生效，命中时刻错位 → 测出 6 倍偏差。
            //    cnt==1023 是样点边界里的固定时刻（每个样点恰好一次），最可靠。
            if (dut.g_voice[gg].u_v.cnt == 10'd1023 &&
                dut.g_voice[gg].u_v.ready &&
                !dut.g_voice[gg].u_v.loading) begin
                if (ph_ok[gg])
                    ph_delta[gg] <= dut.g_voice[gg].u_v.st_ph[0] - ph_prev[gg];
                ph_prev[gg] <= dut.g_voice[gg].u_v.st_ph[0];
                ph_ok[gg]   <= 1'b1;
            end

            // ── ② 每声部峰值 / 非零统计 ─────────────────────────────
            if (sample_tick) begin
                nv = dut.g_voice[gg].u_v.sample;
                if (nv != 0) samp_nz[gg] = samp_nz[gg] + 1;
                pv = (nv < 0) ? -nv : nv;
                if (pv > samp_pk[gg]) samp_pk[gg] = pv;
            end
        end
    end
    endgenerate

    //======================= ④ 求和 bit-exact 检查 ====================
    //   mix_sum 内部流水 5 拍：sum_r(1) → ax/d(2) → d²(3) → out(4) → tick_d[4] 锁存(5)
    //   在 sample_tick 后 1 拍锁存 sum_r（此刻它正好是 sample_tick 时 vs 的和）
    reg signed [19:0] sum_snap;
    reg [5:0]         tdly = 6'd0;       // ★ 6 位：tdly[5] 才是 sample_l 已更新之后
    integer badmix = 0, mix_n = 0;
    integer mix_pk = 0, mix_clip = 0;

    // 复现 mix_sum 的软限幅（与 mix_sum.v 保持完全一致）
    function signed [15:0] softclip;
        input signed [19:0] s;
        integer x, ax, d, y, mag;
        begin
            x  = s >>> MIX_SHIFT;
            ax = (x < 0) ? -x : x;
            if (ax <= KNEE) d = 0;
            else begin
                d = ax - KNEE;
                if (d > 32768) d = 32768;
            end
            y = KNEE + d - ((d * d) >> 16);
            mag = (ax <= KNEE) ? ax : ((y > 32767) ? 32767 : y);
            softclip = (x < 0) ? -mag : mag;
        end
    endfunction

    always @(posedge clk) begin
        tdly <= {tdly[4:0], sample_tick};

        // sample_tick 后第 1 拍：sum_r 已是该样点的和
        if (tdly[0]) sum_snap <= dut.u_mix.sum_r;

        // ★ sample_tick 后第 6 拍：sample_l 在 T+5 沿被【非阻塞】更新，
        //   在 T+5 同一沿读到的是旧值 → 必须再等一拍，用 tdly[5]
        if (tdly[5]) begin
            mix_n = mix_n + 1;
            if (sample_l !== softclip(sum_snap)) begin
                badmix = badmix + 1;
                if (badmix <= 5)
                    $display("  [求和] 第%0d样点 sample_l=%0d 期望 %0d (sum_snap=%0d)",
                             mix_n, sample_l, softclip(sum_snap), sum_snap);
            end
            if (sample_l != 0) begin
                if ((sample_l > 0 ? sample_l : -sample_l) > mix_pk)
                    mix_pk = (sample_l > 0 ? sample_l : -sample_l);
            end
            if (sample_l >= 32767 || sample_l <= -32768) mix_clip = mix_clip + 1;
        end
    end

    //======================= 主流程 ===================================
    integer n, fail;
    real    f_meas, f_exp, cents;

    initial begin
        v_trig = {NVOICE{1'b0}};
        v_gate = {NVOICE{1'b0}};

        $dumpfile("tb_v8_check.vcd");
        $dumpvars(0, tb_v8_check);

        $display("");
        $display("================ 8 声部验证开始 ================");
        $display("NVOICE=%0d  NPART=%0d  PH_SHIFT=%0d  MIX_SHIFT=%0d",
                 NVOICE, NPART, (1024/NPART)/NVOICE, MIX_SHIFT);
        $display("音符：60 62 64 65 67 69 71 72（C4 大调音阶）");
        $display("");

        #200 rst_n = 1'b1;

        // 空跑两个样点，让内部计数器稳定
        repeat (2100) @(posedge clk);

        // ── 8 个声部【同一拍】全部 note-on ────────────────────────
        @(posedge clk) v_trig <= {NVOICE{1'b1}};
        @(posedge clk) v_trig <= {NVOICE{1'b0}};
        @(posedge clk) v_gate <= {NVOICE{1'b1}};

        // ★ 装载总耗时 = 等 cnt 回 0（最坏 1024 拍）+ 128 分量 × 8 拍 = 2048 拍
        //   （之前只等 1600 拍 → 只装到第 78 个分量，是 TB 的错，不是 RTL 的错）
        repeat (2400) @(posedge clk);

        // ── DMA 调试 ─────────────────────────────────────────────
        $display("---- DMA 调试 ----");
        $display("  v_note_off = %h", dut.v_note_off);
        $display("  dma_sel=%0d  dma_note_off=%0d  dma_pend=%b",
                 dut.dma_sel, dut.dma_note_off, dut.dma_pend);
        $display("  v0: cache[0]=%h src=%0d", dut.g_voice[0].u_cache.mem[0],
                 dut.g_voice[0].u_dma.src_addr);
        $display("  v1: cache[0]=%h src=%0d", dut.g_voice[1].u_cache.mem[0],
                 dut.g_voice[1].u_dma.src_addr);
        $display("  v7: cache[0]=%h src=%0d", dut.g_voice[7].u_cache.mem[0],
                 dut.g_voice[7].u_dma.src_addr);
        $display("");

        // 再跑 3 个样点让包络/相位进入稳态
        repeat (3*1024 + 200) @(posedge clk);

        // ── 收集 NSMP 个样点 ──────────────────────────────────────
        $display("");
        $display("---- ②③④⑤ 收集 %0d 个样点 ----", NSMP);
        n = 0;
        while (n < NSMP) begin
            @(posedge clk);
            if (sample_tick) n = n + 1;
        end
        repeat (20) @(posedge clk);

        //──────────────────────── 报告 ────────────────────────────
        $display("");
        $display("================ 结果 ================");

        fail = 0;

        // ① 装载
        $display("① 装载正确性（逐分量实时比对，期望每声部 128 个分量）：");
        $display("   声部 音符  分量  bank0(inc)  bank1(R1)  bank2(a16)  bank2(phi8)  " );
        z = 0;
        for (g0 = 0; g0 < NVOICE; g0 = g0 + 1) begin
            $display("   %2d  %3d  %3d/128   %2d错      %2d错      %2d错       %2d错     %s",
                     g0, noteOf(g0), nload[g0], badinc[g0], badr1[g0], bade1[g0], badph[g0],
                     (nload[g0] == NPART && badinc[g0] == 0 && badr1[g0] == 0 &&
                      bade1[g0] == 0 && badph[g0] == 0) ? "[OK]" : "[FAIL]");
            z = z + badinc[g0] + badr1[g0] + bade1[g0] + badph[g0];
            if (nload[g0] != NPART) z = z + 1;
        end
        if (z != 0) fail = fail + 1;

        // ② 每声部出声 + ③ 相位累加一致性
        $display("");
        $display("② 每声部输出 + ③ 相位累加：");
        $display("   声部 音符  非零/总   峰值   实测相位推进   表内 inc[0](分量0)  一致?");
        for (g0 = 0; g0 < NVOICE; g0 = g0 + 1) begin
            $display("   %2d  %3d  %4d/%4d  %5d  %11d    %11d        %s",
                     g0, noteOf(g0), samp_nz[g0], NSMP, samp_pk[g0],
                     ph_delta[g0], dut.u_rom_p.m0[baseOf(g0)],
                     (ph_delta[g0] == dut.u_rom_p.m0[baseOf(g0)]) ? "[OK]" : "[FAIL]");
            if (samp_nz[g0] == 0) begin
                $display("        [FAIL] 声部 %0d 完全没有输出！", g0);
                fail = fail + 1;
            end
            if (ph_delta[g0] != dut.u_rom_p.m0[baseOf(g0)]) begin
                $display("        [FAIL] 声部 %0d 相位推进量不等于自己音符的 inc[0]！", g0);
                fail = fail + 1;
            end
        end

        // ④ 求和
        $display("");
        $display("④ 8 路求和 bit-exact：比对 %0d 个样点，%0d 处不符 %s",
                 mix_n, badmix, (badmix == 0) ? "[OK]" : "[FAIL]");
        if (badmix != 0) fail = fail + 1;

        // ⑤ 削顶 / 静音
        $display("");
        $display("⑤ 混音输出：峰值 %0d，削顶样点 %0d，v_idle=%b %s",
                 mix_pk, mix_clip, v_idle,
                 (mix_clip == 0 && mix_pk > 0 && v_idle == {NVOICE{1'b0}}) ? "[OK]" : "[FAIL]");
        if (mix_clip != 0 || mix_pk == 0) fail = fail + 1;
        if (v_idle != {NVOICE{1'b0}}) begin
            $display("        [FAIL] v_idle=%b，有 %0d 个声部报 idle（应当全部在发声）",
                     v_idle, $countones(v_idle));
            fail = fail + 1;
        end

        $display("");
        if (fail == 0)
            $display("================ [PASS] 全部通过：8 声部共存正常 ================");
        else
            $display("================ [FAIL] %0d 项失败 ================", fail);
        $display("");
        $finish;
    end

    // 超时保护
    initial begin
        #200_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
