`timescale 1ns/1ps
`default_nettype none
module tb_bt_sd_card;
    reg csd=0,clk=0,c100=0,rst_n=0;
    always #10 csd=~csd;
    always #11 clk=~clk; // unrelated phase and frequency, as real CDC must allow
    always #5 c100=~c100;
    reg next_key=0,confirm=0,guide=1;
    wire sdclk,readerclk,writerclk;tri1 sdcmd;tri1 [3:0] sddat;
    wire store_request,store_grant;
    assign sdclk=store_grant?writerclk:readerclk;
    wire rom_req;wire [39:0] rom_addr;
    reg [15:0] rom_data;
    reg [15:0] disk[0:32767];
    reg inject_bad=0;
    `include "work/song_checks/disk_meta.vh"
    initial $readmemh("work/bt_store/btcard.hex",disk);
    always @(posedge sdclk) if(rom_req)
        rom_data<=disk[rom_addr] ^ (inject_bad && rom_addr==SONG02_BAD_WORD ? 16'h0100 : 16'd0);
    wire wrvalid;wire [31:0] wrsector;wire [8:0] wraddr;wire [7:0] wrbyte;
    integer card_writes=0;
    always @(posedge sdclk)if(wrvalid)begin
        if(wraddr[0])disk[wrsector*256+(wraddr>>1)][15:8]<=wrbyte;
        else disk[wrsector*256+(wraddr>>1)][7:0]<=wrbyte;
        card_writes=card_writes+1;
    end
    sd_fake_rw card(.rstn_async(rst_n),.sdclk(sdclk),.sdcmd(sdcmd),.sddat(sddat),
        .rdreq(rom_req),.rdaddr(rom_addr),.rddata(rom_data),.reject_write(1'b0),.wrvalid(wrvalid),.wrsector(wrsector),.wraddr(wraddr),.wrbyte(wrbyte));
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
        .dbg_pll(1'b1),.dbg_por_n(1'b1),.dbg_reset_n(1'b1),.sd_clk(readerclk),.sd_cmd(sdcmd),.sd_dat0(sddat[0]),
        .app_cmd(cmd),.app_en(en),.app_addr(addr),.app_wdf_data(wdata),.app_wdf_wren(wren),
        .app_wdf_end(),.app_wdf_mask(),.app_burst(),.app_rdy(1'b1),.wr_data_rdy(1'b1),
        .app_rd_data_valid(rv),.app_rd_data(rdata),.load_done(load_done),.load_ok(load_ok),
        .stage(),.nbytes(),.nwords(),.err_ov(),.nfiles(),.file_no(),.uart_txd(),
        .store_request(store_request),.store_grant(store_grant),
        .song_request(req),.song_request_index(selected),.song_file_count(nc),.song_ids(ids),
        .song_catalog_done(cat),.song_busy(),.song_byte(data),.song_byte_valid(valid),
        .song_begin(begin_t),.song_end(end_t),.song_error(se)
    );
    defparam sd.u_f.u_sd_reader.SIMULATE=1;
    song_system #(.CLK_HZ(50000),.LONG_MS(20)) dut (
        .clk(clk),.clk_sd(csd),.rst_n(rst_n),.guide(guide),.next_state(next_key),.confirm_state(confirm),
        .remote_toggle(bt_command),.remote_play(bt_play),.remote_id(saved_id),.remote_allowed(1'b1),
        .remote_reply(remote_reply),.remote_error(remote_error),.remote_active(remote_active),
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
    reg rx=1;wire tx,bt_command,bt_play,remote_reply,remote_active;
    wire [7:0] remote_error,saved_id,save_error,stream_data;
    wire save_start,save_done,saving,stream_start,stream_valid,stream_ready,committed;
    wire [15:0] file_size,accepted;
    reg [1:0] reply_sync=0,playing_sync=0;
    always @(posedge csd)begin reply_sync<={reply_sync[0],remote_reply};playing_sync<={playing_sync[0],playing};end
    bt_song_upload #(.CLK_HZ(1000000),.BAUD(100000)) bt(.clk(csd),.rst_n(rst_n),.rx(rx),.tx(tx),
      .source_ready(load_ok),.current_timbre(2'd0),.playing(playing_sync[1]),.dropped(1'b0),.position(32'd0),
      .command_toggle(bt_command),.command_play(bt_play),.command_reply(reply_sync[1]),.command_error(remote_error),
      .save_start(save_start),.save_done(save_done),.save_error(save_error),.file_size(file_size),
      .stream_start(stream_start),.stream_ready(stream_ready),.stream_valid(stream_valid),.stream_data(stream_data),
      .song_timbre(),.song_valid(committed),.uploading(),.accepted_count(accepted),.last_error());
    song_sd_save #(.SIMULATE(1)) save_service(.clk(csd),.rst_n(rst_n),.start(save_start),.file_size(file_size),
      .request(store_request),.grant(store_grant),.catalog_ready(cat),.catalog_error(se),.sdclk(writerclk),.sdcmd(sdcmd),.sddat0(sddat[0]),
      .stream_start(stream_start),.stream_valid(stream_valid),.stream_data(stream_data),.stream_ready(stream_ready),
      .busy(saving),.done(save_done),.error(save_error),.saved_id(saved_id));
    wire av,ae;wire [7:0] ackbyte;reg [7:0] ack[0:22];integer an=0;
    bt_uart_rx #(.CLK_HZ(1000000),.BAUD(100000)) monitor(.clk(csd),.rst_n(rst_n),.rx(tx),.data(ackbyte),.valid(av),.framing_error(ae));
    always @(posedge csd)begin
      if(ae)$fatal(1,"UART ACK framing");
      if(av)begin ack[an]=ackbyte;an=an+1;end
      if(store_grant && sd.f_rstn)$fatal(1,"both SD masters enabled");
    end
    function [15:0] crcbyte(input [15:0] c,input [7:0] b);
      reg [15:0] x;integer k;begin x=c^{b,8'd0};for(k=0;k<8;k=k+1)x=x[15]?(x<<1)^16'h1021:x<<1;crcbyte=x;end
    endfunction
    task uart(input [7:0] b);integer k;
      begin rx=0;repeat(10)@(negedge csd);for(k=0;k<8;k=k+1)begin rx=b[k];repeat(10)@(negedge csd);end rx=1;repeat(10)@(negedge csd);end
    endtask
    task check_ack(input [7:0] kind,seq);
      reg [15:0] crc;integer k;
      begin wait(an==23);repeat(40)@(negedge csd);
        if(ack[4]!=seq || ack[7]!=kind || ack[8]!=0)$fatal(1,"ACK kind=%h seq=%h status=%d save_error=%d",ack[7],ack[4],ack[8],save_error);
        crc=16'hffff;for(k=0;k<21;k=k+1)crc=crcbyte(crc,ack[k]);if(crc!={ack[22],ack[21]})$fatal(1,"ACK CRC");
      end
    endtask
    task command(input [7:0] kind,seq);
      reg [15:0] crc;integer k;reg [7:0] b;
      begin an=0;crc=16'hffff;
        for(k=0;k<7;k=k+1)begin case(k)0:b=8'ha5;1:b=8'h5a;2:b=3;3:b=kind;4:b=seq;default:b=0;endcase crc=crcbyte(crc,b);uart(b);end
        uart(crc[7:0]);uart(crc[15:8]);check_ack(kind,seq);
      end
    endtask
    reg [7:0] upload_bytes[0:313];integer offset,j,length,old_writes,fd;
    initial begin
        $readmemh("work/bt_store/upload33.hex",upload_bytes);
        repeat(12)@(negedge clk);rst_n=1;
        wait(fc==4);repeat(20)@(negedge clk);
        if(!load_ok)$fatal(1,"image not verified");
        // A phone can upload and play from the main page without local menu keys.
        guide=0;offset=0;
        while(offset<314)begin
            an=0;length={upload_bytes[offset+6],upload_bytes[offset+5]}+9;
            for(j=0;j<length;j=j+1)uart(upload_bytes[offset+j]);
            check_ack(upload_bytes[offset+3],upload_bytes[offset+4]);offset=offset+length;
        end
        if(!committed || save_error!=0 || saved_id!=8'h05 || fc!=5 || !cat || ddr_writes!=64)
            $fatal(1,"commit/catalog/image: committed=%d err=%d id=%h count=%d DDRwrites=%d",committed,save_error,saved_id,fc,ddr_writes);
        // A lost END ACK must not create SONG06 or repeat an SD write.
        old_writes=card_writes;an=0;
        for(j=303;j<314;j=j+1)uart(upload_bytes[j]);check_ack(3,3);
        if(card_writes!=old_writes || fc!=5)$fatal(1,"END retry wrote twice");
        command(8'h10,20);repeat(30)@(negedge clk);
        if(!playing || !remote_active || menu!=3 || teach || !score_valid || accepted!=33)$fatal(1,"remote PLAY failed");
        command(8'h11,21);repeat(30)@(negedge clk);
        if(playing || gate!=0 || remote_active)$fatal(1,"remote STOP failed");
        fd=$fopen("work/bt_store/btcard.after","wb");
        for(j=0;j<32768;j=j+1)begin $fwrite(fd,"%c",disk[j][7:0]);$fwrite(fd,"%c",disk[j][15:8]);end
        $fclose(fd);
        $display("PASS end-to-end phone UART->CRC/ACK->SD ownership->native CMD24/CRC/busy/status->FAT append/readback->catalog refresh->existing SD loader->CDC RAM->remote PLAY/STOP; END retry idempotent; P64 DDR preserved");$finish;
    end
    initial begin #1000000000;$fatal(1,"timeout BT=%d SD=%d save=%d/%d cat=%d menu=%d",bt.state,sd.pst,save_service.state,save_service.u_store.state,fc,menu);end
endmodule
`default_nettype wire
