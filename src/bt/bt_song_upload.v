// BT36 v3 endpoint: CRC-validated upload, duplicate suppression, SD commit and ACK.
// END success is delayed until persistent storage and catalog refresh complete.
// PLAY/STOP use a bundled-data toggle mailbox into the existing score player.
// All logic runs on clk; song RAM is independent of the DDR timbre image.
`default_nettype none
module bt_song_upload #(parameter integer CLK_HZ=50000000, BAUD=115200, MAX_EVENTS=2048, RX_TIMEOUT_MS=2000)(
    input wire clk, rst_n, rx, output wire tx,
    input wire source_ready, input wire [1:0] current_timbre,
    input wire playing,dropped,input wire [31:0] position,
    output reg command_toggle, output reg command_play,
    input wire command_reply,input wire [7:0] command_error,
    output reg save_start,input wire save_done,input wire [7:0] save_error,
    output wire [15:0] file_size,
    input wire stream_start,stream_ready,output wire stream_valid,output wire [7:0] stream_data,
    output reg [1:0] song_timbre,output reg song_valid,uploading,
    output reg [15:0] accepted_count,output reg [7:0] last_error
);
    wire [7:0] rx_byte;
    wire rx_valid, rx_error;
    bt_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_rx(
        .clk(clk),.rst_n(rst_n),.rx(rx),.data(rx_byte),.valid(rx_valid),.framing_error(rx_error));
    reg consume;
    reg [8:0] payload_addr;
    wire [7:0] payload_data, frame_error, frame_type, frame_seq;
    wire [15:0] frame_length, frame_crc;
    wire frame_valid;
    bt_frame_rx #(.CLK_HZ(CLK_HZ),.TIMEOUT_MS(RX_TIMEOUT_MS)) u_frame(
        .clk(clk),.rst_n(rst_n),.byte_data(rx_byte),.byte_valid(rx_valid),.byte_error(rx_error),
        .consume(consume),.payload_addr(payload_addr),.payload_data(payload_data),
        .valid(frame_valid),.error_code(frame_error),.frame_type(frame_type),.seq(frame_seq),
        .length(frame_length),.frame_crc(frame_crc));

    reg [63:0] song_ram[0:MAX_EVENTS-1];
    reg ram_write;
    reg [10:0] write_addr;
    reg [63:0] write_word,read_word;
    wire [10:0] read_addr;
    always @(posedge clk) begin
        if(ram_write) song_ram[write_addr]<=write_word;
        read_word<=song_ram[read_addr];
    end
    reg allow_drop,multi_mode;
    reg [15:0] expected_count;
    reg [31:0] song_duration, previous_start;
    song_file_encode u_encoder(.clk(clk),.rst_n(rst_n),.start(stream_start),
        .count(expected_count),.duration_ms(song_duration),.timbre(song_timbre),
        .flags({multi_mode,6'd0,allow_drop}),.read_addr(read_addr),.read_data(read_word),
        .valid(stream_valid),.ready(stream_ready),.data(stream_data),.done(),.file_size(file_size));

    wire [1:0] report_timbre=(song_valid || uploading) ? song_timbre : current_timbre;
    wire [7:0] voices=(report_timbre<2) ? 8 : 1;
    wire [7:0] note_lo=(report_timbre==0) ? 21 : (report_timbre==1) ? 38 : (report_timbre==2) ? 69 : 67;
    wire [7:0] note_hi=(report_timbre==0) ? 108 : (report_timbre==1) ? 86 : (report_timbre==2) ? 96 : 91;

    localparam IDLE=0, HEADER=1, DISPATCH=2, COPY=3, CHECK=4, NEXT_EVENT=5,
               ACK_WAIT=6, ACK_BUILD=7, ACK_SEND=8, ACK_DRAIN=9, RELEASE=10, SAVE_WAIT=11, COMMAND_WAIT=12;
    reg [3:0] state;
    reg [31:0] command_timer;
    reg [63:0] header, event_word;
    reg [3:0] header_index, header_bytes, byte_index;
    reg [5:0] event_index, frame_events;
    reg [7:0] status;
    reg [31:0] check_end[0:7];
    integer chosen, i;
    wire [31:0] event_start=event_word[31:0];
    wire [7:0] event_note=multi_mode?{1'b0,event_word[38:32]}:event_word[39:32];
    wire [1:0] event_timbre=multi_mode?{event_word[39],event_word[63]}:song_timbre;
    wire [7:0] event_lo=event_timbre==0?21:event_timbre==1?38:event_timbre==2?69:67;
    wire [7:0] event_hi=event_timbre==0?108:event_timbre==1?86:event_timbre==2?96:91;
    wire [15:0] event_duration=multi_mode?{1'b0,event_word[54:40]}:event_word[55:40];
    wire [7:0] event_velocity=multi_mode?{1'b0,event_word[62:56]}:event_word[63:56];
    wire [32:0] event_end={1'b0,event_start}+{17'd0,event_duration};
    always @(*) begin
        chosen=-1;
        for(integer j=7;j>=0;j=j-1)
            if((multi_mode?(event_timbre<2?j<7:j==7):(song_timbre<2 || j==0)) && check_end[j]<=event_start) chosen=j;
    end

    // Cache only the immediately previous successful request for safe retries.
    reg last_valid;
    reg [7:0] last_type, last_seq;
    reg [15:0] last_crc;
    wire duplicate=last_valid && last_type==frame_type && last_seq==frame_seq && last_crc==frame_crc;
    reg [111:0] ack_payload;
    reg [15:0] ack_crc;
    reg [4:0] ack_index;
    reg [7:0] tx_byte;
    reg tx_send;
    wire tx_busy;
    bt_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_tx(
        .clk(clk),.rst_n(rst_n),.data(tx_byte),.send(tx_send),.tx(tx),.busy(tx_busy));
    reg [7:0] ack_byte;
    always @(*) begin
        case(ack_index)
            0: ack_byte=8'ha5;
            1: ack_byte=8'h5a;
            2: ack_byte=3;
            3: ack_byte=8'h80;
            4: ack_byte=frame_seq;
            5: ack_byte=14;
            6: ack_byte=0;
            21: ack_byte=ack_crc[7:0];
            22: ack_byte=ack_crc[15:8];
            default: ack_byte=ack_payload[(ack_index-7)*8+:8];
        endcase
    end
    function [15:0] crc_byte;
        input [15:0] c; input [7:0] b;
        reg [15:0] x; integer k;
        begin x=c^{b,8'd0}; for(k=0;k<8;k=k+1) x=x[15] ? (x<<1)^16'h1021 : x<<1; crc_byte=x; end
    endfunction

    always @(posedge clk) begin
        if(!rst_n) begin
            command_timer<=0;state<=IDLE; consume<=0; payload_addr<=0; header<=0; event_word<=0;
            header_index<=0; header_bytes<=0; byte_index<=0; event_index<=0; frame_events<=0;
            song_valid<=0; uploading<=0; allow_drop<=0; expected_count<=0; accepted_count<=0;
            song_duration<=0; previous_start<=0; song_timbre<=0; multi_mode<=0; last_error<=0;
            command_toggle<=0;command_play<=0;save_start<=0; ram_write<=0; write_addr<=0; write_word<=0;
            status<=0; last_valid<=0; last_type<=0; last_seq<=0; last_crc<=0;
            ack_payload<=0; ack_crc<=16'hffff; ack_index<=0; tx_byte<=0; tx_send<=0;
            for(i=0;i<8;i=i+1) check_end[i]<=0;
        end else begin
            consume<=0; save_start<=0; ram_write<=0; tx_send<=0;
            if(state==COMMAND_WAIT)command_timer<=command_timer+1'b1;else command_timer<=0;
            case(state)
                IDLE: if(frame_valid) begin
                    status<=0; header<=0; header_index<=0; payload_addr<=0;
                    header_bytes<=(frame_length>8) ? 8 : frame_length[3:0];
                    if(frame_error!=0) begin status<=frame_error; state<=ACK_WAIT; end
                    else if(duplicate) state<=ACK_WAIT;
                    else begin last_valid<=0; state<=(frame_length==0) ? DISPATCH : HEADER; end
                end
                HEADER: begin
                    header[header_index*8+:8]<=payload_data;
                    if(header_index+1>=header_bytes) state<=DISPATCH;
                    else begin header_index<=header_index+1'b1; payload_addr<=payload_addr+1'b1; end
                end
                DISPATCH: begin
                    state<=ACK_WAIT;
                    case(frame_type)
                        8'h01: begin
                            if(frame_length!=8) status<=2;
                            else if(header[15:0]==0 || header[15:0]>MAX_EVENTS) status<=4;
                            else if(header[47:16]==0 || header[47:16]>86400000 || header[55:48]>3 || (header[63:56]&8'h7e)!=0) status<=5;
                            else begin
                                command_play<=0;command_toggle<=~command_toggle;state<=COMMAND_WAIT;
                                song_valid<=0; uploading<=1; accepted_count<=0;last_error<=0;
                                expected_count<=header[15:0]; song_duration<=header[47:16];
                                song_timbre<=header[49:48]; multi_mode<=header[63]; allow_drop<=header[56]; previous_start<=0;
                                for(i=0;i<8;i=i+1) check_end[i]<=0;
                            end
                        end
                        8'h02: begin
                            if(!uploading) status<=3;
                            else if(frame_length<10 || frame_length>258 || (frame_length-2)%8!=0) begin status<=2; uploading<=0; end
                            else if(header[15:0]!=accepted_count) begin status<=7;uploading<=0;end
                            else if(accepted_count+(frame_length-2)/8>expected_count) begin status<=4; uploading<=0; end
                            else begin
                                frame_events<=(frame_length-2)/8; event_index<=0; byte_index<=0;
                                event_word<=0; payload_addr<=2; state<=COPY;
                            end
                        end
                        8'h03: begin
                            if(frame_length!=2) status<=2;
                            else if(!uploading || header[15:0]!=expected_count || accepted_count!=expected_count) status<=3;
                            else begin save_start<=1;state<=SAVE_WAIT;end
                        end
                        8'h10: begin
                            if(frame_length!=0) status<=2;
                            else if(!song_valid || uploading) status<=3;
                            else if(!source_ready) status<=6;
                            else begin command_play<=1;command_toggle<=~command_toggle;state<=COMMAND_WAIT;end
                        end
                        8'h11: begin if(frame_length!=0) status<=2; else begin command_play<=0;command_toggle<=~command_toggle;state<=COMMAND_WAIT;end end
                        8'h12: if(frame_length!=0) status<=2;
                        default: status<=11;
                    endcase
                end
                COPY: begin
                    event_word[byte_index*8+:8]<=payload_data;
                    if(payload_addr<257) payload_addr<=payload_addr+1'b1;
                    if(byte_index==7) state<=CHECK; else byte_index<=byte_index+1'b1;
                end
                CHECK: begin
                    if(event_note<event_lo || event_note>event_hi || event_duration==0 ||
                       event_velocity==0 || event_velocity>127 || event_end>{1'b0,song_duration} ||
                       ((accepted_count!=0 || event_index!=0) && event_start<previous_start)) begin
                        status<=5; uploading<=0; state<=ACK_WAIT;
                    end else if(chosen<0 && (!allow_drop || multi_mode)) begin status<=9; uploading<=0; state<=ACK_WAIT; end
                    else begin
                        write_addr<=accepted_count+event_index; write_word<=event_word; ram_write<=1;
                        previous_start<=event_start;
                        if(chosen>=0) check_end[chosen]<=event_end[31:0];
                        state<=NEXT_EVENT;
                    end
                end
                NEXT_EVENT: begin
                    if(event_index+1>=frame_events) begin accepted_count<=accepted_count+frame_events; state<=ACK_WAIT; end
                    else begin event_index<=event_index+1'b1; byte_index<=0; event_word<=0; state<=COPY; end
                end
                SAVE_WAIT:if(save_done)begin
                    uploading<=0;song_valid<=save_error==0;
                    status<=save_error==0?0:3;last_error<=save_error;state<=ACK_WAIT;
                end
                COMMAND_WAIT:begin
                    if(command_reply==command_toggle)begin status<=command_error;state<=ACK_WAIT;end
                    else if(command_timer>=(CLK_HZ/1000)*4500)begin
                        command_play<=0;command_toggle<=~command_toggle;status<=3;state<=ACK_WAIT;
                    end
                end
                ACK_WAIT: state<=ACK_BUILD; // allow player/control state to settle before snapshot
                ACK_BUILD: begin
                    if(status!=0)last_error<=status;
                    ack_payload[7:0]<=frame_type;
                    ack_payload[15:8]<=status;
                    ack_payload[31:16]<=accepted_count;
                    ack_payload[39:32]<={3'd0,dropped,uploading,playing,song_valid,source_ready};
                    ack_payload[47:40]<={6'd0,report_timbre};
                    ack_payload[55:48]<=voices; ack_payload[63:56]<=note_lo; ack_payload[71:64]<=note_hi;
                    ack_payload[87:72]<=MAX_EVENTS;
                    ack_payload[111:88]<=(position>32'hffffff) ? 24'hffffff : position[23:0];
                    ack_crc<=16'hffff; ack_index<=0; state<=ACK_SEND;
                    if(status==0) begin last_valid<=1; last_type<=frame_type; last_seq<=frame_seq; last_crc<=frame_crc; end
                end
                ACK_SEND: if(!tx_busy && !tx_send) begin
                    tx_byte<=ack_byte; tx_send<=1;
                    if(ack_index<21) ack_crc<=crc_byte(ack_crc,ack_byte);
                    if(ack_index==22) state<=ACK_DRAIN; else ack_index<=ack_index+1'b1;
                end
                ACK_DRAIN: if(!tx_busy && !tx_send) begin consume<=1; state<=RELEASE; end
                RELEASE: if(!frame_valid) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
