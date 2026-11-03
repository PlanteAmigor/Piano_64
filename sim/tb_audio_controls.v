`timescale 1ns/1ps
`default_nettype none
module tb_audio_controls;
    reg clk=0,rst_n=0,tick=0,art=0,stop_hold=0;
    always #10 clk=~clk;
    add_engine8 #(.NVOICE(1)) piano (
        .clk(clk),.rst_n(rst_n),.clk100(clk),.rst100_n(rst_n),
        .app_rdy(1'b0),.app_rd_data_valid(1'b0),.app_rd_data(256'd0),
        .v_note(7'd60),.v_trig(1'b0),.v_gate(1'b0),.v_vel(8'd96),
        .bend_q14(16'd16384),.vib_en(1'b0),.art_en(art),.stop_hold(stop_hold),
        .sustain(1'b0),.timbre(1'b0),.sample_tick(tick)
    );
    add_engine_harm #(.NVOICE(4),.SCORE_VELOCITY(1)) harm (
        .clk(clk),.rst_n(rst_n),.clk100(clk),.rst100_n(rst_n),
        .note_lo(7'd69),.note_hi(7'd96),.inf_base(8'd0),.desc_base(29'd69064),
        .app_rdy(1'b0),.app_rd_data_valid(1'b0),.app_rd_data(256'd0),
        .v_note(28'd69),.v_trig(4'd0),.v_gate(4'd0),.v_vel(32'd96),.score_mode(1'b1),
        .bend_q14(16'd16384),.trem_en(1'b0),.vib_pitch(1'b0),.vib_am(1'b0),
        .art_en(art),.stop_hold(stop_hold),.hand_on(1'b1),.opt_en(1'b0),.opt_vel(8'd0),
        .sustain(1'b0),.sample_tick(tick)
    );
    task sample;
        begin @(negedge clk);tick=1;@(negedge clk);tick=0;repeat(7) @(negedge clk);end
    endtask
    integer i;
    initial begin
        repeat(5) @(negedge clk);rst_n=1;repeat(5) @(negedge clk);
        if(harm.vel_all!==96) $fatal(1,"harmonic score velocity ignored");
        art=1;@(negedge clk);art=0;
        repeat(1600) @(negedge clk);
        if(piano.fm_hold!=1600 || harm.fm_hold!=1600 || harm.fm_g!=256)
            $fatal(1,"articulation duration/ramp must use samples, not system clocks");
        for(i=0;i<1600;i=i+1) begin
            sample;
            if(piano.fm_hold!=1599-i || harm.fm_hold!=1599-i) $fatal(1,"hold countdown %d",i);
            if(i==15 && harm.fm_g!=0) $fatal(1,"16-sample fade down");
        end
        repeat(16) sample;
        if(harm.fm_g!=256 || piano.mute_fast) $fatal(1,"16-sample recovery");
        stop_hold=1;repeat(25) sample;
        if(piano.fm_hold!=1000 || harm.fm_hold!=1200 || harm.fm_g!=0) $fatal(1,"sustained stop");
        stop_hold=0;
        $display("PASS audio controls: 1600-sample articulation, 16-sample ramps, sustained stop, harmonic score velocity");
        $finish;
    end
    initial begin #10000000;$fatal(1,"audio control timeout");end
endmodule
`default_nettype wire
