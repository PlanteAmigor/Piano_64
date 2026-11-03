// Absolute millisecond scheduling. Equal timestamps remain polyphonic.
// A dedicated allocator avoids physical-key debounce/scale mapping.
`default_nettype none
module bt_song_player #(parameter integer CLK_HZ=50000000, MAX_EVENTS=8192)(
    input wire clk, rst_n, start, stop, input wire [15:0] count,
    input wire [31:0] duration_ms, input wire [1:0] timbre,
    output reg [12:0] read_addr, input wire [63:0] read_data,
    output reg playing, overflow, output reg [31:0] position_ms,
    output reg [55:0] v_note, output reg [7:0] v_trig, v_gate,
    output reg [63:0] v_vel
);
    localparam integer MS_CW=(CLK_HZ/1000<=2) ? 1 : $clog2(CLK_HZ/1000);
    reg [MS_CW-1:0] divider;
    reg [15:0] event_index;
    reg [2:0] state;
    reg [63:0] event_word;
    reg [31:0] end_ms[0:7];
    integer i, chosen;
    wire [31:0] note_start=event_word[31:0];
    wire [15:0] note_duration=event_word[55:40];
    wire [7:0] note_velocity=event_word[63:56];
    wire [31:0] note_end=note_start+{16'd0,note_duration};
    always @(*) begin
        chosen=-1;
        for(integer j=7;j>=0;j=j-1)
            if((timbre<2 || j==0) && (!v_gate[j] || end_ms[j]<=position_ms)) chosen=j;
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            playing<=0; overflow<=0; position_ms<=0; divider<=0; event_index<=0;
            state<=0; read_addr<=0; event_word<=0; v_note<=0; v_trig<=0; v_gate<=0; v_vel<=0;
            for(i=0;i<8;i=i+1) end_ms[i]<=0;
        end else begin
            v_trig<=0;
            if(stop) begin playing<=0; position_ms<=0; divider<=0; v_gate<=0; state<=0; end
            else if(start) begin
                playing<=1; overflow<=0; position_ms<=0; divider<=0; event_index<=0;
                read_addr<=0; v_gate<=0; state<=1;
                for(i=0;i<8;i=i+1) end_ms[i]<=0;
            end else if(playing) begin
                if(divider==CLK_HZ/1000-1) begin divider<=0; position_ms<=position_ms+1'b1; end
                else divider<=divider+1'b1;
                for(i=0;i<8;i=i+1)
                    if(v_gate[i] && end_ms[i]<=position_ms) v_gate[i]<=0;
                case(state)
                    1: state<=2; // synchronous song RAM address latency
                    2: begin event_word<=read_data; state<=3; end
                    3: if(note_start<=position_ms) begin
                        // Already expired notes are never emitted as a stale retrigger.
                        if(note_end>position_ms) begin
                            if(chosen<0) overflow<=1;
                            else begin
                                v_note[chosen*7+:7]<=event_word[38:32];
                                v_vel[chosen*8+:8]<={note_velocity[6:0],1'b0};
                                v_gate[chosen]<=1; v_trig[chosen]<=1; end_ms[chosen]<=note_end;
                            end
                        end
                        event_index<=event_index+1'b1;
                        if(event_index+1'b1>=count) state<=4;
                        else begin read_addr<=read_addr+1'b1; state<=1; end
                    end
                    default: ;
                endcase
                if(position_ms>=duration_ms && event_index>=count) begin playing<=0; v_gate<=0; state<=0; end
            end
        end
    end
endmodule
`default_nettype wire
