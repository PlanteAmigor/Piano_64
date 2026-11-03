// Native 1-bit SD sector service. Initialization/command transport follows the
// existing WangXuan95 reader; writes add CMD24, CRC16, DAT0 status/busy, CMD13.
// Own the card exclusively before releasing rst_n. A failed operation never
// retries a write automatically; its caller decides whether metadata is safe.
`default_nettype none
module sd_sector_rw #(
    parameter integer CLK_HZ=50000000, CLK_DIV=1, SIMULATE=0
)(
    input wire clk,rst_n,
    output wire sdclk,inout wire sdcmd,inout wire sddat0,
    input wire request,write_sector,input wire [31:0] sector,
    output wire ready,output reg done,output reg [7:0] error,
    output reg [8:0] waddr,input wire [7:0] wdata,
    output reg rvalid,output reg [8:0] raddr,output reg [7:0] rdata
);
    localparam integer FAST=1<<CLK_DIV,SLOW=FAST*(SIMULATE?2:48);
    localparam [3:0] I0=0,I8=1,I55=2,I41=3,I2=4,I3=5,I7=6,I16=7,
        READY=8,READ_CMD=9,READ_DATA=10,WRITE_CMD=11,WRITE_DATA=12,STATUS_CMD=13,STATUS_RESP=14;
    reg [3:0] state;
    reg cmd_start;reg [5:0] cmd;
    reg [31:0] arg;reg [15:0] clkdiv,precnt,rca;
    reg [1:0] card_type;reg [2:0] init_tries;
    wire cmd_busy,cmd_done,cmd_timeout,cmd_syntax;
    wire [31:0] response;
    sdcmd_ctrl u_cmd(.rstn(rst_n),.clk(clk),.sdclk(sdclk),.sdcmd(sdcmd),
        .clkdiv(clkdiv),.start(cmd_start),.precnt(precnt),.cmd(cmd),.arg(arg),
        .busy(cmd_busy),.done(cmd_done),.timeout(cmd_timeout),.syntaxe(cmd_syntax),.resparg(response));
    assign ready=state==READY && !cmd_busy;
    task automatic send(input [5:0] c,input [31:0] a,input [15:0] gap);
        begin cmd_start<=1;cmd<=c;arg<=a;precnt<=gap;end
    endtask
    wire data_done;wire [7:0] data_error;
    reg [31:0] watchdog;
    // Bounded even with a removed/unresponsive card. Reads/writes themselves
    // also have SD-clock deadlines below; this includes initialization.
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=I0;cmd_start<=0;cmd<=0;arg<=0;precnt<=0;clkdiv<=SLOW;
            rca<=0;card_type<=0;init_tries<=0;
            done<=0;error<=0;watchdog<=0;
        end else begin
            cmd_start<=0;done<=0;
            if(state==READY)watchdog<=0;else if(watchdog<CLK_HZ*2)watchdog<=watchdog+1'b1;
            if(state==READ_DATA || state==WRITE_DATA)begin
                if(data_done)begin
                    if(data_error!=0)begin error<=data_error;done<=1;state<=READY;end
                    else if(state==WRITE_DATA)state<=STATUS_CMD;
                    else begin error<=0;done<=1;state<=READY;end
                end
            end else if(!cmd_busy && !cmd_start)begin
                case(state)
                    I0:send(0,0,SIMULATE?512:64000);
                    I8:send(8,32'h1aa,512);
                    I55:send(55,0,512);
                    I41:send(41,32'h40100000,256);
                    I2:send(2,0,256);
                    I3:send(3,0,256);
                    I7:send(7,{rca,16'd0},256);
                    I16:send(16,512,SIMULATE?512:64000);
                    READY:if(request)begin
                        send(write_sector?24:17,card_type==3?sector:sector<<9,96);
                        error<=0;state<=write_sector?WRITE_CMD:READ_CMD;
                    end
                    STATUS_CMD:begin send(13,{rca,16'd0},96);state<=STATUS_RESP;end
                endcase
            end else if(cmd_done)begin
                case(state)
                    I0:state<=I8;
                    I8:if(!cmd_timeout && !cmd_syntax && response[7:0]==8'haa)state<=I55;
                       else if(cmd_timeout)begin
                           init_tries<=init_tries+1'b1;
                           if(init_tries==7)begin card_type<=1;state<=I55;end
                       end
                    I55:if(!cmd_timeout && !cmd_syntax)state<=I41;
                    I41:if(!cmd_timeout && !cmd_syntax && response[31])begin
                        card_type<=card_type==1?1:response[30]?3:2;state<=I2;
                    end else state<=I55;
                    I2:if(!cmd_timeout && !cmd_syntax)state<=I3;
                    I3:if(!cmd_timeout && !cmd_syntax)begin rca<=response[31:16];state<=I7;end
                    I7:if(!cmd_timeout && !cmd_syntax)begin clkdiv<=FAST;state<=I16;end
                    I16:if(!cmd_timeout && !cmd_syntax)state<=READY;
                    READ_CMD,WRITE_CMD:begin
                        if(cmd_timeout || cmd_syntax || (response & 32'hfdffe008)!=0)begin
                            error<=1;done<=1;state<=READY;
                        end else state<=state==READ_CMD?READ_DATA:WRITE_DATA;
                    end
                    STATUS_RESP:begin
                        error<=cmd_timeout || cmd_syntax || (response & 32'hfdffe008)!=0 ? 5:0;
                        done<=1;state<=READY;
                    end
                endcase
            end
            if(watchdog>=CLK_HZ*2)begin error<=6;done<=1;state<=READY;end
        end
    end

    function automatic [15:0] crc_bit(input [15:0] c,input b);
        begin crc_bit={c[14:0],1'b0}^((c[15]^b)?16'h1021:16'd0);end
    endfunction
    reg sd_last;
    wire rise=sdclk && !sd_last,fall=!sdclk && sd_last;
    localparam [3:0] WAIT=0,RDATA=1,RCRC=2,REND=3,WGAP=4,WSTART=5,WDATA=6,
        WCRC=7,WEND=8,WRELEASE=9,WACK0=10,WACK=11,WBUSY=12,TAIL=13,FINISH=14;
    reg [3:0] phase;
    reg [23:0] bit_count;
    reg [15:0] crc,received_crc;
    reg [7:0] tx_word;
    reg [3:0] token;
    reg dat_oe,dat_out;
    reg [7:0] transfer_error;
    assign sddat0=dat_oe?dat_out:1'bz;
    assign data_done=phase==FINISH;
    assign data_error=transfer_error;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            sd_last<=0;phase<=WAIT;bit_count<=0;crc<=0;received_crc<=0;
            tx_word<=0;token<=0;dat_oe<=0;dat_out<=1;transfer_error<=0;
            rvalid<=0;raddr<=0;rdata<=0;waddr<=0;
        end else begin
            sd_last<=sdclk;rvalid<=0;
            if(state!=READ_CMD && state!=READ_DATA && state!=WRITE_DATA)begin
                phase<=WAIT;bit_count<=0;crc<=0;received_crc<=0;
                dat_oe<=0;dat_out<=1;transfer_error<=0;waddr<=0;
            end else if(state==WRITE_DATA && phase==WAIT)begin phase<=WGAP;bit_count<=0;end
            else case(phase)
                WAIT:if(rise)begin
                    if(!sddat0)begin phase<=RDATA;bit_count<=0;crc<=0;end
                    else if(bit_count>=1000000)begin transfer_error<=2;phase<=FINISH;end
                    else bit_count<=bit_count+1'b1;
                end
                RDATA:if(rise)begin
                    rdata[7-bit_count[2:0]]<=sddat0;crc<=crc_bit(crc,sddat0);
                    if(bit_count[2:0]==7)begin rvalid<=1;raddr<=bit_count[11:3];end
                    if(bit_count==4095)begin phase<=RCRC;bit_count<=0;end
                    else bit_count<=bit_count+1'b1;
                end
                RCRC:if(rise)begin
                    received_crc<={received_crc[14:0],sddat0};
                    if(bit_count==15)begin phase<=REND;bit_count<=0;end
                    else bit_count<=bit_count+1'b1;
                end
                REND:if(rise)begin
                    if(received_crc!=crc || !sddat0)transfer_error<=3;
                    phase<=TAIL;bit_count<=0;
                end
                WGAP:if(fall)begin
                    if(bit_count==7)begin phase<=WSTART;bit_count<=0;end
                    else bit_count<=bit_count+1'b1;
                end
                WSTART:if(fall)begin dat_oe<=1;dat_out<=0;crc<=0;phase<=WDATA;end
                WDATA:if(fall)begin
                    if(bit_count[2:0]==0)begin
                        tx_word<=wdata;dat_out<=wdata[7];crc<=crc_bit(crc,wdata[7]);
                        if(bit_count<4088)waddr<=waddr+1'b1;
                    end else begin dat_out<=tx_word[7-bit_count[2:0]];crc<=crc_bit(crc,tx_word[7-bit_count[2:0]]);end
                    if(bit_count==4095)begin phase<=WCRC;bit_count<=0;end
                    else bit_count<=bit_count+1'b1;
                end
                WCRC:if(fall)begin
                    dat_out<=crc[15-bit_count[3:0]];
                    if(bit_count==15)begin phase<=WEND;bit_count<=0;end
                    else bit_count<=bit_count+1'b1;
                end
                WEND:if(fall)begin dat_out<=1;phase<=WRELEASE;end
                WRELEASE:if(fall)begin dat_oe<=0;phase<=WACK0;bit_count<=0;end
                WACK0:if(rise)begin
                    if(!sddat0)begin phase<=WACK;bit_count<=0;token<=0;end
                    else if(bit_count>=1000000)begin transfer_error<=4;phase<=FINISH;end
                    else bit_count<=bit_count+1'b1;
                end
                WACK:if(rise)begin
                    token<={token[2:0],sddat0};
                    if(bit_count==3)begin
                        if({token[2:0],sddat0}!=4'b0101)transfer_error<=4;
                        phase<=WBUSY;bit_count<=0;
                    end else bit_count<=bit_count+1'b1;
                end
                WBUSY:if(rise)begin
                    if(sddat0)begin phase<=TAIL;bit_count<=0;end
                    else if(bit_count>=12500000)begin transfer_error<=6;phase<=FINISH;end
                    else bit_count<=bit_count+1'b1;
                end
                TAIL:if(rise)begin
                    if(bit_count==63)phase<=FINISH;else bit_count<=bit_count+1'b1;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
