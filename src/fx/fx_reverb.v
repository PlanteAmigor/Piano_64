//==========================================================================
//  fx_reverb —— Freeverb 结构（8 梳状 + 4 全通），单声道内核 + 左右双抽头
//
//  参考实现（tools/fx_sim.py 的 reverb()）
//  -----------------------------------------------------------------------
//      COMB = [1236,1315,1414,1502,1574,1651,1724,1790]   （48828 Hz 下）
//      AP   = [616,488,378,249]
//      SPREAD = 23        右声道每个延迟多 23 样本
//      FB   = 0.88        梳状反馈（决定尾巴长度）
//      DAMP = 0.40        阻尼
//
//  ★ 与参考的两处有意差异（都是为了省资源，不是笔误）
//  -----------------------------------------------------------------------
//  1) 参考是【左右两套完全独立】的混响（2 倍内存）。这里改成
//     【一套单声道内核 + 左右两个抽头】：左读 延迟 D、右读 延迟 D+23。
//     左右来自同一个混响的不同时间点 → 仍有立体声宽度，内存减半。
//     如果听感上宽度不够，再改回独立两套（+16 块 BSRAM）。
//
//  2) 阻尼取 0.5 而不是参考的 0.40：这样
//         fs <= (rd + fs) >> 1
//     一条移位就够，8 条梳状共省 16 个乘法器。
//     Freeverb 的默认 damp 本来就是 0.5，听感差异很小。
//
//  内存（BSRAM）
//  -----------------------------------------------------------------------
//      cmem : 8 段 × 2048 深 × 16 位 = 16384 → 16 块
//      amem : 左右各 4 段 × 1024 深 × 16 位 = 4096 → 各 4 块，共 8 块
//      合计 24 块
//
//  内存（BSRAM）
    //  -----------------------------------------------------------------------
    //  ★ 打包存放：每段不再按 2048/1024 对齐，而是首尾相接，
    //    缓冲区【长度就等于延迟 D】，读写同地址（read-first，靠两拍分离）。
    //    这样地址就是「段基址 + 段内指针」，不需要取模。
    //
    //      cmem : 8 段共 12206 样本 → 12288 深 × 16 位 = 12 块
    //      amem : 4 段共 1731 样本  → 1792  深 × 16 位 = 2 块（左右各 2）
    //      合计 16 块（对齐写法要 24 块）
    //
    //  时序（每音频样点 1024 个 clk_sys 拍，本模块只用 ~44 拍）
//==========================================================================
`default_nettype none

module fx_reverb #(
    parameter integer FB_Q8  = 225,     // 梳状反馈 0.879
    parameter integer GD_Q8  = 128,     // 干声 0.500
    parameter integer GW_Q8  = 140      // 湿声 0.547（钢琴类需要更明显的混响）
)(
    input  wire               clk,      // clk_sys = 50 MHz
    input  wire               rst_n,
    input  wire               tick,     // 每音频采样一个脉冲
    input  wire               enable,   // 1 = 应用混响；0 = 旁通
    input  wire signed [15:0] in_l,
    input  wire signed [15:0] in_r,
    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r
);

    localparam integer CBUF = 12288;    // 8 段梳状打包（12 块）
    localparam integer ABUF = 1792;     // 4 段全通打包（2 块 / 声道）
    localparam integer SPREAD = 23;     // 右声道多出来的延迟

    //======================================================================
    //  1. 延迟线
    //======================================================================
    reg [15:0] cmem [0:CBUF-1];
    reg [10:0] cptr [0:7];              // 0..D-1 循环
    reg signed [15:0] cfs [0:7];        // 每段阻尼低通的状态

    reg [15:0] amem_l [0:ABUF-1];
    reg [15:0] amem_r [0:ABUF-1];
    reg [9:0]  aptr [0:3];              // 0..D-1 循环

    //======================================================================
    //  2. 段长度表
    //======================================================================
    function [11:0] clen;
        input [2:0] k;
        begin
            case (k)
                3'd0: clen = 12'd1236;
                3'd1: clen = 12'd1315;
                3'd2: clen = 12'd1414;
                3'd3: clen = 12'd1502;
                3'd4: clen = 12'd1574;
                3'd5: clen = 12'd1651;
                3'd6: clen = 12'd1724;
                default: clen = 12'd1790;
            endcase
        end
    endfunction

    function [9:0] alen;
        input [1:0] k;
        begin
            case (k)
                2'd0: alen = 10'd616;
                2'd1: alen = 10'd488;
                2'd2: alen = 10'd378;
                default: alen = 10'd249;
            endcase
        end
    endfunction

    // 段基址 = 前面所有段长度之和（打包存放；每段长度 = D + 1）
    function [13:0] cbase;
        input [2:0] k;
        begin
            case (k)
                3'd0: cbase = 14'd0;
                3'd1: cbase = 14'd1237;
                3'd2: cbase = 14'd2553;
                3'd3: cbase = 14'd3968;
                3'd4: cbase = 14'd5471;
                3'd5: cbase = 14'd7046;
                3'd6: cbase = 14'd8698;
                default: cbase = 14'd10423;
            endcase
        end
    endfunction

    function [10:0] abase;
        input [1:0] k;
        begin
            case (k)
                2'd0: abase = 11'd0;
                2'd1: abase = 11'd617;
                2'd2: abase = 11'd1106;
                default: abase = 11'd1485;
            endcase
        end
    endfunction

    //======================================================================
    //  3. 状态机
    //======================================================================
    localparam [3:0]
        S_WAIT = 4'd0,
        S_LD   = 4'd1,
        S_CRD  = 4'd2,      // 梳状：读左抽头
        S_CRD2 = 4'd3,      // 梳状：读右抽头
        S_CFS  = 4'd4,      // 梳状：阻尼
        S_CMU  = 4'd5,      // 梳状：反馈乘法
        S_CWR  = 4'd6,      // 梳状：写回 + 累加
        S_ARD  = 4'd7,      // 全通：读
        S_AWR  = 4'd8,      // 全通：写回
        S_OUT  = 4'd9;      // 干湿混合 + 输出

    reg [3:0]  st;
    reg [2:0]  k;                       // 梳状段号
    reg [1:0]  a;                       // 全通级号

    reg signed [15:0] xin;              // 单声道输入（已 >>6）
    reg signed [15:0] dry_l, dry_r;     // 原始输入（干声用）

    reg signed [19:0] acc_l, acc_r;     // 8 条梳状的和
    reg signed [15:0] rdl, rdr;         // 读出的左右抽头
    reg signed [15:0] fsn;              // 阻尼后的值
    reg signed [31:0] mul;              // fsn * FB_Q8

    reg signed [19:0] ap_l, ap_r;       // 全通链的当前值（逐级推进）

    // 地址
    //   ★ 阻尼求和的中间变量必须显式 signed：
    //     {rdl[15], rdl} 是拼接，属于 unsigned；一旦表达式里有 unsigned，
    //     整条表达式都按 unsigned 求值，后面的 >>> 会退化成逻辑右移（符号位被清零）。
    wire signed [16:0] fs_sum = $signed({rdl[15], rdl}) + $signed({cfs[k][15], cfs[k]});
    //   base = k*2048 / a*1024 用拼接实现（移位常量，不占逻辑）
    //   段内偏移用 11/10 位无符号减法 → 负数自动按位宽取模，正好是要的回绕
    //   ★ 函数返回值不能直接位选（iverilog 语法），先落到 wire
    wire [11:0] cl_k   = clen(k);
    wire [9:0]  al_a   = alen(a);
    wire [13:0] cb_k   = cbase(k);
    wire [10:0] ab_k   = abase(a);

    // ★★ 环形长度取 L = D + 1，读地址 = ptr+1、写地址 = ptr。
    //    为什么不直接用 L = D（读写同地址）：
    //    那样综合器会推断成「read-before-write」写模式，
    //    而 Gowin DPB 只支持 00/01 两种写模式，直接报
    //        PA2122: Not support WRITE_MODE0 = 2'b10
    //    用 L = D+1 后读写地址必然不同 → 推断成简单双口，合法。
    //    延迟仍是 D（绕一圈 L-1 = D）。
    wire [10:0] cl_lo   = cl_k[10:0];          // D
    wire [10:0] cl_l1   = cl_lo + 11'd1;       // L = D+1
    wire [10:0] p1      = cptr[k] + 11'd1;     // ptr + 1
    wire [10:0] p24     = cptr[k] + 11'd24;    // ptr + 1 + SPREAD
    wire [10:0] r1_off  = (p1  >= cl_l1) ? (p1  - cl_l1) : p1;
    wire [10:0] r2_off  = (p24 >= cl_l1) ? (p24 - cl_l1) : p24;

    wire [13:0] ca_rd_l = cb_k + {3'b000, r1_off};
    wire [13:0] ca_rd_r = cb_k + {3'b000, r2_off};
    wire [13:0] ca_wr   = cb_k + {3'b000, cptr[k]};

    wire [9:0]  al_l1   = al_a + 10'd1;        // L = D+1
    wire [9:0]  a1      = aptr[a] + 10'd1;
    wire [9:0]  a1_off  = (a1 >= al_l1) ? (a1 - al_l1) : a1;
    wire [10:0] aa_rd   = ab_k + {1'b0, a1_off};
    wire [10:0] aa_wr   = ab_k + {1'b0, aptr[a]};

    //======================================================================
    //  4. 主状态机
    //======================================================================
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_WAIT; k <= 3'd0; a <= 2'd0;
            xin <= 16'sd0; dry_l <= 16'sd0; dry_r <= 16'sd0;
            acc_l <= 20'sd0; acc_r <= 20'sd0;
            rdl <= 16'sd0; rdr <= 16'sd0;
            fsn <= 16'sd0; mul <= 32'sd0;
            ap_l <= 20'sd0; ap_r <= 20'sd0;
            out_l <= 16'sd0; out_r <= 16'sd0;
            for (i = 0; i < 8; i = i + 1) begin
                cptr[i] <= 11'd0; cfs[i] <= 16'sd0;
            end
            for (i = 0; i < 4; i = i + 1) aptr[i] <= 10'd0;
        end
        else begin
            case (st)
            // ── 等一个样点 ──────────────────────────────────────────
            S_WAIT: begin
                if (tick) begin
                    dry_l <= in_l;
                    dry_r <= in_r;
                    // 单声道化 + 输入衰减 1/128（≈ Freeverb 的 fixedgain 0.015）
                    // 8 条梳状并联的稳态增益约 1/(1-0.88)≈8.3，
                    // 不先衰减必然溢出 16 位。
                    // ★ 必须先把两个输入扩到 17 位再相加：
                    //   32767+32767 在 16 位里会溢出成 -2。
                    xin   <= ($signed({in_l[15], in_l}) + $signed({in_r[15], in_r})) >>> 7;
                    acc_l <= 20'sd0;
                    acc_r <= 20'sd0;
                    k     <= 3'd0;
                    st    <= S_LD;
                end
            end
            S_LD: st <= S_CRD;

            // ── 梳状：读左抽头 ───────────────────────────────────────
            //  ★ 左右分两拍读：BSRAM 只有一个读口，同拍读两个不同地址
            //    会被综合器把整块存储复制成双份 —— 实测 BSRAM 从 16 块
            //    涨到 32 块（全设计 96%）。分两拍后回到 16 块。
            S_CRD: begin
                rdl <= $signed(cmem[ca_rd_l]);
                st  <= S_CRD2;
            end
            S_CRD2: begin
                rdr <= $signed(cmem[ca_rd_r]);
                st  <= S_CFS;
            end
            // ── 梳状：一阶低通（damp=0.5 → 一条移位）────────────────
            S_CFS: begin
                fsn     <= fs_sum >>> 1;
                cfs[k]  <= fs_sum >>> 1;
                st      <= S_CMU;
            end
            // ── 梳状：反馈乘法 ───────────────────────────────────────
            S_CMU: begin
                mul <= fsn * FB_Q8;
                st  <= S_CWR;
            end
            // ── 梳状：写回 + 累加到湿声和 ────────────────────────────
            S_CWR: begin
                cmem[ca_wr] <= xin + mul[23:8];
                cptr[k]     <= (cptr[k] == cl_lo) ? 11'd0 : (cptr[k] + 11'd1);
                acc_l       <= acc_l + rdl;
                acc_r       <= acc_r + rdr;
                if (k == 3'd7) begin
                    // 8 条跑完 → 进全通
                    ap_l <= acc_l + rdl;
                    ap_r <= acc_r + rdr;
                    a    <= 2'd0;
                    st   <= S_ARD;
                end
                else begin
                    k  <= k + 3'd1;
                    st <= S_CRD;
                end
            end

            // ── 全通：读 ─────────────────────────────────────────────
            S_ARD: begin
                rdl <= $signed(amem_l[aa_rd]);
                rdr <= $signed(amem_r[aa_rd]);
                st  <= S_AWR;
            end
            // ── 全通：写回 + 输出级 ──────────────────────────────────
            //   输出 = rd - (in >> 1)
            //   写回 = in + (rd >> 1)
            S_AWR: begin
                // ★ $signed(...) 不能省：ap_l[15:0] 是位选（unsigned），
                //   否则 (rdl >>> 1) 会变成逻辑右移，负值的符号位被清掉。
                amem_l[aa_wr] <= $signed(ap_l[15:0]) + (rdl >>> 1);
                amem_r[aa_wr] <= $signed(ap_r[15:0]) + (rdr >>> 1);
                aptr[a] <= (aptr[a] == al_a) ? 10'd0 : (aptr[a] + 10'd1);

                ap_l <= $signed(rdl) - (ap_l >>> 1);
                ap_r <= $signed(rdr) - (ap_r >>> 1);
                a    <= a + 2'd1;
                if (a == 2'd3) st <= S_OUT;
                else           st <= S_ARD;
            end

            // ── 输出：干湿混合 ───────────────────────────────────────
            S_OUT: begin
                if (enable) begin
                    out_l <= clamp16(($signed(dry_l) * GD_Q8 + $signed(ap_l[15:0]) * GW_Q8) >>> 8);
                    out_r <= clamp16(($signed(dry_r) * GD_Q8 + $signed(ap_r[15:0]) * GW_Q8) >>> 8);
                end
                else begin
                    out_l <= dry_l;
                    out_r <= dry_r;
                end
                st <= S_WAIT;
            end

            default: st <= S_WAIT;
            endcase
        end
    end

    function signed [15:0] clamp16;
        input signed [31:0] v;
        begin
            if      (v >  32'sd32767) clamp16 = 16'sd32767;
            else if (v < -32'sd32768) clamp16 = -16'sd32768;
            else                      clamp16 = v[15:0];
        end
    endfunction

endmodule
