`timescale 1ns/1ps
`default_nettype none
// Exercise the actual add_top audio route, not a replacement tone generator.
// Only physical DDR/PLL are models. Startup image-ready and a stationary valid
// optical hand are preconditions; no forcing of PCM, DMA, attack or counters.
module tb_key_latency;
    parameter integer TIMBRE=0;
    parameter integer EFFECT=0;
    reg clk=0,rst=0; always #10 clk=~clk;
    reg [8:0] keys=9'h1ff;
    wire bck,lrck,din;
    add_top #(.STARTUP(8)) dut(
        .CLOCK_50(clk),.RESET_n(rst),.KEY_R1(keys),.KEY_R2(9'h1ff),
        .KEY_AUX(2'b11),.KEY0(1'b1),.BT_RX(1'b1),.SONG_UI_ACK(1'b0),
        .ADC_BUSY(1'b0),.ADC_DOUTA(1'b0),.ADC_DOUTB(1'b0),
        .AUD_BCK(bck),.AUD_LRCK(lrck),.AUD_DIN(din));
    initial begin
        force dut.ld_done=1'b1;
        force dut.ld_ok=1'b1;
        force dut.manual_timbre_r=TIMBRE;
        force dut.fx_r=EFFECT;
        force dut.opt_hand=1'b1;
        force dut.opt_en=1'b1;
        force dut.opt_vel=8'd255;
        force dut.opt_bend_q14=16'd16384;
        force dut.opt_stop=1'b0;
        force dut.opt_art=1'b0;
        force dut.opt_vib_en=1'b0;
        force dut.opt_trem_en=1'b0;
        // Model FPGA power-up zero initialization for effect RAMs.
        for(integer i=0;i<12288;i=i+1)dut.u_fx_reverb.cmem[i]=0;
        for(integer i=0;i<1792;i=i+1)begin
            dut.u_fx_reverb.amem_l[i]=0;dut.u_fx_reverb.amem_r[i]=0;
        end
    end
    integer phase=0,trigger_count=0,expected=1;
    reg [7:0] triggered=0,started=0,audible=0;
    reg measuring=0,got_dac=0;
    time raw_time,pcm_time=0,dac_time=0;
    real latency_us;
    integer harm_ticks=0;
    always @(negedge clk) if(rst && measuring) begin
        for(integer i=0;i<8;i=i+1)if(dut.v_trig[i])begin
            trigger_count=trigger_count+1;triggered[i]=1;
        end
        if(TIMBRE<2) begin
            if(trigger_count==expected && ((audible & triggered)==triggered) && pcm_time==0)
                pcm_time=$time;
        end else begin
            if(dut.u_harm.dma_done_p)begin started=1;harm_ticks=0;end
            if(started && dut.tick)harm_ticks=harm_ticks+1;
            if(trigger_count==expected && harm_ticks>=2 && dut.sua_l!=0 && pcm_time==0)
                pcm_time=$time;
        end
    end
    genvar g;
    generate for(g=0;g<8;g=g+1)begin:watch
        always @(negedge clk) if(rst && measuring && TIMBRE<2)begin
            if(dut.u_piano.vtrig_q[g])started[g]=1;
            if(started[g] && dut.u_piano.g_voice[g].u_v.ready &&
                !dut.u_piano.g_voice[g].u_v.loading && dut.u_piano.g_voice[g].u_v.sample!=0)
                audible[g]=1;
        end
        // Every cache write must follow fade completion. This catches the
        // otherwise audible old-envelope/new-parameter overwrite transient.
        always @(posedge dut.ddr_clk_x1)if(rst && dut.u_piano.g_voice[g].dma_we)begin
            if(!dut.u_piano.cache_safe[g] || dut.u_piano.g_voice[g].u_v.sample!==0)
                $fatal(1,"voice %0d cache overwritten before silent fade",g);
        end
    end endgenerate
    // Independent I2S receiver observes the actual DAC pins. Wait four sample
    // frames after all newly loaded voices produce PCM, including output FX.
    reg prev_lr=0,active=0;reg [15:0] word=0;integer bits=0;
    always @(posedge bck)begin
        if(!rst)begin active=0;prev_lr=lrck;bits=0;end
        else if(lrck!=prev_lr)begin prev_lr=lrck;bits=0;word=0;active=1;end
        else if(active && bits<16)begin
            word={word[14:0],din};bits=bits+1;
            if(bits==16 && !lrck && measuring && pcm_time!=0 &&
                $time>=pcm_time+81920 && word!=0 && !got_dac)begin
                got_dac=1;dac_time=$time;
                latency_us=($time-raw_time)/1000.0;
                $display("MEASURE timbre=%0d effect=%0d phase=%0d triggers=%0d pcm_us=%.3f dac_us=%.3f",TIMBRE,EFFECT,phase,trigger_count,(pcm_time-raw_time)/1000.0,latency_us);
                $fflush();
                if($time-raw_time>5000000)$fatal(1,"5ms DAC latency exceeded");
            end
        end
    end
    task begin_measure(input integer n);
        begin
            measuring=0;@(negedge clk);
            phase=phase+1;expected=n;trigger_count=0;triggered=0;
            started=0;audible=0;pcm_time=0;dac_time=0;got_dac=0;
            raw_time=$time;measuring=1;
        end
    endtask
    task finish_measure;
        begin
            // Explicit finite deadline, including failures that never emit PCM.
            fork:deadline
                begin wait(got_dac);end
                begin #(5000020-($time-raw_time));$fatal(1,"no new DAC output within 5ms timbre=%0d phase=%0d count=%0d started=%h audible=%h",TIMBRE,phase,trigger_count,started,audible);end
            join_any
            disable deadline;
            #200000;
            if(trigger_count!=expected)$fatal(1,"unexpected retrigger count %d expected %d",trigger_count,expected);
            measuring=0;
        end
    endtask
    integer nkeys;
    initial begin
        repeat(12)@(negedge clk);rst=1;
        // Allow hand gain/reset/clock-domain synchronizers to settle.
        #100000;
        begin_measure(1);keys[0]=0;
        // 0.6ms bounded bounce before final stable closure.
        repeat(3)begin #100000;keys[0]=1;#100000;keys[0]=0;end
        finish_measure;
        #3000000; // reach normal/full optical velocity, without bypassing ramp
        keys=9'h1ff;#20200000;
        if(dut.note_key_state!=0 || dut.v_gate!=0)$fatal(1,"release stuck");
        begin_measure(1);keys[0]=0;finish_measure;
        keys=9'h1ff;#20200000;
        if(TIMBRE<2)begin
            nkeys=TIMBRE==1?6:8;
            begin_measure(nkeys);keys[7:0]=0;finish_measure;
            #3000000;keys=9'h1ff;#20200000;
            // Reuse all tails well before the old 340ms quarantine expires.
            begin_measure(nkeys);keys[7:0]=0;finish_measure;
        end else begin
            begin_measure(1);keys[7]=0;finish_measure;
        end
        keys=9'h1ff;#20200000;
        if(dut.note_key_state!=0 || dut.v_gate!=0)$fatal(1,"final release stuck");
        $display("PASS full key latency timbre=%0d effect=%0d: raw pin -> real P64/DDR arbiter -> synthesis/limiter/effects -> complete DAC word, each <=5ms; rearm, chord, safe tail reuse",TIMBRE,EFFECT);
        $finish;
    end
    initial begin #200000000;$fatal(1,"global timeout");end
endmodule
`default_nettype wire
