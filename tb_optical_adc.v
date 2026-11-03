//==========================================================================
//  tb_optical_adc —— ir_tdm_ctrl + ad7606_serial 联合仿真
//
//  用行为级 AD7606 模型（双 DOUT、BUSY=tCONV 4 µs、CS 下降推 MSB、
//  SCLK 上升沿移位）回放，检查：
//    1. emitter 任意时刻要么全 0、要么严格 one-hot
//    2. 亮值转换（conv_on）读回的 8 通道 == ON_CODE
//    3. 暗值转换（conv_off）读回的 8 通道 == OFF_CODE   → 通道映射/位序正确
//    4. 一轮 = 6 个时隙 = 12 ms，round_stb 只出现一次
//    5. hw_err 始终为 0
//
//  运行：
//    iverilog -g2012 -o <tmp>/tb_optical_adc \
//        src/optical/ir_tdm_ctrl.v src/optical/ad7606_serial.v tb_optical_adc.v
//    vvp <tmp>/tb_optical_adc
//==========================================================================
`timescale 1ns/1ps
`default_nettype none

//--------------------------------------------------------------------------
//  行为级 AD7606（仅串行读取部分）
//--------------------------------------------------------------------------
module ad7606_model #(
    parameter integer TCONV_CYC = 200      // 4 µs @50 MHz
)(
    input  wire         clk,
    input  wire         convst,
    input  wire         reset,
    input  wire         cs_n,
    input  wire         sclk,
    output reg          busy,
    output reg          douta,
    output reg          doutb,
    input  wire [127:0] flat          // flat[16*i +: 16] = Vi+1
);
    reg [127:0] lat;                  // CONVST 上升沿冻结的采样值
    reg [6:0]   bitp;                 // 0 = MSB 已推出，1..63 = 后续位
    reg [15:0]  bcnt;

    integer bp, ch, bi;               // （不能用 bit：SystemVerilog 关键字）

    // ① CONVST 上升沿冻结采样 + 拉高 BUSY
    always @(posedge convst) begin
        lat  <= flat;
        busy <= 1'b1;
        bcnt <= 16'd0;
    end

    // ② BUSY 保持 tCONV 后释放
    always @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0;
            bcnt <= 16'd0;
        end else if (busy) begin
            if (bcnt == TCONV_CYC - 1) begin
                busy <= 1'b0;
                bcnt <= 16'd0;
            end else begin
                bcnt <= bcnt + 16'd1;
            end
        end
    end

    // ③ CS 下降沿把 V1 / V5 的 MSB 推到两根 DOUT 上
    always @(negedge cs_n) begin
        bitp  <= 7'd0;
        douta <= lat[15];
        doutb <= lat[4*16 + 15];
    end

    // ④ 之后每一位在 SCLK【上升沿】被推出
    always @(posedge sclk) begin
        if (!cs_n && bitp < 7'd63) begin
            bitp <= bitp + 7'd1;
            bp   = bitp + 1;
            ch   = bp >> 4;               // 0..3
            bi   = 15 - (bp & 15);
            douta <= lat[ch*16 + bi];         // V(ch+1)
            doutb <= lat[(ch+4)*16 + bi];     // V(ch+5)
        end
    end
endmodule

//--------------------------------------------------------------------------
//  测试平台
//--------------------------------------------------------------------------
module tb_optical_adc;

    // 亮值：每路不同码，其中 V8 取负值验证二补码
    localparam [15:0] ON_V1 = 16'h7ABC, ON_V2 = 16'h6789,
                      ON_V3 = 16'h5678, ON_V4 = 16'h4567,
                      ON_V5 = 16'h3456, ON_V6 = 16'h2345,
                      ON_V7 = 16'h1234, ON_V8 = 16'hF000;   // -4096
    localparam [127:0] ON_CODE = {ON_V8, ON_V7, ON_V6, ON_V5,
                                  ON_V4, ON_V3, ON_V2, ON_V1};

    localparam [127:0] OFF_CODE = {16'h0008, 16'h0007, 16'h0006, 16'h0005,
                                   16'h0004, 16'h0003, 16'h0002, 16'h0001};

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg tdm_rst_n = 1'b0;        // ★ 比 rst_n 释放得更晚：等 ADC 上电复位跑完
    always #10 clk = ~clk;              // 50 MHz

    // ---- TDM ----
    wire [5:0]  emitter;
    wire        conv_on, conv_off, round_stb;
    wire [2:0]  slot_idx;
    wire [15:0] round_cnt;

    ir_tdm_ctrl u_tdm (
        .clk       (clk),
        .rst_n     (tdm_rst_n),
        .emitter   (emitter),
        .conv_on   (conv_on),
        .conv_off  (conv_off),
        .slot_idx  (slot_idx),
        .round_stb (round_stb),
        .round_cnt (round_cnt)
    );

    // ---- ADC ----
    wire [127:0] ch_flat;
    wire         done, ready;
    wire [2:0]   hw_err;
    wire         adc_convst, adc_reset, adc_cs_n, adc_sclk, adc_busy;
    wire         adc_douta, adc_doutb;

    // 光敏板行为：发射管亮 → 亮码；全灭 → 暗码
    wire [127:0] flat = (|emitter) ? ON_CODE : OFF_CODE;

    ad7606_serial u_adc (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (conv_on | conv_off),
        .ch_flat    (ch_flat),
        .done       (done),
        .ready      (ready),
        .hw_err     (hw_err),
        .adc_convst (adc_convst),
        .adc_reset  (adc_reset),
        .adc_cs_n   (adc_cs_n),
        .adc_sclk   (adc_sclk),
        .adc_busy   (adc_busy),
        .adc_douta  (adc_douta),
        .adc_doutb  (adc_doutb)
    );

    ad7606_model #(.TCONV_CYC(200)) u_model (
        .clk    (clk),
        .convst (adc_convst),
        .reset  (adc_reset),
        .cs_n   (adc_cs_n),
        .sclk   (adc_sclk),
        .busy   (adc_busy),
        .douta  (adc_douta),
        .doutb  (adc_doutb),
        .flat   (flat)
    );

    // ---- 差分滤波 ----
    wire [107:0] diff_flat, flt_flat;
    wire         frame_valid;
    wire [15:0]  frame_cnt;

    ir_diff_filter #(.NCH(6)) u_diff (
        .clk         (clk),
        .rst_n       (rst_n),
        .done        (done),
        .ch_flat     (ch_flat),
        .slot_idx    (slot_idx),
        .is_on       (|emitter),
        .diff_flat   (diff_flat),
        .flt_flat    (flt_flat),
        .frame_valid (frame_valid),
        .frame_cnt   (frame_cnt)
    );

    // 期望差值 = ON_Vi − OFF_Vi
    localparam [107:0] DIFF_CODE = {18'd9023,   // ch6: 0x2345 - 6
                                    18'd13393,  // ch5: 0x3456 - 5
                                    18'd17763,  // ch4: 0x4567 - 4
                                    18'd22133,  // ch3: 0x5678 - 3
                                    18'd26503,  // ch2: 0x6789 - 2
                                    18'd31419}; // ch1: 0x7ABC - 1

    // ---- 串口上报（真实 uart_tx，验证握手与十进制格式）----
    wire [7:0] rp_char;
    wire       rp_vld, utx_busy, utx_txd;

    uart_tx #(.CLK_HZ(50_000_000), .BAUD(115_200)) u_utx (
        .clk   (clk),
        .rst_n (rst_n),
        .dbyte (rp_char),
        .send  (rp_vld),
        .busy  (utx_busy),
        .txd   (utx_txd)
    );

    report6 #(.NCH(6)) u_rep (
        .clk         (clk),
        .rst_n       (rst_n),
        .frame_valid (frame_valid),
        .flt_flat    (flt_flat),
        .uart_char   (rp_char),
        .uart_valid  (rp_vld),
        .uart_ready  (~utx_busy)
    );

    // 收到的字节直接拼成文字打印出来
    always @(posedge clk) begin
        if (rp_vld && !utx_busy) begin
            $write("%c", rp_char);
            if ($test$plusargs("dbg")) $display("BYTE[%0t] %02x '%c'", $time, rp_char, rp_char);
        end
    end

    //----------------------------------------------------------------------
    //  检查
    //----------------------------------------------------------------------
    integer err = 0;
    integer n_on = 0, n_off = 0, n_diff = 0;
    reg     exp_on = 1'b0;
    reg     done_d = 1'b0;
    reg [127:0] exp_code;
    reg         exp_vld = 1'b0;
    reg [2:0]   prev_slot = 3'd0;
    time        t_slot0 = 0, t_round0 = 0;

    // 记住每次 start 是亮值还是暗值
    always @(posedge clk) begin
        if (conv_on)  begin exp_on <= 1'b1; exp_code <= ON_CODE;  exp_vld <= 1'b1; end
        if (conv_off) begin exp_on <= 1'b0; exp_code <= OFF_CODE; exp_vld <= 1'b1; end
    end

    // emitter 必须 one-hot
    always @(posedge clk) begin
        if (rst_n && (|emitter)) begin
            if ((emitter & (emitter - 6'd1)) != 6'd0) begin
                $display("[%0t] FAIL: emitter 不是 one-hot = %b", $time, emitter);
                err = err + 1;
            end
            if (emitter !== (6'b1 << slot_idx)) begin
                $display("[%0t] FAIL: emitter=%b 与 slot_idx=%0d 不符", $time, emitter, slot_idx);
                err = err + 1;
            end
        end
    end

    // 结果比对（延迟一拍，ch_flat 已稳定）
    always @(posedge clk) begin
        done_d <= done;
        if (done_d && exp_vld) begin
            if (ch_flat !== exp_code) begin
                $display("[%0t] FAIL: %s 帧读回错误", $time, exp_on ? "亮值" : "暗值");
                $display("        期望 %h", exp_code);
                $display("        实际 %h", ch_flat);
                err = err + 1;
            end else if (exp_on) begin
                n_on = n_on + 1;
            end else begin
                n_off = n_off + 1;
            end
            exp_vld <= 1'b0;
        end
    end

    // 时隙长度 / 轮次
    always @(posedge clk) begin
        if (rst_n) begin
            if (slot_idx != prev_slot) begin
                if (t_slot0 != 0) begin
                    if (($time - t_slot0) != 2_000_000) begin
                        $display("[%0t] FAIL: 时隙长度 %0d ns（应为 2 000 000）",
                                 $time, $time - t_slot0);
                        err = err + 1;
                    end
                end
                t_slot0   = $time;
                prev_slot = slot_idx;
            end
            if (round_stb) begin
                if (t_round0 != 0 && ($time - t_round0) != 12_000_000) begin
                    $display("[%0t] FAIL: 一轮长度 %0d ns（应为 12 000 000）",
                             $time, $time - t_round0);
                    err = err + 1;
                end
                t_round0 = $time;
            end
        end
    end

    // hw_err 必须为 0
    always @(posedge clk) begin
        if (rst_n && hw_err != 3'd0) begin
            $display("[%0t] FAIL: hw_err = %0d", $time, hw_err);
            err = err + 1;
        end
    end

    // 六路差分帧比对（frame_valid 打一拍后 flt 已稳定）
    always @(posedge clk) begin
        if (frame_valid) begin
            if (flt_flat !== DIFF_CODE || diff_flat !== DIFF_CODE) begin
                $display("[%0t] FAIL: 六路差分帧错误", $time);
                $display("        期望 flt %h", DIFF_CODE);
                $display("        实际 flt %h", flt_flat);
                $display("        实际 dif %h", diff_flat);
                err = err + 1;
            end else begin
                n_diff = n_diff + 1;
            end
        end
    end

    //----------------------------------------------------------------------
    //  主流程
    //----------------------------------------------------------------------
    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("tb_optical_adc.vcd");
            $dumpvars(0, tb_optical_adc);
        end
        #200 rst_n = 1'b0;
        #2000 rst_n = 1'b1;

        // ★ ADC 上电复位需要 1 ms，这段时间不能发 start（发了会被丢掉）。
        //   真实系统中由 add_top 把「ADC ready」作为 TDM 的使能，这里同样处理。
        wait (ready == 1'b1);
        #1000 tdm_rst_n = 1'b1;

        // 跑满 2 轮
        wait (round_cnt == 16'd2);
        #5_000_000;          // 留足时间把第二行串口打完（一行约 3.7 ms）

        $display("");
        $display("================ 结果 ================");
        $display("  亮值帧 OK : %0d", n_on);
        $display("  暗值帧 OK : %0d", n_off);
        $display("  差分帧 OK : %0d", n_diff);
        $display("  错误数    : %0d", err);
        if (err == 0 && n_diff == 2 && n_on >= 12 && n_off >= 12)
            $display("  PASS");
        else
            $display("  FAIL");
        $display("======================================");
        $finish;
    end

    // 超时保护
    initial begin
        #40_000_000;
        $display("FAIL: 超时（40 ms 未完成 2 轮）");
        $finish;
    end

endmodule

`default_nettype wire
