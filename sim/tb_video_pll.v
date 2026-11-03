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
            begin @(posedge dut.ref_clk);start_reference=$realtime;repeat(100)@(posedge dut.ref_clk);reference_period=($realtime-start_reference)/100.0;end
            begin @(posedge pix);start_pixel=$realtime;repeat(100)@(posedge pix);pixel_period=($realtime-start_pixel)/100.0;end
            begin @(posedge ser);start_serial=$realtime;repeat(500)@(posedge ser);serial_period=($realtime-start_serial)/500.0;end
        join
        if(reference_period<36.35 || reference_period>36.38 || pixel_period<6.72 || pixel_period>6.75 || serial_period<1.34 || serial_period>1.35)
            $fatal(1,"PLL periods ref=%f pixel=%f serial=%f",reference_period,pixel_period,serial_period);
        $display("PASS vendor PLL model: cascaded lock, 27.5 MHz reference, 148.5 MHz pixels and 742.5 MHz serializer; periods %f %f %f ns",reference_period,pixel_period,serial_period);$finish;
    end
    initial begin #1000000;$fatal(1,"PLL lock timeout");end
endmodule
