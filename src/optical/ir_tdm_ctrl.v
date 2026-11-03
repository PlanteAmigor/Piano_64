//==========================================================================
//  ir_tdm_ctrl —— 六路红外发射 时分复用（TDM）时序发生器
//
//  完全复现 F407 上已验证的时刻（移植文档 §AD7606 采样状态机）：
//
//       │◄──────────── 一个 2 ms 时隙 ────────────►│
//       0        0.4ms      0.7ms                 1.7ms        2.0ms
//       │          │          │                     │            │
//       ├─EMIT_ON──┤          │                     │            │
//       │      conv_on        │                     │            │
//       │                     ├────发射管全关────────┤            │
//       │                                   conv_off             │
//       │                                                     切下一路
//
//  · 每个时隙只有【一路】发射管点亮（one-hot）→ 避免六路互相串光
//  · 亮值在点亮后 0.4 ms 采（避开 LED 上升沿与接收管前级建立）
//  · 0.7 ms 关发射管 → 剩 1.0 ms 让环境光读数稳定
//  · 暗值在 1.7 ms 采 → 同一路的「亮 − 暗」把环境光/暗电流/失调逐位抵消
//  · 六路一轮 = 12 ms → 每路 83.3 Hz
//
//  ⚠️ 不要「优化」这三个时刻！它们是 F407 实测可用的值，
//     换平台先原样复现，等上板抓到波形再说。
//
//  ⚠️ conv_on / conv_off 是【单拍脉冲】。必须在 ad7606_serial 处于 ready
//     时才有效（转换约 15 µs，与 1300 µs 的间隔相比余量极大）。
//==========================================================================
`default_nettype none

module ir_tdm_ctrl #(
    parameter integer CLK_HZ     = 50_000_000,
    parameter integer SLOT_MS    = 2,      // 每个通道占用时长
    parameter integer ON_US      = 400,    // 亮值采样时刻（时隙内偏移）
    parameter integer EMITOFF_US = 700,    // 关闭发射管时刻
    parameter integer DARK_US    = 1700,   // 暗值采样时刻
    parameter integer NCH        = 6
)(
    input  wire            clk,
    input  wire            rst_n,

    output reg  [NCH-1:0]  emitter,    // one-hot（或全 0 = 全灭阶段）
    output reg             conv_on,    // 亮值转换脉冲
    output reg             conv_off,   // 暗值转换脉冲
    output reg  [2:0]      slot_idx,   // 当前通道 0..NCH-1
    output reg             round_stb,  // 六路一轮结束的单拍脉冲
    output reg  [15:0]     round_cnt   // 轮次计数（调试/上位机用）
);

    localparam integer CYC_PER_US = CLK_HZ / 1_000_000;
    localparam integer SLOT_CYC   = CYC_PER_US * 1000 * SLOT_MS;
    localparam integer ON_CYC     = CYC_PER_US * ON_US;
    localparam integer EOFF_CYC   = CYC_PER_US * EMITOFF_US;
    localparam integer DARK_CYC   = CYC_PER_US * DARK_US;

    // 编译期自检：三个时刻必须严格递增且在时隙内
    // synthesis translate_off
    initial begin
        if (!(ON_CYC < EOFF_CYC && EOFF_CYC < DARK_CYC && DARK_CYC < SLOT_CYC)) begin
            $display("ir_tdm_ctrl: 时刻参数非法 ON=%0d EOFF=%0d DARK=%0d SLOT=%0d",
                     ON_CYC, EOFF_CYC, DARK_CYC, SLOT_CYC);
            $finish;
        end
    end
    // synthesis translate_on

    reg [23:0] c;

    always @(posedge clk) begin
        if (!rst_n) begin
            c         <= 24'd0;
            emitter   <= {NCH{1'b0}};
            conv_on   <= 1'b0;
            conv_off  <= 1'b0;
            slot_idx  <= 3'd0;
            round_stb <= 1'b0;
            round_cnt <= 16'd0;
        end else begin
            conv_on   <= 1'b0;
            conv_off  <= 1'b0;
            round_stb <= 1'b0;

            // ---- 发射管：时隙前 0.7 ms 点亮当前这一路，之后全灭 ----
            emitter <= (c < EOFF_CYC) ? ({{(NCH-1){1'b0}}, 1'b1} << slot_idx)
                                      : {NCH{1'b0}};

            // ---- 两个采样时刻 ----
            if (c == ON_CYC)   conv_on  <= 1'b1;
            if (c == DARK_CYC) conv_off <= 1'b1;

            // ---- 时隙推进 ----
            if (c == SLOT_CYC - 1) begin
                c <= 24'd0;
                if (slot_idx == NCH[2:0] - 3'd1) begin
                    slot_idx  <= 3'd0;
                    round_stb <= 1'b1;
                    round_cnt <= round_cnt + 16'd1;
                end else begin
                    slot_idx <= slot_idx + 3'd1;
                end
            end else begin
                c <= c + 24'd1;
            end
        end
    end

endmodule

`default_nettype wire
