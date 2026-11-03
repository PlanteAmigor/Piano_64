`timescale 1ns/1ps
`default_nettype none
module tb_sd_longname;
    reg clk=0,rst=0;always #10 clk=~clk;
    wire ready;wire [7:0] name[0:51],len;
    sd_file_list_reader dut(.clk(clk),.rstn(rst),.op(1'b0),.read_file(12'd0),
        .sdclk(),.sdcmd(),.sddat0(1'b1),.list_name(name),.list_namelen(len),.list_en(ready));
    reg injected_valid=0;reg [8:0] address=0;reg [7:0] value=0;
    reg [7:0] entry[0:31];reg [7:0] expected[0:29];
    integer i,j,part,index,seen=0;
    task send_entry;
        begin
            for(j=0;j<32;j=j+1)begin @(negedge clk);injected_valid=1;address=j;value=entry[j];end
            @(negedge clk);injected_valid=0;
        end
    endtask
    function integer offset(input integer k);
        begin if(k<5)offset=1+k*2;else if(k<11)offset=14+(k-5)*2;else offset=28+(k-11)*2;end
    endfunction
    always @(negedge clk)if(ready)begin
        if(len!=30)$fatal(1,"long filename length %0d",len);
        for(integer x=0;x<30;x=x+1)if(name[x]!==expected[x])$fatal(1,"long filename byte %0d got%h expected%h",x,name[x],expected[x]);
        seen=seen+1;
    end
    initial begin
        for(i=0;i<26;i=i+1)expected[i]=65+i;
        expected[26]=".";expected[27]="B";expected[28]="I";expected[29]="N";
        force dut.filesystem_state=dut.LS_ROOT_FAT32;
        force dut.search_fat=0;force dut.rvalid=injected_valid;force dut.raddr=address;force dut.rdata=value;
        repeat(5)@(negedge clk);rst=1;
        for(part=3;part>=1;part=part-1)begin
            for(i=0;i<32;i=i+1)entry[i]=0;
            entry[0]=part|(part==3?64:0);entry[11]=15;
            for(i=0;i<13;i=i+1)begin
                index=(part-1)*13+i;
                if(index<30)begin entry[offset(i)]=expected[index];entry[offset(i)+1]=0;end
                else if(index==30)begin entry[offset(i)]=0;entry[offset(i)+1]=0;end
                else begin entry[offset(i)]=255;entry[offset(i)+1]=255;end
            end
            send_entry;
        end
        for(i=0;i<32;i=i+1)entry[i]=0;
        for(i=0;i<11;i=i+1)entry[i]=32;
        entry[0]="A";entry[8]="B";entry[9]="I";entry[10]="N";entry[11]=32;
        send_entry;repeat(5)@(negedge clk);
        if(seen!=1)$fatal(1,"missing filename publication %0d",seen);
        $display("PASS real FAT filename parser: three UTF-16 LFN entries, contiguous bytes, correct 30-byte name and one publication");$finish;
    end
    initial begin #100000;$fatal(1,"LFN timeout");end
endmodule
`default_nettype wire
