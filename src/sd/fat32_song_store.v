// Append a new SONGxx.BIN to a FAT32 root directory. Existing file chains and
// contents are never reused. Data and every metadata sector are read back
// byte-for-byte; the directory entry is published last. Card access must be
// exclusive. Sector I/O errors are terminal and never acknowledged as success.
`default_nettype none
module fat32_song_store #(parameter integer CLK_HZ=50000000,TIMEOUT_MS=3800)(
 input wire clk,rst_n,start,input wire [15:0] file_size,
 output reg busy,done,output reg [7:0] error,saved_id,
 output reg stream_start,input wire stream_valid,input wire [7:0] stream_data,output wire stream_ready,
 output reg io_request,io_write,output reg [31:0] io_sector,
 input wire io_ready,io_done,input wire [7:0] io_error,
 input wire rvalid,input wire [8:0] raddr,input wire [7:0] rdata,
 input wire [8:0] waddr,output wire [7:0] wdata
);
 localparam [7:0] IDLE=0,BOOT=1,GEOM0=2,GEOM1=3,GEOM2=4,ROOT=5,ROOT_DONE=6,
  ROOT_LINK=7,ROOT_LINK_DONE=8,CHOOSE=9,FREE=10,FREE_DONE=11,DATA_BEGIN=12,FILL=13,
  DATA_WRITE=14,DATA_NEXT=15,ROOT_CLEAR=16,ROOT_ZERO_NEXT=17,FAT_BEGIN=18,FAT_READ=19,
  FAT_PATCH=20,FAT_WRITE=21,FAT_NEXT=22,END_MARK=23,END_LINK_DONE=24,END_READ=25,
  END_PATCH=26,END_WRITE=27,DIR_READ=28,DIR_PATCH=29,DIR_WRITE=30,SUCCESS=31,
  IO_START=32,IO_WAIT=33,FSI_READ=34,FSI_CHECK=35,FSI_PATCH=36,FSI_WRITE=37,FSI_NEXT=38;
 localparam [2:0] P_BOOT=0,P_ROOT=1,P_LINK=2,P_FREE=3,P_PATCH=4,P_PLAIN=5,P_VERIFY=6,P_FSI=7;
 reg [7:0] state,return_state;
 reg [2:0] purpose;
 reg [31:0] timer;
 reg [7:0] buffer[0:511];
 reg buffer_we;reg [8:0] buffer_wa;reg [7:0] buffer_wd,buffer_q;
 reg verify_mode,verify_pending,mismatch;
 reg [7:0] verify_data;
 wire [8:0] buffer_ra=verify_mode?raddr:waddr;
 assign wdata=buffer_q;
 always @(posedge clk)begin
  buffer_q<=buffer[buffer_ra];
  if(buffer_we)buffer[buffer_wa]<=buffer_wd;
  if(rvalid && !verify_mode)buffer[raddr]<=rdata;
  if(!rst_n)begin verify_pending<=0;verify_data<=0;end
  else begin verify_pending<=rvalid && verify_mode;verify_data<=rdata;end
 end
 // These are the only bytes needed from the boot sector; the sector itself
 // stays in synchronous RAM for read/modify/write operations.
 reg [767:0] bpb;
 reg [15:0] signature;
 reg [31:0] partition_lba;
 reg [7:0] partition_type;
 reg [255:0] entry;
 reg entry_pending;
 reg [8:0] entry_offset;
 reg [31:0] fat_word;
 reg [8:0] fat_offset;
 reg [31:0] fsi_signature0,fsi_signature1,fsi_signature2;
 wire [15:0] bps=bpb[11*8+:16],reserved=bpb[14*8+:16];
 wire [7:0] sectors_per_cluster=bpb[13*8+:8],fat_count=bpb[16*8+:8];
 wire [31:0] total_sectors=bpb[32*8+:32],fat_size=bpb[36*8+:32];
 wire [15:0] fat_flags=bpb[40*8+:16];
 wire [31:0] bpb_root=bpb[44*8+:32];
 wire [15:0] fsi_sector=bpb[48*8+:16],backup_boot=bpb[50*8+:16];
 reg [31:0] volume_base,fat_start,data_start,cluster_limit,data_sectors;
 reg [7:0] spc;reg [2:0] spc_shift;
 reg [31:0] fatsz;
 reg [1:0] nfats,active_fat;
 reg mirrored;
 reg [31:0] root_cluster,root_last;
 reg [7:0] root_sector;
 reg [15:0] root_sectors_seen;
 reg root_end,extend_root,slot_found;
 reg [31:0] slot_lba,slot_cluster;
 reg [7:0] slot_sector;
 reg [8:0] slot_offset;
 reg [99:0] used_ids;
 reg [4:0] song_count;
 reg [6:0] candidate;
 reg [3:0] candidate_tens,candidate_ones;
 reg [31:0] allocated[0:34];
 reg [5:0] allocated_count,needed,total_needed;
 reg [31:0] free_sector;
 reg [6:0] file_sectors;
 reg [5:0] data_cluster_index;
 reg [7:0] data_sector_index;
 reg [15:0] remaining;
 reg [8:0] fill_index;
 reg [5:0] fat_index;
 reg [1:0] fat_copy;
 reg linking_root;
 reg [31:0] patch_cluster,patch_value;
 reg [3:0] patch_index;
 reg [7:0] zero_sector;
 reg [31:0] end_lba;
 reg [1:0] fsi_copy;
 reg [31:0] fsi_lba;
 wire [31:0] cluster_lba=data_start+((root_cluster-2)<<spc_shift)+root_sector;
 wire [31:0] data_lba=data_start+((allocated[data_cluster_index]-2)<<spc_shift)+data_sector_index;
 wire [31:0] read_fat_base=fat_start+(active_fat==1?fatsz:0);
 wire [31:0] patch_fat_base=fat_start+((mirrored?fat_copy:active_fat)==1?fatsz:0);
 wire [6:0] entry_id=(entry[4*8+:8]-8'd48)*7'd10+(entry[5*8+:8]-8'd48);
 wire song_name=(entry[0*8+:8]|8'h20)=="s" && (entry[1*8+:8]|8'h20)=="o" &&
  (entry[2*8+:8]|8'h20)=="n" && (entry[3*8+:8]|8'h20)=="g" &&
  entry[4*8+:8]>="0" && entry[4*8+:8]<="9" && entry[5*8+:8]>="0" && entry[5*8+:8]<="9" &&
  entry[6*8+:8]==" " && entry[7*8+:8]==" " && (entry[8*8+:8]|8'h20)=="b" &&
  (entry[9*8+:8]|8'h20)=="i" && (entry[10*8+:8]|8'h20)=="n";
 assign stream_ready=busy && state==FILL && remaining!=0;
 task read_sector(input [31:0] lba,input [7:0] next_state,input [2:0] use_as);
  begin io_sector<=lba;io_write<=0;return_state<=next_state;purpose<=use_as;verify_mode<=0;state<=IO_START;end
 endtask
 task write_sector(input [31:0] lba,input [7:0] next_state);
  begin io_sector<=lba;io_write<=1;return_state<=next_state;verify_mode<=0;state<=IO_START;end
 endtask
 task fail(input [7:0] code);
  begin error<=code;busy<=0;done<=1;state<=IDLE;io_request<=0;buffer_we<=0;end
 endtask
 integer k;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;busy<=0;done<=0;error<=0;saved_id<=0;stream_start<=0;
   io_request<=0;io_write<=0;io_sector<=0;purpose<=P_BOOT;return_state<=IDLE;
   buffer_we<=0;buffer_wa<=0;buffer_wd<=0;verify_mode<=0;mismatch<=0;
   timer<=0;bpb<=0;signature<=0;partition_lba<=0;partition_type<=0;entry<=0;entry_pending<=0;
   entry_offset<=0;fat_word<=0;fat_offset<=0;volume_base<=0;fat_start<=0;data_start<=0;
   cluster_limit<=0;data_sectors<=0;spc<=1;spc_shift<=0;fatsz<=0;nfats<=0;active_fat<=0;mirrored<=1;
   root_cluster<=2;root_last<=2;root_sector<=0;root_sectors_seen<=0;root_end<=0;extend_root<=0;slot_found<=0;
   slot_lba<=0;slot_cluster<=0;slot_sector<=0;slot_offset<=0;used_ids<=0;song_count<=0;
   candidate<=1;candidate_tens<=0;candidate_ones<=1;allocated_count<=0;needed<=0;total_needed<=0;
   free_sector<=0;file_sectors<=0;
   data_cluster_index<=0;data_sector_index<=0;remaining<=0;fill_index<=0;fat_index<=0;fat_copy<=0;
   linking_root<=0;patch_cluster<=0;patch_value<=0;patch_index<=0;zero_sector<=0;end_lba<=0;
   fsi_copy<=0;fsi_lba<=0;fsi_signature0<=0;fsi_signature1<=0;fsi_signature2<=0;
  end else begin
   io_request<=0;buffer_we<=0;done<=0;stream_start<=0;entry_pending<=0;
   if(busy)timer<=timer+1'b1;
   if(verify_pending && buffer_q!==verify_data)mismatch<=1;
   if(rvalid && !verify_mode)begin
    if(purpose==P_BOOT)begin
     if(raddr<96)bpb[raddr*8+:8]<=rdata;
     if(raddr==450)partition_type<=rdata;
     if(raddr>=454 && raddr<=457)partition_lba[(raddr-454)*8+:8]<=rdata;
     if(raddr>=510)signature[(raddr-510)*8+:8]<=rdata;
    end
    if(purpose==P_ROOT)begin
     entry[raddr[4:0]*8+:8]<=rdata;
     if(raddr[4:0]==31)begin entry_pending<=1;entry_offset<={raddr[8:5],5'd0};end
    end
    if((purpose==P_LINK || purpose==P_PATCH) && raddr[8:2]==fat_offset[8:2])fat_word[raddr[1:0]*8+:8]<=rdata;
    if(purpose==P_FREE)begin
     fat_word[raddr[1:0]*8+:8]<=rdata;
     if(raddr[1:0]==3 && allocated_count<total_needed &&
        {free_sector[24:0],raddr[8:2]}>=2 && {free_sector[24:0],raddr[8:2]}<=cluster_limit &&
        {rdata[3:0],fat_word[23:0]}==0)begin
      allocated[allocated_count]<={free_sector[24:0],raddr[8:2]};allocated_count<=allocated_count+1'b1;
     end
    end
    if(purpose==P_FSI)begin
     if(raddr<4)fsi_signature0[raddr[1:0]*8+:8]<=rdata;
     if(raddr>=484 && raddr<=487)fsi_signature1[raddr[1:0]*8+:8]<=rdata;
     if(raddr>=508)fsi_signature2[raddr[1:0]*8+:8]<=rdata;
    end
   end
   if(entry_pending && !root_end)begin
    if(entry[7:0]==0)begin
     root_end<=1;slot_found<=1;slot_lba<=io_sector;slot_cluster<=root_cluster;
     slot_sector<=root_sector;slot_offset<=entry_offset;
    end else if(entry[7:0]!=8'he5 && (entry[11*8+:8]&8'h18)==0 && song_name)begin
     used_ids[entry_id]<=1;
     if(song_count<16)song_count<=song_count+1'b1;
    end
   end
   case(state)
    IDLE:if(start)begin
     busy<=1;error<=0;timer<=0;volume_base<=0;root_end<=0;slot_found<=0;extend_root<=0;
     used_ids<=0;song_count<=0;candidate<=1;candidate_tens<=0;candidate_ones<=1;root_sectors_seen<=0;
     allocated_count<=0;free_sector<=0;verify_mode<=0;mismatch<=0;
     read_sector(0,BOOT,P_BOOT);
    end
    BOOT:begin
     if(signature!=16'haa55)fail(20);
     else if((bpb[7:0]==8'heb || bpb[7:0]==8'he9) && bps==512 && bpb[17*8+:16]==0 && bpb[22*8+:16]==0)begin
      if(file_size==0 || file_size>17116 || sectors_per_cluster==0 || sectors_per_cluster>128 ||
         (sectors_per_cluster&(sectors_per_cluster-1))!=0 || reserved==0 || fat_count<1 || fat_count>2 ||
         fat_size==0 || fat_size>32'h01ffffff || total_sectors==0 || bpb_root<2 || bpb[42*8+:16]!=0 ||
         (fat_flags[7] && fat_flags[3:0]>=fat_count))fail(20);
      else begin
       spc<=sectors_per_cluster;spc_shift<=0;
       for(k=0;k<8;k=k+1)if(sectors_per_cluster==(1<<k))spc_shift<=k;
       fatsz<=fat_size;nfats<=fat_count;mirrored<=!fat_flags[7];active_fat<=fat_flags[7]?fat_flags[1:0]:0;
       root_cluster<=bpb_root;root_last<=bpb_root;root_sector<=0;
       fat_start<=volume_base+reserved;state<=GEOM0;
      end
     end else if(volume_base==0 && (partition_type==8'h0b || partition_type==8'h0c) && partition_lba!=0)begin
      volume_base<=partition_lba;read_sector(partition_lba,BOOT,P_BOOT);
     end else fail(20);
    end
    GEOM0:begin
     data_start<=fat_start+(nfats==2?fatsz<<1:fatsz);
     data_sectors<=total_sectors-reserved-(nfats==2?fatsz<<1:fatsz);
     file_sectors<=(file_size+16'd511)>>9;state<=GEOM1;
    end
    GEOM1:begin cluster_limit<=(data_sectors>>spc_shift)+1;needed<=(file_sectors+spc-1)>>spc_shift;state<=GEOM2;end
    GEOM2:begin
     if(data_start<volume_base || volume_base+total_sectors<volume_base || data_start-volume_base>=total_sectors || cluster_limit>=32'h0ffffff0 ||
        cluster_limit<2 || bpb_root>cluster_limit || {1'b0,fatsz,7'd0}<={1'b0,cluster_limit})fail(20);
     else state<=ROOT;
    end
    ROOT:begin root_sectors_seen<=root_sectors_seen+1'b1;read_sector(cluster_lba,ROOT_DONE,P_ROOT);end
    ROOT_DONE:begin
     if(root_end)state<=CHOOSE;
     else if(root_sectors_seen>=4096)fail(21);
     else if(root_sector+1<spc)begin root_sector<=root_sector+1'b1;state<=ROOT;end
     else state<=ROOT_LINK;
    end
    ROOT_LINK:begin fat_offset<={root_cluster[6:0],2'b00};read_sector(read_fat_base+(root_cluster>>7),ROOT_LINK_DONE,P_LINK);end
    ROOT_LINK_DONE:begin
     if(fat_word[27:0]>=28'hffffff8)begin extend_root<=1;root_last<=root_cluster;state<=CHOOSE;end
     else if(fat_word[27:0]<2 || fat_word[27:0]>cluster_limit || fat_word[27:0]==root_cluster)fail(20);
     else begin root_cluster<={4'd0,fat_word[27:0]};root_sector<=0;state<=ROOT;end
    end
    CHOOSE:begin
     if(song_count>=16 || candidate>=100)fail(22);
     else if(used_ids[candidate])begin
      candidate<=candidate+1'b1;
      if(candidate_ones==9)begin candidate_ones<=0;candidate_tens<=candidate_tens+1'b1;end
      else candidate_ones<=candidate_ones+1'b1;
     end else begin saved_id<={candidate_tens,candidate_ones};total_needed<=needed+extend_root;state<=FREE;end
    end
    FREE:read_sector(read_fat_base+free_sector,FREE_DONE,P_FREE);
    FREE_DONE:begin
     if(allocated_count==total_needed)state<=DATA_BEGIN;
     else if(free_sector+1>=fatsz || ((free_sector+1)<<7)>cluster_limit)fail(23);
     else begin free_sector<=free_sector+1'b1;state<=FREE;end
    end
    DATA_BEGIN:begin
     stream_start<=1;data_cluster_index<=0;data_sector_index<=0;remaining<=file_size;
     fill_index<=0;state<=FILL;
    end
    FILL:if(remaining==0 || stream_valid)begin
     buffer_we<=1;buffer_wa<=fill_index;buffer_wd<=remaining==0?0:stream_data;
     if(remaining!=0)remaining<=remaining-1'b1;
     if(fill_index==511)state<=DATA_WRITE;else fill_index<=fill_index+1'b1;
    end
    DATA_WRITE:write_sector(data_lba,DATA_NEXT);
    DATA_NEXT:begin
     if(remaining==0)begin
      fill_index<=0;zero_sector<=0;
      if(extend_root)state<=ROOT_CLEAR;else begin fsi_copy<=0;state<=FSI_READ;end
     end else begin
      if(data_sector_index+1>=spc)begin data_cluster_index<=data_cluster_index+1'b1;data_sector_index<=0;end
      else data_sector_index<=data_sector_index+1'b1;
      fill_index<=0;state<=FILL;
     end
    end
    ROOT_CLEAR:begin
     buffer_we<=1;buffer_wa<=fill_index;buffer_wd<=0;
     if(fill_index==511)begin
      slot_lba<=data_start+((allocated[needed]-2)<<spc_shift);slot_offset<=0;
      write_sector(data_start+((allocated[needed]-2)<<spc_shift)+zero_sector,ROOT_ZERO_NEXT);
     end else fill_index<=fill_index+1'b1;
    end
    ROOT_ZERO_NEXT:begin
     if(zero_sector+1>=spc)begin fsi_copy<=0;state<=FSI_READ;end
     else begin zero_sector<=zero_sector+1'b1;fill_index<=0;state<=ROOT_CLEAR;end
    end
    FSI_READ:begin
     if(fsi_sector==0 || fsi_sector>=reserved || fsi_sector==16'hffff ||
        (fsi_copy==1 && (backup_boot==0 || backup_boot==16'hffff || {1'b0,backup_boot}+fsi_sector>=reserved)))state<=FAT_BEGIN;
     else begin
      fsi_lba<=volume_base+fsi_sector+(fsi_copy==1?backup_boot:0);
      read_sector(volume_base+fsi_sector+(fsi_copy==1?backup_boot:0),FSI_CHECK,P_FSI);
     end
    end
    FSI_CHECK:begin
     if(fsi_signature0==32'h41615252 && fsi_signature1==32'h61417272 && fsi_signature2==32'haa550000)begin patch_index<=0;state<=FSI_PATCH;end
     else state<=FSI_NEXT;
    end
    FSI_PATCH:begin
     buffer_we<=1;buffer_wa<=488+patch_index;buffer_wd<=8'hff;
     if(patch_index==7)state<=FSI_WRITE;else patch_index<=patch_index+1'b1;
    end
    FSI_WRITE:write_sector(fsi_lba,FSI_NEXT);
    FSI_NEXT:if(fsi_copy==0)begin fsi_copy<=1;state<=FSI_READ;end else state<=FAT_BEGIN;
    FAT_BEGIN:begin fat_index<=0;fat_copy<=0;linking_root<=0;state<=FAT_READ;end
    FAT_READ:begin
     patch_cluster<=linking_root?root_last:allocated[fat_index];
     patch_value<=linking_root?allocated[needed]:(fat_index+1<needed?allocated[fat_index+1]:32'h0fffffff);
     fat_offset<=((linking_root?root_last:allocated[fat_index])&127)<<2;
     read_sector(patch_fat_base+((linking_root?root_last:allocated[fat_index])>>7),FAT_PATCH,P_PATCH);patch_index<=0;
    end
    FAT_PATCH:begin
     // Preserve FAT32's reserved high nibble in every copy.
     buffer_we<=1;buffer_wa<=fat_offset+patch_index;
     buffer_wd<=patch_index==3?{fat_word[31:28],patch_value[27:24]}:patch_value[patch_index*8+:8];
     if(patch_index==3)state<=FAT_WRITE;else patch_index<=patch_index+1'b1;
     if(patch_index==0 && (linking_root?fat_word[27:0]<28'hffffff8:fat_word[27:0]!=0))fail(20);
    end
    FAT_WRITE:write_sector(patch_fat_base+(patch_cluster>>7),FAT_NEXT);
    FAT_NEXT:begin
     if(mirrored && fat_copy+1<nfats)begin fat_copy<=fat_copy+1'b1;state<=FAT_READ;end
     else begin
      fat_copy<=0;
      if(!linking_root && fat_index+1<total_needed)begin fat_index<=fat_index+1'b1;state<=FAT_READ;end
      else if(extend_root && !linking_root)begin linking_root<=1;state<=FAT_READ;end
      else state<=END_MARK;
     end
    end
    END_MARK:begin
     if(extend_root || slot_offset!=480)state<=DIR_READ;
     else if(slot_sector+1<spc)begin end_lba<=slot_lba+1'b1;state<=END_READ;end
     else begin fat_offset<={slot_cluster[6:0],2'b00};read_sector(read_fat_base+(slot_cluster>>7),END_LINK_DONE,P_LINK);end
    end
    END_LINK_DONE:begin
     if(fat_word[27:0]>=28'hffffff8)state<=DIR_READ;
     else if(fat_word[27:0]<2 || fat_word[27:0]>cluster_limit)fail(20);
     else begin end_lba<=data_start+(({4'd0,fat_word[27:0]}-2)<<spc_shift);state<=END_READ;end
    end
    END_READ:read_sector(end_lba,END_PATCH,P_PLAIN);
    END_PATCH:begin buffer_we<=1;buffer_wa<=0;buffer_wd<=0;state<=END_WRITE;end
    END_WRITE:write_sector(end_lba,DIR_READ);
    DIR_READ:begin patch_index<=0;fill_index<=0;read_sector(slot_lba,DIR_PATCH,P_PLAIN);end
    DIR_PATCH:begin
     buffer_we<=1;buffer_wa<=slot_offset+fill_index;buffer_wd<=0;
     case(fill_index)
      0:buffer_wd<="S";1:buffer_wd<="O";2:buffer_wd<="N";3:buffer_wd<="G";
      4:buffer_wd<=8'd48+candidate_tens;5:buffer_wd<=8'd48+candidate_ones;
      6,7:buffer_wd<=" ";8:buffer_wd<="B";9:buffer_wd<="I";10:buffer_wd<="N";11:buffer_wd<=8'h20;
      16,18,24:buffer_wd<=8'h21;
      20:buffer_wd<=allocated[0][23:16];21:buffer_wd<=allocated[0][31:24];
      26:buffer_wd<=allocated[0][7:0];27:buffer_wd<=allocated[0][15:8];
      28:buffer_wd<=file_size[7:0];29:buffer_wd<=file_size[15:8];
     endcase
     if(fill_index==31)begin
      if(slot_offset<480)begin fill_index<=32;end else state<=DIR_WRITE;
     end else if(fill_index==32)state<=DIR_WRITE;
     else fill_index<=fill_index+1'b1;
    end
    DIR_WRITE:write_sector(slot_lba,SUCCESS);
    SUCCESS:begin busy<=0;done<=1;error<=0;state<=IDLE;end
    IO_START:if(io_ready)begin io_request<=1;state<=IO_WAIT;end
    IO_WAIT:if(io_done)begin
     if(io_error!=0)fail(24);
     else if(io_write)begin
      io_write<=0;verify_mode<=1;mismatch<=0;purpose<=P_VERIFY;state<=IO_START;
     end else if(verify_mode && mismatch)fail(25);
     else begin verify_mode<=0;state<=return_state;end
    end
   endcase
   if(busy && timer>=(CLK_HZ/1000)*TIMEOUT_MS)fail(26);
  end
 end
endmodule
`default_nettype wire
