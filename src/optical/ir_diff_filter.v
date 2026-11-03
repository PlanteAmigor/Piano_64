//==========================================================================
//  ir_diff_filter —— 六路「亮值 − 暗值」差分 + 4 点滑动平均
//
//  完全按 F407 已验证的流程（移植文档 §AD7606 采样状态机 第 5 步）：
//      diff_code = on_code − off_code
//      按 4 点窗口更新该通道滤波值
//      完成 CH6 后发布一致的六路帧
//
//  ── 为什么要亮暗相减 ─────────────────────────────────────────────
//    接收管上的电压 = LED 反射光 + 环境光 + 暗电流/失调。
//    后两项是加性的、会随现场灯光和温度漂。同一路通道在「亮/灭」两个相位
//    各采一次再相减，环境光、暗电流、ADC 失调【逐位抵消】——这就是全部意义。
//
//  ── 为什么还要 4 点平均 ─────────────────────────────────────────
//    每路 83.3 Hz（一轮 12 ms），单帧抖动大（信号小 + 噪声）。
//    4 点平均 → 每路每 4 轮（48 ms）更新一次平滑值，约 20 Hz，跟手够快。
//
//  ── 通道对齐（重要）──────────────────────────────────────────────
//    TDM 每个时隙只点亮【一路】发射管，接收侧读回 V1..V6。
//    本模块取的是「当前时隙对应那一路」的值：V(slot+1)。
//    也就是说 diff[i] 一定来自「第 i 路发射管亮着的时候、第 i 路接收管」的读数，
//    不会把别的通道的串光算进来。
//
//  ── 输出格式 ────────────────────────────────────────────────────
//    diff_flat[18*i +: 18] = 第 i 路原始差值（18 位二补码）
//    flt_flat [18*i +: 18] = 第 i 路 4 点平均（18 位二补码）
//    量纲仍是 AD7606 码值：1 LSB = 152.6 µV（±5 V 量程）
//
//    上电后每个通道的【第一帧】直接把 d1/d2/d3 都填成当前差值，
//    因此第一轮输出的 flt 就等于 diff，不存在「前几帧被 4 除」的问题。
//==========================================================================
`default_nettype none

module ir_diff_filter #(
    parameter integer NCH = 6
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ---- 来自 ad7606_serial ----
    input  wire                  done,       // 一帧读完（单拍）
    input  wire [127:0]          ch_flat,    // ch_flat[16*i +: 16] = Vi+1
    input  wire [2:0]            slot_idx,   // 当前时隙/通道号
    input  wire                  is_on,      // 1 = 本次是亮值（发射管亮着）

    // ---- 输出 ----
    output wire [NCH*18-1:0]     diff_flat,  // 原始差值
    output wire [NCH*18-1:0]     flt_flat,   // 4 点平均
    output reg                   frame_valid,// 六路一轮更新完（单拍）
    output reg  [15:0]           frame_cnt   // 已发布的轮数
);

    //======================================================================
    //  存储
    //======================================================================
    reg signed [15:0] on_code  [0:NCH-1];
    reg signed [17:0] diff_r   [0:NCH-1];
    reg signed [17:0] d1 [0:NCH-1];   // 上一帧
    reg signed [17:0] d2 [0:NCH-1];   // 上上帧
    reg signed [17:0] d3 [0:NCH-1];   // 上上上帧
    reg signed [17:0] flt [0:NCH-1];
    reg               ini [0:NCH-1];  // 该通道是否已经收到过差值

    //======================================================================
    //  一帧到来时：亮值存档 / 暗值算差
    //======================================================================
    //  ★ 全部用 wire 算，不要在时序 always 里用 blocking 中间变量
    //    （那会额外推断出寄存器，而且 Gowin 对 signed 混合表达式很敏感）
    wire [15:0]        vv = ch_flat[16*slot_idx +: 16];   // 当前时隙通道的码值
    wire [15:0]        oc = on_code[slot_idx];            // 本次亮值存档
    // ★ 差值 = 亮值 − 暗值（vv 此刻是【暗值】）
    wire signed [17:0] dv_w  = $signed({oc[15], oc[15], oc})
                             - $signed({vv[15], vv[15], vv});
    wire signed [19:0] sum_w = dv_w + d1[slot_idx] + d2[slot_idx] + d3[slot_idx];
    wire signed [17:0] avg_w = sum_w >>> 2;

    integer k;

    always @(posedge clk) begin
        if (!rst_n) begin
            frame_valid <= 1'b0;
            frame_cnt   <= 16'd0;
            for (k = 0; k < NCH; k = k + 1) begin
                on_code[k] <= 16'sd0;
                diff_r[k]  <= 18'sd0;
                d1[k]      <= 18'sd0;
                d2[k]      <= 18'sd0;
                d3[k]      <= 18'sd0;
                flt[k]     <= 18'sd0;
                ini[k]     <= 1'b0;
            end
        end else begin
            frame_valid <= 1'b0;

            if (done) begin
                if (is_on) begin
                    // ---- 亮值：只存档，等暗值来了再相减 ----
                    on_code[slot_idx] <= vv;
                end else begin
                    // ---- 暗值：算差 + 4 点平均 ----
                    diff_r[slot_idx] <= dv_w;

                    if (!ini[slot_idx]) begin
                        // ★ 第一帧：三个延迟寄存器全填当前值 → flt 立刻等于 dv_w，
                        //   避免「前几帧被 4 除」的虚假小值。
                        d1[slot_idx]  <= dv_w;
                        d2[slot_idx]  <= dv_w;
                        d3[slot_idx]  <= dv_w;
                        flt[slot_idx] <= dv_w;
                        ini[slot_idx] <= 1'b1;
                    end else begin
                        d1[slot_idx]  <= dv_w;
                        d2[slot_idx]  <= d1[slot_idx];
                        d3[slot_idx]  <= d2[slot_idx];
                        flt[slot_idx] <= avg_w;
                    end

                    // ---- 第六路更新完 → 发布一致的六路帧 ----
                    if (slot_idx == NCH[2:0] - 3'd1) begin
                        frame_valid <= 1'b1;
                        frame_cnt   <= frame_cnt + 16'd1;
                    end
                end
            end
        end
    end

    //======================================================================
    //  打包输出
    //======================================================================
    genvar i;
    generate
        for (i = 0; i < NCH; i = i + 1) begin : g_pack
            assign diff_flat[18*i +: 18] = diff_r[i];
            assign flt_flat [18*i +: 18] = flt[i];
        end
    endgenerate

endmodule

`default_nettype wire
