`timescale 1ns/1ps
`default_nettype none
module tb_song_sd;
    parameter integer CORRUPT_IMAGE=0,BACKPRESSURE=0,PIPELINE=0;
    reg [7:0] throttle=1;
    always @(posedge c100)throttle<={throttle[6:0],throttle[7]^throttle[5]^throttle[4]^throttle[3]};
    reg csd=0,clk=0,c100=0,rst_n=0;
    always #10 csd=~csd;
    always #11 clk=~clk; // unrelated phase and frequency, as real CDC must allow
    always #5 c100=~c100;
    reg next_key=0,confirm=0,guide=1;
    wire req,cat,begin_t,end_t,se,valid,playing,score_valid,teach;
    wire [3:0] selected;
    wire [4:0] nc,fc;
    wire [127:0] ids,fids;
    wire [7:0] data,error;
    wire [2:0] menu;
    wire [1:0] timbre,cd;
    wire [7:0] gate,trig;
    wire [55:0] notes;
    wire [63:0] vel;
    wire [6:0] expected,matched;
    wire [31:0] pos;
    wire [15:0] wrong,miss;
    wire load_done,load_ok;
    wire [2:0] cmd;
    wire en,wren;
    wire [28:0] addr;
    wire [255:0] wdata;
    wire cmd_ready=!BACKPRESSURE || throttle[0],data_ready=!BACKPRESSURE || throttle[2];
    wire client_ready,client_wready,client_rvalid;
    wire [255:0] client_rdata;
    wire [2:0] mem_cmd;
    wire mem_en,mem_we,mem_en_raw,mem_we_raw;
    wire [28:0] mem_addr;
    wire [255:0] mem_wdata;
    generate if(PIPELINE)begin
        ddr_ui_pipeline pipe(.clk(c100),.rst_n(rst_n),.s_cmd(cmd),.s_en(en),.s_addr(addr),
            .s_wdata(wdata),.s_wren(wren),.s_ready(client_ready),.s_wready(client_wready),
            .s_rvalid(client_rvalid),.s_rdata(client_rdata),.m_cmd(mem_cmd),.m_en(mem_en_raw),.m_addr(mem_addr),
            .m_wdata(mem_wdata),.m_wren(mem_we_raw),.m_ready(cmd_ready),.m_wready(data_ready),.m_rvalid(rv),.m_rdata(rdata));
        assign mem_en=mem_en_raw && cmd_ready;assign mem_we=mem_we_raw && data_ready;
    end else begin
        assign client_ready=cmd_ready;assign client_wready=data_ready;assign client_rvalid=rv;assign client_rdata=rdata;
        assign mem_cmd=cmd;assign mem_en=en;assign mem_addr=addr;assign mem_wdata=wdata;assign mem_we=wren;
    end endgenerate
    reg [255:0] mem[0:127],rdata=0;
    reg [28:0] wa=0;
    reg rv=0;
    integer ddr_writes=0,sd_bytes=0;
    reg command_pending=0,data_pending=0;
    reg [255:0] pending_data;
    always @(posedge c100) begin
        rv<=mem_en && mem_cmd==1;
        if(mem_en && mem_cmd==1) rdata<=mem[mem_addr>>3] ^ (CORRUPT_IMAGE && mem_addr==8 ? 256'd1 : 256'd0);
        if(mem_en && mem_cmd==0)begin wa<=mem_addr;command_pending<=1;end
        if(mem_we)begin pending_data<=mem_wdata;data_pending<=1;end
        if((command_pending || (mem_en && mem_cmd==0)) && (data_pending || mem_we))begin
            if(cat)$fatal(1,"song traffic entered DDR FIFO");
            mem[(mem_en && mem_cmd==0?mem_addr:wa)>>3]<=mem_we?mem_wdata:pending_data;
            command_pending<=0;data_pending<=0;ddr_writes=ddr_writes+1;
        end
    end
    always @(posedge csd) if(valid) sd_bytes=sd_bytes+1;
    sd_ddr_loader #(.CLK50_HZ(50000),.CLK100_HZ(1000000),.BOOT_MS(1)) sd (
        .clk50(csd),.clk100(c100),.arst_n(rst_n),.calib_done(rst_n),
        .dbg_pll(1'b1),.dbg_por_n(1'b1),.dbg_reset_n(1'b1),.sd_clk(),.sd_cmd(),.sd_dat0(1'b1),
        .app_cmd(cmd),.app_en(en),.app_addr(addr),.app_wdf_data(wdata),.app_wdf_wren(wren),
        .app_wdf_end(),.app_wdf_mask(),.app_burst(),.app_rdy(client_ready),.wr_data_rdy(client_wready),
        .app_rd_data_valid(client_rvalid),.app_rd_data(client_rdata),.load_done(load_done),.load_ok(load_ok),
        .stage(),.nbytes(),.nwords(),.err_ov(),.nfiles(),.file_no(),.uart_txd(),
        .song_request(req),.song_request_index(selected),.song_file_count(nc),.song_ids(ids),
        .song_catalog_done(cat),.song_busy(),.song_byte(data),.song_byte_valid(valid),
        .song_begin(begin_t),.song_end(end_t),.song_error(se)
    );
    song_system #(.CLK_HZ(50000),.LONG_MS(20)) dut (
        .clk(clk),.clk_sd(csd),.rst_n(rst_n),.guide(guide),.next_state(next_key),.confirm_state(confirm),
        .key_press(7'd0),.key_state(7'd0),.sd_count(nc),.sd_ids(ids),.sd_catalog_done(cat),
        .sd_begin(begin_t),.sd_end(end_t),.sd_error(se),.sd_byte(data),.sd_byte_valid(valid),
        .request_toggle(req),.selected(selected),.v_note(notes),.v_trig(trig),.v_gate(gate),.v_vel(vel),
        .playing(playing),.timbre(timbre),.score_valid(score_valid),.menu_state(menu),.teaching(teach),
        .expected_keys(expected),.matched_keys(matched),.countdown(cd),.position_ms(pos),
        .wrong_count(wrong),.missed_count(miss),.error_code(error),.file_count(fc),.file_ids(fids)
    );
    task short_confirm;
        begin @(negedge clk);confirm=1;repeat(8) @(negedge clk);confirm=0;repeat(8) @(negedge clk);end
    endtask
    task next;
        begin @(negedge clk);next_key=1;repeat(8) @(negedge clk);next_key=0;repeat(8) @(negedge clk);end
    endtask
    initial begin
        repeat(12) @(negedge clk);rst_n=1;
        if(CORRUPT_IMAGE) begin
            wait(load_done);repeat(50) @(negedge clk);
            if(load_ok || cat || playing) $fatal(1,"corrupt P64 image must block catalog and playback");
            $display("PASS P64 checksum: corrupted DDR readback blocks catalog and playback");$finish;
        end
        wait(fc==4);repeat(10) @(negedge clk);
        if(!load_ok || !load_done || fids[31:0]!==32'h03020104) $fatal(1,"catalog after image check %h",fids);
        next; if(selected!=1) $fatal(1,"selection"); // SONG01 appears second
        short_confirm; if(menu!=1) $fatal(1,"mode select");
        short_confirm;wait(playing);repeat(100) @(negedge clk);
        if(menu!=3 || !score_valid || timbre!=0 || gate!=15 || sd_bytes!=426) $fatal(1,"auto stream %d/%b/%d",menu,gate,sd_bytes);
        short_confirm;if(menu!=1 || playing || gate!=0) $fatal(1,"stop");
        // Long press returns once; its release must not confirm the list again.
        @(negedge clk);confirm=1;repeat(1300) @(negedge clk);confirm=0;
        repeat(20) @(negedge clk);if(menu!=0) $fatal(1,"long release also acted as short");
        next; // SONG02
        short_confirm;next;short_confirm;
        wait(playing);repeat(100) @(negedge clk);
        if(!teach || timbre!=1 || cd!=3 || gate!=0) $fatal(1,"teach mode and preparation");
        wait(pos>=1); repeat(30) @(negedge clk);
        if(gate==0 || vel[7:0]==0) $fatal(1,"no-hand fallback should play");
        @(negedge clk);guide=0;repeat(10) @(negedge clk);
        if(playing || gate!=0 || menu!=0) $fatal(1,"page exit stop");
        @(negedge clk);guide=1;
        sd.u_f.inject_bad=1;
        short_confirm;short_confirm;wait(menu==4);
        if(playing || error==0) $fatal(1,"CRC fault should block playback");
        short_confirm;
        sd.u_f.inject_bad=0;
        short_confirm;short_confirm;wait(playing);
        if(!score_valid) $fatal(1,"reset on reload must recover");
        $display("PASS SD->CDC->RAM->player: verified image, real catalog order, all bytes, auto/teach, long/short keys, stop/exit, CRC rejection and reload");
        $finish;
    end
    initial begin #100000000; $fatal(1,"timeout menu=%d load=%d count=%d error=%d sdstate=%d",menu,load_ok,fc,error,sd.pst);end
endmodule
`default_nettype wire
