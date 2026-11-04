`include "src/hdmi/ui_video_mode.vh"
`timescale 1ns/1ps
module tb_video_pll;
    reg clk=0;always #10 clk=~clk;
    wire lock,pix,ser;
    Gowin_PLL_720P dut(.clkin(clk),.lock(lock),.clkout0(pix),.clkout1(ser));
    real reference_period,pixel_period,serial_period;
    realtime start_reference,start_pixel,start_serial;
    initial begin
        wait(lock);repeat(20)@(posedge pix);
        fork
`ifndef UI_VIDEO_1080P_SINGLE
            begin @(posedge dut.ref_clk);start_reference=$realtime;repeat(100)@(posedge dut.ref_clk);reference_period=($realtime-start_reference)/100.0;end
`endif
            begin @(posedge pix);start_pixel=$realtime;repeat(100)@(posedge pix);pixel_period=($realtime-start_pixel)/100.0;end
            begin @(posedge ser);start_serial=$realtime;repeat(500)@(posedge ser);serial_period=($realtime-start_serial)/500.0;end
        join
`ifdef UI_VIDEO_1080P_SINGLE
`ifdef UI_VIDEO_1080P_HALF
        if(pixel_period<13.32 || pixel_period>13.35 || serial_period<2.66 || serial_period>2.68)
`else
        if(pixel_period<6.65 || pixel_period>6.68 || serial_period<1.32 || serial_period>1.35)
`endif
            $fatal(1,"single PLL periods pixel=%f serial=%f",pixel_period,serial_period);
        $display("PASS vendor single PLL model: lock and phase-related pixel/serializer periods %f %f ns",pixel_period,serial_period);$finish;
`else
        if(reference_period<36.35 || reference_period>36.38 || pixel_period<6.72 || pixel_period>6.75 || serial_period<1.34 || serial_period>1.35)
            $fatal(1,"PLL periods ref=%f pixel=%f serial=%f",reference_period,pixel_period,serial_period);
        $display("PASS vendor PLL model: cascaded lock, 27.5 MHz reference, 148.5 MHz pixels and 742.5 MHz serializer; periods %f %f %f ns",reference_period,pixel_period,serial_period);$finish;
`endif
    end
    initial begin #1000000;$fatal(1,"PLL lock timeout");end
endmodule
