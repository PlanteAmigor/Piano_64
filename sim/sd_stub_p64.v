//==========================================================================
//  sd_stub_p64.v —— 仿真用假 sd_file_list_reader（针对 P64.BIN）
//
//  接口与官方 sd_file_list_reader 完全一致，但：
//      · 根目录只有 1 个文件 "P64.BIN"，编号 1
//      · op=1 时把磁盘上的 P64.BIN 按字节流吐出（outen/outbyte）
//  这样就能把 sd_ddr_loader 的「字节→256 位→写 DDR→读回校验」整段离线验证。
//==========================================================================
`default_nettype none

module sd_file_list_reader #(
    parameter [2:0] CLK_DIV  = 3'd2,
    parameter       SIMULATE = 0
)(
    input  wire        rstn,
    input  wire        clk,
    output wire        sdclk,
    inout              sdcmd,
    input  wire        sddat0,
    output wire [ 3:0] card_stat,
    output wire [ 1:0] card_type,
    output wire [ 1:0] filesystem_type,
    output reg         file_found,
    input  wire        op,
    input  wire [11:0] read_file,
    output reg  [ 2:0] done,
    output reg  [ 7:0] list_name [0:51],
    output reg  [ 7:0] list_namelen,
    output reg  [11:0] list_file_num,
    output reg         list_en,
    output reg         outen,
    output reg  [ 7:0] outbyte,
    output wire        debug_read_done,
    output wire [31:0] debug_read_sector_no,
    output wire        debug_filesystem_state
);

    assign sdclk = 1'b0;
    assign sdcmd = 1'bz;
    assign card_stat = 4'h8;
    assign card_type = 2'd3;
    assign filesystem_type = 2'd3;
    assign debug_read_done = 1'b0;
    assign debug_read_sector_no = 32'd0;
    assign debug_filesystem_state = 1'b0;

    integer fd;
    integer i;
    integer cnt;

    localparam [2:0] P_IDLE = 3'd0,
                     P_LIST = 3'd1,
                     P_READ = 3'd2,
                     P_DONE = 3'd3,
                     P_LWAIT= 3'd4;

    reg [2:0]  ph;
    reg [15:0] gap;

    // 把名字写成 "P64.BIN"
    task set_name;
        begin
            for (i = 0; i < 52; i = i + 1) list_name[i] = 8'h00;
            list_name[0] = 8'h50;  // P
            list_name[1] = 8'h36;  // 6
            list_name[2] = 8'h34;  // 4
            list_name[3] = 8'h2E;  // .
            list_name[4] = 8'h42;  // B
            list_name[5] = 8'h49;  // I
            list_name[6] = 8'h4E;  // N
            list_namelen = 8'd7;
        end
    endtask

    initial begin
        ph = P_IDLE; done = 3'd0; list_en = 1'b0; outen = 1'b0;
        outbyte = 8'd0; file_found = 1'b0; list_file_num = 12'd0;
        list_namelen = 8'd0; gap = 16'd0; fd = 0; cnt = 0;
        set_name;
    end

    always @(posedge clk) begin
        if (!rstn) begin
            ph      <= P_IDLE;
            done    <= 3'd0;
            list_en <= 1'b0;
            outen   <= 1'b0;
            gap     <= 16'd0;
            file_found <= 1'b0;
        end
        else begin
            case (ph)
            //---------------------------------------------- 复位后等 op
            P_IDLE: begin
                done <= 3'd0;
                outen <= 1'b0;
                if (!op) begin
                    gap <= 16'd64;      // 模拟 SD 初始化耗时
                    ph  <= P_LIST;
                end
                else begin
                    fd   = $fopen("P64.BIN", "rb");
                    if (fd == 0) begin
                        $display("[STUB] 打不开 P64.BIN");
                        done <= 3'b111;
                        ph   <= P_DONE;
                    end
                    else begin
                        file_found <= 1'b1;
                        gap <= 16'd64;
                        ph  <= P_READ;
                    end
                end
            end

            //---------------------------------------------- 列目录
            P_LIST: begin
                if (gap != 16'd0) gap <= gap - 16'd1;
                else begin
                    list_file_num <= 12'd1;
                    set_name;
                    list_en <= 1'b1;
                    done    <= 3'b001;      // ★ 列目录完成
                    ph      <= P_LWAIT;
                end
            end

            P_LWAIT: begin
                list_en <= 1'b0;
                done    <= 3'b001;
            end

            //---------------------------------------------- 吐文件字节
            P_READ: begin
                list_en <= 1'b0;
                if (gap != 16'd0) gap <= gap - 16'd1;
                else begin
                    cnt = $fgetc(fd);
                    if (cnt < 0) begin
                        $fclose(fd);
                        outen <= 1'b0;
                        done  <= 3'b100;
                        ph    <= P_DONE;
                    end
                    else begin
                        outen   <= 1'b1;
                        outbyte <= cnt[7:0];
                        // 每拍一个字节（仿真加速；真卡是 12.5MHz/8）
                        gap <= 16'd0;
                    end
                end
            end

            P_DONE: begin
                outen <= 1'b0;
                list_en <= 1'b0;
                if (!rstn) ph <= P_IDLE;
            end
            endcase
        end
    end

endmodule

`default_nettype wire
