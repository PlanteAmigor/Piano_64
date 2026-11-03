// SD transport, dual-clock event RAM, teaching player and two-key menu.
// The SD reader owns clk_sd; all playback/control state lives in clk.
`default_nettype none
module song_system #(
    parameter integer CLK_HZ=50000000, LONG_MS=800, SETTLE_MS=1,
    parameter integer PREPARE_MS=3000
)(
    input wire clk, clk_sd, rst_n, guide,
    input wire next_state, confirm_state,
    input wire remote_toggle,remote_play,remote_allowed,
    input wire [7:0] remote_id,
    output reg remote_reply,output reg [7:0] remote_error,
    output reg remote_active,
    input wire [6:0] key_press, key_state,
    input wire [4:0] sd_count,
    input wire [127:0] sd_ids,
    input wire sd_catalog_done, sd_begin, sd_end, sd_error,
    input wire [7:0] sd_byte,
    input wire sd_byte_valid,
    output reg request_toggle,
    output reg [3:0] selected,
    output wire [55:0] v_note,
    output wire [15:0] v_timbre,
    output wire [7:0] v_lead,
    output wire multi_score,
    output wire [31:0] score_duration,
    output reg [1023:0] roll_preview,
    output reg [10:0] progress,
    output wire [7:0] v_trig, v_gate,
    output wire [63:0] v_vel,
    output wire playing,dropped,
    output wire [1:0] timbre,
    output wire score_valid,
    output reg [2:0] menu_state,
    output reg teaching,
    output wire [6:0] expected_keys, matched_keys,
    output wire [1:0] countdown,
    output wire [31:0] position_ms,
    output wire [15:0] wrong_count, missed_count,
    output reg [7:0] error_code,
    output reg [4:0] file_count,
    output wire catalog_ready,
    output reg [127:0] file_ids
);
    localparam integer MS_DIV=CLK_HZ/1000;
    localparam integer MW=MS_DIV<=2 ? 1 : $clog2(MS_DIV);
    localparam [2:0] LIST=0, MODE=1, LOAD=2, RUN=3, ERROR=4;
    reg [MW-1:0] ms_div;
    wire ms_tick=ms_div==MS_DIV-1;
    reg next_d, confirm_d, long_fired;
    reg [15:0] hold_ms;
    wire next_short=next_d && !next_state;
    wire confirm_short=confirm_d && !confirm_state && !long_fired;
    wire confirm_long=confirm_state && !long_fired && hold_ms>=LONG_MS;
    reg play_start, play_stop, playing_d;
    reg [1:0] cat_sync;
    assign catalog_ready=cat_sync[1];
    reg [2:0] remote_sync;
    reg remote_seen,remote_pending,guide_d;
    integer remote_match;
    always @(*)begin
        remote_match=-1;
        for(integer n=15;n>=0;n=n-1)
            if(n<file_count && file_ids[n*8+:8]==remote_id)remote_match=n;
    end
    reg [2:0] begin_sync, end_sync;
    reg [1:0] err_sync;
    reg [1:0] sd_reset;
    reg fifo_overflow, begin_sd_d;
    wire fifo_full, fifo_empty, fifo_inc, fifo_valid;
    wire [7:0] fifo_data;
    reg receiving, eof_seen;
    reg [3:0] reset_wait;
    reg [15:0] quiet_ms;
    wire loader_rst_n=rst_n && reset_wait==0;
    wire fifo_read=receiving && reset_wait==0;
    always @(posedge clk_sd) begin
        sd_reset <= {sd_reset[0],!rst_n};
        begin_sd_d <= sd_begin;
        if(sd_reset[1] || sd_begin!=begin_sd_d) fifo_overflow<=0;
        else if(sd_byte_valid && fifo_full) fifo_overflow<=1;
    end
    sd_async_fifo #(.AW(9)) u_transport (
        .wclk(clk_sd),.wrst(sd_reset[1]),.win(sd_byte_valid),.wdata(sd_byte),.wfull(fifo_full),
        .rclk(clk),.rrst(!rst_n),.ren(fifo_read),.rdata(fifo_data),
        .rinc(fifo_inc),.rinc_d(fifo_valid),.rempty(fifo_empty)
    );
    reg [1:0] ov_sync;
    wire ram_we, loader_busy, loader_idle,allow_drop;
    wire [10:0] ram_waddr;
    wire [63:0] ram_wdata;
    wire [15:0] count;
    wire [31:0] duration_ms;
    wire [1:0] file_timbre,player_timbre;
    wire signed [32:0] roll_time;
    assign score_duration=duration_ms;
    assign timbre=multi_score && playing ? player_timbre:file_timbre;
    wire [7:0] loader_error;
    song_loader #(.CLK_HZ(CLK_HZ)) u_loader (
        .clk(clk),.rst_n(loader_rst_n),.byte_data(fifo_data),.byte_valid(fifo_valid),
        .byte_error(ov_sync[1]),.ram_we(ram_we),.ram_waddr(ram_waddr),.ram_wdata(ram_wdata),
        .song_valid(score_valid),.song_count(count),.song_duration(duration_ms),.song_timbre(file_timbre),.song_multi(multi_score),.song_allow_drop(allow_drop),
        .err_code(loader_error),.busy(loader_busy),.frame_hit(),.stream_idle(loader_idle)
    );
    reg [63:0] events[0:2047];
    wire [12:0] read_addr;
    reg [63:0] read_data;
    always @(posedge clk) begin
        if(ram_we) events[ram_waddr]<=ram_wdata;
        else read_data<=events[read_addr[10:0]];
    end
    wire player_overflow;
    assign dropped=player_overflow;
    bt_song_player #(.CLK_HZ(CLK_HZ),.MAX_EVENTS(2048),.MULTI_ENABLED(1),.TEACH_ENABLED(1),.START_DELAY_MS(PREPARE_MS)) u_player (
        .clk(clk),.rst_n(rst_n),.start(play_start),.stop(play_stop),.count(count),
        .duration_ms(duration_ms),.timbre(file_timbre),.read_addr(read_addr),.read_data(read_data),
        .playing(playing),.overflow(player_overflow),.position_ms(position_ms),
        .v_note(v_note),.v_trig(v_trig),.v_gate(v_gate),.v_vel(v_vel),
        .teach_mode(teaching),.multi_mode(multi_score),.v_timbre(v_timbre),.v_lead(v_lead),.lead_timbre(player_timbre),.roll_time_ms(roll_time),.key_press(key_press),.key_state(key_state),
        .expected_keys(expected_keys),.matched_keys(matched_keys),.countdown(countdown),
        .wrong_count(wrong_count),.missed_count(missed_count)
    );
    // Independent synchronous display port: playback never waits for rendering.
    // Port B shares the loaded score with playback port A.
    reg [10:0] preview_addr;
    reg [63:0] preview_data, preview_word;
    always @(posedge clk) begin
        preview_data<=events[preview_addr];
    end
    reg [3:0] scan_state;
    reg publish_preview;
    reg [15:0] scan_index;
    reg [5:0] sprite_count;
    reg [1023:0] sprite_work;
    reg signed [32:0] scan_time, delta_start, delta_end;
    reg signed [15:0] clipped_start,clipped_end;
    reg [10:0] sprite_top,sprite_bottom;
    reg visible_note;
    wire [15:0] preview_duration=multi_score ? {1'b0,preview_word[54:40]}:preview_word[55:40];
    wire [1:0] preview_timbre=multi_score ? {preview_word[39],preview_word[63]}:file_timbre;
    wire preview_lead=!multi_score || !preview_word[55];
    function [3:0] preview_lane;
        input [6:0] n;
        begin
            case(n%12)
                0:preview_lane=0;2:preview_lane=1;4:preview_lane=2;5:preview_lane=3;
                7:preview_lane=4;9:preview_lane=5;11:preview_lane=6;default:preview_lane=7;
            endcase
        end
    endfunction
    wire [3:0] lane=preview_lane(preview_word[38:32]);
    wire preview_hit=preview_lead && lane<7 && delta_start<=0 && delta_end>0 && matched_keys[lane];
    always @(posedge clk) begin
        if(!rst_n) begin
            scan_state<=0;scan_index<=0;sprite_count<=0;sprite_work<=0;roll_preview<=0;publish_preview<=0;
            preview_addr<=0;preview_word<=0;scan_time<=0;delta_start<=0;delta_end<=0;
            clipped_start<=0;clipped_end<=0;sprite_top<=0;sprite_bottom<=0;visible_note<=0;
        end else if(!playing) begin scan_state<=0;roll_preview<=0;publish_preview<=0;end
        else begin
            publish_preview<=0;
            if(publish_preview)roll_preview<=sprite_work;
            case(scan_state)
            0:if(ms_tick)begin
                scan_index<=0;preview_addr<=0;sprite_count<=0;sprite_work<=0;scan_time<=roll_time;scan_state<=1;
            end
            1:scan_state<=2;
            2:begin preview_word<=preview_data;scan_state<=3;end
            3:begin
                delta_start<=$signed({1'b0,preview_word[31:0]})-scan_time;
                delta_end<=$signed({1'b0,preview_word[31:0]})+$signed({17'd0,preview_duration})-scan_time;
                scan_state<=4;
            end
            4:begin
                visible_note<=delta_start<3040 && delta_end> -80;
                clipped_start<=delta_start>3040?16'sd3040:delta_start< -80? -16'sd80:delta_start[15:0];
                clipped_end<=delta_end>3040?16'sd3040:delta_end< -80? -16'sd80:delta_end[15:0];
                scan_state<=5;
            end
            5:begin
                sprite_top<=16'sd864-($signed(clipped_end)/16'sd5);
                sprite_bottom<=16'sd864-($signed(clipped_start)/16'sd5);
                scan_state<=6;
            end
            6:begin
                if(visible_note && sprite_count<32)begin
                    sprite_work[sprite_count*32+:32]<={1'b1,preview_lead,preview_hit,preview_timbre,lane,
                        sprite_top,sprite_bottom,1'b0};
                    sprite_count<=sprite_count+1'b1;
                end
                scan_state<=7;
            end
            7:if(scan_index+1>=count || sprite_count==32)begin publish_preview<=1;scan_state<=0;end
              else begin scan_index<=scan_index+1'b1;preview_addr<=preview_addr+1'b1;scan_state<=1;end
            default:scan_state<=0;
        endcase
        end
    end
    // Restoring division, one bit/cycle. No wide combinational divider in UI.
    reg [41:0] progress_dividend,progress_quotient;
    reg [32:0] progress_remainder;
    reg [31:0] progress_denominator;
    reg [5:0] progress_left;
    wire [32:0] remainder_next={progress_remainder[31:0],progress_dividend[41]};
    wire progress_ge=remainder_next>={1'b0,progress_denominator};
    wire [41:0] quotient_next={progress_quotient[40:0],progress_ge};
    always @(posedge clk)begin
        if(!rst_n)begin progress<=0;progress_left<=0;progress_dividend<=0;progress_quotient<=0;
            progress_remainder<=0;progress_denominator<=1;end
        else if(ms_tick && progress_left==0)begin
            if(!score_valid || duration_ms==0)progress<=0;
            else if(position_ms>=duration_ms)progress<=1024;
            else begin
                progress_dividend<={position_ms,10'd0};progress_quotient<=0;progress_remainder<=0;
                progress_denominator<=duration_ms;progress_left<=42;
            end
        end else if(progress_left!=0)begin
            progress_dividend<={progress_dividend[40:0],1'b0};progress_quotient<=quotient_next;
            progress_remainder<=progress_ge?remainder_next-{1'b0,progress_denominator}:remainder_next;
            progress_left<=progress_left-1'b1;
            if(progress_left==1)progress<=quotient_next[10:0];
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            guide_d<=0;remote_sync<=0;remote_seen<=0;remote_pending<=0;remote_active<=0;remote_reply<=0;remote_error<=0;
            ms_div<=0; next_d<=0; confirm_d<=0; long_fired<=0; hold_ms<=0;
            cat_sync<=0; begin_sync<=0; end_sync<=0; err_sync<=0; ov_sync<=0;
            file_count<=0; file_ids<=0; selected<=0; request_toggle<=0;
            menu_state<=LIST; teaching<=0; play_start<=0; play_stop<=0; playing_d<=0;
            receiving<=0; eof_seen<=0; reset_wait<=4'd8; quiet_ms<=0; error_code<=0;
        end else begin
            guide_d<=guide;remote_sync<={remote_sync[1:0],remote_toggle};
            cat_sync<={cat_sync[0],sd_catalog_done};
            begin_sync<={begin_sync[1:0],sd_begin}; end_sync<={end_sync[1:0],sd_end};
            err_sync<={err_sync[0],sd_error}; ov_sync<={ov_sync[0],fifo_overflow};
            if(cat_sync[1]) begin file_count<=sd_count; file_ids<=sd_ids; end
            if(ms_tick) ms_div<=0; else ms_div<=ms_div+1'b1;
            next_d<=next_state; confirm_d<=confirm_state; playing_d<=playing;
            play_start<=0; play_stop<=0;
            if(!confirm_state) hold_ms<=0;
            else if(!confirm_d) begin long_fired<=0; hold_ms<=0; end
            else if(ms_tick && hold_ms<LONG_MS) hold_ms<=hold_ms+1'b1;
            if(confirm_long) long_fired<=1;
            if(reset_wait!=0) reset_wait<=reset_wait-1'b1;
            if(begin_sync[2]!=begin_sync[1]) begin
                receiving<=1; eof_seen<=0; quiet_ms<=0; reset_wait<=8;
            end
            if(end_sync[2]!=end_sync[1]) eof_seen<=1;
            // End-of-file is not end-of-parse. Drain both FIFOs and allow the
            // parser to consume its last frame before deciding success.
            if(receiving && eof_seen) begin
                if(!fifo_empty || fifo_valid || loader_busy) quiet_ms<=0;
                else if(ms_tick) begin
                    if(quiet_ms<SETTLE_MS+1) quiet_ms<=quiet_ms+1'b1;
                    else begin
                        receiving<=0;
                        if(menu_state==LOAD && (guide || remote_active)) begin
                            if(score_valid && loader_idle && loader_error==0 && !err_sync[1] && !ov_sync[1]) begin
                                play_start<=1; menu_state<=RUN; error_code<=0;
                                if(remote_pending)begin remote_reply<=remote_seen;remote_error<=0;remote_pending<=0;end
                            end else begin
                                menu_state<=ERROR;
                                if(remote_pending)begin remote_reply<=remote_seen;remote_error<=3;remote_pending<=0;remote_active<=0;end
                                error_code<=loader_error!=0 ? loader_error : 8'd3;
                            end
                        end
                    end
                end
            end
            if(!guide && !remote_active) begin
                menu_state<=LIST; play_stop<=1;
            end else begin
                case(menu_state)
                    LIST: begin
                        if(next_short && file_count!=0)
                            selected<=selected+1 >= file_count ? 0 : selected+1'b1;
                        if(confirm_short && file_count!=0 && !receiving) menu_state<=MODE;
                    end
                    MODE: begin
                        if(next_short) teaching<=!teaching;
                        if(confirm_long) menu_state<=LIST;
                        else if(confirm_short && !receiving) begin
                            request_toggle<=~request_toggle; error_code<=0; menu_state<=LOAD;
                        end
                    end
                    LOAD: if(confirm_long) begin
                        menu_state<=MODE;play_stop<=1;remote_active<=0;
                        if(remote_pending)begin remote_reply<=remote_seen;remote_error<=3;remote_pending<=0;end
                    end
                    RUN: begin
                        if(confirm_short || confirm_long || (playing_d && !playing)) begin
                            play_stop<=1; menu_state<=MODE;remote_active<=0;
                        end
                        if(player_overflow && !allow_drop) begin remote_active<=0;play_stop<=1; error_code<=9; menu_state<=ERROR; end
                    end
                    ERROR: if(confirm_short || confirm_long) menu_state<=LIST;
                    default:menu_state<=LIST;
                endcase
            end
            if(remote_active && guide_d && !guide)begin
                play_stop<=1;remote_active<=0;menu_state<=LIST;
                if(remote_pending)begin remote_reply<=remote_seen;remote_error<=3;remote_pending<=0;end
            end
            if(remote_sync[2]!=remote_seen)begin
                remote_seen<=remote_sync[2];play_stop<=1;remote_pending<=0;remote_error<=0;
                if(!remote_play)begin
                    remote_active<=0;remote_reply<=remote_sync[2];menu_state<=LIST;
                end else if(!remote_allowed || !cat_sync[1] || remote_match<0 || receiving)begin
                    remote_error<=!remote_allowed?8'd6:8'd3;remote_reply<=remote_sync[2];remote_active<=0;
                end else begin
                    selected<=remote_match;teaching<=0;remote_active<=1;remote_pending<=1;
                    request_toggle<=~request_toggle;error_code<=0;menu_state<=LOAD;
                end
            end
        end
    end
endmodule
`default_nettype wire
