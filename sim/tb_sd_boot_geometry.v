`timescale 1ns/1ps
module tb_sd_boot_geometry;
    reg clk=0,rst=0;always #10 clk=~clk;
    wire sdclk;tri cmd;
    reg valid=0,done=0;reg [8:0] address=0;reg [7:0] data=0;
    reg [7:0] image[0:511];
    sd_file_list_reader dut(.clk(clk),.rstn(rst),.sdclk(sdclk),.sdcmd(cmd),.sddat0(1'b1),.op(1'b0),.read_file(12'd0));
    integer n,i,seed=1080;
    reg fat16;reg [31:0] partition,spf,root,fatbase,rootdir,data_base,root_sector;
    reg [7:0] spc,nf;reg [15:0] reserve,items,count;
    initial begin
        force dut.rvalid=valid;force dut.raddr=address;force dut.rdata=data;force dut.read_done=done;
        for(n=0;n<256;n=n+1)begin
            rst=0;valid=0;done=0;repeat(4)@(negedge clk);rst=1;@(negedge clk);
            fat16=n[0];partition=$random(seed);spc=1<<($unsigned($random(seed))%8);
            nf=1+($unsigned($random(seed))%4);reserve=1+($unsigned($random(seed))%64);
            spf=fat16?1+($unsigned($random(seed))%65535):$unsigned($random(seed))|32'h00010000;
            root=2+($unsigned($random(seed))%100000);items=16*($unsigned($random(seed))%4096);
            for(i=0;i<512;i=i+1)image[i]=0;
            image[0]=8'heb;image[11]=0;image[12]=2;image[13]=spc;
            {image[15],image[14]}=reserve;image[16]=nf;{image[18],image[17]}=items;
            if(fat16){image[23],image[22]}=spf[15:0];
            else begin
                image[86]=8'h32;{image[39],image[38],image[37],image[36]}=spf;
                {image[47],image[46],image[45],image[44]}=root;
            end
            image[510]=8'h55;image[511]=8'haa;
            dut.filesystem_state=2;dut.read_sector_no=partition;
            // Consecutive bytes are faster than the actual native SD stream.
            for(i=0;i<512;i=i+1)begin valid=1;address=i;data=image[i];@(negedge clk);end
            valid=0;done=1;@(negedge clk);done=0;
            fatbase=partition+reserve;rootdir=fatbase+spf*nf;count=items>>4;
            data_base=rootdir+(fat16?count:0)-spc*2;
            root_sector=fat16?rootdir:data_base+spc*root;
            if(dut.first_fat_sector_no!==fatbase || dut.first_data_sector_no!==data_base || dut.read_sector_no!==root_sector || dut.filesystem_state!==(fat16?3'd3:3'd4))
                $fatal(1,"boot geometry n%0d FAT%0d fat%h/%h data%h/%h root%h/%h state%0d",n,fat16?16:32,dut.first_fat_sector_no,fatbase,dut.first_data_sector_no,data_base,dut.read_sector_no,root_sector,dut.filesystem_state);
            if(fat16 && (dut.rootdir_sector!==rootdir || dut.rootdir_sectorcount!==count))$fatal(1,"FAT16 root layout");
        end
        $display("PASS SD boot geometry: 256 independent FAT16/FAT32 BPBs, consecutive real byte writes, immediate completion, random partition/FAT/root-cluster geometry and 32-bit wrap");$finish;
    end
    initial begin #10000000;$fatal(1,"boot geometry timeout");end
endmodule
