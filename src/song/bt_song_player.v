// v3 scheduler: synchronous event RAM, pipelined dispatch, independent ends.
// Score time is registered; allocation uses an 8-bit one-hot grant, never a
// time subtraction -> priority encoder -> variable-width bus write chain.
`default_nettype none
module bt_song_player #(
    parameter integer CLK_HZ=50000000, MAX_EVENTS=2048,
    parameter integer MULTI_ENABLED=0, TEACH_ENABLED=0, WINDOW_MS=150, START_DELAY_MS=3000
)(
    input wire clk, rst_n, start, stop, input wire [15:0] count,
    input wire [31:0] duration_ms, input wire [1:0] timbre,
    output reg [12:0] read_addr, input wire [63:0] read_data,
    output reg playing, overflow, output reg [31:0] position_ms,
    output reg [55:0] v_note, output reg [7:0] v_trig, v_gate,
    output reg [63:0] v_vel,
    input wire teach_mode, multi_mode,
    output reg [15:0] v_timbre,
    output reg [7:0] v_lead,
    output reg [1:0] lead_timbre,
    output wire signed [32:0] roll_time_ms,
    input wire [6:0] key_press, key_state,
    output reg [6:0] expected_keys, matched_keys,
    output wire [1:0] countdown,
    output reg [15:0] wrong_count, missed_count
);
    localparam integer MS_DIV=(CLK_HZ/1000 < 1) ? 1 : CLK_HZ/1000;
    localparam integer MS_CW=(MS_DIV<=2) ? 1 : $clog2(MS_DIV);
    reg [MS_CW-1:0] divider;
    reg [31:0] elapsed_ms, song_time;
    reg teaching;
    wire multi=(MULTI_ENABLED!=0)&&multi_mode;
    assign roll_time_ms=$signed({1'b0,elapsed_ms})-$signed({1'b0,delay_ms});
    wire ms_tick=divider==MS_DIV-1;
    wire [31:0] delay_ms=teaching ? START_DELAY_MS : 0;
    wire ready_time=elapsed_ms>=delay_ms;
    assign countdown=!playing || ready_time ? 0 :
        (delay_ms-elapsed_ms>2000 ? 3 : delay_ms-elapsed_ms>1000 ? 2 : 1);
    reg [15:0] event_index;
    reg [3:0] state;
    reg [63:0] event_word;
    wire [31:0] note_start=event_word[31:0];
    wire [1:0] event_timbre=multi ? {event_word[39],event_word[63]} : timbre;
    wire event_lead=!multi || !event_word[55];
    wire [15:0] event_duration=multi ? {1'b0,event_word[54:40]} : event_word[55:40];
    reg [31:0] note_end, note_absolute, early_open;
    reg [3:0] next_key;
    reg event_due, early_hit;
    reg [7:0] grant;
    reg [31:0] end_ms[0:7], start_ms[0:7], onset_absolute[0:7], late_close[0:7];
    reg [7:0] full_vel[0:7];
    reg [3:0] voice_key[0:7];
    reg [7:0] active, hit, expired, late_window, late_hit;
    reg [31:0] last_press[0:6], press_onset[0:6], latest_onset[0:6];
    reg [6:0] press_valid, press_used, press_expired, key_press_d;
    reg [31:0] press_deadline[0:6];
    reg [6:0] late_used;
    always @(*) begin
        late_used=0;
        for(integer a=0;a<7;a=a+1)
            for(integer b=0;b<8;b=b+1)
                if(active[b] && !expired[b] && late_hit[b] && voice_key[b]==a) late_used[a]=1;
    end
    wire [7:0] free_mask=(~active) & (multi ? (event_timbre<2 ? 8'h7f:8'h80) : (timbre<2 ? 8'hff:8'h01));
    wire [7:0] first_free=free_mask & (~free_mask+8'd1);
    integer i,k,wrong_delta,miss_delta;
    reg [7:0] target_vel;
    function [3:0] pitch_key;
        input [6:0] note;
        begin
            case(note%12)
                0:pitch_key=0; 2:pitch_key=1; 4:pitch_key=2;
                5:pitch_key=3; 7:pitch_key=4; 9:pitch_key=5;
                11:pitch_key=6; default:pitch_key=7;
            endcase
        end
    endfunction
    always @(*) begin
        expected_keys=0; matched_keys=0;
        for(integer j=0;j<8;j=j+1)
            if(playing && active[j] && voice_key[j]<7 && !expired[j]) begin
                expected_keys[voice_key[j]]=1;
                if(hit[j]) matched_keys[voice_key[j]]=1;
            end
        if(playing && state==5 && next_key<7 && elapsed_ms>=early_open && elapsed_ms<=note_absolute)
            expected_keys[next_key]=1;
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            v_timbre<=0;v_lead<=0;lead_timbre<=0;
            playing<=0; teaching<=0; overflow<=0; position_ms<=0; elapsed_ms<=0; song_time<=0;
            divider<=0; event_index<=0; state<=0; read_addr<=0; event_word<=0;
            note_end<=0;note_absolute<=0;early_open<=0;next_key<=7;event_due<=0;early_hit<=0;grant<=0;
            v_note<=0;v_trig<=0;v_gate<=0;v_vel<=0;active<=0;hit<=0;expired<=0;late_window<=0;late_hit<=0;
            press_valid<=0;press_used<=0;press_expired<=0;key_press_d<=0;wrong_count<=0;missed_count<=0;
            for(i=0;i<8;i=i+1) begin
                end_ms[i]<=0;start_ms[i]<=0;full_vel[i]<=0;voice_key[i]<=7;
                onset_absolute[i]<=0;late_close[i]<=0;
            end
            for(i=0;i<7;i=i+1) begin last_press[i]<=0;press_onset[i]<=0;latest_onset[i]<=0;press_deadline[i]<=0;end
        end else begin
            v_trig<=0;key_press_d<=key_press;
            for(k=0;k<7;k=k+1) press_expired[k]<=elapsed_ms>press_deadline[k];
            // One-cycle predicates keep 32-bit time arithmetic out of the
            // allocation and velocity paths. They settle long before a ms.
            event_due<=ready_time && note_start<=song_time;
            early_hit<=0;
            for(k=0;k<7;k=k+1)
                if(next_key==k && press_valid[k] && (!press_used[k] || press_onset[k]==note_start) &&
                   last_press[k]>=early_open && last_press[k]<=note_absolute) early_hit<=1;
            for(i=0;i<8;i=i+1) begin
                expired[i]<=end_ms[i]<=song_time;
                late_window[i]<=voice_key[i]<7 && last_press[voice_key[i]]>=onset_absolute[i] &&
                    last_press[voice_key[i]]<=late_close[i];
                late_hit[i]<=voice_key[i]<7 && !key_press[voice_key[i]] && !key_press_d[voice_key[i]] &&
                    press_valid[voice_key[i]] && late_window[i] &&
                    press_onset[voice_key[i]]==start_ms[i];
            end
            if(stop) begin
                playing<=0;position_ms<=0;elapsed_ms<=0;song_time<=0;divider<=0;
                v_gate<=0;v_vel<=0;active<=0;state<=0;
            end else if(start) begin
                playing<=count!=0 && count<=MAX_EVENTS;
                lead_timbre<=timbre;v_lead<=0;
                teaching<=TEACH_ENABLED!=0 && teach_mode;overflow<=count>MAX_EVENTS;
                position_ms<=0;elapsed_ms<=0;song_time<=0;divider<=0;event_index<=0;read_addr<=0;
                v_gate<=0;v_vel<=0;active<=0;hit<=0;press_valid<=0;press_used<=0;
                wrong_count<=0;missed_count<=0;
                state<=count!=0 && count<=MAX_EVENTS ? 1 : 0;
            end else if(playing) begin
                wrong_delta=0;miss_delta=0;
                if(ms_tick) begin
                    divider<=0;elapsed_ms<=elapsed_ms+1'b1;
                    if(ready_time) song_time<=song_time+1'b1;
                end else divider<=divider+1'b1;
                position_ms<=song_time;
                if(teaching) for(k=0;k<7;k=k+1) begin
                    if(key_press[k]) begin
                        last_press[k]<=elapsed_ms;press_valid[k]<=1;press_used[k]<=0;
                        press_deadline[k]<=elapsed_ms+WINDOW_MS;press_expired[k]<=0;
                        press_onset[k]<=latest_onset[k];
                    end
                    else if(press_valid[k] && press_expired[k]) begin
                        press_valid[k]<=0;
                        if(!press_used[k]) wrong_delta=wrong_delta+1;
                    end else if(late_used[k] && !key_press_d[k]) press_used[k]<=1;
                    if(state==6 && (|grant) && next_key==k) begin
                        latest_onset[k]<=note_start;
                        if(early_hit) begin press_used[k]<=1;press_onset[k]<=note_start;end
                    end
                end
                for(i=0;i<8;i=i+1) if(active[i]) begin
                    if(expired[i]) begin
                        active[i]<=0;v_gate[i]<=0;
                        if(teaching && voice_key[i]<7 && !hit[i]) miss_delta=miss_delta+1;
                    end else if(teaching && voice_key[i]<7) begin
                        // Press history also catches a key on the exact dispatch
                        // cycle. One press may serve only one score onset group.
                        if(late_hit[i]) hit[i]<=1;
                        if(hit[i] && !key_state[voice_key[i]]) v_gate[i]<=0;
                    end
                    target_vel=(!teaching || voice_key[i]==7 || hit[i]) ? full_vel[i] : full_vel[i]>>1;
                    if(ms_tick) begin
                        if(v_vel[i*8+:8]<target_vel)
                            v_vel[i*8+:8]<=target_vel-v_vel[i*8+:8]>8 ? v_vel[i*8+:8]+8'd8 : target_vel;
                        else if(v_vel[i*8+:8]>target_vel)
                            v_vel[i*8+:8]<=v_vel[i*8+:8]-target_vel>8 ? v_vel[i*8+:8]-8'd8 : target_vel;
                    end
                end
                case(state)
                    1:state<=2; // synchronous RAM address settle
                    2:begin event_word<=read_data;state<=3;end
                    3:begin
                        next_key<=event_lead?pitch_key(event_word[38:32]):7;
                        note_end<=note_start+{16'd0,event_duration};
                        note_absolute<=note_start+delay_ms;state<=4;
                    end
                    4:begin early_open<=note_absolute>WINDOW_MS ? note_absolute-WINDOW_MS : 0;state<=5;end
                    5:if(event_due) begin
                        if(note_end<=song_time) begin grant<=0;state<=6;end
                        else if(|free_mask) begin grant<=first_free;state<=6;end
                        else if(song_time>note_start+1) overflow<=1;
                    end
                    6:begin
                        for(i=0;i<8;i=i+1) if(grant[i]) begin
                            v_note[i*7+:7]<=event_word[38:32];
                            v_timbre[i*2+:2]<=event_timbre;v_lead[i]<=event_lead;
                            if(event_lead)lead_timbre<=event_timbre;
                            full_vel[i]<={event_word[62:56],1'b0};
                            v_vel[i*8+:8]<=teaching && next_key<7 && !early_hit ?
                                {1'b0,event_word[62:56]} : {event_word[62:56],1'b0};
                            voice_key[i]<=next_key;hit[i]<=!teaching || next_key==7 || early_hit;
                            active[i]<=1;expired[i]<=0;late_hit[i]<=0;v_gate[i]<=1;v_trig[i]<=1;
                            start_ms[i]<=note_start;end_ms[i]<=note_end;
                            onset_absolute[i]<=note_absolute;late_close[i]<=note_absolute+WINDOW_MS;
                        end
                        event_index<=event_index+1'b1;
                        if(event_index+1'b1>=count) state<=7;
                        else begin read_addr<=read_addr+1'b1;state<=1;end
                    end
                    default:;
                endcase
                wrong_count<=wrong_count+wrong_delta;missed_count<=missed_count+miss_delta;
                if(ready_time && song_time>=duration_ms && event_index>=count) begin
                    playing<=0;v_gate<=0;v_vel<=0;active<=0;state<=0;
                end
            end
        end
    end
endmodule
`default_nettype wire
