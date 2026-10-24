//==========================================================================
//  add_param_rom —— 音色参数表
//
//  ⚠️ 为什么写成【两个模块】而不是一个带文件名参数的模块：
//     iverilog 不支持把字符串参数喂给 $readmemh
//     （会报 "file name argument (vpiParameter) is not a valid string"），
//     gw_sh 反而支持。为了两种工具都能仿真/综合，这里写成两份、由
//     add_voice 用 generate-if 选一份。
//
//  地址 = (note − NOTE_LO) × 32 + p        【定长布局，不需要偏移表】
//  DEPTH = NNOTE × 64：钢琴 88×64=5632，古筝 49×64=3136（新模态表 D2..D6）
//  ★ 只有 4 个 bank：bank4 的 Rr 是起音项，两个音色现在都是 ATK=0，用不上 → d4 恒 1
//    省下的 BSRAM 正好够 NPART 翻倍（32→64）
//
//  每行 5 个 32bit 字：
//     bank0 = inc[31:0]                     相位增量 = round(f_n·2^32/fs)
//     bank1 = { R1[23:0],  w8[7:0] }        第 1 段衰减率 / 双段权重
//     bank2 = { R2[23:0],  phi8[7:0] }      第 2 段衰减率 / 初相
//     bank3 = { a16[15:0], 16'b0 }          初幅
//     bank4 = Rr[24:0]                      ★ 起音上升率（钢琴全 0，用不到）
//
//  高云 BSRAM 只支持【同步读】：地址打一拍，数据下一拍出。
//  add_voice 的流水线按这个延迟排。
//==========================================================================
`default_nettype none


//──────────────────────────────────────────────────────────────────────
//  钢琴：新模态公式表，MIDI 21..108，88 音，无起音项
//  由 tools/gen_modal_rom.py 生成 add_param0..3.hex（64 模态/音）
//──────────────────────────────────────────────────────────────────────
module piano_param_rom #(
    parameter ADDR_W = 13,
    parameter DEPTH  = 5632
)(
    input  wire              clk,
    input  wire [ADDR_W-1:0] addr,
    output reg  [31:0]       d0,
    output reg  [31:0]       d1,
    output reg  [31:0]       d2
);
    reg [31:0] m0 [0:DEPTH-1];
    reg [31:0] m1 [0:DEPTH-1];
    reg [31:0] m2 [0:DEPTH-1];

    initial begin
        $readmemh("add_param0.hex", m0);
        $readmemh("add_param1.hex", m1);
        $readmemh("add_param2.hex", m2);
    end

    // bank0 = inc[31:0]   bank1 = R1[31:0]   bank2 = {a16[15:0], phi8[7:0], 8'b0}
    // ★ 只有 3 个 bank：bank2 的高 16 位放 a16、次 8 位放 phi8，剩下 8 位空着。
    //   原来 R2/Rr 各占一整个 bank，但 w≡1（e2 恒等 e1）和 ATK=0 让它们全是死数据。
    always @(posedge clk) begin
        d0 <= m0[addr];  d1 <= m1[addr];  d2 <= m2[addr];
    end
endmodule


//──────────────────────────────────────────────────────────────────────
//  古筝：新模态公式表，MIDI 38..86，49 音，无起音项
//  由 tools/gen_modal_rom.py 生成 gz_param0..3.hex（64 模态/音）
//──────────────────────────────────────────────────────────────────────
module guzheng_param_rom #(
    parameter ADDR_W = 13,
    parameter DEPTH  = 3136
)(
    input  wire              clk,
    input  wire [ADDR_W-1:0] addr,
    output reg  [31:0]       d0,
    output reg  [31:0]       d1,
    output reg  [31:0]       d2
);
    reg [31:0] m0 [0:DEPTH-1];
    reg [31:0] m1 [0:DEPTH-1];
    reg [31:0] m2 [0:DEPTH-1];

    initial begin
        $readmemh("gz_param0.hex", m0);
        $readmemh("gz_param1.hex", m1);
        $readmemh("gz_param2.hex", m2);
    end

    // bank0 = inc[31:0]   bank1 = R1[31:0]   bank2 = {a16[15:0], phi8[7:0], 8'b0}
    // ★ 只有 3 个 bank：bank2 的高 16 位放 a16、次 8 位放 phi8，剩下 8 位空着。
    //   原来 R2/Rr 各占一整个 bank，但 w≡1（e2 恒等 e1）和 ATK=0 让它们全是死数据。
    always @(posedge clk) begin
        d0 <= m0[addr];  d1 <= m1[addr];  d2 <= m2[addr];
    end
endmodule

`default_nettype wire
