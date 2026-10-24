//==========================================================================
//  tb_hdbg —— 谐波引擎逐项调试：打印前 3 个样点的每个谐波贡献
//==========================================================================
`timescale 1ns/1ps

module tb_hdbg;

    localparam integer MIDI = 67;
    localparam integer NLO  = 67;

    reg clk = 1'b0, rst_n = 1'b0;
    always #10 clk = ~clk;

    reg [6:0] note = MIDI;
    reg       trig = 1'b0;
    reg       gate = 1'b1;

    reg [31:0] ptab [0:262143];
    initial $readmemh("harm_tab/dizi_param.hex", ptab);

    reg [18:0] paddr;
    reg [31:0] prd;
    always @(posedge clk) prd <= ptab[paddr];

    reg [31:0] btab [0:27];
    initial $readmemh("harm_tab/dizi_base.hex", btab);
    wire [18:0] base_rd = btab[note - NLO][18:0];

    reg [31:0] utab [0:16383];    initial $readmemh("harm_tab/harm_u.hex", utab);
    reg [13:0] uaddr;
    reg [31:0] urd;
    always @(posedge clk) urd <= utab[uaddr];

    reg [15:0] stab [0:1023];
    initial $readmemh("harm_tab/harm_sin.hex", stab);
    reg [9:0]  saddr;
    reg [15:0] srd;
    always @(posedge clk) srd <= stab[saddr];

    wire signed [15:0] smp;
    wire               svalid, idle;

    add_voice_harm #(
        .ROM_AW (19), .NT(600), .NT2(300), .NT3(150),
        .NOTE_LO(NLO), .NOTE_HI(91), .U_AW(14)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .note(note), .trig(trig), .gate(gate),
        .rd(prd), .rom_addr(paddr),
        .u_rd(urd), .u_addr(uaddr),
        .sin_rd(srd), .sin_addr(saddr),
        .base_rd(base_rd),
        .sample(smp), .sample_valid(svalid), .idle(idle)
    );

    // 在 s==15 那一刻打印：本谐波的 env0 / hAS / sn0 / 乘积
    integer nsm = 0;
    always @(posedge clk) begin
        if (rst_n && dut.st == 3'd3 && dut.s == 4'd15 && nsm < 4) begin
            if (dut.m == 8'd0) begin
                nsm <= nsm + 1;
                $display("--- t_smp=%0d u=%08h env_pos=%0d env_fr=%08h Phi=%0d pfrac=%08h ---",
                         dut.t_smp, dut.u_acc, dut.env_pos, dut.env_fr, dut.Phi, dut.pfrac);
            end
            $display("  m=%2d env0=%6d hAS=%7d sn0=%7d theta=%0h term=%0d",
                     dut.m, dut.env0, dut.hAS, dut.sn0, dut.theta,
                     $signed((((dut.env0 * dut.hAS) >>> 15) * dut.sn0)));
        end
    end

    // 同时把 acc 的增量打印出来
    reg signed [63:0] acc_d = 0;
    always @(posedge clk) acc_d <= dut.acc;

    always @(posedge clk) begin
        if (rst_n && dut.st == 3'd4) begin
            $display("=== OUT t_smp=%0d acc=%0d  acc/2^20=%0d  smp=%0d  u=%08h Phi=%0d",
                     dut.t_smp, dut.acc, dut.acc >>> 20, smp, dut.u_acc, dut.Phi);
        end
    end

    // 指定时刻的逐谐波快照
    always @(posedge clk) begin
        if (rst_n && dut.st == 3'd3 && dut.s == 4'd14 && dut.t_smp == 20'd4093)
            $display("SNP t=%0d m=%0d theta=%0h psi0=%0d hPA=%0d hDM=%0d sa=%0d sn0=%0d env0=%0d hAS=%0d",
                     dut.t_smp, dut.m, dut.theta, dut.psi0, dut.hPA, dut.hDM,
                     dut.sin_addr, dut.sn0, dut.env0, dut.hAS);
    end

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);
        trig = 1'b1;
        repeat (3) @(posedge clk);
        trig = 1'b0;
        repeat (4100 * 1024) @(posedge clk);
        $finish;
    end

endmodule
