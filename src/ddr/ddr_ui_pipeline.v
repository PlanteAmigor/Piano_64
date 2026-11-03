// One independent holding register per DDR command/write-data channel.
// Client ready depends only on register occupancy, never DDR combinational
// readiness. Read data and valid are captured together before fanout to DMA.
`default_nettype none
module ddr_ui_pipeline(
    input wire clk,rst_n,
    input wire [2:0] s_cmd,input wire s_en,input wire [28:0] s_addr,
    input wire [255:0] s_wdata,input wire s_wren,
    output wire s_ready,s_wready,output reg s_rvalid,output reg [255:0] s_rdata,
    output reg [2:0] m_cmd,output reg m_en,output reg [28:0] m_addr,
    output reg [255:0] m_wdata,output reg m_wren,
    input wire m_ready,m_wready,m_rvalid,input wire [255:0] m_rdata
);
    assign s_ready=!m_en;
    assign s_wready=!m_wren;
    always @(posedge clk)begin
        if(!rst_n)begin
            m_en<=0;m_wren<=0;
            s_rvalid<=0;
        end else begin
            if(m_en && m_ready)m_en<=0;
            if(s_en && s_ready)m_en<=1;
            if(m_wren && m_wready)m_wren<=0;
            if(s_wren && s_wready)m_wren<=1;
            s_rvalid<=m_rvalid;

        end
    end
    // Payload contents are irrelevant until their valid flag is asserted.
    // Avoid distributing calibration reset through 288 data-bit input muxes.
    always @(posedge clk)begin
        if(s_en && s_ready)begin m_cmd<=s_cmd;m_addr<=s_addr;end
        if(s_wren && s_wready)m_wdata<=s_wdata;
        if(m_rvalid)s_rdata<=m_rdata;
    end
endmodule
`default_nettype wire
