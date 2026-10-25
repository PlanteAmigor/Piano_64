//==========================================================================
//  tb_ab8 —— A/B 对比：旧 64 分量引擎 vs 新 128 分量引擎
//
//  同一个 testbench 结构、同样的触发时序、同样的 note 60，
//  分别实例化两个引擎（用 `ENG_OLD 编译开关选），各导出 800 个 sample_l，
//  在 Python 里算峰值 / 周期性 / 相关系数。
//
//  用法（在各自源码目录跑，因为 $readmemh 是相对路径）：
//    旧： iverilog -g2012 -DSIM_INIT -DENG_OLD -o old.vvp -s tb_ab8 \
//             add_engine.v add_voice.v mix_sum.v add_param_rom.v add_sine_lut.v tb_ab8.v
//    新： iverilog -g2012 -DSIM_INIT -o new.vvp -s tb_ab8 \
//             src/add_engine8.v src/add_voice8.v src/mix_sum.v \
//             src/add_param_rom.v src/add_sine_lut.v sim/tb_ab8.v
//==========================================================================
`default_nettype none

module tb_ab8;

    localparam integer NVOICE = 4;
    localparam integer NOTE   = 60;
    localparam integer NLO    = 21;      // 新引擎
    localparam integer NLO_OLD= 36;      // 旧引擎默认
    localparam integer NSMP   = 800;

    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg rst_n = 1'b0;

    reg  [NVOICE*7-1:0] v_note;
    reg  [NVOICE-1:0]   v_trig, v_gate;
    reg                 sample_tick;
    wire signed [15:0]  sample_l, sample_r;
    wire [NVOICE-1:0]   v_idle;

    initial begin
        v_note = {(NVOICE*7){1'b0}};
        v_note[0*7 +: 7] = NOTE[6:0];
        v_note[1*7 +: 7] = NOTE[6:0];
        v_note[2*7 +: 7] = NOTE[6:0];
        v_note[3*7 +: 7] = NOTE[6:0];
    end

`ifdef ENG_OLD
    add_engine #(
        .NVOICE(NVOICE),
        .MIX_SHIFT(1), .SOFT(1),
        .ROM_DEPTH(5632),
        .NOTE_LO(36), .NOTE_HI(88), .ATK(0), .TIMBRE(0)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .v_note(v_note), .v_trig(v_trig), .v_gate(v_gate),
        .sample_tick(sample_tick),
        .sample_l(sample_l), .sample_r(sample_r), .v_idle(v_idle)
    );
`else
    add_engine8 #(
        .NVOICE(NVOICE), .NPART(128), .ROM_AW(14), .ROM_DEPTH(11264),
        .NOTE_LO(21), .NOTE_HI(108), .ATK(0), .TIMBRE(0),
        .MIX_SHIFT(1), .SOFT(1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .v_note(v_note), .v_trig(v_trig), .v_gate(v_gate),
        .sample_tick(sample_tick),
        .sample_l(sample_l), .sample_r(sample_r), .v_idle(v_idle)
    );
`endif

    reg [9:0] st_cnt = 10'd0;
    always @(posedge clk) begin
        st_cnt <= st_cnt + 10'd1;
        sample_tick <= (st_cnt == 10'd1023);
    end

    integer f, n;
    integer maxabs, nclip, nz;

    initial begin
`ifdef ENG_OLD
        f = $fopen("out_old.txt", "w");
`else
        f = $fopen("out_new.txt", "w");
`endif
        v_trig = 0; v_gate = 0;
        #200 rst_n = 1'b1;

        // 先空跑两个样点，让内部计数器稳定
        repeat (2100) @(posedge clk);

        @(posedge clk) v_trig[0] <= 1'b1;
        @(posedge clk) v_trig[0] <= 1'b0;
        @(posedge clk) v_gate[0] <= 1'b1;

        // 装载 + 让包络跑起来：等 3 个样点
        repeat (3*1024 + 200) @(posedge clk);

        n = 0; maxabs = 0; nclip = 0; nz = 0;
        while (n < NSMP) begin
            @(posedge clk);
            if (sample_tick) begin
                $fdisplay(f, "%0d", sample_l);
                if (sample_l !== 16'sd0) nz = nz + 1;
                if ((sample_l > 0 ? sample_l : -sample_l) > maxabs)
                    maxabs = (sample_l > 0 ? sample_l : -sample_l);
                if (sample_l >= 32767 || sample_l <= -32768) nclip = nclip + 1;
                n = n + 1;
            end
        end
        $fclose(f);
        $display("RESULT  maxabs=%0d  nclip=%0d  nonzero=%0d / %0d",
                 maxabs, nclip, nz, NSMP);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
