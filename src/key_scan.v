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
//     电平连续保持 DEBOUNCE 个时钟才认；松开用 RELEASE_DEBOUNCE。
//     ★ 消抖是【必须】的：不消抖的话一次按下会被当成几十次触发，
//       复音分配会瞬间把 4 个声部全抢光，听起来像噪声。
//==========================================================================
`default_nettype none

module key_scan #(
    parameter integer N         = 8,         // 按键数
    parameter integer DEBOUNCE  = 400_000,   // 8 ms @50MHz
    // IMMEDIATE=0: qualify both edges independently. This is the performance
    // path; RELEASE_DEBOUNCE may be longer than the press qualification.
    // IMMEDIATE=1 preserves the legacy function-button behavior (delayed
    // press, immediate release + blanking). Do not use it for playing keys.
    parameter integer IMMEDIATE = 1,
    parameter integer RELEASE_DEBOUNCE = DEBOUNCE
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [N-1:0] key_in,      // 低有效（片内上拉）
    output reg  [N-1:0] key_state,   // 1 = 按下（已消抖）
    output reg  [N-1:0] key_press,   // 按下那一拍（一个时钟宽）
    output reg  [N-1:0] key_release  // 松开那一拍
);

    reg [N-1:0] key_d;               // 上一拍的稳定值，用来做边沿

    // Mechanical contacts are asynchronous to clk. Synchronize before any
    // debounce counter or edge detector consumes the pin level.
    reg [N-1:0] key_sync0, key_sync1;
    always @(posedge clk) begin
        if(!rst_n) begin
            key_sync0 <= {N{1'b1}};
            key_sync1 <= {N{1'b1}};
        end else begin
            key_sync0 <= key_in;
            key_sync1 <= key_sync0;
        end
    end

    integer i;
    genvar  g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_key
            localparam integer MAX_DB = (DEBOUNCE > RELEASE_DEBOUNCE) ? DEBOUNCE : RELEASE_DEBOUNCE;
            localparam integer CW = (MAX_DB < 2) ? 1 : $clog2(MAX_DB + 1);
            wire [CW-1:0] qualify = raw ? DEBOUNCE : RELEASE_DEBOUNCE;
            reg [CW-1:0] cnt;
            reg [CW-1:0] blank;

            // ★★ 低有效输入 → 高有效状态。这一行是整个模块最容易写错的地方：
            //    引脚有片内上拉，【松开=高、按下=低】。
            //    如果忘了取反，key_state 就变成"松开的电平"，
            //    于是 key_press 的上升沿出现在【松手】那一刻 ——
            //    现象就是"碰地不响、离开才响"。（这个 bug 踩过）
            wire raw = ~key_sync1[g];     // synchronized, 按下 = 1

            always @(posedge clk) begin
                if (!rst_n) begin
                    cnt          <= {CW{1'b0}};
                    blank        <= {CW{1'b0}};
                    key_state[g] <= 1'b0;
                end
                else if (IMMEDIATE) begin
                    // Legacy function-button mode; retained for compatibility.
                    if (raw != key_state[g]) begin
                        if (raw) begin
                            if (cnt >= DEBOUNCE[CW-1:0]) begin
                                cnt          <= {CW{1'b0}};
                                key_state[g] <= 1'b1;
                            end
                            else
                                cnt <= cnt + 1'b1;
                        end
                        else begin
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
                    // A pulse shorter than its qualification cannot change state.
                    if (raw != key_state[g]) begin
                        if (qualify <= 1 || cnt >= qualify - 1'b1) begin
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
