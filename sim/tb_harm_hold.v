`timescale 1ns/1ps
`default_nettype none
// Real P64 DMA and PCM synthesis. Fast-forward only the long attack and idle
// sample spacing; all prefetch/harmonic pipeline clocks run unchanged.
module tb_harm_hold;
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    reg [7:0] image[0:1127967];
    initial $readmemh("work/song_checks/image_bytes.hex",image);
    reg [6:0] note=69,lo=69,hi=96;
    reg [7:0] inf=0;
    reg [28:0] base=69064;
    reg [3:0] trig=0,gate=0;
    reg hand=1,score=0,sustain=0;
    reg [15:0] bend=16384;
    wire en;wire [28:0] addr;
    reg pending=0,valid=0;
    reg [28:0] saved;
    reg [255:0] data;
    integer delay=0,j,requests=0;
    always @(posedge clk) begin
        valid<=0;
        if(en && !pending) begin saved<=addr;pending<=1;delay<=3;requests=requests+1;end
        else if(pending && delay!=0) delay<=delay-1;
        else if(pending) begin
            for(j=0;j<32;j=j+1) data[j*8+:8]<=image[(saved<<2)+j];
            valid<=1;pending<=0;
        end
    end
    wire signed [15:0] pcm;
    add_engine_harm #(.NVOICE(4),.SCORE_VELOCITY(1)) dut (
        .clk(clk),.rst_n(rst_n),.clk100(clk),.rst100_n(rst_n),
        .note_lo(lo),.note_hi(hi),.inf_base(inf),.desc_base(base),
        .v_note({21'd0,note}),.v_trig(trig),.v_gate(gate),.v_vel(32'd220),.score_mode(score),
        .bend_q14(bend),.trem_en(1'b0),.vib_pitch(1'b0),.vib_am(1'b0),
        .art_en(1'b0),.stop_hold(1'b0),.hand_on(hand),.opt_en(1'b1),.opt_vel(8'd180),
        .sustain(sustain),.sample_tick(dut.cnt==0),.sample_l(pcm),
        .app_en(en),.app_addr(addr),.app_rdy(!pending),.app_rd_data_valid(valid),.app_rd_data(data)
    );
    // The real scheduler is done well before cycle 200 (max 62 harmonics).
    // Remove only the unused 824 clocks between audio samples.
    task sample;
        begin
            wait(dut.cnt==200);@(negedge clk);dut.cnt=1023;
            @(negedge clk);@(negedge clk);
        end
    endtask
    integer inst,n,k,nonzero,reads_before,phase_changes,pcm_min,pcm_max;
    reg [18:0] last_phase;
    reg signed [15:0] saved_step;
    reg signed [63:0] before_dmt,after_dmt;
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        for(inst=0;inst<2;inst=inst+1) begin
            lo=inst==0?69:67;hi=inst==0?96:91;inf=inst==0?0:112;
            base=inst==0?69064:176352;
            for(n=lo;n<=hi;n=n+1) begin
                note=n;gate=1;hand=1;score=0;bend=16384;
                @(negedge clk);trig=1;@(negedge clk);trig=0;
                wait(dut.dma_done_p);repeat(3) @(negedge clk);
                // Approach the default steady-state boundary using real tables.
                wait(dut.cnt==200);@(negedge clk);
                dut.v_ts[0]=dut.HOLD_SAMPLES-64;
                dut.v_clock[0]=dut.HOLD_SAMPLES-64;
                repeat(80) sample;
                if(dut.v_step[0]<=0 || dut.v_ts[0]!=dut.HOLD_SAMPLES)
                    $fatal(1,"no sustained oscillator inst=%d note=%d step=%d age=%d",inst,n,dut.v_step[0],dut.v_ts[0]);
                saved_step=dut.v_step[0];reads_before=requests;
                // Beyond the former 5s cutoff, with the original gate still high.
                @(negedge clk);dut.v_clock[0]=488281;
                nonzero=0;phase_changes=0;pcm_min=32767;pcm_max=-32768;last_phase=dut.v_pf[0];
                for(k=0;k<128;k=k+1) begin
                    sample;
                    if(pcm===16'bx) $fatal(1,"unknown PCM");
                    if(pcm!=0) nonzero=nonzero+1;
                    if(pcm<pcm_min) pcm_min=pcm;
                    if(pcm>pcm_max) pcm_max=pcm;
                    if(dut.v_pf[0]!=last_phase) phase_changes=phase_changes+1;
                    last_phase=dut.v_pf[0];
                    if(!dut.v_act[0] || dut.v_step[0]!=saved_step || requests!=reads_before)
                        $fatal(1,"held note stopped or retriggered inst=%d note=%d",inst,n);
                end
                if(nonzero<100 || phase_changes<120 || pcm_min>=0 || pcm_max<=0)
                    $fatal(1,"silent/frozen sustained PCM inst=%d note=%d nonzero=%d changes=%d",inst,n,nonzero,phase_changes);
                // Live optical pitch control must still reach the carrier.
                bend=18432;repeat(3) sample;
                if(dut.dphi_s2<=saved_step) $fatal(1,"held bend ignored");
                // At the 29-bit clock wrap, dm phase must be continuous modulo one turn.
                @(negedge clk);dut.v_clock[0]=29'h1fffffff;
                force dut.dq_vo=0;
                force dut.s1_DM=16'sd123;
                #1;before_dmt=dut.s1_dmt;
                dut.v_clock[0]=0;#1;after_dmt=dut.s1_dmt;
                if(((after_dmt-before_dmt)&524287)!=((123*11+511)/1024))
                    $fatal(1,"dm phase jumped at wrap");
                release dut.s1_DM;
                release dut.dq_vo;
                dut.v_clock[0]=29'h1fffffff;sample;
                if(dut.v_clock[0]!=0) $fatal(1,"phase clock did not wrap");
                // No hand must mute; returning hand resumes this same held note.
                if(n==lo) begin
                    hand=0;repeat(20) sample;
                    if(dut.fm_g!=0 || pcm!=0) $fatal(1,"hand removal did not mute");
                    hand=1;repeat(1230) sample;
                    if(dut.fm_g!=256 || !dut.v_act[0] || requests!=reads_before) $fatal(1,"hand return retrigger/stall");
                end
                score=n%2;
                if(n==lo) begin
                    sustain=1;gate=0;repeat(64) sample;
                    if(!dut.v_act[0] || dut.rel_gain>=255) $fatal(1,"sustain tail lost");
                    @(negedge clk);dut.rel_gain=0;sample;
                    sustain=0;
                end
                gate=0;repeat(20) sample;
                if(dut.v_act[0]) $fatal(1,"score/manual gate release ignored");
                repeat(512) sample;
                if(pcm!=0) $fatal(1,"release did not settle to zero");
            end
        end
        $display("PASS harmonic hold: all 53 real P64 notes, steady boundary, >10s age, nonzero moving PCM, live bend, clock wrap, hand mute/resume, gate release; no DMA retrigger");
        $finish;
    end
    initial begin #1000000000;$fatal(1,"hold timeout");end
endmodule
`default_nettype wire
