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
    parameter integer NOTE_LO    = 69,      // 镜像里唢呐最低音
    parameter integer SUONA_BASE = 8769,    // 唢呐段起始 word
    parameter integer DESC_OFF   = 2        // 描述符表在段内的 word 偏移
)(
    input  wire         clk,        // clk_x1（100 MHz，DDR 用户域）
    input  wire         rst_n,

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

    assign app_cmd = 3'b001;        // 只读

    // ── 描述符寄存器 ────────────────────────────────────────────────
    reg [31:0] d_k, d_ab, d_bc, d_pi, d_ee, d_eo, d_elen,
               d_pe, d_po, d_plen, d_ph, d_flen;

    // ── 当前搬运段 ──────────────────────────────────────────────────
    //  0=ab 1=bc 2=pi 3=env_e 4=env_o 5=psi_e 6=psi_o 7=phi
    reg [3:0]  seg;
    reg [15:0] seg_n;        // 本段元素总数
    reg [15:0] wptr;         // 已写元素数
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
        if (seg == 4'd0 || seg == 4'd1 || seg == 4'd7) begin
            elem32 = beat[ (beat_cnt[2:0] * 32) +: 32 ];
        end
        else if (seg == 4'd2 || seg == 4'd5 || seg == 4'd6) begin
            elem16 = beat[ (beat_cnt[3:0] * 16) +: 16 ];
        end
        else begin
            elem8  = beat[ (beat_cnt[4:0] * 8)  +: 8  ];
        end
    end

    // ── 状态机 ──────────────────────────────────────────────────────
    localparam [2:0] S_IDLE = 3'd0,
                     S_DESC = 3'd1,
                     S_DW   = 3'd2,
                     S_SEG  = 3'd3,
                     S_CMD  = 3'd4,
                     S_WAIT = 3'd5,
                     S_WR   = 3'd6,
                     S_DONE = 3'd7;

    reg [2:0]  st;
    reg [1:0]  desc_cnt;
    reg [28:0] cmd_addr;
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

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            ab_we <= 0; bc_we <= 0; pi_we <= 0;
            ee_we <= 0; eo_we <= 0; pe_we <= 0; po_we <= 0; ph_we <= 0;
            seg <= 4'd0; wptr <= 16'd0; beat_cnt <= 6'd0;
            seg_n <= 16'd0; desc_cnt <= 2'd0;
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
                        // 描述符字节偏移 = (SUONA_BASE+DESC_OFF)*32 + (note-NOTE_LO)*64
                        // app_addr = 字节 >> 2
                        cmd_addr <= ((SUONA_BASE + DESC_OFF) << 3)
                                  + {{22{1'b0}}, note, 4'b0000}
                                  - ((NOTE_LO * 16));
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
                        d_k    <= app_rd_data[ 31:  0];
                        d_ab   <= app_rd_data[ 63: 32];
                        d_bc   <= app_rd_data[ 95: 64];
                        d_pi   <= app_rd_data[127: 96];
                        d_ee   <= app_rd_data[159:128];
                        d_eo   <= app_rd_data[191:160];
                        d_elen <= app_rd_data[223:192];
                        desc_cnt <= 2'd1;
                        cmd_addr <= cmd_addr + 29'd8;
                        st <= S_DESC;
                    end
                    else begin
                        d_pe   <= app_rd_data[ 31:  0];
                        d_po   <= app_rd_data[ 63: 32];
                        d_plen <= app_rd_data[ 95: 64];
                        d_ph   <= app_rd_data[127: 96];
                        d_flen <= app_rd_data[159:128];
                        seg    <= 4'd0;
                        st     <= S_SEG;
                    end
                end

                //──────────────────────────────────────────────────
                S_SEG: begin
                    if (seg > 4'd7) begin
                        st <= S_DONE;
                    end
                    else if (px_n == 16'd0) begin
                        seg <= seg + 4'd1;          // 空段跳过
                    end
                    else begin
                        seg_n    <= px_n;
                        wptr     <= 16'd0;
                        beat_cnt <= 6'd0;
                        cmd_addr <= px_off[28:2];   // 字节 → 4 字节单位
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

                    if (wptr + 16'd1 >= seg_n) begin
                        // 本段搬完 → 下一段
                        seg <= seg + 4'd1;
                        st  <= S_SEG;
                    end
                    else if (beat_cnt + 6'd1 >= px_per) begin
                        // 本 beat 用完 → 取下一拍
                        beat_cnt <= 6'd0;
                        cmd_addr <= cmd_addr + 29'd8;
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
