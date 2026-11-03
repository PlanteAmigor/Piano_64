`timescale 1ns/1ps
`default_nettype none
module tb_song_keys;
    parameter integer LEGACY=0;
    // One cycle represents one millisecond of the menu's configured clock.
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    reg next_n=1,confirm_n=1;
    wire ns,cs,req;
    wire [3:0] selected;
    wire [2:0] menu;
    wire teaching;
    generate if(LEGACY) begin:g_old
        wire [1:0] state;
        key_scan #(.N(2),.DEBOUNCE(20),.IMMEDIATE(1)) keys (
            .clk(clk),.rst_n(rst_n),.key_in({confirm_n,next_n}),
            .key_state(state),.key_press(),.key_release()
        );
        assign {cs,ns}=state;
    end else begin:g_new
        song_menu_keys #(.CLK_HZ(1000)) keys (
            .clk(clk),.rst_n(rst_n),.next_n(next_n),.confirm_n(confirm_n),
            .next_state(ns),.confirm_state(cs)
        );
    end endgenerate
    song_system #(.CLK_HZ(1000)) dut (
        .clk(clk),.clk_sd(clk),.rst_n(rst_n),.guide(1'b1),
        .next_state(ns),.confirm_state(cs),.key_press(7'd0),.key_state(7'd0),
        .sd_count(5'd4),.sd_ids(128'h04030201),.sd_catalog_done(1'b1),
        .sd_begin(1'b0),.sd_end(1'b0),.sd_error(1'b0),.sd_byte(8'd0),.sd_byte_valid(1'b0),
        .request_toggle(req),.selected(selected),.menu_state(menu),.teaching(teaching)
    );
    task wait_ms(input integer ms);
        repeat(ms) @(negedge clk);
    endtask
    task level(input integer key,input reg pressed,input integer ms);
        begin
            if(key==0) next_n=!pressed;else confirm_n=!pressed;
            wait_ms(ms);
        end
    endtask
    task bouncing_click(input integer key);
        begin
            level(key,1,23);level(key,0,5);level(key,1,23);level(key,0,5);
            level(key,1,80);
            level(key,0,23);level(key,1,23);level(key,0,5);level(key,1,5);
            level(key,0,80);
        end
    endtask
    task clean_click(input integer key);
        begin level(key,1,60);level(key,0,60);end
    endtask
    initial begin
        wait_ms(8);rst_n=1;wait_ms(60);
        bouncing_click(0);
        if(selected!=1) $fatal(1,"one bounced NEXT skipped songs: selected=%0d",selected);
        // Holding NEXT never auto-repeats; another physical click still works.
        level(0,1,1200);
        if(selected!=1) $fatal(1,"held NEXT repeated before release");
        level(0,0,60);
        if(selected!=2) $fatal(1,"held NEXT release must act once");
        clean_click(0);clean_click(0);
        if(selected!=0) $fatal(1,"two separate rapid clicks or wrap lost");
        // A short isolated glitch is not a click on either menu key.
        level(0,1,23);level(0,0,60);level(1,1,23);level(1,0,60);
        if(selected!=0 || menu!=0) $fatal(1,"idle glitch activated menu");
        bouncing_click(1);
        if(menu!=1 || req) $fatal(1,"one CONFIRM both selected and started song");
        bouncing_click(0);
        if(!teaching || menu!=1) $fatal(1,"mode changed twice on bounced NEXT");
        // Long BACK fires while held; bouncing release must not re-confirm.
        level(1,1,900);
        if(menu!=0) $fatal(1,"long BACK did not return");
        level(1,0,23);level(1,1,23);level(1,0,80);
        if(menu!=0 || req) $fatal(1,"long release generated short CONFIRM");
        clean_click(1);bouncing_click(1);
        if(menu!=2 || !req) $fatal(1,"start request not issued exactly once");
        $display("PASS menu physical keys: press/release bounce, one click one action, no held repeat, rapid clicks, glitches, mode/start, long BACK release");
        $finish;
    end
    initial begin #2000000;$fatal(1,"menu key timeout");end
endmodule
`default_nettype wire
