`timescale 1ns/1ps
module tb_ui_controls;
    reg clk=0,resetn=0;always #3.367 clk=~clk;
    hdmi_ui3_top dut(.CLK_SCOPE(clk),.clk(clk),.resetn(resetn),.BANDS(256'd0),.BANDS_TICK(1'b0),.UI_INFO(19'd0),
        .SONG_UI(384'd0),.SONG_ROLL(1024'd0),.SONG_UI_TOGGLE(1'b0),.COMP_AMP(512'd0),
        .SCOPE_SMP(16'sd0),.SCOPE_TOG(1'b0),.SCOPE_TRG(1'b0));
    integer n;
    always @(negedge clk)if(dut.local_rst_n!=={8{dut.rst_n}})$fatal(1,"local reset cycle mismatch");
    initial begin
        repeat(20)@(negedge clk);resetn=1;wait(dut.rst_n);@(negedge clk);
        force dut.fading_out=1;force dut.fade_lvl=8;
        dut.fade_cnt=0;
        for(n=1;n<=118800;n=n+1)begin
            @(negedge clk);
            if(dut.fade_cnt!==(n%118800))$fatal(1,"fade counter n%0d got%0d",n,dut.fade_cnt);
            // Stop precisely with a pending chunk carry, then resume. The
            // lookahead registers must hold with the counter in the idle path.
            if(n==63 || n==4095)begin
                force dut.fading_out=0;force dut.fade_lvl=15;
                repeat(5)begin
                    @(negedge clk);
                    if(dut.fade_cnt!==n)$fatal(1,"fade idle hold n%0d got%0d",n,dut.fade_cnt);
                end
                force dut.fading_out=1;force dut.fade_lvl=8;
            end
        end
        release dut.fade_lvl;release dut.fading_out;
        resetn=0;repeat(4)@(negedge clk);resetn=1;repeat(24)@(negedge clk);
        if(dut.page_show!==0 || dut.fade_lvl!==15)$fatal(1,"UI reset state");
        $display("PASS UI controls: every fade count through all carry boundaries and exact 118800-cycle wrap, idle/resume at both pending carry boundaries; eight local resets cycle-identical before/after reset");$finish;
    end
    initial begin #2000000;$fatal(1,"UI controls timeout");end
endmodule
