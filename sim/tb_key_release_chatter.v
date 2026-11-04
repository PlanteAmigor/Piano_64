`timescale 1ns/1ps
module tb_key_release_chatter;
reg clk=0,rst=0,key_n=1;always #10 clk=~clk;
wire p_fast,r_fast,s_fast,p_safe,r_safe,s_safe;
integer fast_p=0,fast_r=0,safe_p=0,safe_r=0;
key_scan #(.N(1),.DEBOUNCE(25000),.RELEASE_DEBOUNCE(100000),.IMMEDIATE(0)) current_keys(.clk(clk),.rst_n(rst),.key_in(key_n),.key_state(s_fast),.key_press(p_fast),.key_release(r_fast));
key_scan #(.N(1),.DEBOUNCE(25000),.RELEASE_DEBOUNCE(1000000),.IMMEDIATE(0)) longer_release(.clk(clk),.rst_n(rst),.key_in(key_n),.key_state(s_safe),.key_press(p_safe),.key_release(r_safe));
always @(negedge clk)if(rst)begin
 if(p_fast)fast_p=fast_p+1;if(r_fast)fast_r=fast_r+1;
 if(p_safe)safe_p=safe_p+1;if(r_safe)safe_r=safe_r+1;
end
initial begin
 repeat(8)@(negedge clk);rst=1;key_n=0;#1000000;
 // A 4ms contact opening while physically held; reclosure is not a new note.
 key_n=1;#4000000;key_n=0;#1000000;
 if(fast_p!=2 || fast_r!=1)$fatal(1,"expected current scanner false rearm not reproduced");
 if(safe_p!=1 || safe_r!=0 || !s_safe)$fatal(1,"longer release did not suppress chatter");
 key_n=1;#21000000;
 if(safe_p!=1 || safe_r!=1 || s_safe)$fatal(1,"true release stuck");
 $display("PASS reproducer: held contact opening for 4ms -> current 2ms release generates false note-off/note-on; 20ms release gives one press and one final release");$finish;
end
initial begin #40000000;$fatal(1,"timeout");end
endmodule
