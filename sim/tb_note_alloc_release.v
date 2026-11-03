`timescale 1ns/1ps
`default_nettype none
module tb_note_alloc_release;
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    reg [7:0] keys=0;
    wire [7:0] gate,trig;
    wire [55:0] notes;
    wire [63:0] vel;
    integer triggers=0;
    always @(posedge clk) if(rst_n)
        for(integer i=0;i<8;i=i+1) if(trig[i]) triggers<=triggers+1;
    note_alloc #(.NKEY(8),.NVOICE(8)) dut (
        .clk(clk),.rst_n(rst_n),.key_state(keys),.key_enable(8'hff),
        .note_base(7'd60),.key_step(32'hcb975420),.key_vel({8{8'd128}}),
        .transpose(8'sd0),.v_idle(~gate),.v_note(notes),.v_trig(trig),.v_gate(gate),.v_vel(vel)
    );
    initial begin
        repeat(4) @(negedge clk);rst_n=1;keys=8'hff;
        repeat(40) @(negedge clk);
        if(gate!==8'hff || triggers!=8) $fatal(1,"eight keys not allocated once: gate=%h triggers=%0d",gate,triggers);
        keys=8'h7f;
        repeat(24) @(negedge clk);
        if(gate!==8'h7f) $fatal(1,"last physical key release stuck: gate=%h expected 7f",gate);
        if(triggers!=8) $fatal(1,"release retriggered a voice");
        keys=0;repeat(24) @(negedge clk);
        if(gate!==0) $fatal(1,"release all must clear every voice gate: %h",gate);
        $display("PASS note allocator: all eight keys allocate once, key 7 releases independently, all gates clear on release");
        $finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule
`default_nettype wire
