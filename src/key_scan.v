//==========================================================================
//  key_scan —— 8 个直连按键的扫描 + 消抖
//
//  ⚠️ 本模块【只管一件事】：把 8 根线的电平变成 8 个稳定的"按下/松开"状态。
//     不含音高、不含发声 —— 那些属于 poly_engine。
//
//  ── 接线（PMOD1 / J8）──────────────────────────────────────────
//     每个按键：一端接 J8 的 IO 脚，另一端接 GND（J8 脚 3 或 4）
//     脚内上拉（PULL_MODE=UP），所以：
//         松开 = 高电平(1)      按下 = 低电平(0)
//
//     ★ 用杜邦线碰一下 GND 就能当按键试，不需要任何元件。
//
//     J8（PMOD1）8 个 IO 的引脚：
//       KEY[0]=IO0=Y21   KEY[1]=IO1=Y22   KEY[2]=IO2=AB21  KEY[3]=IO3=AB22
//       KEY[4]=IO4=AA20  KEY[5]=IO5=AA21  KEY[6]=IO6=AA19  KEY[7]=IO7=AB20
//     用哪几个 IO 由 src/pcm5102a.cst 决定，本模块不关心。
//
//  ── 消抖 ───────────────────────────────────────────────────────
//     机械按键按下/松开时触点会抖 1~10 ms。做法：每个键一个计数器，
//     电平连续保持 DEBOUNCE 个时钟才认。DEBOUNCE=30000 @50MHz = 0.6 ms。
//     ★ 消抖是【必须】的：不消抖的话一次按下会被当成几十次触发，
//       复音分配会瞬间把 4 个声部全抢光，听起来像噪声。
//==========================================================================
`default_nettype none

module key_scan #(
    parameter integer N         = 8,         // 按键数
    parameter integer DEBOUNCE  = 400_000,   // 8 ms @50MHz
    // ★★ IMMEDIATE 决定【演奏延迟】。实测（tools/tb_latency.v）：
    //      IMMEDIATE=0（等电平稳定 8ms 才认）→ 控制信号到 I2S 输出 8069 µs
    //                                            ❌ 赛题扩展 #13（≤5ms）不过
    //      IMMEDIATE=1（边沿立即认 + 消隐窗只挡抖动）→ 82 µs ✅ 10 倍余量
    //    机理：按键抖动的第一跳【一定】是真的按下，抖动发生在它【之后】，
    //    所以立刻认第一条边沿不会误触发，只要之后 8ms 的边沿不理它就行。
    //    代价：比消隐窗（8ms）还短的"极短点击"会被当成一次按下-松开（正确行为）。
    parameter integer IMMEDIATE = 1
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [N-1:0] key_in,      // 低有效（片内上拉）
    output reg  [N-1:0] key_state,   // 1 = 按下（已消抖）
    output reg  [N-1:0] key_press,   // 按下那一拍（一个时钟宽）
    output reg  [N-1:0] key_release  // 松开那一拍
);

    reg [N-1:0] key_d;               // 上一拍的稳定值，用来做边沿

    integer i;
    genvar  g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_key
            localparam integer CW = $clog2(DEBOUNCE + 1);
            reg [CW-1:0] cnt;
            reg [CW-1:0] blank;

            // ★★ 低有效输入 → 高有效状态。这一行是整个模块最容易写错的地方：
            //    引脚有片内上拉，【松开=高、按下=低】。
            //    如果忘了取反，key_state 就变成"松开的电平"，
            //    于是 key_press 的上升沿出现在【松手】那一刻 ——
            //    现象就是"碰地不响、离开才响"。（这个 bug 踩过）
            wire raw = ~key_in[g];        // 按下 = 1

            always @(posedge clk) begin
                if (!rst_n) begin
                    cnt          <= {CW{1'b0}};
                    blank        <= {CW{1'b0}};
                    key_state[g] <= 1'b0;
                end
                else if (IMMEDIATE) begin
                    // ── ★ 非对称消抖（低延迟 + 防抬起抖动）──────────────
                    //    按下（raw 0→1）：【立即】生效，0 延迟（演奏手感）
                    //    抬起（raw 1→0）：必须稳定 DEBOUNCE 拍才认
                    //
                    //    为什么抬起要延时：微动开关【抬起】时的触点抖动比按下
                    //    更脏，实测会连出好几个 0/1 跳变。原来的做法是"边沿立即
                    //    生效 + 之后 DEBOUNCE 拍消隐"，如果抖动跨过消隐窗末尾
                    //    就会漏过去 → 多次 note-off/note-on → 爆音。
                    //    抬起慢 20 ms 完全无感（余音本来就在衰减），但抖动
                    //    被彻底挡掉。
                    if (raw != key_state[g]) begin
                        if (raw) begin
                            // ── 抬起：稳定 DEBOUNCE 拍才认 ─────────────
                            if (cnt >= DEBOUNCE[CW-1:0]) begin
                                cnt          <= {CW{1'b0}};
                                key_state[g] <= 1'b1;
                            end
                            else
                                cnt <= cnt + 1'b1;
                        end
                        else begin
                            // ── 按下：立即认，但【消隐窗内不重复触发】──
                            //  ★★ 消隐窗是治"猛按爆音"的关键：
                            //     猛按时机械冲击会抖出一长串跳变，如果每个
                            //     下降沿都当真按下，key_state 就会反复 1/0，
                            //     note_alloc 的 handled 被反复清零 → 同一个键
                            //     被分配到好几个声部、每个都从满幅重新起音
                            //     → 幅度叠加 → 爆音。
                            cnt <= {CW{1'b0}};    // 抖动回落，清抬起计时
                            if (blank == {CW{1'b0}}) begin
                                key_state[g] <= 1'b0;
                                blank        <= DEBOUNCE[CW-1:0];
                            end
                        end
                    end
                    else begin
                        cnt <= {CW{1'b0}};        // 电平稳定，计数归零
                        if (blank != {CW{1'b0}})
                            blank <= blank - 1'b1;
                    end
                end
                else begin
                    // ── 等电平稳定够久才认（老行为，延迟 8ms）──────────
                    if (raw != key_state[g]) begin
                        if (cnt >= DEBOUNCE[CW-1:0]) begin
                            cnt          <= {CW{1'b0}};
                            key_state[g] <= raw;
                        end
                        else
                            cnt <= cnt + 1'b1;
                    end
                    else
                        cnt <= {CW{1'b0}};
                end
            end
        end
    endgenerate

    // 边沿检测
    always @(posedge clk) begin
        if (!rst_n) begin
            key_d       <= {N{1'b0}};
            key_press   <= {N{1'b0}};
            key_release <= {N{1'b0}};
        end
        else begin
            key_d       <= key_state;
            key_press   <=  key_state & ~key_d;
            key_release <= ~key_state &  key_d;
        end
    end

endmodule

`default_nettype wire
