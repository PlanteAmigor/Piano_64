`timescale 1ns/1ps
`default_nettype none
module tb_key_fast;
    reg clk=0,rst=0;always #10 clk=~clk;
    reg [7:0] raw=8'hff;
    wire [7:0] state,press,release_key,trig,gate;
    wire [55:0] notes;
    integer presses=0,releases=0,triggers=0;
    key_scan #(.N(8),.DEBOUNCE(25000),.RELEASE_DEBOUNCE(1000000),.IMMEDIATE(0)) keys(
        .clk(clk),.rst_n(rst),.key_in(raw),.key_state(state),.key_press(press),.key_release(release_key));
    // idle deliberately remains high during allocation, as it does before real
    // DMA/load completes. Gate must reserve every voice immediately.
    note_alloc #(.NKEY(8),.NVOICE(8)) alloc(
        .clk(clk),.rst_n(rst),.key_state(state),.key_enable(8'hff),
        .note_base(7'd60),.key_step(32'hcb975420),.key_vel({8{8'd255}}),
        .transpose(8'sd0),.v_idle(8'hff),.v_note(notes),.v_trig(trig),.v_gate(gate),.v_vel());
    always @(negedge clk)if(rst)for(integer i=0;i<8;i=i+1)begin
        if(press[i])presses=presses+1;
        if(release_key[i])releases=releases+1;
        if(trig[i])triggers=triggers+1;
    end
    time first_edge;
    task quiet;
        begin #1000;if(state!=0 || gate!=0)$fatal(1,"release stuck state=%h gate=%h",state,gate);end
    endtask
    initial begin
        repeat(8)@(negedge clk);rst=1;
        // Reject a 499us input spike on every key, including simultaneous EMI.
        raw=0;#499000;raw=8'hff;#10000;
        if(presses || triggers || state!=0)$fatal(1,"short press glitch accepted");
        first_edge=$time;raw=0;
        // A bounded train of contact bounce must produce exactly one chord.
        repeat(5)begin #100000;raw=8'hff;#100000;raw=0;end
        #501000;
        if(state!=8'hff || gate!=8'hff || presses!=8 || triggers!=8)
            $fatal(1,"chord lost/duplicated during delayed idle: state=%h gate=%h press=%d trig=%d",state,gate,presses,triggers);
        if($time-first_edge>=5000000)$fatal(1,"press >5ms");
        // Even 19.999ms of opening while held is insufficient to rearm.
        raw=8'hff;#19999000;raw=0;#501000;
        if(releases || triggers!=8 || gate!=8'hff)$fatal(1,"release chatter retriggered");
        raw=8'hff;first_edge=$time;#20001000;quiet;
        if($time-first_edge<20000000 || $time-first_edge>20005000 || releases!=8)$fatal(1,"release qualification");
        // Twelve very fast repeated chords; old 120/340ms timers would lose
        // these. Each 20.7ms cycle is independently debounced, not time-scaled.
        for(integer stroke=0;stroke<12;stroke=stroke+1)begin
            raw=0;#601000;
            if(gate!=8'hff || triggers!=16+stroke*8)$fatal(1,"rapid chord swallowed %d triggers=%d gate=%h",stroke,triggers,gate);
            raw=8'hff;#20101000;quiet;
        end
        if(presses!=104 || releases!=104 || triggers!=104)$fatal(1,"one stroke one edge failed");
        // Independent keys held, one released/repressed. No shared lock timer.
        raw=0;#601000;raw[7]=1;#20001000;
        if($countones(gate)!=7)$fatal(1,"one release disturbed chord");
        raw[7]=0;#601000;
        if(gate!=8'hff || triggers!=113)$fatal(1,"key7 rapid rearm lost");
        #5000000;
        if(triggers!=113)$fatal(1,"held key repeated");
        raw=8'hff;#20001000;quiet;
        $display("PASS performance keys at 50MHz: 499us glitches rejected, bounded bounce one chord, 19.999ms false releases rejected, 12 repeated 20.7ms chords, delayed-idle reservation, independent key7 rearm, long hold, final gates zero");
        $finish;
    end
    initial begin #400000000;$fatal(1,"timeout");end
endmodule
`default_nettype wire
