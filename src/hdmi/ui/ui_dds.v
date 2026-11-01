//==========================================================================
//  ui_dds —— UI 测试用的合成音源（不是最终音频！）
//
//  波形 = sin(φ) + 0.5·sin(2φ) + 0.25·sin(3φ)，256 点正弦查表
//         （之前用三角波加谐波，正负半周不对称：
//           峰 +12282 / -28655，波形整个偏下。
//           换成正弦后上下对称，相图也变成漂亮的闭合花瓣。）
//
//  频率字 inc = f × 2^32 / fs。440 Hz @ fs=48828 → 38,702,809。
//  ★ 踩过：inc 原来只有 16 位且写成 9 → 实际 0.0001 Hz ≈ 直流，什么都不动。
//==========================================================================
`default_nettype none

module ui_dds (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] inc,          // 频率字
    output reg  signed [15:0] sample,
    output reg         sample_tick   // 每采样一拍
);

    // ── 采样率分频：50 MHz / 1024 = 48828 Hz ────────────────────
    reg [9:0] cnt;
    wire      tick = (cnt == 10'd1023);
    always @(posedge clk) begin
        if (!rst_n) cnt <= 10'd0;
        else        cnt <= tick ? 10'd0 : (cnt + 10'd1);
    end

    // ── 相位累加 + 极缓慢颤音 ──────────────────────────────────
    reg [31:0] ph;
    reg [15:0] vib;
    always @(posedge clk) begin
        if (!rst_n) begin
            ph  <= 32'd0;
            vib <= 16'd0;
        end
        else if (tick) begin
            ph  <= ph + inc + {{12{vib[15]}}, vib[15:4], 4'd0};
            vib <= vib + 16'd1;
        end
    end

    // ── 256 点正弦表 ───────────────────────────────────────────
    reg signed [15:0] sine [0:255];
    initial $readmemh("src/hdmi/ui/ui_sine.hex", sine);

    wire [31:0] ph2 = {ph[30:0], 1'b0};          // 2φ
    wire [31:0] ph3 = ph + ph2;                  // 3φ

    wire signed [15:0] y1 = sine[ph [31:24]];
    wire signed [15:0] y2 = sine[ph2[31:24]];
    wire signed [15:0] y3 = sine[ph3[31:24]];

    // 1.0 + 0.5 + 0.25 → 最大 57343，用 18 位中间量，最后 >>>1
    wire signed [17:0] sum3 = y1 + (y2 >>> 1) + (y3 >>> 2);

    always @(posedge clk) begin
        if (!rst_n) begin
            sample      <= 16'sd0;
            sample_tick <= 1'b0;
        end
        else begin
            sample_tick <= tick;
            if (tick) sample <= sum3[16:1];
        end
    end

endmodule

`default_nettype wire
