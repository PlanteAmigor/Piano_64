`timescale 1ns/1ps
`default_nettype none
module tb_dma_image #(parameter ABORT_RESET=0);
    reg clk=0,rst_n=0,start=0;
    always #5 clk=~clk;
    reg [6:0] note;
    reg [28:0] base;
    reg [7:0] image[0:1127967];
    initial $readmemh("work/song_checks/image_bytes.hex",image);
    function [31:0] u32;
        input integer a;
        begin u32={image[a+3],image[a+2],image[a+1],image[a]};end
    endfunction
    wire [2:0] cmd;
    wire en,busy,done;
    wire [28:0] addr;
    reg pending=0,valid=0;
    reg [28:0] saved;
    reg [255:0] data;
    integer delay=0,j;
    always @(posedge clk) begin
        valid<=0;
        if(en && !pending) begin saved<=addr;pending<=1;delay<=3;end
        else if(pending && delay!=0) delay<=delay-1;
        else if(pending) begin
            for(j=0;j<32;j=j+1) data[j*8+:8]<=image[(saved<<2)+j];
            valid<=1;pending<=0;
        end
    end
    wire aw,bw,iw,ew,ow,pw,qw,fw;
    wire [5:0] aa,ba,ia;
    wire [12:0] ea,oa;
    wire [11:0] pa,qa;
    wire [9:0] fa;
    wire [31:0] ad,bd,fd;
    wire [15:0] id,pd,qd;
    wire [7:0] ed,od;
    suona_dma dut (
        .clk(clk),.rst_n(rst_n),.note(note),.desc_base(base),.start(start),.busy(busy),.done(done),
        .ab_we(aw),.ab_a(aa),.ab_d(ad),.bc_we(bw),.bc_a(ba),.bc_d(bd),.pi_we(iw),.pi_a(ia),.pi_d(id),
        .ee_we(ew),.ee_a(ea),.ee_d(ed),.eo_we(ow),.eo_a(oa),.eo_d(od),
        .pe_we(pw),.pe_a(pa),.pe_d(pd),.po_we(qw),.po_a(qa),.po_d(qd),.ph_we(fw),.ph_a(fa),.ph_d(fd),
        .app_cmd(cmd),.app_en(en),.app_addr(addr),.app_rdy(!pending),.app_rd_data_valid(valid),.app_rd_data(data)
    );
    integer off[0:7],num[0:7],seen[0:7],widths[0:7];
    integer n,inst,b,lo,hi,d,k,s,total=0;
    task check_write;
        input integer seg, a;input [31:0] value;
        reg [31:0] want;integer x;
        begin
            want=0;
            for(x=0;x<widths[seg];x=x+1) want=want | ({24'd0,image[off[seg]+seen[seg]*widths[seg]+x]} << (8*x));
            if(a!=seen[seg] || seen[seg]>=num[seg] || value!==want)
                $fatal(1,"DMA note=%d seg=%d index=%d addr=%d got=%h expected=%h",n,seg,seen[seg],a,value,want);
            seen[seg]=seen[seg]+1;total=total+1;
        end
    endtask
    always @(negedge clk) if(rst_n) begin
        if(aw) check_write(0,aa,ad);if(bw) check_write(1,ba,bd);if(iw) check_write(2,ia,{16'd0,id});
        if(ew) check_write(3,ea,{24'd0,ed});if(ow) check_write(4,oa,{24'd0,od});
        if(pw) check_write(5,pa,{16'd0,pd});if(qw) check_write(6,qa,{16'd0,qd});if(fw) check_write(7,fa,fd);
    end
    initial begin
        widths[0]=4;widths[1]=4;widths[2]=2;widths[3]=1;widths[4]=1;widths[5]=2;widths[6]=2;widths[7]=4;
        repeat(5) @(negedge clk);rst_n=1;
        for(inst=0;inst<2;inst=inst+1) begin
            b=inst==0 ? 8769 : 22176;lo=inst==0 ? 69 : 67;hi=inst==0 ? 96 : 91;
            base=((b+2)<<3)-lo*16;
            for(n=lo;n<=hi;n=n+1) begin
                d=(b+2)*32+(n-lo)*64;k=u32(d);
                off[0]=u32(d+4);off[1]=u32(d+8);off[2]=u32(d+12);off[3]=u32(d+16);off[4]=u32(d+20);
                off[5]=u32(d+32);off[6]=u32(d+36);off[7]=u32(d+44);
                num[0]=k;num[1]=k;num[2]=k;num[3]=u32(d+24);num[4]=num[3];
                num[5]=u32(d+40)/2;num[6]=num[5];num[7]=u32(d+48)/4;
                for(s=0;s<8;s=s+1) seen[s]=0;
                if(ABORT_RESET && inst==0 && n==lo)begin
                    @(negedge clk);note=n;start=~start;
                    wait(dut.st==dut.S_DW && valid);
                    @(negedge clk);rst_n=0;start=0;
                    repeat(8)@(negedge clk);
                    if(busy || done || aw || bw || iw || ew || ow || pw || qw || fw)
                        $fatal(1,"descriptor abort reset did not clear transfer/strobes");
                    for(s=0;s<8;s=s+1)if(seen[s]!=0)$fatal(1,"data written during aborted descriptor fetch");
                    rst_n=1;repeat(4)@(negedge clk);
                end
                @(negedge clk);note=n;start=~start;wait(done);repeat(3) @(negedge clk);
                for(s=0;s<8;s=s+1) if(seen[s]!=num[s]) $fatal(1,"missing writes note=%d seg=%d",n,s);
            end
        end
        if(ABORT_RESET)$display("PASS DMA reset recovery: abort during descriptor response, no output writes, restart and validate every note");
        $display("PASS DMA: all 53 suona/dizi notes, 8 tables, %0d elements match P64.BIN exactly",total);$finish;
    end
    initial begin #30000000;$fatal(1,"DMA timeout");end
endmodule
`default_nettype wire
