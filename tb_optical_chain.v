//==========================================================================
//  tb_optical_chain —— 光学前端【整链】仿真（TDM → AD7606 → 差分 → 特征
//                      → 质心 → 控制律），用「假手」模型驱动
//
//  目的：不依赖硬件、不依赖串口，直接复现/回归现场行为：
//    · x_q8 是否跟着手的横向位置走
//    · bend 是否随 x 变化（±700 音分）
//    · vel  是否随手的高度变化
//
//  假手模型（由 calib/opt_calib.csv 拟合）：
//    · 横向：高斯分布，σ≈2.2 cm，传感器 i 在 X_i = 0/2.5/5/10/12.5/15 cm
//    · 高度：峰值幅度按实测表 A(h) 衰减（1cm 1979mV → 10cm 305mV）
//    · 1 mV ≈ 6.55 ADC 码
//
//  运行：
//    iverilog -g2012 -o ../.tmp/tb_chain \
//        src/optical/ir_tdm_ctrl.v src/optical/ad7606_serial.v \
//        src/optical/ir_diff_filter.v src/optical/opt_feat.v \
//        src/optical/opt_pos.v src/optical/position_control.v \
//        tb_optical_chain.v
//    cd ../.tmp && vvp tb_chain
//==========================================================================
`timescale 1ns/1ps
`default_nettype none

//--------------------------------------------------------------------------
//  行为级 AD7606（与 tb_optical_adc 相同）
//--------------------------------------------------------------------------
module ad7606_model #(
    parameter integer TCONV_CYC = 200
)(
    input  wire         clk,
    input  wire         convst,
    input  wire         reset,
    input  wire         cs_n,
    input  wire         sclk,
    output reg          busy,
    output reg          douta,
    output reg          doutb,
    input  wire [127:0] flat
);
    reg [127:0] lat;
    reg [6:0]   bitp;
    reg [15:0]  bcnt;
    integer bp, ch, bi;

    always @(posedge convst) begin
        lat  <= flat;
        busy <= 1'b1;
        bcnt <= 16'd0;
    end

    always @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0;
            bcnt <= 16'd0;
        end else if (busy) begin
            if (bcnt == TCONV_CYC - 1) begin
                busy <= 1'b0;
                bcnt <= 16'd0;
            end else bcnt <= bcnt + 16'd1;
        end
    end

    always @(negedge cs_n) begin
        bitp  <= 7'd0;
        douta <= lat[15];
        doutb <= lat[4*16 + 15];
    end

    always @(posedge sclk) begin
        if (!cs_n && bitp < 7'd63) begin
            bitp <= bitp + 7'd1;
            bp   = bitp + 1;
            ch   = bp >> 4;
            bi   = 15 - (bp & 15);
            douta <= lat[ch*16 + bi];
            doutb <= lat[(ch+4)*16 + bi];
        end
    end
endmodule

//--------------------------------------------------------------------------
//  测试平台
//--------------------------------------------------------------------------
module tb_optical_chain;

    // ---- 传感器横向位置（cm）----
    localparam real XS0 = 0.0, XS1 = 2.5, XS2 = 5.0,
                   XS3 = 10.0, XS4 = 12.5, XS5 = 15.0;

    // ---- 每路串扰（mV）：手拿开时的 diff 也不是 0，是发射管直射 PCB 的串扰。
    //      实测无手 Σ ≈ 2068 码 ≈ 328 mV，分到 6 路如下 ----
    real XTLK [0:5];

    // ---- 假手状态 ----
    real hand_x  = -100.0;      // cm，负 = 没有手
    real hand_h  = 100.0;       // cm
    reg  conv_is_on = 1'b1;     // 当前这次转换是亮值还是暗值

    // ---- 高斯横向分布表 exp(-d^2/(2*2.2^2))，d = 0..8 cm ----
    real GW [0:8];

    real amp_h;                 // 峰值幅度（mV）
    real sig [0:5];             // 每路信号（mV）
    integer i, k;
    real d, ad, f;

    // 高度 → 六路总和 Σ(mV)，含串扰。实测（x=0，手正对 CH1）
    //   1cm 3451 / 2cm 2955 / 4cm 1688 / 7cm 1172 / 10cm 1165 / 无手 328
    real sum_mv;
    task calc_amp;
        begin
            if      (hand_h <= 1.0)  sum_mv = 3451.0;
            else if (hand_h <= 2.0)  sum_mv = 3451.0 + (2955.0-3451.0)*(hand_h-1.0);
            else if (hand_h <= 4.0)  sum_mv = 2955.0 + (1688.0-2955.0)*(hand_h-2.0)/2.0;
            else if (hand_h <= 7.0)  sum_mv = 1688.0 + (1172.0-1172.0)*(hand_h-4.0)/3.0
                                             + (1172.0-1688.0)*(hand_h-4.0)/3.0;
            else if (hand_h <= 10.0) sum_mv = 1172.0 + (1165.0-1172.0)*(hand_h-7.0)/3.0;
            else                     sum_mv = 1165.0;
            // 扣掉串扰，剩下的才是手反射的可用分量
            amp_h = sum_mv - 328.0;
            if (amp_h < 0.0) amp_h = 0.0;
        end
    endtask

    function real gauss;
        input real dd;
        integer kk;
        real ff;
        begin
            ad = (dd < 0.0) ? -dd : dd;
            kk = $rtoi(ad);
            if (kk >= 8) gauss = 0.0;
            else begin
                ff = ad - kk;
                gauss = GW[kk] + (GW[kk+1] - GW[kk]) * ff;
            end
        end
    endfunction

    // ---- 根据假手位置算 flat ----
    // ---- 通道噪声（每个转换更新一次，±3 mV ≈ ±20 码）----
    reg signed [15:0] nz [0:5];
    integer n;
    always @(posedge adc_convst) begin
        for (n = 0; n < 6; n = n + 1)
            nz[n] = ($random % 40) - 20;
    end

    reg [127:0] flat;
    integer c;
    real        v, gsum;
    always @(*) begin
        calc_amp;
        // 先把高斯权重归一化，让六路之和等于 amp_h
        gsum = 0.0;
        for (c = 0; c < 6; c = c + 1) begin
            case (c)
                0: d = XS0; 1: d = XS1; 2: d = XS2;
                3: d = XS3; 4: d = XS4; default: d = XS5;
            endcase
            if (hand_x < -50.0) sig[c] = 0.0;
            else                sig[c] = gauss(hand_x - d);
            gsum = gsum + sig[c];
        end
        for (c = 0; c < 6; c = c + 1) begin
            if (gsum > 0.001 && hand_x > -50.0) sig[c] = amp_h * sig[c] / gsum;
            else                                sig[c] = 0.0;
            // 亮值 = 串扰 + 手反射；暗值 = 0（差分后剩下串扰+手）
            v = (conv_is_on ? (XTLK[c] + sig[c]) : 0.0) * 6.55;
            v = v + nz[c];
            if (v >  32000.0) v =  32000.0;
            if (v <  -32000.0) v = -32000.0;
            flat[16*c +: 16] = $rtoi(v);
        end
    end

    // ---- 时钟/复位 ----
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;
    reg tdm_rst_n = 0;

    // ---- DUT ----
    wire [5:0]  emitter;
    wire        conv_on, conv_off, round_stb;
    wire [2:0]  slot_idx;
    wire [15:0] round_cnt;

    ir_tdm_ctrl #(
        .CLK_HZ(50_000_000), .SLOT_MS(2), .ON_US(400),
        .EMITOFF_US(700), .DARK_US(1700), .NCH(6)
    ) u_tdm (
        .clk(clk), .rst_n(tdm_rst_n),
        .emitter(emitter), .conv_on(conv_on), .conv_off(conv_off),
        .slot_idx(slot_idx), .round_stb(round_stb), .round_cnt(round_cnt)
    );

    wire [127:0] ch_flat;
    wire         adc_done, adc_ready;
    wire [2:0]   hw_err;
    wire         adc_convst, adc_reset, adc_cs_n, adc_sclk;
    wire         adc_busy, adc_douta, adc_doutb;

    ad7606_serial #(.SCLK_HALF(4), .CONVST_CYC(12), .CS_SETUP(8)) u_adc (
        .clk(clk), .rst_n(rst_n),
        .start(conv_on | conv_off),
        .ch_flat(ch_flat), .done(adc_done), .ready(adc_ready), .hw_err(hw_err),
        .adc_convst(adc_convst), .adc_reset(adc_reset), .adc_cs_n(adc_cs_n),
        .adc_sclk(adc_sclk), .adc_busy(adc_busy),
        .adc_douta(adc_douta), .adc_doutb(adc_doutb)
    );

    ad7606_model u_model (
        .clk(clk), .convst(adc_convst), .reset(adc_reset),
        .cs_n(adc_cs_n), .sclk(adc_sclk),
        .busy(adc_busy), .douta(adc_douta), .doutb(adc_doutb),
        .flat(flat)
    );

    wire [107:0] diff_flat, flt_flat;
    wire         frame_valid;
    wire [15:0]  frame_cnt;

    ir_diff_filter #(.NCH(6)) u_diff (
        .clk(clk), .rst_n(rst_n), .done(adc_done), .ch_flat(ch_flat),
        .slot_idx(slot_idx), .is_on(|emitter),
        .diff_flat(diff_flat), .flt_flat(flt_flat),
        .frame_valid(frame_valid), .frame_cnt(frame_cnt)
    );

    wire signed [23:0] rho_raw, rho_dc, rho_ac, ac_env;
    wire [15:0]        half_period;

    opt_feat #(.NCH(6), .LP_SHIFT(3), .ENV_SHIFT(2), .AC_DB(256)) u_feat (
        .clk(clk), .rst_n(rst_n), .frame_valid(frame_valid), .raw_flat(diff_flat),
        .rho_raw(rho_raw), .rho_dc(rho_dc), .rho_ac(rho_ac), .ac_env(ac_env),
        .half_period(half_period), .frame_cnt()
    );

    wire [15:0] x_q8;
    wire [23:0] sum_pos;
    wire        x_valid;

    opt_pos #(.NCH(6)) u_pos (
        .clk(clk), .rst_n(rst_n), .frame_valid(frame_valid), .raw_flat(diff_flat),
        .x_q8(x_q8), .sum_pos(sum_pos), .x_valid(x_valid), .x_frame()
    );

    wire signed [15:0] bend;
    wire        [7:0]  vel;
    wire        [15:0] bend_q14;

    position_control u_ctl (
        .clk(clk), .rst_n(rst_n), .frame_valid(frame_valid),
        .x_q8(x_q8), .x_valid(x_valid), .rho_dc(rho_dc),
        .bend(bend), .vel(vel), .bend_q14(bend_q14)
    );

    // ---- 驱动 ----
    initial begin
        XTLK[0]=50.0; XTLK[1]=69.0; XTLK[2]=36.0; XTLK[3]=57.0; XTLK[4]=66.0; XTLK[5]=60.0;
        for (i = 0; i <= 8; i = i + 1)
            GW[i] = $exp(-(i*i)/(2.0*2.2*2.2));

        rst_n = 0; tdm_rst_n = 0;
        repeat (200) @(posedge clk);
        rst_n = 1;
        wait (adc_ready == 1'b1);
        repeat (10) @(posedge clk);
        tdm_rst_n = 1;
    end

    // 跟踪亮/暗转换
    always @(posedge clk) begin
        if (conv_on)  conv_is_on <= 1;
        if (conv_off) conv_is_on <= 0;
    end

    // ---- 场景 ----
    integer fc;
    always @(posedge frame_valid) begin
        fc = fc + 1;
        if (fc % 4 == 0)
            $display("f=%3d  x=%6.2f h=%5.2f | rho_raw=%7.0f rho_dc=%7.0f  x_q8=%5d xv=%0d  bend=%5d  vel=%3d",
                     fc, hand_x, hand_h, rho_raw, rho_dc, x_q8, x_valid, bend, vel);
    end

    initial begin
        fc = 0;
        hand_x = -100.0; hand_h = 100.0;

        // 阶段 1：手拿开
        repeat (8) @(posedge frame_valid);

        // 阶段 2：手放在高度 3 cm，从 2 cm 横向扫到 13 cm
        hand_x = 2.0; hand_h = 3.0;
        for (k = 0; k <= 11; k = k + 1) begin
            hand_x = 2.0 + k * 1.0;
            repeat (4) @(posedge frame_valid);
        end

        // 阶段 3：回到中间位置，高度从 12 cm 降到 1 cm
        hand_x = 7.5;
        for (k = 0; k <= 11; k = k + 1) begin
            hand_h = 12.0 - k * 1.0;
            repeat (4) @(posedge frame_valid);
        end

        // 阶段 4：手拿开
        hand_x = -100.0; hand_h = 100.0;
        repeat (20) @(posedge frame_valid);

        $display("\n==== 仿真结束 ====");
        $finish;
    end

endmodule

`default_nettype wire
