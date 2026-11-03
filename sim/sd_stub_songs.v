// Behavioral file-service model. It exercises the loader's SD-host interface;
// it does not claim to simulate SD electrical signalling or FAT sectors.
`default_nettype none
module sd_file_list_reader #(
    parameter [2:0] CLK_DIV=1, parameter SIMULATE=0
)(
    input wire rstn,clk,output wire sdclk,inout wire sdcmd,input wire sddat0,
    input wire op,input wire [11:0] read_file,output reg [2:0] done,
    output wire [3:0] card_stat,output wire [1:0] card_type,filesystem_type,
    output reg file_found,output reg [7:0] list_name[0:51],
    output reg [7:0] list_namelen,output reg [11:0] list_file_num,
    output reg list_en,outen,output reg [7:0] outbyte,
    output wire debug_read_done,output wire [31:0] debug_read_sector_no,
    output wire debug_filesystem_state
);
    assign sdclk=0;assign sdcmd=1'bz;assign card_stat=8;assign card_type=3;
    assign filesystem_type=3;assign debug_read_done=0;assign debug_read_sector_no=0;
    assign debug_filesystem_state=0;
    integer state=0,timer=0,idx=0,fd=0,c,j,nbyte;
    reg inject_bad=0;
    reg [79:0] name;
    always @(posedge clk) begin
        if(!rstn) begin
            state<=0;timer<=0;idx<=0;done<=0;list_en<=0;outen<=0;file_found<=0;nbyte<=0;
            if(fd!=0) begin $fclose(fd);fd=0;end
        end else begin
            list_en<=0;outen<=0;
            case(state)
                0:begin
                    if(!op) state<=1;
                    else begin
                        case(read_file)
                            1:fd=$fopen("work/song_checks/P64.BIN","rb");
                            2:fd=$fopen("tools/generated/SONG04.BIN","rb");
                            4:fd=$fopen("tools/generated/SONG01.BIN","rb");
                            5:fd=$fopen("tools/generated/SONG02.BIN","rb");
                            6:fd=$fopen("tools/generated/SONG03.BIN","rb");
                            default:fd=0;
                        endcase
                        file_found<=fd!=0;state<=fd!=0 ? 2 : 3;
                    end
                end
                1:begin
                    timer<=timer+1;
                    if(timer==8) begin
                        timer<=0;
                        case(idx)
                            0:begin name={"P64.BIN",24'd0};list_namelen<=7;list_file_num<=1;end
                            1:begin name="SONG04.BIN";list_namelen<=10;list_file_num<=2;end
                            2:begin name="OTHER0.TXT";list_namelen<=10;list_file_num<=3;end
                            3:begin name="SONG01.BIN";list_namelen<=10;list_file_num<=4;end
                            4:begin name="SONG02.BIN";list_namelen<=10;list_file_num<=5;end
                            default:begin name="SONG03.BIN";list_namelen<=10;list_file_num<=6;end
                        endcase
                        for(j=0;j<52;j=j+1) list_name[j]<=j<10 ? name[(9-j)*8+:8] : 0;
                        list_en<=1;idx<=idx+1;
                        if(idx==5) begin done<=1;state<=3;end // last entry and done same cycle
                    end
                end
                2:begin
                    if(timer!=0) timer<=timer-1;
                    else begin
                        c=$fgetc(fd);
                        if(c<0) begin $fclose(fd);fd=0;done<=1;state<=3;end
                        else begin
                            outbyte<=inject_bad && read_file!=1 && nbyte==15 ? c[7:0]^8'h01 : c[7:0];
                            outen<=1;nbyte<=nbyte+1;timer<=31;
                        end
                    end
                end
                3:done<=1;
            endcase
        end
    end
endmodule
`default_nettype wire
