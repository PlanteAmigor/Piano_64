`timescale 1ns/1ps
`default_nettype none
module tb_key_scan_bounce;
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    reg [0:0] key_n=1;
    wire [0:0] safe_state,safe_press,safe_release;
    wire [0:0] old_state,old_press,old_release;
    integer safe_presses=0,safe_releases=0;
    integer old_presses=0,old_releases=0;
    always @(posedge clk) if(rst_n) begin
        if(safe_press[0]) safe_presses<=safe_presses+1;
        if(safe_release[0]) safe_releases<=safe_releases+1;
        if(old_press[0]) old_presses<=old_presses+1;
        if(old_release[0]) old_releases<=old_releases+1;
    end
    key_scan #(.N(1),.DEBOUNCE(8),.IMMEDIATE(0)) safe_keys (
        .clk(clk),.rst_n(rst_n),.key_in(key_n),.key_state(safe_state),
        .key_press(safe_press),.key_release(safe_release)
    );
    key_scan #(.N(1),.DEBOUNCE(8),.IMMEDIATE(1)) legacy_keys (
        .clk(clk),.rst_n(rst_n),.key_in(key_n),.key_state(old_state),
        .key_press(old_press),.key_release(old_release)
    );
    task cycles(input integer n); repeat(n) @(negedge clk); endtask
    initial begin
        cycles(3);rst_n=1;
        key_n=0;cycles(14);
        if(safe_state!=1 || safe_presses!=1) $fatal(1,"stable press not accepted once");
        // Contact briefly opens, closes long enough to fool the old press
        // path, then opens again. Old mode emits false release/press edges.
        key_n=1;cycles(3);key_n=0;cycles(12);key_n=1;cycles(3);
        if(safe_state!=1 || safe_releases!=0 || safe_presses!=1)
            $fatal(1,"release chatter reached stable key state");
        if(old_presses<2 || old_releases<1)
            $fatal(1,"legacy scan did not report false edges during release chatter");
        key_n=1;cycles(14);
        if(safe_state!=0 || safe_releases!=1 || safe_presses!=1)
            $fatal(1,"stable release was not exactly one release");
        key_n=0;cycles(14);
        if(safe_state!=1 || safe_presses!=2) $fatal(1,"next real press was lost");
        key_n=1;cycles(14);
        if(safe_state!=0 || safe_releases!=2) $fatal(1,"next real release was lost");
        $display("PASS piano key bounce: legacy scanner emits false release/retrigger; symmetric stable-edge debounce produces one press/release per physical stroke");
        $finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule
`default_nettype wire
