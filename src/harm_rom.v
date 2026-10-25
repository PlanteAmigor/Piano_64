//==========================================================================
//  harm_rom —— 谐波表的 8 个并行 bank（由 tools/npz2hex_harm2.py 生成）
//
//  ★ 为什么拆成这么多 bank：
//    旧版一个 16 位 ROM，9 个字段九次串行读 → 16 拍/谐波 → 一个样点(1024 拍)
//    只放得下 1 个声部。拆成独立存储器后每个 bank 各有一个读端口，可以同拍发地址，
//    一个谐波的所有参数一拍就拿全，配合流水线做到 1 谐波/拍。
//
//  ★ ab / bc / pi 三个 bank 长度相同、基址相同 → 共用一个地址。
//
//  ★ 高云 BSRAM 只支持同步读：地址打一拍，数据下一拍出。本模块与引擎的
//    流水线按这个延迟排。
//
//  ★ 为什么不把文件名做成字符串参数：iverilog 不支持把字符串参数喂 $readmemh
//    （会报 "file name argument (vpiParameter) is not a valid string"），
//    gw_sh 反而支持。所以写成两个模块、由引擎用 generate-if 选一个。
//==========================================================================
`default_nettype none

module harm_rom_dizi #(
    parameter integer AB_AW   = 11,
    parameter integer PSI_AW  = 16,
    parameter integer ENV_AW  = 16,
    parameter integer PHI_AW  = 15,
    parameter integer INFO_AW = 7,
    parameter integer AB_DEPTH   = 837,
    parameter integer PSI_DEPTH  = 54662,
    parameter integer ENV_DEPTH  = 63536,
    parameter integer PHI_DEPTH  = 15000,
    parameter integer INFO_DEPTH = 100
)(
    input  wire                  clk,

    input  wire [AB_AW-1:0]      abc_a,
    input  wire [AB_AW-1:0]      pi_a,
    output reg  [31:0]           ab_d,      // {A(Q4.11), phi_a(Q0.16)}
    output reg  [31:0]           bc_d,      // {dm(0.001Hz), env_scale(Q1.15)}
    output reg  [15:0]           pi_d,      // psi_off（行号×步长，已预乘）

    input  wire [PSI_AW-1:0]     pe_a, po_a,
    output reg  [15:0]           pe_d, po_d,

    input  wire [ENV_AW-1:0]     ee_a, eo_a,
    output reg  [7:0]            ee_d, eo_d,

    input  wire [PHI_AW-1:0]     ph_a,
    output reg  [31:0]           ph_d,

    input  wire [13:0]           u_a,
    output reg  [31:0]           u_d,

    input  wire [9:0]            sn_a,
    output reg  [31:0]           sn_d,      // {sin[i+1], sin[i]}

    input  wire [INFO_AW-1:0]    inf_a,
    output reg  [31:0]           inf_d
);
    reg [31:0] m_ab  [0:AB_DEPTH-1];
    reg [31:0] m_bc  [0:AB_DEPTH-1];
    reg [15:0] m_pi  [0:AB_DEPTH-1];
    reg [15:0] m_pe  [0:PSI_DEPTH-1];
    reg [15:0] m_po  [0:PSI_DEPTH-1];
    reg [7:0]  m_ee  [0:ENV_DEPTH-1];
    reg [7:0]  m_eo  [0:ENV_DEPTH-1];
    reg [31:0] m_ph  [0:PHI_DEPTH-1];
    reg [31:0] m_u   [0:16383];
    reg [31:0] m_sn  [0:1023];
    reg [31:0] m_inf [0:INFO_DEPTH-1];

    initial begin
        $readmemh("dizi_ab.hex",   m_ab);
        $readmemh("dizi_bc.hex",   m_bc);
        $readmemh("dizi_pi.hex",   m_pi);
        $readmemh("dizi_psi_e.hex", m_pe);
        $readmemh("dizi_psi_o.hex", m_po);
        $readmemh("dizi_env_e.hex", m_ee);
        $readmemh("dizi_env_o.hex", m_eo);
        $readmemh("dizi_phi.hex",  m_ph);
        $readmemh("harm_u.hex",    m_u);
        $readmemh("add_sine.hex",  m_sn);
        $readmemh("dizi_info.hex", m_inf);
    end

    always @(posedge clk) begin
        ab_d  <= m_ab[abc_a];
        bc_d  <= m_bc[abc_a];
        pi_d  <= m_pi[pi_a];
        pe_d  <= m_pe[pe_a];
        po_d  <= m_po[po_a];
        ee_d  <= m_ee[ee_a];
        eo_d  <= m_eo[eo_a];
        ph_d  <= m_ph[ph_a];
        u_d   <= m_u[u_a];
        sn_d  <= m_sn[sn_a];
        inf_d <= m_inf[inf_a];
    end
endmodule


module harm_rom_suona #(
    parameter integer AB_AW   = 11,
    parameter integer PSI_AW  = 16,
    parameter integer ENV_AW  = 16,
    parameter integer PHI_AW  = 15,
    parameter integer INFO_AW = 7,
    parameter integer AB_DEPTH   = 780,
    parameter integer PSI_DEPTH  = 57833,
    parameter integer ENV_DEPTH  = 59204,
    parameter integer PHI_DEPTH  = 16800,
    parameter integer INFO_DEPTH = 112
)(
    input  wire                  clk,

    input  wire [AB_AW-1:0]      abc_a,
    input  wire [AB_AW-1:0]      pi_a,
    output reg  [31:0]           ab_d,
    output reg  [31:0]           bc_d,
    output reg  [15:0]           pi_d,

    input  wire [PSI_AW-1:0]     pe_a, po_a,
    output reg  [15:0]           pe_d, po_d,

    input  wire [ENV_AW-1:0]     ee_a, eo_a,
    output reg  [7:0]            ee_d, eo_d,

    input  wire [PHI_AW-1:0]     ph_a,
    output reg  [31:0]           ph_d,

    input  wire [13:0]           u_a,
    output reg  [31:0]           u_d,

    input  wire [9:0]            sn_a,
    output reg  [31:0]           sn_d,

    input  wire [INFO_AW-1:0]    inf_a,
    output reg  [31:0]           inf_d
);
    reg [31:0] m_ab  [0:AB_DEPTH-1];
    reg [31:0] m_bc  [0:AB_DEPTH-1];
    reg [15:0] m_pi  [0:AB_DEPTH-1];
    reg [15:0] m_pe  [0:PSI_DEPTH-1];
    reg [15:0] m_po  [0:PSI_DEPTH-1];
    reg [7:0]  m_ee  [0:ENV_DEPTH-1];
    reg [7:0]  m_eo  [0:ENV_DEPTH-1];
    reg [31:0] m_ph  [0:PHI_DEPTH-1];
    reg [31:0] m_u   [0:16383];
    reg [31:0] m_sn  [0:1023];
    reg [31:0] m_inf [0:INFO_DEPTH-1];

    initial begin
        $readmemh("suona_ab.hex",   m_ab);
        $readmemh("suona_bc.hex",   m_bc);
        $readmemh("suona_pi.hex",   m_pi);
        $readmemh("suona_psi_e.hex", m_pe);
        $readmemh("suona_psi_o.hex", m_po);
        $readmemh("suona_env_e.hex", m_ee);
        $readmemh("suona_env_o.hex", m_eo);
        $readmemh("suona_phi.hex",  m_ph);
        $readmemh("harm_u.hex",    m_u);
        $readmemh("add_sine.hex",  m_sn);
        $readmemh("suona_info.hex", m_inf);
    end

    always @(posedge clk) begin
        ab_d  <= m_ab[abc_a];
        bc_d  <= m_bc[abc_a];
        pi_d  <= m_pi[pi_a];
        pe_d  <= m_pe[pe_a];
        po_d  <= m_po[po_a];
        ee_d  <= m_ee[ee_a];
        eo_d  <= m_eo[eo_a];
        ph_d  <= m_ph[ph_a];
        u_d   <= m_u[u_a];
        sn_d  <= m_sn[sn_a];
        inf_d <= m_inf[inf_a];
    end
endmodule

`default_nettype wire
