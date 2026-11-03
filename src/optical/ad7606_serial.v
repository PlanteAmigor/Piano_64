//==========================================================================
//  ad7606_serial —— AD7606 双串行(DB7 + DB8)读取控制器
//
//  目标板：Tang Mega 138K（GW5AST-LV138PG484AC1/I0），clk = 50 MHz
//  接线（F407 那一套，SDRAM1_* 球号）：
//      CONVST → R14    CS → U17    SCLK(RD) → R16   RESET → P15
//      BUSY   ← U18    DOUTA/DB7 ← P14   DOUTB/DB8 ← Y19
//      模块侧：OS0/1/2、RANGE 接地（±5V 量程）；REF_SELECT 不接
//
//  ── 一次转换的时序（AD7606 数据手册 Table 3 / 串口时序）──────────────
//    ① CONVST 正脉冲（≥25 ns）：【上升沿】冻结 8 路采样
//    ② BUSY 上跳（t1 ≤ 40 ns），保持高 tCONV（无过采样 3.45–4.15 µs）
//    ③ BUSY 下降 → CS 拉低（t4 ≥ 0）
//    ④ 64 拍 SCLK：DOUTA 移出 V1..V4，DOUTB 移出 V5..V8（各 4×16 bit）
//         · CS 下降沿本身就把 V1 / V5 的 MSB 推到两根 DOUT 上（t18 ≤ 20 ns）
//         · 之后的位在 SCLK【上升沿】被芯片推出
//         · 所以第 k 位在「第 k 个 SCLK 下降沿」一定已经稳定 →
//           本设计就在下降沿末尾采样（离上一次上升沿整整半个周期，余量最大）
//    ⑤ CS 拉高，锁存 8 通道，done 打一拍
//
//  ⚠️ SCLK 空闲电平 = 【高】。AD7606 串口时序里 V1 的 MSB 是 CS 下降沿推出来的，
//     第一个 SCLK 下降沿就是拿来采它的。若 SCLK 空闲为低，第一个下降沿之前
//     没有上升沿，位序会整体错一位（0x06 → 0x0C 那种特征错误）。
//
//  ── 为什么 start 做成外部脉冲 ────────────────────────────────────────
//    F407 那套是「每个 2 ms 时隙里在 0.4 ms 采亮值、1.7 ms 采暗值」，
//    采样时刻由 ir_tdm_ctrl 决定。本模块只负责「你叫我转我就转」，
//    这样两个模块都能单独仿真，也方便以后换采样节奏。
//
//  ── 报错 ────────────────────────────────────────────────────────────
//    hw_err = 1 : CONVST 之后 BUSY 一直不上跳（等 50 µs 超时）
//                 → CONVST/RST 线没接、模块没 5 V、芯片没在跑
//    hw_err = 2 : BUSY 高电平超过 2 ms 不降，或进 IDLE 时 BUSY 还是高
//                 → OS0/1/2 悬空（过采样 ×64 → tCONV 315 µs）、供电不足
//    hw_err = 3 : 上一次还没读完就又来 start（采样节奏排错了）
//    hw_err 只要有一帧完整读成功就被清 0（不锁死）。
//==========================================================================
`default_nettype none

module ad7606_serial #(
    parameter integer SCLK_HALF  = 4,        // SCLK 半周期 = 几个 clk
                                             //   4 → 160 ns 周期 = 6.25 MHz
                                             //   （VDRIVE=3.3V 上限 17 MHz）
    parameter integer CONVST_CYC = 12,       // CONVST 高电平宽度 240 ns
    parameter integer CS_SETUP   = 8,        // CS 下降 → 第一个 SCLK 下降
    parameter integer TMO_HI     = 2_500,    // 等 BUSY 上升超时 50 µs
    parameter integer TMO_LO     = 100_000,  // BUSY 允许的最大高电平 2 ms
    parameter integer RESET_CYC  = 50_000,   // 上电 RESET 高电平 1 ms
    parameter integer RST_RETRY  = 5_000,    // 自动重试 RESET 宽度 100 µs
    parameter integer FAIL_LIMIT = 16        // 连续多少次 BUSY 不上跳就重发 RESET
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- 控制 ----
    input  wire         start,        // 单拍脉冲：发起一次转换（IDLE 时有效）
    output reg  [127:0] ch_flat,      // ch_flat[16*i +: 16] = Vi+1（16 位二补码）
    output reg          done,         // 单拍脉冲：一帧读完
    output reg          ready,        // 1 = 可以接受 start
    output reg  [2:0]   hw_err,

    // ---- AD7606 引脚 ----
    output reg          adc_convst,   // → CONVST（A/B 短接）
    output reg          adc_reset,    // → RESET
    output reg          adc_cs_n,     // → CS
    output reg          adc_sclk,     // → RD/SCLK（空闲高）
    input  wire         adc_busy,     // ← BUSY
    input  wire         adc_douta,    // ← DB7 / DOUTA（V1..V4）
    input  wire         adc_doutb     // ← DB8 / DOUTB（V5..V8）
);

    //======================================================================
    // 1) 输入同步（BUSY / DOUT 都是芯片侧的异步信号）
    //======================================================================
    reg [1:0] busy_sr, douta_sr, doutb_sr;
    always @(posedge clk) begin
        if (!rst_n) begin
            busy_sr  <= 2'b00;
            douta_sr <= 2'b00;
            doutb_sr <= 2'b00;
        end else begin
            busy_sr  <= {busy_sr[0],  adc_busy};
            douta_sr <= {douta_sr[0], adc_douta};
            doutb_sr <= {doutb_sr[0], adc_doutb};
        end
    end
    wire busy_s  = busy_sr[1];
    wire douta_s = douta_sr[1];
    wire doutb_s = doutb_sr[1];

    //======================================================================
    // 2) 主状态机
    //======================================================================
    localparam S_RST   = 4'd0,   // 上电复位脉冲
               S_IDLE  = 4'd1,
               S_CONV  = 4'd2,   // CONVST 正脉冲
               S_BH    = 4'd3,   // 等 BUSY 上升
               S_BL    = 4'd4,   // 等 BUSY 下降
               S_CS    = 4'd5,   // CS 拉低 + 建立时间
               S_READ  = 4'd6,   // 64 拍 SCLK（两根线并行，共 8 通道）
               S_DONE  = 4'd7,
               S_STUCK = 4'd8;   // BUSY 卡高

    reg [3:0]  st;
    reg [23:0] cnt;
    reg [7:0]  bitn;         // 0..63
    reg [15:0] sh_a, sh_b;   // 当前通道的移位寄存器（两线各一份）
    reg [63:0] acc_a;        // V1..V4
    reg [63:0] acc_b;        // V5..V8
    reg [1:0]  chi;          // 当前通道对 0..3（→ V(chi+1) / V(chi+5)）
    reg [7:0]  fail_run;     // 连续多少次 BUSY 不上跳
    reg        retry_rst;    // 本次复位是自动重试（宽度更短）
    reg        ha;           // SCLK 相位：0=低电平段 1=高电平段
    reg [7:0]  hcnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            st         <= S_RST;
            cnt        <= 24'd0;
            bitn       <= 8'd0;
            sh_a       <= 16'd0;
            sh_b       <= 16'd0;
            acc_a      <= 64'd0;
            acc_b      <= 64'd0;
            chi        <= 2'd0;
            ha         <= 1'b0;
            hcnt       <= 8'd0;
            adc_convst <= 1'b0;
            adc_reset  <= 1'b1;
            adc_cs_n   <= 1'b1;
            adc_sclk   <= 1'b1;     // ★ 空闲为高
            ch_flat    <= 128'd0;
            done       <= 1'b0;
            ready      <= 1'b0;
            hw_err     <= 3'd0;
            fail_run   <= 8'd0;
            retry_rst  <= 1'b0;
        end else begin
            done <= 1'b0;

            case (st)
            //---------------- 复位脉冲（上电 1 ms / 自动重试 100 µs）------
            S_RST: begin
                ready     <= 1'b0;
                adc_reset <= 1'b1;
                adc_cs_n  <= 1'b1;
                adc_sclk  <= 1'b1;
                adc_convst<= 1'b0;
                if (cnt == (retry_rst ? RST_RETRY : RESET_CYC) - 1) begin
                    cnt       <= 24'd0;
                    adc_reset <= 1'b0;   // 之后一直低（t7 ≥ 25 ns 由 IDLE 保证）
                    retry_rst <= 1'b0;
                    st        <= S_IDLE;
                end else cnt <= cnt + 24'd1;
            end

            //---------------- 空闲：CONVST 低，SCLK 高 --------------------
            S_IDLE: begin
                ready      <= 1'b1;
                adc_convst <= 1'b0;
                adc_cs_n   <= 1'b1;
                adc_sclk   <= 1'b1;
                cnt        <= 24'd0;
                if (busy_s) begin
                    // BUSY 还没降下来：上一次转换没结束 / 卡死
                    ready <= 1'b0;
                    st    <= S_STUCK;
                end else if (start) begin
                    ready      <= 1'b0;
                    adc_convst <= 1'b1;      // ★ 上升沿 = 采样时刻
                    st         <= S_CONV;
                end
            end

            //---------------- CONVST 正脉冲 -------------------------------
            S_CONV: begin
                if (cnt == CONVST_CYC - 1) begin
                    cnt        <= 24'd0;
                    adc_convst <= 1'b0;
                    st         <= S_BH;
                end else cnt <= cnt + 24'd1;
            end

            //---------------- 等 BUSY 上升 --------------------------------
            S_BH: begin
                if (busy_s) begin
                    cnt <= 24'd0;
                    st  <= S_BL;
                end else if (cnt == TMO_HI - 1) begin
                    hw_err <= 3'd1;              // ⚠️ BUSY 不上跳
                    cnt    <= 24'd0;
                    // 连续 FAIL_LIMIT 次都没反应 → 重发一次 RESET。
                    // 场景：模块 5 V 比 FPGA 配置完成得晚，芯片错过了上电复位；
                    //       或者芯片被之前的状态卡住。
                    if (fail_run + 8'd1 >= FAIL_LIMIT) begin
                        fail_run  <= 8'd0;
                        retry_rst <= 1'b1;
                        st        <= S_RST;
                    end else begin
                        fail_run <= fail_run + 8'd1;
                        st       <= S_IDLE;
                    end
                end else cnt <= cnt + 24'd1;
            end

            //---------------- 等 BUSY 下降（tCONV）------------------------
            S_BL: begin
                if (!busy_s) begin
                    cnt <= 24'd0;
                    st  <= S_CS;
                end else if (cnt == TMO_LO - 1) begin
                    hw_err <= 3'd2;              // ⚠️ BUSY 卡高
                    cnt    <= 24'd0;
                    st     <= S_IDLE;
                end else cnt <= cnt + 24'd1;
            end

            //---------------- CS 拉低 + 建立时间 --------------------------
            S_CS: begin
                adc_cs_n  <= 1'b0;
                adc_sclk  <= 1'b1;               // 空闲高
                if (cnt == CS_SETUP - 1) begin
                    cnt      <= 24'd0;
                    adc_sclk <= 1'b0;            // ★ 第 1 个下降沿 → 采 V1/V5 的 MSB
                    ha       <= 1'b0;
                    hcnt     <= 8'd0;
                    chi      <= 2'd0;
                    bitn     <= 8'd0;
                    sh_a     <= 16'd0;
                    sh_b     <= 16'd0;
                    acc_a    <= 64'd0;
                    acc_b    <= 64'd0;
                    st       <= S_READ;
                end else cnt <= cnt + 24'd1;
            end

            //---------------- 64 拍 SCLK（两线并行）-----------------------
            S_READ: begin
                if (ha == 1'b0) begin
                    // ---- 低电平段：末尾采样 ----
                    if (hcnt == SCLK_HALF - 1) begin
                        hcnt     <= 8'd0;
                        adc_sclk <= 1'b1;                    // 上升沿 → 芯片推出下一位
                        sh_a     <= {sh_a[14:0], douta_s};   // ★ 采样点
                        sh_b     <= {sh_b[14:0], doutb_s};
                        ha       <= 1'b1;
                        if (bitn == 8'd15) begin
                            // 一对通道 16 位收齐：A→V(chi+1)，B→V(chi+5)
                            acc_a[chi*16 +: 16] <= {sh_a[14:0], douta_s};
                            acc_b[chi*16 +: 16] <= {sh_b[14:0], doutb_s};
                            sh_a <= 16'd0;
                            sh_b <= 16'd0;
                            bitn <= 8'd0;
                            if (chi == 2'd3) st <= S_DONE;   // 8 通道全收完
                            else             chi <= chi + 2'd1;
                            // ⚠️ 不要在这里把 adc_sclk 拉低！上面那个上升沿正是
                            //    芯片推出【下一通道 MSB】的时刻，必须让它走完
                            //    整个高电平段，再从下降沿开始采。
                        end else begin
                            bitn <= bitn + 8'd1;
                        end
                    end else hcnt <= hcnt + 8'd1;
                end else begin
                    // ---- 高电平段 ----
                    if (hcnt == SCLK_HALF - 1) begin
                        hcnt     <= 8'd0;
                        ha       <= 1'b0;
                        adc_sclk <= 1'b0;                    // 下降沿 → 下一位可采
                    end else hcnt <= hcnt + 8'd1;
                end
            end

            //---------------- 收尾 ----------------------------------------
            S_DONE: begin
                adc_cs_n <= 1'b1;
                adc_sclk <= 1'b1;
                ch_flat  <= {acc_b, acc_a};      // ch_flat[16*i] = Vi+1
                done     <= 1'b1;
                hw_err   <= 3'd0;                // 读到完整一帧 → 清硬件错误
                fail_run <= 8'd0;
                st       <= S_IDLE;
            end

            //---------------- BUSY 卡高 -----------------------------------
            S_STUCK: begin
                adc_convst <= 1'b0;
                ready      <= 1'b0;
                if (!busy_s) begin
                    cnt <= 24'd0;
                    st  <= S_IDLE;
                end else if (cnt == TMO_LO - 1) begin
                    // 确认卡死 2 ms：报错，并主动发一次 RESET（RESET 会把 BUSY 拉低）
                    hw_err    <= 3'd2;
                    cnt       <= 24'd0;
                    retry_rst <= 1'b1;
                    st        <= S_RST;
                end else cnt <= cnt + 24'd1;
            end

            default: st <= S_IDLE;
            endcase

            // start 冲突：上一次转换还没结束就又来一个（采样节奏排错了）
            if (start && !ready && st != S_RST) hw_err <= 3'd3;
        end
    end

    //======================================================================
    // 3) start 冲突检测：非 IDLE 时来 start 说明采样节奏排错了
    //    ★ 必须并进主 FSM 的同一个 always 块（一个 reg 只能有一个驱动源），
    //      放在 case 之后 → 条件成立时覆盖本拍的 hw_err。
    //======================================================================
    //  （见上方 else 分支末尾的记录）

endmodule

`default_nettype wire
