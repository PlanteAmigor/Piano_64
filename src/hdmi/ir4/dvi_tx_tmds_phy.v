`include "src/hdmi/ui_video_mode.vh"
module dvi_tx_tmds_phy(
	
	input				pixel_clock,
	input				ddr_bit_clock,
	input				reset,
	input	[9 : 0]		data,
	output	[1 : 0]		tmds_lane
);
	
	reg reset_reg;
	
	wire dq_tmds;
`ifdef UI_VIDEO_720P
    wire [9:0] parallel_data=data;
`else
    // A dedicated unconditional pixel register can be placed next to OSER10,
    // separating the encoder's disparity/control logic from the IO route.
    reg [9:0] parallel_data /* synthesis syn_preserve=1 */;
    always @(posedge pixel_clock)parallel_data<=data;
`endif

	
	always@(posedge pixel_clock)begin
		if(reset)begin
			reset_reg <= 1'b1;
		end else begin
			reset_reg <= 1'b0;
		end
	end
	
	OSER10 tmds_serdes_inst0 (
		.Q(dq_tmds),
		.D0(parallel_data[0]),
		.D1(parallel_data[1]),
		.D2(parallel_data[2]),
		.D3(parallel_data[3]),
		.D4(parallel_data[4]),
		.D5(parallel_data[5]),
		.D6(parallel_data[6]),
		.D7(parallel_data[7]),
		.D8(parallel_data[8]),
		.D9(parallel_data[9]),
		.PCLK(pixel_clock),
		.FCLK(ddr_bit_clock),
`ifdef UI_VIDEO_720P
        .RESET(reset_reg)
`else
        // Configuration GSR initializes OSER10. Keep the serializer running
        // through pixel-domain resets; encoder reset emits safe control words.
        // Avoid an unsynchronized fabric-reset release in the fast IO domain.
        .RESET(1'b0)
`endif
	);
	
	ELVDS_OBUF tmds_bufds_isnt0 (
		.I(dq_tmds),
		.O(tmds_lane[1]),
		.OB(tmds_lane[0])
	);
	
endmodule
