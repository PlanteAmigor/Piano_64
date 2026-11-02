//==========================================================================
//  tb_ui3.v —— hdmi_ui3_top 离线出图（不经 PLL / DVI 原语）
//
//  用法：
//    iverilog -g2012 -DSIM_UI3 -Ptb_ui3.PAGE=0 -o ui3 out \
//             src/hdmi/hdmi_ui3_top.v tb_ui3.v && vvp ui3
//  产物：frame_p<page>.ppm（1280×720，可直接用 ImageMagick 转 PNG）
//==========================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_ui3;

    parameter integer PAGE = 0;          // 0=主页面 1=测试 2=教学
    parameter integer AMP  = 10000;      // 李萨如激励幅度（满幅约 16000）
    parameter real    TAU  = 0.0;        // 衰减时间常数（秒），0 = 不衰减
    parameter integer AGL  = 0;          // 余辉档位 0..3
    parameter integer FILT = 0;          // 显示低通档位 0..2
    localparam [1:0] AGLV  = AGL;        // ★ 不能直接写 AGL[1:0]（integer 位选会得 X）
    localparam [1:0] FLTV  = FILT;

    reg clk = 1'b0;
    always #6.667 clk = ~clk;            // 75 MHz

    reg resetn = 1'b0;

    wire [255:0] BANDS;
    wire [511:0] COMP_AMP;
    wire [17:0]  UI_INFO;
    wire signed [15:0] SCOPE_SMP;
    wire               SCOPE_TOG;
    reg                scope_trg = 1'b0;

    // 柱高给一个递增的测试图样，方便核对柱高换算
    genvar gi;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : g_band
            assign BANDS[gi*8 +: 8] = gi[7:0] * 8;      // 0, 8, 16 ... 248
        end
    endgenerate

    // 分量柱给一条典型谐波包络：基频最强，前 8 次谐波快速下降，
    // 8~19 次平缓，之后很低。用来检查坐标轴刻度是否对得上。
    genvar ck;
    generate
        for (ck = 0; ck < 64; ck = ck + 1) begin : g_comp
            localparam integer AV = (ck == 0)  ? 240 :
                                    (ck <  8)  ? (200 - ck * 18) :
                                    (ck <  20) ? (56 - (ck - 8) * 4) : 10;
            assign COMP_AMP[ck*8 +: 8] = AV;
        end
    endgenerate

    // 李萨如激励：基频 + 三次谐波，模拟带谐波的乐器波形
    //   每 32768 个 clk 一个样点（相当于 75MHz/48828 ≈ 1536，这里慢一点看得清）
    real    ph1;
    real    env;
    reg  signed [15:0] scope_smp;
    reg                scope_tog = 1'b0;
    integer            sc_cnt = 0;

    always @(posedge clk) begin
        sc_cnt <= sc_cnt + 1;
        if (sc_cnt >= 1536) begin
            sc_cnt    <= 0;
            ph1       <= ph1 + 0.0334;          // 基频≈262 Hz（相对 48828）
            env        = (TAU > 0.0) ? $exp(-($realtime * 1.0e-9) / TAU) : 1.0;
            scope_smp <= $rtoi(AMP * env) * $sin(ph1)
                       + $rtoi(AMP * env * 0.40) * $sin(3.0 * ph1)
                       + $rtoi(AMP * env * 0.20) * $sin(5.0 * ph1);
            scope_tog <= ~scope_tog;
        end
    end

    assign SCOPE_SMP = scope_smp;
    assign SCOPE_TOG = scope_tog;

    // 模拟一个 note-on：单次捕获从这里开始，200 ms 后冻结
    initial begin
        #50_000 scope_trg = 1'b1;
    end

    // 音色/效果器也取个固定值：古筝 + REVERB + +12 半音
    //   ★ 位图：[15:8] transpose  [7:6] 预留  [5:4] fx  [3:2] timbre  [1:0] mode
    assign UI_INFO = {8'sd12, FLTV, AGLV, 2'd2, 2'd1, PAGE[1:0]};

    hdmi_ui3_top dut (
        .clk   (clk),
        .resetn(resetn),
        .BANDS (BANDS),
        .BANDS_TICK(1'b0),
        .UI_INFO(UI_INFO),
        .COMP_AMP(COMP_AMP),
        .SCOPE_SMP(SCOPE_SMP),
        .SCOPE_TOG(SCOPE_TOG),
        .SCOPE_TRG(scope_trg),
        .tmds_clk_n_0(), .tmds_clk_p_0(),
        .tmds_d_n_0(),   .tmds_d_p_0()
    );

    // ── 抓可见像素（vis_d3 高 = 这一拍 rgb_r 就是一个可见像素）────────
    //    ★ 前 8 帧跳过：上电时 page_show 从 0 淡出到目标页，过渡帧里
    //      版面/柱高/亮度是混合状态；另外单次捕获要累积到第 8 帧
    //      （≈150 ms）才能画出完整的相位图。
    integer fout;
    integer ox = 0, oy = 0;
    integer frames = 0;

    initial begin
        ph1 = 0.0;
        scope_smp = 16'sd0;
    end

    initial begin
        if (PAGE == 0) fout = $fopen("frame_p0.ppm", "w");
        else if (PAGE == 1) fout = $fopen("frame_p1.ppm", "w");
        else                fout = $fopen("frame_p2.ppm", "w");
        $fwrite(fout, "P3\n1280 720\n255\n");
    end

    always @(posedge clk) begin
        if (!resetn) begin
            ox <= 0; oy <= 0; frames <= 0;
        end
        else if (dut.vis_d3) begin
            if (frames >= 8)
                $fwrite(fout, "%0d %0d %0d\n",
                        dut.rgb_r[23:16], dut.rgb_r[15:8], dut.rgb_r[7:0]);

            if (ox != 1279) begin
                ox <= ox + 1;
            end
            else if (oy != 719) begin
                ox <= 0;
                oy <= oy + 1;
            end
            else begin
                ox     <= 0;
                oy     <= 0;
                frames <= frames + 1;
                if (frames >= 8) begin
                    $fwrite(fout, "\n");
                    $fclose(fout);
                    $display("tb_ui3: 输出 P%0d 完成（第 %0d 帧）", PAGE, frames);
                    $finish;
                end
            end
        end
    end

    initial begin
        #1000 resetn = 1'b1;
        #400_000_000;                      // 超时保护（9 帧 ≈ 150 ms）
        $display("tb_ui3: TIMEOUT");
        $fclose(fout);
        $finish;
    end

endmodule

`default_nettype wire
