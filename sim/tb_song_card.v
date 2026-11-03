`timescale 1ns/1ps
`default_nettype none
module tb_song_card;
    reg csd=0,clk=0,c100=0,rst_n=0;
    always #10 csd=~csd;
    always #11 clk=~clk; // unrelated phase and frequency, as real CDC must allow
    always #5 c100=~c100;
    reg next_key=0,confirm=0,guide=1;
    wire sdclk;tri1 sdcmd;wire [3:0] sddat;
    wire rom_req;wire [39:0] rom_addr;
    reg [15:0] rom_data;
    reg [15:0] disk[0:32767];
    reg inject_bad=0;
    `include "work/song_checks/disk_meta.vh"
    initial $readmemh("work/song_checks/card.hex",disk);
    always @(posedge sdclk) if(rom_req)
        rom_data<=disk[rom_addr] ^ (inject_bad && rom_addr==SONG02_BAD_WORD ? 16'h0100 : 16'd0);
    sd_fake card(.rstn_async(rst_n),.sdclk(sdclk),.sdcmd(sdcmd),.sddat(sddat),
        .rdreq(rom_req),.rdaddr(rom_addr),.rddata(rom_data));
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
    reg [255:0] mem[0:127],rdata=0;
    reg [28:0] wa=0;
    reg rv=0;
    integer ddr_writes=0,sd_bytes=0;
    always @(posedge c100) begin
        rv<=en && cmd==1;
        if(en && cmd==1) rdata<=mem[addr>>3];
        if(en && cmd==0) wa<=addr;
        if(wren) begin
            if(cat) $fatal(1,"song traffic entered DDR FIFO");
            mem[(en && cmd==0 ? addr : wa)>>3]<=wdata;
            ddr_writes=ddr_writes+1;
        end
    end
    always @(posedge csd) if(valid) sd_bytes=sd_bytes+1;
    sd_ddr_loader #(.CLK50_HZ(50000),.CLK100_HZ(1000000),.BOOT_MS(1)) sd (
        .clk50(csd),.clk100(c100),.arst_n(rst_n),.calib_done(rst_n),
        .dbg_pll(1'b1),.dbg_por_n(1'b1),.dbg_reset_n(1'b1),.sd_clk(sdclk),.sd_cmd(sdcmd),.sd_dat0(sddat[0]),
        .app_cmd(cmd),.app_en(en),.app_addr(addr),.app_wdf_data(wdata),.app_wdf_wren(wren),
        .app_wdf_end(),.app_wdf_mask(),.app_burst(),.app_rdy(1'b1),.wr_data_rdy(1'b1),
        .app_rd_data_valid(rv),.app_rd_data(rdata),.load_done(load_done),.load_ok(load_ok),
        .stage(),.nbytes(),.nwords(),.err_ov(),.nfiles(),.file_no(),.uart_txd(),
        .song_request(req),.song_request_index(selected),.song_file_count(nc),.song_ids(ids),
        .song_catalog_done(cat),.song_busy(),.song_byte(data),.song_byte_valid(valid),
        .song_begin(begin_t),.song_end(end_t),.song_error(se)
    );
    defparam sd.u_f.u_sd_reader.SIMULATE=1;
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
        inject_bad=1;
        short_confirm;short_confirm;wait(menu==4);
        if(playing || error==0) $fatal(1,"CRC fault should block playback");
        short_confirm;
        inject_bad=0;
        short_confirm;short_confirm;wait(playing);
        if(!score_valid) $fatal(1,"reset on reload must recover");
        $display("PASS SD card CMD/DAT->FAT32 fragmented clusters->directory->P64 checksum->SONG->RAM->auto/teach, CRC rejection/reload");
        $finish;
    end
    initial begin #300000000; $fatal(1,"timeout menu=%d load=%d count=%d error=%d sdstate=%d",menu,load_ok,fc,error,sd.pst);end
endmodule
`default_nettype wire
