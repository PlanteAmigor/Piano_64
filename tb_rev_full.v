//==========================================================================
//  tb_rev_full —— 混响【满量程稳定性】测试
//
//  为什么需要这个 tb：tb_fx_reverb.v 用单位脉冲（幅度 17~35），
//  根本没跑到满量程，所以 60000 点 bit-exact 也说明不了硬件上的问题。
//
//  流程：灌 N_IN 个样点满量程噪声（±32767）→ 静音 N_TAIL 个样点 → 看尾巴。
//  判据：静音后尾巴必须衰减，不能停在噪声上。
//
//  全通级若用 ap_l[15:0] 把 20 位截断成 16 位（无饱和），
//  输入一旦超过 32767 就会把回绕的垃圾写进延迟线，
//  而全通有 0.5 反馈 → 垃圾自我维持 → 输出永远是噪声。
//==========================================================================
`timescale 1ns/1ps

module tb_rev_full;

    localparam integer TICKDIV = 60;       // 每样点 60 拍（FSM 约 44 拍，留余量）
    localparam integer N_IN    = 20000;
    localparam integer N_TAIL  = 60000;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;
    reg tick  = 1'b0;
    reg signed [15:0] in_l = 16'sd0, in_r = 16'sd0;
    wire signed [15:0] out_l, out_r;

    fx_reverb #(
        .FB_Q8  (225),
        .GD_Q8  (128),
        .GW_Q8  (140)
    ) dut (
        .clk    (clk), .rst_n(rst_n), .tick(tick), .enable(1'b1),
        .in_l   (in_l), .in_r(in_r), .out_l(out_l), .out_r(out_r)
    );

    integer cyc = 0;
    always @(posedge clk) begin
        if (cyc == TICKDIV-1) begin
            cyc  <= 0;
            tick <= 1'b1;
        end else begin
            cyc  <= cyc + 1;
            tick <= 1'b0;
        end
    end

    // ★ 必须初始化延迟线：Gowin BSRAM 上电为 0，iverilog 给 X，
    //   不然整条链全是 X，输出恒为 X（看起来像"输出 0"）
    integer mi;
    initial begin
        for (mi = 0; mi < 12288; mi = mi + 1) dut.cmem[mi] = 16'd0;
        for (mi = 0; mi < 1792; mi = mi + 1) begin
            dut.amem_l[mi] = 16'd0;
            dut.amem_r[mi] = 16'd0;
        end
    end

    real    sum_in, sum_tail, pk_in, pk_in_out, pk_tail;
    integer n, seed, i;
    real    v, o;
    integer omin, omax;

    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        seed = 12345; sum_in = 0.0; pk_in = 0.0; pk_in_out = 0.0;

        // ---- 满量程噪声 ----
        for (n = 0; n < N_IN; n = n + 1) begin
            in_l = $random(seed) % 32768;
            in_r = in_l;
            v = in_l;
            sum_in = sum_in + v*v;
            if (v > pk_in)  pk_in = v;
            if (-v > pk_in) pk_in = -v;
            for (i = 0; i < TICKDIV; i = i + 1) begin
                @(posedge clk);
                o = out_l;
                if (o > pk_in_out)  pk_in_out = o;
                if (-o > pk_in_out) pk_in_out = -o;
            end
        end
        $display("  输入：%0d 样点，峰值 %0.0f，RMS %0.0f", N_IN, pk_in, $sqrt(sum_in/N_IN));
        $display("  输入期间输出峰值 = %0.0f", pk_in_out);

        // ---- 静音，测尾巴 ----
        in_l = 16'sd0; in_r = 16'sd0;
        sum_tail = 0.0; pk_tail = 0.0;
        for (n = 0; n < N_TAIL; n = n + 1) begin
            for (i = 0; i < TICKDIV; i = i + 1) begin
                @(posedge clk);
                if (n >= N_TAIL/2) begin
                    o = out_l;
                    sum_tail = sum_tail + o*o;
                    if (o > pk_tail)  pk_tail = o;
                    if (-o > pk_tail) pk_tail = -o;
                end
            end
        end

        // 分 4 段看衰减：正常混响每 0.3s 应该掉 ~13 dB（T60≈1.35s，即 4.6 倍）
        $display("  静音后分 4 段 RMS（每段 %0d 样点 ≈ 0.3 s）:", N_TAIL/4);
        begin : win
            integer w, j;
            real    s2;
            real    r0, r1;
            r0 = 0.0;
            for (w = 0; w < 4; w = w + 1) begin
                in_l = 16'sd0; in_r = 16'sd0;
                s2 = 0.0; omin = 0; omax = 0;
                for (j = 0; j < N_TAIL/4; j = j + 1) begin
                    for (i = 0; i < TICKDIV; i = i + 1) begin
                        @(posedge clk);
                        if (out_l > omax) omax = out_l;
                        if (out_l < omin) omin = out_l;
                        o = out_l;
                        s2 = s2 + o*o;
                    end
                end
                s2 = $sqrt(s2/(N_TAIL/4));
                $display("    第 %0d 段 RMS = %0.1f  min=%0d max=%0d  curr=%0d",
                         w+1, s2, omin, omax, out_l);
                if (w == 0) r0 = s2;
                if (w == 3) r1 = s2;
            end
            $display("  内部：ap_l=%0d  acc_l=%0d  cfs0=%0d", dut.ap_l, dut.acc_l, dut.cfs[0]);
            begin : memscan
                integer m; reg [15:0] mx; reg [15:0] mn;
                reg signed [15:0] v;
                integer maxv, minv;
                maxv = -99999; minv = 99999;
                for (m = 0; m < 12288; m = m + 1) begin
                    v = dut.cmem[m];
                    if (v > maxv) maxv = v;
                    if (v < minv) minv = v;
                end
                $display("  cmem 末端范围: %0d .. %0d", minv, maxv);
                for (m = 0; m < 1792; m = m + 1) begin
                    v = dut.amem_l[m];
                    if (v > maxv) maxv = v;
                    if (v < minv) minv = -99999;
                end
            end
            if (r0 > 1.0 && r1 > r0*0.4)
                $display("  *** FAIL：尾巴不衰减 = 自激噪声 ***");
            else
                $display("  PASS：尾巴正常衰减");
        end
        $finish;
    end

endmodule
