//==========================================================================
//  suona_dma —— 按音把唢呐表从 DDR 搬进 BSRAM 缓冲
//
//  为什么是「按音」而不是「全表」：
//    唢呐全表 244 KB（108 块 BSRAM），和钢琴/古筝引擎放一起会顶到 83%，
//    布线必然拥塞。而单声部实际只需要【当前这一个音】的表：
//    最大 21 KB（9 块），平均 15 KB。所以 note-on 时临时搬一份就够。
//
//  搬运耗时：约 1.2 万拍 ≈ 120 us @100 MHz（每个元素写口占一拍）。
//    唢呐是吹奏乐器，本身就有起音过程，120 us 完全听不出。
//
//  镜像布局（见 tools/make_ddr_image.py）：
//    SUONA_BASE word 处：
//      word 0  段头 {magic "SUON", n_inst, note_lo, desc_off}
//      word 1  8 个表基址（字节偏移）
//      word 2.. 每音 2 word 描述符（64 B，12 个 u32）
//    描述符字段（u32）：
//      0 K        1 ab_off   2 bc_off   3 pi_off
//      4 env_e_off  5 env_o_off  6 env_len(字节)
//      7 psi_e_off  8 psi_o_off  9 psi_len(字节)
//     10 phi_off   11 phi_len(字节)
//
//  ★ app_addr 单位是 4 字节 → app_addr = 字节偏移 >> 2
//  ★ 段长度一律换算成【元素个数】再计数，避免运行时做变量乘法
//==========================================================================
`default_nettype none

module suona_dma #(
    parameter integer DESC_OFF   = 2        // 描述符表在段内的 word 偏移
)(
    input  wire         clk,        // clk_x1（100 MHz，DDR 用户域）
    input  wire         rst_n,

    // ★ 段基址改成【运行时端口】：唢呐与笛子是镜像里两个独立的小段，
    //   各自有自己的段头+描述符表。上层按音色选一个传进来。
    //   取值 = ((BASE_word + DESC_OFF) << 3) - (note_lo * 16)
    //   （<<3：word=32 字节=8 个 4 字节单位；note_lo*16：把音号归一到段内序号）
    input  wire [28:0]  desc_base,

    input  wire [6:0]   note,       // 要搬的音（MIDI）
    input  wire         start,      // ★ 电平翻转（toggle）：内部边沿检测后启动
                                    //   跨时钟域时用 2FF 同步一个 toggle 最稳
    output reg          busy,
    output reg          done,       // 单拍脉冲：全部搬完

    // ── BSRAM 写口（8 个缓冲）──────────────────────────────────────
    output reg          ab_we,  output reg [5:0]   ab_a,  output reg [31:0] ab_d,
    output reg          bc_we,  output reg [5:0]   bc_a,  output reg [31:0] bc_d,
    output reg          pi_we,  output reg [5:0]   pi_a,  output reg [15:0] pi_d,
    output reg          ee_we,  output reg [12:0]  ee_a,  output reg [7:0]  ee_d,
    output reg          eo_we,  output reg [12:0]  eo_a,  output reg [7:0]  eo_d,
    output reg          pe_we,  output reg [11:0]  pe_a,  output reg [15:0] pe_d,
    output reg          po_we,  output reg [11:0]  po_a,  output reg [15:0] po_d,
    output reg          ph_we,  output reg [9:0]   ph_a,  output reg [31:0] ph_d,

    // ── DDR 读口 ───────────────────────────────────────────────────
    output wire [2:0]   app_cmd,
    output wire         app_en,
    output wire [28:0]  app_addr,
    input  wire         app_rdy,
    input  wire         app_rd_data_valid,
    input  wire [255:0] app_rd_data
);

    // Local reset register removes the DDR calibration fanout from every
    // captured beat bit; transfer requests start only after reset releases.
    reg local_rst_n /* synthesis syn_preserve=1 */ =1'b0;
    always @(posedge clk)local_rst_n<=rst_n;
    assign app_cmd = 3'b001;        // 只读

    // ── 描述符寄存器 ────────────────────────────────────────────────
    reg [31:0] d_k, d_ab, d_bc, d_pi, d_ee, d_eo, d_elen,
               d_pe, d_po, d_plen, d_ph, d_flen;

    // ── 当前搬运段 ──────────────────────────────────────────────────
    //  0=ab 1=bc 2=pi 3=env_e 4=env_o 5=psi_e 6=psi_o 7=phi
    reg [3:0]  seg;
    reg [15:0] wptr;         // 已写元素数
    // ★ 本段【剩余】元素数（= 元素总数 − wptr）。
    //   原来用 `wptr + 16'd1 >= seg_n` 判断段尾：那是 16 位加法器（进位链
    //   从低位一路传上去）再进比较器，输出直接扇出到 beat_cnt / cmd_addr
    //   约 30 个 CE 引脚。100 MHz（10 ns）下实测 DATA DELAY = 10.425 ns，
    //   SETUP slack = -0.891 ns，25 条最差路径全部出自这一根线。
    //   改成倒计数后段尾判断变成 `rem == 1`（15 输入 NOR + AND，两级），
    //   进位链彻底消失。
    reg [15:0] rem;          // 本段剩余元素数
    reg [5:0]  beat_cnt;     // 本 beat 已写元素数
    reg [255:0] beat;

    // ── 段参数（组合）───────────────────────────────────────────────
    reg [31:0] px_off;       // 字节偏移
    reg [15:0] px_n;         // 元素总数
    reg [5:0]  px_per;       // 每个 256 位 beat 的元素数

    always @(*) begin
        case (seg)
            4'd0:    begin px_off = d_ab; px_n = d_k[15:0];        px_per = 6'd8;  end
            4'd1:    begin px_off = d_bc; px_n = d_k[15:0];        px_per = 6'd8;  end
            4'd2:    begin px_off = d_pi; px_n = d_k[15:0];        px_per = 6'd16; end
            4'd3:    begin px_off = d_ee; px_n = d_elen[15:0];     px_per = 6'd32; end
            4'd4:    begin px_off = d_eo; px_n = d_elen[15:0];     px_per = 6'd32; end
            4'd5:    begin px_off = d_pe; px_n = {1'b0, d_plen[15:1]}; px_per = 6'd16; end
            4'd6:    begin px_off = d_po; px_n = {1'b0, d_plen[15:1]}; px_per = 6'd16; end
            default: begin px_off = d_ph; px_n = {2'b00, d_flen[15:2]}; px_per = 6'd8; end
        endcase
    end

    // ── 元素拆包 ────────────────────────────────────────────────────
    reg [31:0] elem32;
    reg [15:0] elem16;
    reg [7:0]  elem8;

    always @(*) begin
        elem32 = beat[31:0]; elem16 = beat[15:0]; elem8 = beat[7:0];
        // Consume the low element then shift. Avoid a beat_cnt driven
        // 16:1/32:1 mux on the 100 MHz memory write-data path.
    end

    // ── 状态机 ──────────────────────────────────────────────────────
    localparam [3:0] S_IDLE = 4'd0,
                     S_DESC = 4'd1,
                     S_DW   = 4'd2,
                     S_SEG  = 4'd3,
                     S_SEG2 = 4'd4,
                     S_CMD  = 4'd5,
                     S_WAIT = 4'd6,
                     S_WR   = 4'd7,
                     S_DONE = 4'd8;

    // ── 当前段的寄存器化参数 ───────────────────────────────────────
    //  ★ 为什么要把它们寄存一级：
    //    px_off / px_n / px_per 是【从 seg 组合查出来的】8 路大 mux，
    //    原来它们直接喂给 cmd_addr 的 CE 和 16 位比较器，形成
    //        seg reg → 8:1 mux → 比较器 → CE
    //    实测 11.58 ns（约束 10 ns），SETUP −1.883 ns，合并 HDMI 后
    //    合成大工程布线更挤，这个路径直接顶爆 100 MHz 域。
    //    现在 S_SEG 只负责「把参数打进寄存器」（D 端不接比较器），
    //    真正做判断的 S_SEG2 全部用寄存器，路径退化成寄存到寄存。
    //    代价：每段多 1 拍，8 段一共多 8 拍（80 ns），完全无感。
    reg [26:0] s_off;        // 段起始地址（4 字节字单位）
    reg [15:0] s_n;          // 段元素总数
    reg [5:0]  s_per;        // 每个 256 位 beat 的元素数

    reg [3:0]  st;
    reg [1:0]  desc_cnt;
    reg [28:0] cmd_addr;
    wire [28:0] cmd_addr_inc /* synthesis syn_keep=1 */;
    wire [3:0] cmd_addr_full /* synthesis syn_keep=1 */;
    assign cmd_addr_full[0]=&cmd_addr[9:3];
    assign cmd_addr_full[1]=&cmd_addr[17:10];
    assign cmd_addr_full[2]=&cmd_addr[25:18];
    assign cmd_addr_full[3]=&cmd_addr[28:26];
    assign cmd_addr_inc[2:0]=cmd_addr[2:0];
    assign cmd_addr_inc[9:3]=cmd_addr[9:3]+7'd1;
    assign cmd_addr_inc[17:10]=cmd_addr[17:10]+{7'd0,cmd_addr_full[0]};
    assign cmd_addr_inc[25:18]=cmd_addr[25:18]+{7'd0,(&cmd_addr_full[1:0])};
    assign cmd_addr_inc[28:26]=cmd_addr[28:26]+{2'd0,(&cmd_addr_full[2:0])};
    reg        en_r;
    reg        st_prev;                 // start 的上一拍（边沿检测）
    wire       start_p = start ^ st_prev;
    // ★ 超时保护：正常情况下一次读约 6 拍就回来。若 DDR 没响应
    //   （地址越界、控制器异常），状态机会永远卡在 S_CMD/S_WAIT，
    //   而引擎那边 sd_pend 不清 0 → quiet 一直为 1 → 永久静音。
    //   超时后强制跳过本段，保证系统能自己恢复。
    reg [13:0] tmo;
    localparam [13:0] TMO_MAX = 14'd4000;

    assign app_en   = en_r;
    assign app_addr = cmd_addr;

    // Descriptor registers intentionally have no reset. Capture beats using
    // the state/valid handshake without the high-fanout reset in their CE.
    // Reset still clears the FSM and every write strobe; both descriptor
    // beats are overwritten before the next transfer can consume them.
    always @(posedge clk) begin
        if (st==S_DW && app_rd_data_valid) begin
            if (desc_cnt==0) begin
                d_k    <= app_rd_data[ 31:  0];
                d_ab   <= app_rd_data[ 63: 32];
                d_bc   <= app_rd_data[ 95: 64];
                d_pi   <= app_rd_data[127: 96];
                d_ee   <= app_rd_data[159:128];
                d_eo   <= app_rd_data[191:160];
                d_elen <= app_rd_data[223:192];
            end else begin
                d_pe   <= app_rd_data[ 31:  0];
                d_po   <= app_rd_data[ 63: 32];
                d_plen <= app_rd_data[ 95: 64];
                d_ph   <= app_rd_data[127: 96];
                d_flen <= app_rd_data[159:128];
            end
        end
    end

    always @(posedge clk) begin
        if (!local_rst_n) begin
            st <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            ab_we <= 0; bc_we <= 0; pi_we <= 0;
            ee_we <= 0; eo_we <= 0; pe_we <= 0; po_we <= 0; ph_we <= 0;
            seg <= 4'd0; wptr <= 16'd0; beat_cnt <= 6'd0;
            rem <= 16'd0; desc_cnt <= 2'd0;
            s_off <= 27'd0; s_n <= 16'd0; s_per <= 6'd0;
            en_r <= 1'b0; cmd_addr <= 29'd0; st_prev <= 1'b0; tmo <= 14'd0;
        end
        else begin
            done  <= 1'b0;
            en_r  <= 1'b0;
            st_prev <= start;
            ab_we <= 0; bc_we <= 0; pi_we <= 0;
            ee_we <= 0; eo_we <= 0; pe_we <= 0; po_we <= 0; ph_we <= 0;

            case (st)
                //──────────────────────────────────────────────────
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start_p) begin
                        busy <= 1'b1;
                        // 描述符 app 地址 = desc_base + note*16
                        //   （desc_base 已扣掉 note_lo*16，上层算好）
                        cmd_addr <= desc_base
                                  + {{18{1'b0}}, note, 4'b0000};
                        desc_cnt <= 2'd0;
                        st <= S_DESC;
                    end
                end

                //──────────────────────────────────────────────────
                S_DESC: if (app_rdy) begin
                    en_r <= 1'b1;
                    st   <= S_DW;
                end

                S_DW: if (app_rd_data_valid) begin
                    if (desc_cnt == 2'd0) begin
                        desc_cnt <= 2'd1;
                        cmd_addr <= cmd_addr_inc;
                        st <= S_DESC;
                    end
                    else begin
                        seg    <= 4'd0;
                        st     <= S_SEG;
                    end
                end


                //──────────────────────────────────────────────────
                S_SEG: begin
                    if (seg > 4'd7) begin
                        st <= S_DONE;
                    end
                    else begin
                        // ★ 本状态【只打寄存器】，不做任何比较/分支
                        s_off <= px_off[28:2];      // 字节 → 4 字节单位
                        s_n   <= px_n;
                        s_per <= px_per;
                        st    <= S_SEG2;
                    end
                end

                //──────────────────────────────────────────────────
                S_SEG2: begin
                    if (s_n == 16'd0) begin
                        seg <= seg + 4'd1;          // 空段跳过
                        st  <= S_SEG;
                    end
                    else begin
                        rem      <= s_n;            // 倒计数初值
                        wptr     <= 16'd0;
                        beat_cnt <= 6'd0;
                        cmd_addr <= {2'b00, s_off};
                        st       <= S_CMD;
                    end
                end

                //──────────────────────────────────────────────────
                S_CMD: begin
                    if (app_rdy) begin
                        en_r <= 1'b1;
                        tmo  <= 14'd0;
                        st   <= S_WAIT;
                    end
                    else if (tmo >= TMO_MAX) begin
                        // DDR 不应答：放弃这一段，继续下一段
                        seg <= seg + 4'd1;
                        st  <= S_SEG;
                    end
                    else tmo <= tmo + 14'd1;
                end

                S_WAIT: begin
                    if (app_rd_data_valid) begin
                        beat     <= app_rd_data;
                        beat_cnt <= 6'd0;
                        st       <= S_WR;
                    end
                    else if (tmo >= TMO_MAX) begin
                        // 数据一直没回来：放弃本段（剩下的段也会超时，最终正常收尾）
                        seg <= seg + 4'd1;
                        st  <= S_SEG;
                    end
                    else tmo <= tmo + 14'd1;
                end

                //──────────────────────────────────────────────────
                S_WR: begin
                    if (seg == 4'd0 || seg == 4'd1 || seg == 4'd7) beat <= beat >> 32;
                    else if (seg == 4'd2 || seg == 4'd5 || seg == 4'd6) beat <= beat >> 16;
                    else beat <= beat >> 8;
                    // 写一个元素
                    case (seg)
                        4'd0: begin ab_we <= 1'b1; ab_a <= wptr[5:0]; ab_d <= elem32; end
                        4'd1: begin bc_we <= 1'b1; bc_a <= wptr[5:0]; bc_d <= elem32; end
                        4'd2: begin pi_we <= 1'b1; pi_a <= wptr[5:0]; pi_d <= elem16; end
                        4'd3: begin ee_we <= 1'b1; ee_a <= wptr[12:0]; ee_d <= elem8; end
                        4'd4: begin eo_we <= 1'b1; eo_a <= wptr[12:0]; eo_d <= elem8; end
                        4'd5: begin pe_we <= 1'b1; pe_a <= wptr[11:0]; pe_d <= elem16; end
                        4'd6: begin po_we <= 1'b1; po_a <= wptr[11:0]; po_d <= elem16; end
                        default: begin ph_we <= 1'b1; ph_a <= wptr[9:0]; ph_d <= elem32; end
                    endcase

                    wptr <= wptr + 16'd1;
                    rem  <= rem - 16'd1;

                    if (rem == 16'd1) begin
                        // 本段搬完 → 下一段
                        seg <= seg + 4'd1;
                        st  <= S_SEG;
                    end
                    else if (beat_cnt + 6'd1 >= s_per) begin
                        // 本 beat 用完 → 取下一拍
                        beat_cnt <= 6'd0;
                        cmd_addr <= cmd_addr_inc;
                        st       <= S_CMD;
                    end
                    else begin
                        beat_cnt <= beat_cnt + 6'd1;
                    end
                end

                //──────────────────────────────────────────────────
                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    st   <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
