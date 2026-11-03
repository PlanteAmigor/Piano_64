//==========================================================================
//  harm_buf —— 唢呐表的工作缓冲（替代 harm_rom_suona）
//
//  和 harm_rom_suona 的区别：
//    · ab/bc/pi/env_e/env_o/psi_e/psi_o/phi 八个表改成【按音预取的缓冲】，
//      由 suona_dma 从 DDR 写进来，只存当前正在吹的那个音
//    · 写口在 clk_x1（100 MHz，DDR 用户域），读口在 clk（50 MHz，引擎域）
//      → 用双时钟 SDP BSRAM，写法与 param_cache 一致
//    · u / sn / info 三个表仍然常驻（u 每样点查两次，sn 每样点查一次，
//      都不能走 DDR），继续用 $readmemh 初始化
//
//  ★ 因为缓冲里只放一个音，引擎里原来的 4 个 base（v_ab/v_eb/v_pb/v_fb）
//    全部变成 0，地址直接用段内相对偏移。深度按【最大单音】留：
//      ab/bc/pi  64  （K ≤ 55）
//      env       8192（最大 4180）
//      psi       4096（最大 2869）
//      phi       1024（最大 600）
//==========================================================================
`default_nettype none

module harm_buf #(
    parameter integer AB_DEPTH   = 64,
    parameter integer ENV_DEPTH  = 8192,
    parameter integer PSI_DEPTH  = 4096,
    parameter integer PHI_DEPTH  = 1024
)(
    input  wire                  clk,       // 引擎域 50 MHz（读）
    input  wire                  rst_n,

    // ── 读口（与 harm_rom_suona 一致）──────────────────────────────
    input  wire [10:0]           abc_a,
    input  wire [10:0]           pi_a,
    output reg  [31:0]           ab_d,
    output reg  [31:0]           bc_d,
    output reg  [15:0]           pi_d,

    input  wire [15:0]           pe_a, po_a,
    output reg  [15:0]           pe_d, po_d,

    input  wire [15:0]           ee_a, eo_a,
    output reg  [7:0]            ee_d, eo_d,

    input  wire [14:0]           ph_a,
    output reg  [31:0]           ph_d,

    input  wire [13:0]           u_a,
    output wire [31:0]           u_d,

    input  wire [9:0]            sn_a,
    output wire [31:0]           sn_d,

    input  wire [7:0]            inf_a,
    output reg  [31:0]           inf_d,
    // ── 写口（来自 suona_dma，clk_x1 域）──────────────────────────
    input  wire                  wclk,
    input  wire                  wrst_n,
    input  wire                  ab_we,
    input  wire [5:0]            ab_a,
    input  wire [31:0]           ab_wd,
    input  wire                  bc_we,
    input  wire [5:0]            bc_a,
    input  wire [31:0]           bc_wd,
    input  wire                  pi_we,
    input  wire [5:0]            pi_a_w,
    input  wire [15:0]           pi_wd,
    input  wire                  ee_we,
    input  wire [12:0]           ee_a_w,
    input  wire [7:0]            ee_wd,
    input  wire                  eo_we,
    input  wire [12:0]           eo_a_w,
    input  wire [7:0]            eo_wd,
    input  wire                  pe_we,
    input  wire [11:0]           pe_a_w,
    input  wire [15:0]           pe_wd,
    input  wire                  po_we,
    input  wire [11:0]           po_a_w,
    input  wire [15:0]           po_wd,
    input  wire                  ph_we,
    input  wire [9:0]            ph_a_w,
    input  wire [31:0]           ph_wd
);

    // ── 8 个按音缓冲（可写）────────────────────────────────────────
    reg [31:0] m_ab [0:AB_DEPTH-1];
    reg [31:0] m_bc [0:AB_DEPTH-1];
    reg [15:0] m_pi [0:AB_DEPTH-1];
    reg [7:0]  m_ee [0:ENV_DEPTH-1];
    reg [7:0]  m_eo [0:ENV_DEPTH-1];
    reg [15:0] m_pe [0:PSI_DEPTH-1];
    reg [15:0] m_po [0:PSI_DEPTH-1];
    reg [31:0] m_ph [0:PHI_DEPTH-1];

    // ── 3 个常驻表 ─────────────────────────────────────────────────
    // The original 16384-word curve becomes constant at address 9156.
    // Separate power-of-two banks avoid rounding the live prefix back to
    // 16384 words. Both synchronous reads and the selector take one cycle,
    // preserving the original interpolation interface exactly.
    reg [31:0] m_u_head [0:8191];
    reg [31:0] m_u_tail [0:1023];
    reg [31:0] u_head_q,u_tail_q;
    reg u_bank_q,u_constant_q;
    always @(posedge clk)begin
        u_head_q<=m_u_head[u_a[12:0]];
        u_tail_q<=m_u_tail[u_a[9:0]];
        u_bank_q<=u_a[13];
        u_constant_q<=u_a>=14'd9156;
    end
    assign u_d=u_constant_q?32'hFFFFFFFF:(u_bank_q?u_tail_q:u_head_q);
    add_sine_lut u_sine(.clk(clk),.addr(sn_a),.dout(sn_d));
    // ★ info 表扩容到 224 词：
    //    0   .. 111  唢呐 28 音 × 4 词（原表刚好用满）
    //    112 .. 211  笛子 25 音 × 4 词
    //    212 .. 223  保留
    //   引擎用 inf_base（0 / 112）选段，同一时刻只有一个乐器在响。
    reg [31:0] m_inf [0:223];

    initial begin
        $readmemh("harm_u_head.hex",m_u_head);
        $readmemh("harm_u_tail.hex",m_u_tail);
        $readmemh("suona_info.hex", m_inf);            // 写到 0..111
        $readmemh("dizi_info.hex",  m_inf, 112, 211);  // 写到 112..211
    end

    // ── 写（clk_x1 域）──────────────────────────────────────────────
    always @(posedge wclk) begin
        if (ab_we) m_ab[ab_a] <= ab_wd;
        if (bc_we) m_bc[bc_a] <= bc_wd;
        if (pi_we) m_pi[pi_a_w] <= pi_wd;
        if (ee_we) m_ee[ee_a_w] <= ee_wd;
        if (eo_we) m_eo[eo_a_w] <= eo_wd;
        if (pe_we) m_pe[pe_a_w] <= pe_wd;
        if (po_we) m_po[po_a_w] <= po_wd;
        if (ph_we) m_ph[ph_a_w] <= ph_wd;
    end

    // ── 读（clk 域）────────────────────────────────────────────────
    always @(posedge clk) begin
        ab_d  <= m_ab[abc_a[5:0]];
        bc_d  <= m_bc[abc_a[5:0]];
        pi_d  <= m_pi[pi_a[5:0]];
        ee_d  <= m_ee[ee_a[12:0]];
        eo_d  <= m_eo[eo_a[12:0]];
        pe_d  <= m_pe[pe_a[11:0]];
        po_d  <= m_po[po_a[11:0]];
        ph_d  <= m_ph[ph_a[9:0]];
        inf_d <= m_inf[inf_a[7:0]];
    end

endmodule

`default_nettype wire
