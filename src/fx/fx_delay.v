//==========================================================================
//  fx_delay —— 立体声乒乓延迟（DELAY），算法与 tools/fx_sim.py 的 delay() 一致
//
//  参考实现（tools/fx_sim.py）
//  -----------------------------------------------------------------------
//      dl = 375ms*fs/1000 , dr = 250ms*fs/1000
//      for i:
//          jl = i % dl ; jr = i % dr
//          yl = bl[jl] ; yr = br[jr]          # 先读
//          bl[jl] = x[i] + FB*yr              # 后写（同地址）
//          br[jr] = x[i] + FB*yl              # 交叉反馈 → 乒乓
//          ol[i] = yl ; orr[i] = yr           # 纯湿声
//
//  这其实是「读写同一地址的反馈梳状滤波器 + 交叉反馈」。结构上和
//  ref/hdl-guitar-fpga/VHDL/.../delay.vhd 的注释一致（它也提示必须
//  先读后写、且抬高 we_n 之后再改地址）。
//
//  ★ 为什么这里不需要插值、不需要 LFO
//  -----------------------------------------------------------------------
//  延迟量是常数，所以没有分数延迟、也没有调制带来的移调。
//  唯一要保证的是「先读旧值、再写新值」—— 本项目用 BSRAM 的
//  read-first 语义天然满足（读在 st2 取到数据，写在 st3 才发生，
//  中间隔一拍，地址保持不变）。
//
//  内存（BSRAM）
//  -----------------------------------------------------------------------
//  Gowin 每块 BSRAM = 18 kbit，且存储深度由模式决定。
//  一条 16384 深 × 16 位 = 262144 bit = 16 块（用 16384×1 模式拼位宽）。
//  左 16384 深、右同样 16384 深（计数器在 12207 处回绕），共 32 块。
//
//  参数（fs = 48828.125 Hz）
//  -----------------------------------------------------------------------
//      AL = log2(左缓冲深度)，AR 同理
//      DLEN_L / DLEN_R：实际延迟样本数（必须 <= 2^AL / 2^AR）
//      FB_Q8：反馈系数，0.38 → 97（Q8）
//
//==========================================================================
`default_nettype none

module fx_delay #(
    parameter integer AL     = 14,          // 左缓冲深度 = 2^14 = 16384 → 335.5 ms
    parameter integer AR     = 14,          // 右缓冲深度 = 2^14 = 16384
    parameter integer DLEN_L = 16384,       // 左实际延迟样本（335.5 ms）
    parameter integer DLEN_R = 12207,       // 右实际延迟样本（250.0 ms）
    parameter integer FB_Q8  = 97,          // 反馈 0.379
    parameter integer GD_Q8  = 128,         // 干声 0.500
    parameter integer GW_Q8  = 141          // 湿声 0.551（湿/干 = 1.10，与参考一致）
)(
    input  wire               clk,          // clk_sys = 50 MHz
    input  wire               rst_n,
    input  wire               tick,         // 每音频采样一个脉冲
    input  wire               enable,       // 1 = 应用延迟；0 = 旁通
    input  wire signed [15:0] in_l,
    input  wire signed [15:0] in_r,
    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r
);

    //======================================================================
    //  1. 环形缓冲（各 16 块 BSRAM）
    //======================================================================
    reg [15:0] mem_l [0:(1<<AL)-1];
    reg [15:0] mem_r [0:(1<<AR)-1];

    reg [AL-1:0] cnt_l;                     // 左写/读指针（自然回绕到 2^AL）
    reg [AR-1:0] cnt_r;                     // 右指针（在 DLEN_R-1 处手动回绕）

    reg          we;
    reg [AL-1:0] wa_l;
    reg [AR-1:0] wa_r;
    reg [15:0]   wd_l, wd_r;

    reg [15:0]   rd_l, rd_r;

    //  读在 st1 施地址、st2 收数据；写在 st3 发生 → 天然「先读后写」
    always @(posedge clk) begin
        if (we) begin
            mem_l[wa_l] <= wd_l;
            mem_r[wa_r] <= wd_r;
        end
        rd_l <= mem_l[cnt_l];
        rd_r <= mem_r[cnt_r];
    end

    //======================================================================
    //  2. 每采样 5 拍的时序机（一个采样有 1024 拍）
    //       st0 等 tick
    //       st1 锁存干声；读地址 = 当前指针
    //       st2 取到旧值 yl / yr
    //       st3 写回 in + FB*yr（左） / in + FB*yl（右）；指针前进
    //       st4 干湿混合 + 钳位 → 输出
    //======================================================================
    reg [2:0] st;

    reg signed [15:0]  dry_l, dry_r;
    reg signed [17:0]  y_l, y_r;            // 读出的旧值（18 位便于参与运算）
    reg signed [31:0]  wl, wr;              // 写回值

    //  写回值：in + FB*y   （|y|<=32767，FB=0.379 → |FB*y| <= 12419，32 位足够）
    wire signed [31:0] fb_l = (y_r * FB_Q8) >>> 8;   // 左写入用的是【右】的旧值
    wire signed [31:0] fb_r = (y_l * FB_Q8) >>> 8;

    //  干湿混合
    wire signed [31:0] mx_l = ($signed(dry_l) * GD_Q8 + y_l * GW_Q8) >>> 8;
    wire signed [31:0] mx_r = ($signed(dry_r) * GD_Q8 + y_r * GW_Q8) >>> 8;

    //  硬钳位（无乘法）
    function signed [15:0] clamp16;
        input signed [31:0] x;
        begin
            if (x > 32'sd32767)       clamp16 = 16'sd32767;
            else if (x < -32'sd32768) clamp16 = -16'sd32768;
            else                      clamp16 = x[15:0];
        end
    endfunction

    //  右指针回绕：到 DLEN_R-1 就回 0
    wire r_wrap = (cnt_r == DLEN_R[AR-1:0] - 1'b1);

    always @(posedge clk) begin
        if (!rst_n) begin
            st    <= 3'd0;
            cnt_l <= {AL{1'b0}};
            cnt_r <= {AR{1'b0}};
            we    <= 1'b0;
            wa_l  <= {AL{1'b0}};
            wa_r  <= {AR{1'b0}};
            wd_l  <= 16'd0;
            wd_r  <= 16'd0;
            dry_l <= 16'sd0;  dry_r <= 16'sd0;
            y_l   <= 18'sd0;  y_r   <= 18'sd0;
            wl    <= 32'sd0;  wr    <= 32'sd0;
            out_l <= 16'sd0;  out_r <= 16'sd0;
        end
        else begin
            case (st)
                //──────────────────────────────────────────────
                3'd0: if (tick) st <= 3'd1;

                //──────────────────────────────────────────────
                3'd1: begin
                    //  锁存干声；读地址 = 当前指针（组合送到 BSRAM）
                    dry_l <= in_l;
                    dry_r <= in_r;
                    we    <= 1'b0;
                    st    <= 3'd2;
                end

                //──────────────────────────────────────────────
                3'd2: begin
                    //  rd_l / rd_r 此刻是 mem[cnt] 的【旧值】
                    y_l <= $signed(rd_l);
                    y_r <= $signed(rd_r);
                    st  <= 3'd3;
                end

                //──────────────────────────────────────────────
                3'd3: begin
                    //  写回：in + FB*（对侧旧值），地址仍是本拍的 cnt
                    we   <= 1'b1;
                    wa_l <= cnt_l;
                    wa_r <= cnt_r;
                    wd_l <= clamp16($signed(dry_l) + fb_l);
                    wd_r <= clamp16($signed(dry_r) + fb_r);
                    //  指针前进
                    cnt_l <= cnt_l + 1'b1;
                    if (r_wrap) cnt_r <= {AR{1'b0}};
                    else        cnt_r <= cnt_r + 1'b1;
                    st    <= 3'd4;
                end

                //──────────────────────────────────────────────
                3'd4: begin
                    we    <= 1'b0;
                    out_l <= enable ? clamp16(mx_l) : dry_l;
                    out_r <= enable ? clamp16(mx_r) : dry_r;
                    st    <= 3'd0;
                end

                default: st <= 3'd0;
            endcase
        end
    end

endmodule

`default_nettype wire
