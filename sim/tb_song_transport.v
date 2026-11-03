`timescale 1ns/1ps
`default_nettype none
module tb_song_transport;
    reg clk=0, rst_n=0;
    always #10 clk=~clk;
    reg [7:0] data=0;
    reg valid=0, byte_error=0;
    wire we, song_valid, idle;
    wire [10:0] wa;
    wire [63:0] wd;
    wire [15:0] count;
    wire [7:0] err;
    wire [31:0] duration;
    wire [1:0] timbre;
    song_loader #(.CLK_HZ(50000),.TIMEOUT_MS(10)) dut (
        .clk(clk),.rst_n(rst_n),.byte_data(data),.byte_valid(valid),.byte_error(byte_error),
        .ram_we(we),.ram_waddr(wa),.ram_wdata(wd),.song_valid(song_valid),
        .song_count(count),.song_duration(duration),.song_timbre(timbre),
        .err_code(err),.busy(),.frame_hit(),.stream_idle(idle)
    );
    reg [63:0] ram[0:2047];
    integer writes=0;
    always @(posedge clk) if(we) begin
        if(wa!==writes[10:0]) $fatal(1,"nonsequential RAM write %d/%d",wa,writes);
        ram[wa]<=wd; writes=writes+1;
    end
    reg [1023:0] file_name, dump_name;
    integer fd,c,gap=4,want_valid=1,want_count=47,force_error=0;
    initial begin
        if(!$value$plusargs("FILE=%s",file_name)) $fatal(1,"FILE required");
        if(!$value$plusargs("DUMP=%s",dump_name)) dump_name="work/events.hex";
        if($value$plusargs("GAP=%d",gap)) begin end
        if($value$plusargs("VALID=%d",want_valid)) begin end
        if($value$plusargs("COUNT=%d",want_count)) begin end
        if($value$plusargs("BYTE_ERROR=%d",force_error)) begin end
        repeat(5) @(negedge clk); rst_n=1;
        fd=$fopen(file_name,"rb"); if(!fd) $fatal(1,"open input");
        c=$fgetc(fd);
        while(c>=0) begin
            @(negedge clk); valid=1; data=c;
            if(gap>1) begin
                @(negedge clk); valid=0;
                repeat(gap-2) @(negedge clk);
            end
            c=$fgetc(fd);
        end
        @(negedge clk); valid=0; byte_error=force_error;
        @(negedge clk); byte_error=0;
        repeat(15000) @(negedge clk);
        if(song_valid!==want_valid[0]) $fatal(1,"valid=%d expected=%d err=%d writes=%d",song_valid,want_valid,err,writes);
        if(want_valid && (err!=0 || count!=want_count || writes!=want_count || !idle))
            $fatal(1,"bad complete upload count=%d writes=%d err=%d idle=%b",count,writes,err,idle);
        if(!want_valid && err==0) $fatal(1,"invalid upload must report error");
        if(want_valid) $writememh(dump_name,ram,0,want_count-1);
        $display("PASS transport valid=%d count=%d writes=%d err=%d",song_valid,count,writes,err);
        $finish;
    end
    initial begin #50000000; $fatal(1,"timeout"); end
endmodule
`default_nettype wire
