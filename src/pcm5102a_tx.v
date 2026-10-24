//==========================================================================
//  pcm5102a_tx —— PCM5102A 立体声 DAC 的 I2S 发送器
//
//  ⚠️ 本模块【只管一件事】：把 16bit 样点串成 I2S 波形。
//     不含音序器、不含波表、不含包络 —— 那些属于 music_engine。
//     换 DAC 只换这一个文件 + .cst，音乐引擎一行都不用动。
//     （对应 i2s_piano / i2s_twinkle 里的 pt8211_tx.v）
//
//  ── 时序（PCM5102A 标准 Philips I2S）────────────────────────────
//    · LRCK 【低 = 左声道】，高 = 右声道
//    · MSB 比 LRCK 跳变沿晚 1 个 BCK（slot 0 是延迟位，恒 0）
//    · 发送端在 BCK 【下降沿】更新 DIN / LRCK，DAC 在 BCK 上升沿采样
//    · 每帧 64 个 BCK = 2 声道 × 32bit 槽位
//      slot 0 = 延迟位, slot 1..16 = 16bit 数据, slot 17..31 = 补零
//
//  ★★ 和板载 PT8211 正好相反 ★★
//     PT8211:   WS 高 = 左，低 = 右
//     PCM5102A: LRCK 低 = 左，高 = 右
//     所以 pt8211_tx.v 和本模块【不能互换】，写反了就是左右声道对调。
//
//  ── 参数 ───────────────────────────────────────────────────────
//    DIV   = 每个 BCK 周期的主时钟数   → BCK = clk / DIV
//    SLOTS = 每帧 BCK 数               → fs  = clk / DIV / SLOTS
//    本工程 DIV=16, SLOTS=64 @50MHz
//      → BCK = 3.125 MHz，fs = 48828.125 Hz
//      → DIN 建立窗口 = 半个 BCK = 8 个主时钟 = 160 ns
//
//  ⚠️ 槽位必须【每个 BCK 周期】加一，不是每个半周期 ——
//     一开始我把 slot 自增写进了 BCK 翻转那个分支里，等于每半周期加一次，
//     帧长减半、采样率翻倍。tools/sim_pcm5102a.py 的 [6] 会测出这个。
//==========================================================================
`default_nettype none

module pcm5102a_tx #(
    parameter DIV   = 16,       // 必须为偶数
    parameter SLOTS = 64        // 32bit × 2ch
)(
    input  wire               clk,           // 唯一时钟域
    input  wire               rst_n,
    input  wire signed [15:0] sample_l,      // 左声道样点
    input  wire signed [15:0] sample_r,      // 右声道样点

    output reg                sample_tick,   // 每帧一个脉冲（= 采样率节拍）
    output reg                bck,
    output reg                lrck,
    output reg                din
);

    localparam integer HALF = DIV / 2;       // BCK 半周期

    reg [15:0] div_cnt;
    reg [5:0]  slot;

    //------------------------------------------------------------------
    //  BCK 分频：每 HALF 个主时钟翻转一次，占空比 50%，输出寄存无毛刺
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            div_cnt <= 16'd0;
            bck     <= 1'b0;
        end
        else if (div_cnt == HALF - 1) begin
            div_cnt <= 16'd0;
            bck     <= ~bck;
        end
        else
            div_cnt <= div_cnt + 16'd1;
    end

    // 本拍 BCK 将由 1 -> 0（数据就在这一拍更新）
    wire bck_fall = (div_cnt == HALF - 1) & bck;

    //------------------------------------------------------------------
    //  槽位 0..SLOTS-1：★ 只在 BCK 下降沿加一（即每个 BCK 周期一次）
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n)
            slot <= 6'd0;
        else if (bck_fall)
            slot <= (slot == SLOTS - 1) ? 6'd0 : slot + 6'd1;
    end

    // 要装载的是【即将开始】的那个槽位的数据
    wire [5:0] slot_nxt = (slot == SLOTS - 1) ? 6'd0 : slot + 6'd1;
    wire       is_left  = ~slot_nxt[5];                  // slot 0..31 = 左
    wire [4:0] npos     = slot_nxt[4:0];                 // 声道内位置 0..31

    wire signed [15:0] src = is_left ? sample_l : sample_r;

    // slot 0 = 延迟位(0)，slot 1..16 = sample[15]..sample[0]，其余补零
    wire dbit = (npos == 5'd0)  ? 1'b0 :
                (npos <= 5'd16) ? src[5'd16 - npos] : 1'b0;

    wire frame_start = bck_fall & (slot == SLOTS - 1);   // 下一拍进入 slot 0（左）
    wire right_start = bck_fall & (slot == 5'd31);       // 下一拍进入 slot 32（右）

    //------------------------------------------------------------------
    //  DIN / LRCK / sample_tick 都在 BCK 下降沿更新
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            din         <= 1'b0;
            lrck        <= 1'b0;
            sample_tick <= 1'b0;
        end
        else begin
            sample_tick <= 1'b0;                          // 默认拉低，只在帧首脉冲
            if (bck_fall) begin
                din <= dbit;
                if (right_start)
                    lrck <= 1'b1;                         // 高 = 右
                else if (frame_start) begin
                    lrck        <= 1'b0;                  // 低 = 左
                    sample_tick <= 1'b1;                  // 通知引擎：取下一个样点
                end
            end
        end
    end

endmodule

`default_nettype wire
