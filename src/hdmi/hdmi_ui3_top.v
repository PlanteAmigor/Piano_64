// Native 1920x1080p60: performance, eight-key test, score/teaching pages.
// 16x32 glyphs, integer-scaled titles, live spectrum/components and 256x256
// persistence plot. Sample DSP uses CLK_SCOPE (global 50 MHz); only complete
// coordinates cross into the 148.5 MHz pixel domain. Registered coordinates and ten pixel stages align
// the text/geometry, graph overlays, palette and fade with DE/HS/VS.
`include "src/hdmi/ui_video_mode.vh"
`default_nettype none

module hdmi_ui3_top (
    input wire CLK_SCOPE,
    input  wire clk,                        // 50 MHz 晶振
    input  wire resetn,                     // 低有效

    // ── 来自 spec_cqt（clk_sys 域）──────────────────────────────────
    input  wire [32*8-1:0] BANDS,           // 32 × 8 位柱高
    input  wire            BANDS_TICK,      // 保留端口（采样不做门控，见下）

    // ── 来自 add_top 的状态总线（clk_sys 域，慢变量）─────────────────
    //    [1:0] ui_mode  [3:2] timbre  [6:4] fx  [18:11] transpose
    input  wire [18:0]     UI_INFO,
    input wire [383:0] SONG_UI,
    input wire [1023:0] SONG_ROLL,
    input wire SONG_UI_TOGGLE,
    output reg SONG_UI_ACK,

    // ── COMPONENT 64：最近触发声部的 64 根分量柱高度 ────────────────
    input  wire [64*8-1:0] COMP_AMP,

    // ── 李萨如（相位图）取样：SCOPE_TOG 每样点翻转一次 ──────────────
    input  wire signed [15:0] SCOPE_SMP,
    input  wire               SCOPE_TOG,
    // ── note-on 触发（每次按键触发翻转一次）────────────────────────
    input  wire               SCOPE_TRG,

    output wire       tmds_clk_n_0,
    output wire       tmds_clk_p_0,
    output wire [2:0] tmds_d_n_0,
    output wire [2:0] tmds_d_p_0
);

    // ══════════════════════════════════════════════════════════════
    //  时钟与复位
    //  ★ SIM_UI3 仅用于离线出图（tb 直接喂 clk，绕过 PLL 与 DVI 原语），
    //    build_full.tcl 从不定义它，不影响综合。
    // ══════════════════════════════════════════════════════════════
`ifdef SIM_UI3
    wire pll_lock = 1'b1;
    wire clk_p    = clk;
    wire clk_p5   = clk;
`else
    wire pll_lock, clk_p, clk_p5;
    Gowin_PLL_720P u_pll (
        .lock(pll_lock), .clkout0(clk_p), .clkout1(clk_p5), .clkin(clk)
    );
`endif

    reg [3:0] por = 4'd0;
    always @(posedge clk_p) begin
        if (!resetn || !pll_lock) por <= 4'd0;
        else if (por != 4'hF)     por <= por + 4'd1;
    end
    reg rst_n=1'b0;
    always @(posedge clk_p)rst_n<=resetn && pll_lock && por==4'hF;
    wire dvi_reset = ~rst_n;
    // Independent, cycle-identical reset registers keep wide status buses
    // from sharing a single routed reset net with the plotter and counters.
    wire [7:0] local_rst_n;
    generate for(genvar rb=0;rb<8;rb=rb+1)begin:g_local_reset
        reg reset_q /* synthesis syn_preserve=1 */ =1'b0;
        wire reset_keep /* synthesis syn_keep=1 */;
        always @(posedge clk_p)reset_q<=resetn && pll_lock && por==4'hF;
        assign reset_keep=reset_q;assign local_rst_n[rb]=reset_keep;
    end endgenerate

    // ══════════════════════════════════════════════════════════════
    //  BANDS 跨时钟域：clk_sys(50 MHz) → clk_p(75 MHz)
    //
    //  ★ 不要加 tick 门控！第一版写成 `if (bt_sync[1]) bands_cap <= BANDS;`，
    //    结果 bt_sync 又只来自 BANDS_TICK，两边互为前提，综合器判定这段
    //    无用，直接把整个 spec_cqt 扫掉（NL0002 is swept in optimizing）。
    //    物理上也根本不需要：BANDS 只在扫完 32 段时更新，两次更新之间静止
    //    几十毫秒，不存在多位撕裂窗口。直接每拍采样最稳。
    //  ★ 必须加复位，否则综合器按「上电未知 = don't care」处理。
    // ══════════════════════════════════════════════════════════════
    reg [255:0] bands_cap;
    reg [511:0] comp_cap;
    reg [18:0]  info_s0, info_s1;

    always @(posedge clk_p) begin
        if (!local_rst_n[0]) begin
            bands_cap <= 256'd0;
            comp_cap  <= 512'd0;
            info_s0   <= 19'd0;
            info_s1   <= 19'd0;
        end
        else begin
            bands_cap <= BANDS;
            comp_cap  <= COMP_AMP;
            info_s0   <= UI_INFO;
            info_s1   <= info_s0;
        end
    end

    // Atomic status mailbox from the audio clock domain.
    reg [2:0] song_toggle_sync;
    reg [383:0] song_status;
    reg [1023:0] roll_status;
    always @(posedge clk_p) begin
        if(!local_rst_n[1]) begin song_toggle_sync<=0; SONG_UI_ACK<=0; song_status<=0; roll_status<=0; end
        else begin
            song_toggle_sync<={song_toggle_sync[1:0],SONG_UI_TOGGLE};
            if(song_toggle_sync[2]!=SONG_UI_ACK) begin
                song_status<=SONG_UI;roll_status<=SONG_ROLL;
                SONG_UI_ACK<=song_toggle_sync[2];
            end
        end
    end
    wire bt_saving=song_status[316],bt_uploading=song_status[317],bt_committed=song_status[318];
    wire [7:0] bt_saved_id=song_status[326:319],bt_error=song_status[334:327];
    wire [255:0] bt_message=bt_saving?"BT / SAVING TO SD               ":bt_uploading?"BT / RECEIVING SCORE            ":
        bt_error!=0?"BT / UPLOAD FAILED. RETRY        ":bt_committed?"BT / SAVED TO SD - SONG          ":"BT / READY TO RECEIVE           ";
    wire guide_catalog_ready=song_status[232];
    wire [4:0] guide_count=song_status[132:128];
    wire [3:0] guide_selected=song_status[136:133];
    wire [2:0] guide_state=song_status[139:137];
    wire guide_teach=song_status[140];
    wire [1:0] guide_countdown=song_status[143:142];
    wire [6:0] guide_expected=song_status[150:144];
    wire [6:0] guide_matched=song_status[157:151];
    wire [7:0] guide_error=song_status[165:158];
    wire [31:0] guide_ms=song_status[197:166];
    wire [1:0]        page_req = info_s1[1:0];
    wire [1:0]        timbre   = info_s1[3:2];
    wire [2:0]        fx       = info_s1[6:4];   // 0=NONE 1=REVERB 2=DELAY 3=SUSTAIN 4=CHORUS
    wire [1:0]        agl      = info_s1[8:7];
    wire [1:0]        flt_sel  = info_s1[10:9];
    wire signed [7:0] tr       = info_s1[18:11];

    // ══════════════════════════════════════════════════════════════
    //  李萨如（相位图）：取样 + AGC + 单次捕获
    //
    //  1) 取样：发端（add_top）每样点锁一次 SCOPE_SMP 并翻转 SCOPE_TOG。
    //     这里把 SCOPE_TOG 打两拍后检测翻转沿产生单拍 plot；
    //     SCOPE_SMP 在两次翻转之间稳定 1024 个 clk_sys 周期（20.5 us），
    //     远大于两拍 clk_p（26.7 ns），所以直接在 plot 那拍采样即可。
    //
    //  2) AGC：峰值跟随（瞬时攻击 / 慢衰减）→ 归一化增益。
    //     解决两个问题：
    //       · 轻力度时图只有窗口的 1/8 大 → 现在一律撑满
    //       · 音符衰减过程中同一个椭圆被画成一串同心环 → 现在半径恒定
    //         （这是钢琴/古筝"模糊"的真正原因，不是分辨率不够）
    //
    //  3) 单次捕获：SCOPE_TRG（note-on）→ 清零 → 画 200 ms → 冻结。
    //     每个音只画一张干净、稳定、满幅的相位图。
    // ══════════════════════════════════════════════════════════════
    // Audio-rate display processing uses the 50 MHz reference clock.
    reg [3:0] scope_por;
    reg [1:0] scope_flt0,scope_flt1;
    always @(posedge CLK_SCOPE)begin
        if(!resetn)begin scope_por<=0;scope_flt0<=0;scope_flt1<=0;end
        else begin
            if(scope_por!=15)scope_por<=scope_por+1'b1;
            scope_flt0<=UI_INFO[10:9];scope_flt1<=scope_flt0;
        end
    end
    wire [7:0] px_pt,py_pt;
    wire point_toggle;
    ui_scope_points u_scope(.clk(CLK_SCOPE),.rst_n(scope_por==15),.flt_sel(scope_flt1),
        .SCOPE_SMP(SCOPE_SMP),.SCOPE_TOG(SCOPE_TOG),.SCOPE_TRG(SCOPE_TRG),
        .px_pt(px_pt),.py_pt(py_pt),.point_toggle(point_toggle));
    reg [2:0] point_sync,trg_sync;
    always @(posedge clk_p)begin
        if(!local_rst_n[2])begin point_sync<=0;trg_sync<=0;end
        else begin point_sync<={point_sync[1:0],point_toggle};trg_sync<={trg_sync[1:0],SCOPE_TRG};end
    end
    wire liss_plot=point_sync[2]^point_sync[1];
    wire noteon=trg_sync[2]^trg_sync[1];

    // ══════════════════════════════════════════════════════════════
    //  切页淡入淡出：12 ms 淡出（15→0）→ 黑场换页 → 12 ms 淡入（0→15）
    //    75 MHz × 12 ms / 15 档 = 60000 拍/档
    // ══════════════════════════════════════════════════════════════
    localparam [16:0] FADE_STEP = 17'd118_799;

    reg [1:0]  page_show;
    reg [1:0]  page_pend;
    reg [3:0]  fade_lvl;
    reg        fading_out;
    reg [16:0] fade_cnt;
    // Register the next carry predicates to keep the long counter off the pixel critical path.
    reg fade_carry6,fade_carry12;
    wire [16:0] fade_increment={
        fade_cnt[16:12]+{4'd0,fade_carry12},
        fade_cnt[11:6]+{5'd0,fade_carry6},
        fade_cnt[5:0]+6'd1};

    always @(posedge clk_p) begin
        if (!local_rst_n[3]) begin
            page_show  <= 2'd0;
            page_pend  <= 2'd0;
            fade_lvl   <= 4'd15;
            fading_out <= 1'b0;
            fade_cnt   <= 17'd0;
            fade_carry6 <= 1'b0;
            fade_carry12 <= 1'b0;
        end
        else if (!fading_out && (page_req != page_show)) begin
            fading_out <= 1'b1;              // 开始淡出
            page_pend  <= page_req;
            fade_cnt   <= 17'd0;
            fade_carry6 <= 1'b0;
            fade_carry12 <= 1'b0;
        end
        else if (fading_out) begin
            if (fade_cnt != FADE_STEP) begin
                fade_cnt <= fade_increment;
                fade_carry6 <= fade_cnt[5:0]==6'd62;
                fade_carry12 <= fade_cnt[11:0]==12'd4094;
            end
            else begin
                fade_cnt <= 17'd0;
                fade_carry6 <= 1'b0;
                fade_carry12 <= 1'b0;
                if (fade_lvl != 4'd0) fade_lvl <= fade_lvl - 4'd1;
                else begin
                    page_show  <= page_pend; // 全黑时换页
                    fading_out <= 1'b0;
                end
            end
        end
        else if (fade_lvl != 4'd15) begin    // 淡入
            if (fade_cnt != FADE_STEP) begin
                fade_cnt <= fade_increment;
                fade_carry6 <= fade_cnt[5:0]==6'd62;
                fade_carry12 <= fade_cnt[11:0]==12'd4094;
            end
            else begin
                fade_cnt <= 17'd0;
                fade_carry6 <= 1'b0;
                fade_carry12 <= 1'b0;
                fade_lvl <= fade_lvl + 4'd1;
            end
        end
    end

    // CEA-861 60 Hz. The 720p output samples the complete logical 1920x1080
    // layout at 3:2; no panel, status line or teaching lane is cropped.
`ifdef UI_VIDEO_720P
    localparam integer H_TOTAL=1650,H_FP=110,H_SYNC=40,H_BP=220,H_VIS=1280;
    localparam integer V_TOTAL=750,V_FP=5,V_SYNC=5,V_BP=20,V_VIS=720;
    localparam integer H_START=370,V_START=30;
`else
    // CEA-861 1920x1080p60: 148.5 MHz / (2200 * 1125).
    localparam integer H_TOTAL=2200,H_FP=88,H_SYNC=44,H_BP=148,H_VIS=1920;
    localparam integer V_TOTAL=1125,V_FP=4,V_SYNC=5,V_BP=36,V_VIS=1080;
    localparam integer H_START=280,V_START=45;
`endif
    reg [11:0] hcnt,vcnt;
    wire [11:0] physical_x=hcnt-H_START,physical_y=vcnt-V_START;
`ifdef UI_VIDEO_720P
    wire [11:0] logical_x=physical_x+(physical_x>>1);
    wire [11:0] logical_y=physical_y+(physical_y>>1);
`else
    wire [11:0] logical_x=physical_x,logical_y=physical_y;
`endif
    // Keep local coordinate registers for four descriptors per bank. Shared
    // low coordinate bits otherwise drive every wide comparison across the
    // device and routing, rather than arithmetic, dominates the pixel path.
    wire [11:0] roll_x[0:31],roll_y[0:31];
    generate for(genvar bank=0;bank<32;bank=bank+1)begin:g_roll_coord
        reg [11:0] x_q /* synthesis syn_preserve=1 */;
        reg [11:0] y_q /* synthesis syn_preserve=1 */;
        wire [11:0] x_keep /* synthesis syn_keep=1 */;
        wire [11:0] y_keep /* synthesis syn_keep=1 */;
        always @(posedge clk_p)begin x_q<=logical_x;y_q<=logical_y;end
        assign x_keep=x_q;assign y_keep=y_q;
        assign roll_x[bank]=x_keep;assign roll_y[bank]=y_keep;
    end endgenerate
    always @(posedge clk_p) begin
        if(!local_rst_n[4])begin hcnt<=0;vcnt<=0;end
        else if(hcnt==H_TOTAL-1)begin hcnt<=0;vcnt<=vcnt==V_TOTAL-1?0:vcnt+1'b1;end
        else hcnt<=hcnt+1'b1;
    end
    reg vis,hsync,vsync,frame_tick;
    reg [11:0] px,py;
    always @(posedge clk_p)begin
        vis<=hcnt>=H_START && hcnt<H_START+H_VIS && vcnt>=V_START && vcnt<V_START+V_VIS;
        hsync<=hcnt>=H_FP && hcnt<H_FP+H_SYNC;
        vsync<=vcnt>=V_FP && vcnt<V_FP+V_SYNC;
        px<=logical_x;py<=logical_y;
        frame_tick<=local_rst_n[4] && hcnt==H_TOTAL-1 && vcnt==V_TOTAL-1;
    end
    reg [3:0] boot_cnt;
    always @(posedge clk_p)if(!local_rst_n[5])boot_cnt<=0;else if(boot_cnt!=15)boot_cnt<=boot_cnt+1'b1;
    wire liss_clr=boot_cnt==8 || noteon;
    reg [2:0] liss_decay_frame;
    always @(posedge clk_p)if(!local_rst_n[5])liss_decay_frame<=0;else if(frame_tick)liss_decay_frame<=liss_decay_frame+1'b1;
    reg liss_decay;
    always @(posedge clk_p)liss_decay<=local_rst_n[5] && vcnt==1 && hcnt==0 &&
        (agl==3 || (agl==2 && !liss_decay_frame[0]) || (agl==1 && liss_decay_frame[1:0]==0) || liss_decay_frame==0);
    wire [3:0] agl_dec=1;
    wire [3:0] agl_ink=15;

    // Native 16x32 font. Text cells occupy 120x34 locations per page.
    reg [7:0] text_rom[0:12287];
    reg [15:0] glyph[0:4095];
    initial begin
        $readmemh("src/hdmi/ui/ui1080_tiles.hex",text_rom);
        $readmemh("src/hdmi/ui/ui1080_font.hex",glyph);
    end
    wire title_on=py>=32 && py<96 && px>=64 && px<1280;
    wire [6:0] tile_col=title_on ? ((px-64)>>5) : px[10:4];
    wire [5:0] tile_row=title_on ? 0 : py[10:5];
    wire [4:0] map_row=tile_row==32?5'd1:tile_row[4:0];
    // Prepare the ROM address alongside px/py; the memory input sees only
    // a register, while all geometry keeps the existing pixel latency.
    wire title_next=logical_y>=32 && logical_y<96 && logical_x>=64 && logical_x<1280;
    wire [6:0] tile_col_next=title_next ? (logical_x[11:5]-7'd2) : logical_x[10:4];
    wire [5:0] tile_row_next=title_next ? 0 : logical_y[10:5];
    wire [4:0] map_row_next=tile_row_next==32?5'd1:tile_row_next[4:0];
    reg [13:0] tile_addr /* synthesis syn_preserve=1 */;
    always @(posedge clk_p)tile_addr<={page_show,map_row_next,tile_col_next};
    wire [3:0] font_x=title_on ? ((px-64)>>1) : px[3:0];
    wire [4:0] font_y=title_on ? ((py-32)>>1) : py[4:0];
    reg [11:0] x1,y1,x2,y2;
    reg [6:0] col1;
    reg [5:0] row1;
    reg [3:0] gx1,gx2;
    reg [4:0] gy1;
    reg [7:0] text1;
    reg [15:0] glyph2;
    wire [31:0] guide_duration=song_status[287:256];
    wire [10:0] guide_progress=song_status[298:288];
    wire [7:0] perf_keys=song_status[306:299];
    wire perf_hand=song_status[307];
    wire [7:0] perf_level=song_status[315:308];

    // Four sequential decimal conversions during blanking; no divider in pixels.
    reg [31:0] decimal_bin;
    reg [39:0] decimal_work,decimal_adjust;
    reg [39:0] time_bcd,total_bcd,miss_bcd,wrong_bcd;
    reg [5:0] decimal_left;
    reg [1:0] decimal_field;
    reg decimal_busy;
    reg decimal_rst_n;
    always @(posedge clk_p)decimal_rst_n<=local_rst_n[6];
    integer dc;
    always @(*)begin
        decimal_adjust=decimal_work;
        for(integer d=0;d<10;d=d+1)
            if(decimal_work[d*4+:4]>=5)decimal_adjust[d*4+:4]=decimal_work[d*4+:4]+4'd3;
    end
    wire [39:0] decimal_next={decimal_adjust[38:0],decimal_bin[31]};
    always @(posedge clk_p)begin
        if(!decimal_rst_n)begin decimal_busy<=0;decimal_field<=0;decimal_left<=0;decimal_work<=0;
            decimal_bin<=0;time_bcd<=0;total_bcd<=0;miss_bcd<=0;wrong_bcd<=0;end
        else if(frame_tick && !decimal_busy)begin
            decimal_busy<=1;decimal_field<=0;decimal_left<=32;decimal_bin<=guide_ms;decimal_work<=0;
        end else if(decimal_busy)begin
            decimal_bin<={decimal_bin[30:0],1'b0};decimal_work<=decimal_next;decimal_left<=decimal_left-1'b1;
            if(decimal_left==1)begin
                case(decimal_field)
                    0:time_bcd<=decimal_next;
                    1:total_bcd<=decimal_next;
                    2:miss_bcd<=decimal_next;
                    3:wrong_bcd<=decimal_next;
                endcase
                if(decimal_field==3)decimal_busy<=0;
                else begin
                    decimal_field<=decimal_field+1'b1;decimal_left<=32;decimal_work<=0;
                    case(decimal_field)
                        0:decimal_bin<=guide_duration;
                        1:decimal_bin<={16'd0,song_status[229:214]};
                        default:decimal_bin<={16'd0,song_status[213:198]};
                    endcase
                end
            end
        end
    end
    function [7:0] string_char;
        input [255:0] s;input [4:0] c;
        begin string_char=s[{~c,3'b000}+:8];end
    endfunction
    function [7:0] instrument_char;
 input [1:0] inst;input [2:0] c;
 begin instrument_char=32;case(inst)
2'd0:case(c) 0:instrument_char=8'd10;1:instrument_char=8'd11;default:instrument_char=32;endcase
2'd1:case(c) 0:instrument_char=8'd12;1:instrument_char=8'd13;default:instrument_char=32;endcase
2'd2:case(c) 0:instrument_char=8'd14;1:instrument_char=8'd15;default:instrument_char=32;endcase
2'd3:case(c) 0:instrument_char=8'd16;1:instrument_char=8'd17;default:instrument_char=32;endcase
endcase end endfunction
    wire [255:0] effect_name=fx==0?"NONE                            ":fx==1?"REVERB                          ":
        fx==2?"DELAY                           ":fx==3?"SUSTAIN                         ":"CHORUS                          ";
    wire [255:0] guide_message=guide_state==0?(!guide_catalog_ready?"WAIT FOR SD CARD                ":guide_count==0?"NO SONGS ON SD                  ":"SELECT A SONG                   "):guide_state==1?"CHOOSE YOUR MODE                ":
        guide_state==2?"LOADING SCORE                   ":guide_state==4?"SCORE ERROR                     ":
        guide_countdown!=0?"GET READY                       ":guide_teach?"PLAY THE LEAD                   ":"AUTO PLAY                       ";
    `include "src/hdmi/ui/ui1080_decimal.vh"
    // Preformat slow status fields outside the per-pixel character path.
    wire [11:0] catalog_bcd=byte_decimal(catalog_value),level_bcd=byte_decimal(perf_level),error_bcd=byte_decimal(guide_error);
    wire [3:0] catalog_tens=catalog_bcd[7:4],catalog_ones=catalog_bcd[3:0];
    reg [127:0] catalog_digits;
    reg [3:0] catalog_scan,catalog_index;
    reg [7:0] catalog_value;
    reg [3:0] level_hundreds,level_tens,level_ones,error_tens,error_ones;
    always @(posedge clk_p)begin
        if(!local_rst_n[6])begin catalog_digits<=0;catalog_scan<=0;catalog_index<=0;catalog_value<=0;
            level_hundreds<=0;level_tens<=0;level_ones<=0;error_tens<=0;error_ones<=0;end
        else begin
            catalog_scan<=catalog_scan+1'b1;catalog_index<=catalog_scan;
            catalog_value<=song_status[catalog_scan*8+:8];
            catalog_digits[catalog_index*8+:8]<=catalog_value;
            level_hundreds<=level_bcd[11:8];level_tens<=level_bcd[7:4];level_ones<=level_bcd[3:0];
            error_tens<=error_bcd[7:4];error_ones<=error_bcd[3:0];
        end
    end
    reg [7:0] char1;
    reg [7:0] file_number;
    reg file_present1;
    wire [3:0] entry0={guide_selected[3],row1[3:1]^3'd4};
    reg [6:0] catalog_col2;
    reg [5:0] catalog_row2;
    always @(posedge clk_p)begin catalog_col2<=col1;catalog_row2<=row1;end
    always @(posedge clk_p)begin
        file_number<=catalog_digits[{entry0,3'b000}+:8];file_present1<=entry0<guide_count;
    end
    wire [3:0] position_digit=4'd8-col1[3:0],duration_digit=4'd1-col1[3:0];
    wire [2:0] missed_digit=3'd3-col1[2:0],wrong_digit=3'd6-col1[2:0];
    // Dynamic text candidates are mutually exclusive. Register their values
    // and enables in parallel, then merge in one short OR stage before glyph RAM.
    reg [8:0] dynamic_char[0:14];
    reg [7:0] static_char;
    reg [255:0] effect_text,message_text,bt_text;
    always @(posedge clk_p)begin
        effect_text<=effect_name;bt_text<={bt_message[31:0],bt_message[255:32]};
        if(bt_committed && !bt_uploading && !bt_saving && bt_error==0)begin
            bt_text[31:24]<=8'd48+{4'd0,bt_saved_id[7:4]};
            bt_text[23:16]<=8'd48+{4'd0,bt_saved_id[3:0]};
        end
        // Rotate by four cells once per status update, so a pixel's message
        // address uses the column directly without a subtract before the mux.
        message_text<={guide_message[31:0],guide_message[255:32]};
        static_char<=text1;
        dynamic_char[0]<={row1==2 && col1>=96 && col1<101,instrument_char(timbre,col1[2:0])};
        dynamic_char[1]<={row1==3 && col1>=96 && col1<104,string_char(effect_text,{2'd0,col1[2:0]})};
        dynamic_char[2]<={page_show==0 && row1==30 && col1>=82 && col1<85,
            string_char(perf_hand?"ON                              ":"OFF                             ",col1[4:0]-5'd18)};
        dynamic_char[3]<={page_show==0 && row1==30 && col1>=102 && col1<105,
            8'd48+(col1==102?level_hundreds:col1==103?level_tens:level_ones)};
        dynamic_char[4]<={row1==31 && col1>=4 && col1<36,
            string_char(bt_text,col1[4:0])};
        dynamic_char[5]<={page_show==2 && row1==25 && col1>=4 && col1<36,string_char(message_text,col1[4:0])};
        dynamic_char[6]<={page_show==2 && row1==30 && col1>=49 && col1<54,8'd48+{4'd0,time_bcd[{position_digit,2'b00}+:4]}};
        dynamic_char[7]<={page_show==2 && row1==30 && col1==54,8'd83};
        dynamic_char[8]<={page_show==2 && row1==30 && col1==56,8'd47};
        dynamic_char[9]<={page_show==2 && row1==30 && col1>=58 && col1<63,8'd48+{4'd0,total_bcd[{duration_digit,2'b00}+:4]}};
        dynamic_char[10]<={page_show==2 && row1==30 && col1>=87 && col1<92,8'd48+{4'd0,miss_bcd[{missed_digit,2'b00}+:4]}};
        dynamic_char[11]<={page_show==2 && row1==30 && col1>=106 && col1<111,8'd48+{4'd0,wrong_bcd[{wrong_digit,2'b00}+:4]}};
        dynamic_char[12]<={page_show==2 && guide_countdown!=0 && row1==17 && col1==41,8'd48+{6'd0,guide_countdown}};
        dynamic_char[13]<={page_show==2 && guide_state==4 && row1==18 && col1==5,8'd48+error_tens};
        dynamic_char[14]<={page_show==2 && guide_state==4 && row1==18 && col1==6,8'd48+error_ones};
    end
    reg [8:0] catalog_char2;
    always @(*)begin
        catalog_char2={page_show==2 && catalog_row2>=9 && catalog_row2<=23 && catalog_row2[0] &&
            (catalog_col2==11 || catalog_col2==12 || (!file_present1 && catalog_col2>=6 && catalog_col2<13)),
            !file_present1?8'd32:8'd48+(catalog_col2==11?file_number[7:4]:file_number[3:0])};
    end
    reg any_dynamic;
    always @(*)begin
        char1=0;any_dynamic=0;
        for(integer ch=0;ch<15;ch=ch+1)begin
            char1=char1 | (dynamic_char[ch][7:0]&{8{dynamic_char[ch][8]}});
            any_dynamic=any_dynamic|dynamic_char[ch][8];
        end
        char1=char1 | (catalog_char2[7:0]&{8{catalog_char2[8]}});
        any_dynamic=any_dynamic|catalog_char2[8];
        char1=char1 | (static_char&{8{!any_dynamic}});
    end
    reg [11:0] x1b,y1b,x1c,y1c;
    reg [3:0] gx1c;
    reg [4:0] gy1c;
    reg [7:0] height1c,component1c;
    reg [9:0] scaled_height1c,scaled_height2;
    reg [7:0] scaled_component1c,scaled_component2;
    reg band_on1c,comp_on1c,note_lead1c,note_auto1c,note_hit1c,note_edge1c;
    reg [1:0] note_color1c;
    reg [3:0] gx1b;
    reg [4:0] gy1b;
    reg [7:0] char2 /* synthesis syn_preserve=1 */;
    reg [7:0] height1b,component1b;
    reg band_on1b,comp_on1b,note_lead1b,note_auto1b,note_hit1b,note_edge1b;
    reg [1:0] note_color1b;
    // Pixel stage 1: independent lookups and 32 note comparisons.
    reg [4:0] band1;
    reg [5:0] component1;
    reg [7:0] height2,component2;
    reg [7:0] main_band_group[0:3],test_band_group[0:3],component_group[0:7];
    reg test_band1;
    wire [4:0] main_band_index=px[9:5]-5'd2;
    wire [11:0] band_origin=page_show==1?96:64;
    wire [11:0] band_pitch=page_show==1?40:32;
`ifdef UI_VIDEO_720P
    // A 720p pixel advances one or two logical pixels. Track that stride
    // in a six-bit phase counter, avoiding constant division in pixel paths.
    reg [5:0] test_band_column,test_band_phase;
    reg pixel_odd;
    wire [6:0] test_phase_next={1'b0,test_band_phase}+(pixel_odd?7'd2:7'd1);
    always @(posedge clk_p)begin
        pixel_odd<=physical_x[0];
        if(!local_rst_n[7] || px<96)begin test_band_column<=0;test_band_phase<=0;end
        else if(px<1376)begin
            if(test_phase_next>=40)begin test_band_phase<=test_phase_next-7'd40;test_band_column<=test_band_column+1'b1;end
            else test_band_phase<=test_phase_next[5:0];
        end
    end
`else
    reg [5:0] test_band_column,test_band_phase;
    always @(posedge clk_p)begin
        if(!local_rst_n[7] || px==95)begin test_band_column<=0;test_band_phase<=0;end
        else if(px>=96 && px<1376)begin
            if(test_band_phase==39)begin test_band_phase<=0;test_band_column<=test_band_column+1'b1;end
            else test_band_phase<=test_band_phase+1'b1;
        end
    end
    wire [11:0] band_index=page_show==1?{6'd0,test_band_column}:((px-12'd64)>>5);
    wire [11:0] band_phase=page_show==1?{6'd0,test_band_phase}:((px-12'd64)&12'd31);
`endif
`ifdef UI_VIDEO_720P
    wire [11:0] band_index=page_show==1?{6'd0,test_band_column}:((px-12'd64)>>5);
    wire [11:0] band_phase=page_show==1?{6'd0,test_band_phase}:((px-12'd64)&12'd31);
`endif
    reg band_on1,band_on2;
    wire [11:0] comp_x=px-64;
    reg [2:0] component_low0 /* synthesis syn_preserve=1 */;
    always @(posedge clk_p)component_low0<=(logical_x-64)>>4;
    reg comp_on1,comp_on2;
    reg [3:0] roll_column[0:31];
    reg [10:0] roll_bottom_edge[0:31];
    always @(posedge clk_p)for(integer b=0;b<32;b=b+1)begin
        roll_bottom_edge[b]<=roll_status[b*32+1+:11]-11'd2;roll_column[b]<=roll_status[b*32+23+:4]+4'd6;
    end
    reg [31:0] roll_lead1,roll_auto1,roll_hit1,roll_edge1;
    reg [31:0] roll_color0,roll_color1;
    reg note_lead2,note_auto2,note_hit2,note_edge2;
    reg [1:0] note_color2;
    wire [3:0] lane0=(px-768)>>7;
    wire lane_in0=px>=768 && px<1792 && py>=256 && py<880 && px[6:0]>=16 && px[6:0]<112;
    reg roll_area1;
    reg [31:0] above_gt1,above_eq1,above_ge_low1,above_eq_low1;
    reg [31:0] below_lt1,below_eq1,below_lt_low1;
    reg [31:0] edge_gt1,edge_eq1,edge_ge_low1,edge_x1,roll_lane1;
    wire [31:0] roll_above1=above_gt1 | (above_eq1 & above_ge_low1);
    wire [31:0] roll_below1=below_lt1 | (below_eq1 & below_lt_low1);
    wire [31:0] roll_outline1=(above_eq1 & above_eq_low1) | edge_gt1 | (edge_eq1 & edge_ge_low1) | edge_x1;
    reg [4:0] roll_meta1[0:31];
    wire [31:0] roll_rect1=roll_above1 & roll_below1 & roll_lane1 & {32{roll_area1}};
    integer r;
    always @(posedge clk_p)begin
        x1<=px;y1<=py;col1<=tile_col;row1<=tile_row;gx1<=font_x;gy1<=font_y;
        text1<=text_rom[tile_addr];
        // Split wide live-bar lookups over the existing two pixel stages.
        for(integer g=0;g<4;g=g+1)begin
            main_band_group[g]<=bands_cap[g*64+main_band_index[2:0]*8+:8];
            test_band_group[g]<=bands_cap[g*64+test_band_column[2:0]*8+:8];
        end
        test_band1<=page_show==1;
        for(integer g=0;g<8;g=g+1)component_group[g]<=comp_cap[g*64+component_low0*8+:8];
        band1<=band_index[4:0];band_on1<=page_show==1 ? (px>=96 && test_band_column<32 && test_band_phase<32) :
            (px>=64 && px<1088 && px[4:0]<24);
        component1<=comp_x[9:4];comp_on1<=px>=64 && px<1088 && comp_x[3:0]<11;
        roll_area1<=lane_in0;
        for(r=0;r<32;r=r+1)begin
            above_gt1[r]<=roll_y[r][11:6]>{1'b0,roll_status[r*32+18+:5]};
            above_eq1[r]<=roll_y[r][11:6]=={1'b0,roll_status[r*32+18+:5]};
            above_ge_low1[r]<=roll_y[r][5:0]>=roll_status[r*32+12+:6];
            above_eq_low1[r]<=roll_y[r][5:0]==roll_status[r*32+12+:6];
            below_lt1[r]<=roll_y[r][11:6]<{1'b0,roll_status[r*32+7+:5]};
            below_eq1[r]<=roll_y[r][11:6]=={1'b0,roll_status[r*32+7+:5]};
            below_lt_low1[r]<=roll_y[r][5:0]<roll_status[r*32+1+:6];
            edge_gt1[r]<=roll_y[r][11:6]>{1'b0,roll_bottom_edge[r][10:6]};
            edge_eq1[r]<=roll_y[r][11:6]=={1'b0,roll_bottom_edge[r][10:6]};
            edge_ge_low1[r]<=roll_y[r][5:0]>=roll_bottom_edge[r][5:0];
            edge_x1[r]<=roll_x[r][6:0]<19 || roll_x[r][6:0]>=109;
            roll_lane1[r]<=roll_x[r][10:7]==roll_column[r];
            roll_meta1[r]<=roll_status[r*32+27+:5];
            roll_lead1[r]<=roll_rect1[r] && roll_meta1[r][4] && roll_meta1[r][3];
            roll_auto1[r]<=roll_rect1[r] && roll_meta1[r][4] && !roll_meta1[r][3];
            roll_hit1[r]<=roll_rect1[r] && roll_meta1[r][4] && roll_meta1[r][2];
            roll_edge1[r]<=roll_rect1[r] && roll_meta1[r][4] && roll_outline1[r];
            roll_color0[r]<=roll_rect1[r] && roll_meta1[r][4] && roll_meta1[r][3] && roll_meta1[r][0];
            roll_color1[r]<=roll_rect1[r] && roll_meta1[r][4] && roll_meta1[r][3] && roll_meta1[r][1];
        end
        x1b<=x1;y1b<=y1;gx1b<=gx1;gy1b<=gy1;char2<=char1;
        height1b<=test_band1?test_band_group[band1[4:3]]:main_band_group[band1[4:3]];component1b<=component_group[component1[5:3]];
        band_on1b<=band_on1;comp_on1b<=comp_on1;

        x1c<=x1b;y1c<=y1b;gx1c<=gx1b;gy1c<=gy1b;
        scaled_height1c<=page_show==1?({2'd0,height1b}<<1)+({2'd0,height1b}>>1):{2'd0,height1b};
        scaled_component1c<=(component1b>>1)+(component1b>>2);
        height1c<=height1b;component1c<=component1b;band_on1c<=band_on1b;comp_on1c<=comp_on1b;
        note_lead1c<=|roll_lead1;note_auto1c<=|roll_auto1;note_hit1c<=|roll_hit1;note_edge1c<=|roll_edge1;note_color1c<={|roll_color1,|roll_color0};
        x2<=x1c;y2<=y1c;gx2<=gx1c;glyph2<=glyph[{char2[6:0],gy1c}];
        height2<=height1c;component2<=component1c;scaled_height2<=scaled_height1c;scaled_component2<=scaled_component1c;
        band_on2<=band_on1c;comp_on2<=comp_on1c;
        note_lead2<=note_lead1c;note_auto2<=note_auto1c;note_hit2<=note_hit1c;note_edge2<=note_edge1c;
        note_color2<=note_color1c;
    end
    // 256x256 native persistence grid, displayed at integer 2x scaling.
    wire liss_in0=px>=1272 && px<1784 && py>=304 && py<816;
    wire [8:0] lx=(px-1272)>>1,ly=(py-304)>>1;
    wire [8:0] lx_next=(logical_x-12'd1272)>>1,ly_next=(logical_y-12'd304)>>1;
    reg [12:0] liss_raddr /* synthesis syn_preserve=1 */;
    // Out-of-panel reads are harmless; visibility masks the pixel later.
    always @(posedge clk_p)liss_raddr<={ly_next[7:0],lx_next[7:3]};
    wire [15:0] liss_word;
    reg [15:0] liss_word_q;
    reg [2:0] nibble2;
    reg [2:0] nibble1;
    reg liss_in1,liss_in2;
    reg [3:0] liss_int,liss_intb,liss_intc;
    reg liss_in2b,liss_in2c;
    always @(posedge clk_p)begin
        nibble1<=lx[2:0];liss_in1<=liss_in0;liss_in2<=liss_in1;
        liss_word_q<=liss_word;nibble2<=nibble1;
        liss_int<={2{liss_word_q[nibble2*2+:2]}};liss_in2b<=liss_in2;liss_intc<=liss_int;liss_in2c<=liss_in2b;
    end
    ui_liss_ram #(.COORD_BITS(8),.PIXEL_BITS(2)) u_liss(.clk(clk_p),.rst_n(local_rst_n[5]),.plot(liss_plot),
        .plot_x(px_pt),.plot_y(py_pt),.clr_en(liss_clr),.clr_done(),
        .decay_req(liss_decay),.decay_step(agl_dec),.ink_step(agl_ink),.decay_busy(),
        .raddr(liss_raddr),.rdata(liss_word));
    function box;
        input [11:0] x,y,x0,y0,xend,yend;
        begin box=x>=x0 && x<xend && y>=y0 && y<yend;end
    endfunction
    function border;
        input [11:0] x,y,x0,y0,xend,yend;
        begin border=box(x,y,x0,y0,xend,yend) && (x==x0||x==xend-1||y==y0||y==yend-1);end
    endfunction
    wire [11:0] spectrum_base=page_show==1?896:544;
    wire [11:0] spectrum_height={2'd0,scaled_height2};
    wire spectrum_lit=band_on2 && y2<spectrum_base && y2+spectrum_height>=spectrum_base && y2>=(page_show==1?256:288);
    wire component_lit=comp_on2 && y2<928 && y2+{4'd0,scaled_component2}>=12'd928 && y2>=696;
    wire [2:0] key_lane1c=x1c[9:7]-3'd6;
    reg [2:0] key_lane;
    reg key_region,key_expected,key_matched;
    always @(posedge clk_p)begin
        key_lane<=key_lane1c;
        key_region<=x1c>=768 && x1c<1792 && y1c>=888 && y1c<944;
        key_expected<=key_lane1c<7 && guide_expected[key_lane1c];
        key_matched<=key_lane1c<7 && guide_matched[key_lane1c];
    end
    wire [23:0] accent=timbre==0?24'h55D8F0:timbre==1?24'hF7C47A:timbre==2?24'hF18F9F:24'h9BCB94;
    wire [23:0] note_color=note_color2==0?24'h55D8F0:note_color2==1?24'hF7C47A:note_color2==2?24'hF18F9F:24'h9BCB94;
    reg [23:0] rgb,background;
    reg [23:0] background3,liss_color3,note_color3,text_color3;
    reg spectrum3,spectrum_high3,component3,liss3,note_auto3,note_lead3,note_hit3,note_edge3,judgment3,text3;
    always @(posedge clk_p)begin
        bg_flags3<=bg_flags;
        spectrum3<=page_show!=2 && spectrum_lit;spectrum_high3<=y2<(page_show==1?12'd544:12'd400);
        component3<=page_show==0 && component_lit;
        liss3<=page_show==0 && liss_in2c && liss_intc!=0;
        liss_color3<={liss_intc,4'h8,liss_intc,4'hF,liss_intc,4'hA};
        note_auto3<=page_show==2 && note_auto2;note_lead3<=page_show==2 && note_lead2;
        note_hit3<=page_show==2 && note_hit2;note_edge3<=page_show==2 && note_edge2;
        note_color3<=note_color;
        judgment3<=page_show==2 && box(x2,y2,752,862,1808,866);
        text3<=glyph2[gx2] && y2>=32 && y2<1056;
        text_color3<=page_show==2 && key_region?24'h142332:y2<128?24'hEDF4F7:24'hB7CBD8;
    end
    reg [31:0] bg_flags,bg_flags3;
    reg testkey_any,testkey_down,testind_any,testind_down,card_any,card_selected,card_stripe;
    reg [11:0] level_end,progress_end;
    reg progress_lt_hi,progress_eq_hi,progress_lt_lo;
    reg level_lt_hi,level_eq_hi,level_lt_lo;
    always @(posedge clk_p)begin
        level_lt_hi<=x1c[11:6]<level_end[11:6];
        level_eq_hi<=x1c[11:6]==level_end[11:6];
        level_lt_lo<=x1c[5:0]<level_end[5:0];
        progress_lt_hi<=x1c[11:6]<progress_end[11:6];
        progress_eq_hi<=x1c[11:6]==progress_end[11:6];
        progress_lt_lo<=x1c[5:0]<progress_end[5:0];
    end
    reg [7:0] visible_cards;
    wire [11:0] bg_x[0:3],bg_y[0:3];
    generate for(genvar bank=0;bank<4;bank=bank+1)begin:g_background_coord
        reg [11:0] x_q /* synthesis syn_preserve=1 */;
        reg [11:0] y_q /* synthesis syn_preserve=1 */;
        wire [11:0] x_keep /* synthesis syn_keep=1 */;
        wire [11:0] y_keep /* synthesis syn_keep=1 */;
        always @(posedge clk_p)begin x_q<=x1c;y_q<=y1c;end
        assign x_keep=x_q;assign y_keep=y_q;
        assign bg_x[bank]=x_keep;assign bg_y[bank]=y_keep;
    end endgenerate
    reg [7:0] testkey_rect2,testind_rect2,card_rect2,card_stripe2;
    always @(posedge clk_p)for(integer k=0;k<8;k=k+1)begin
        testkey_rect2[k]<=box(x1c,y1c,1504,304+k*64,1856,352+k*64);
        testind_rect2[k]<=box(x1c,y1c,1512,316+k*64,1520,340+k*64);
        card_rect2[k]<=box(x1c,y1c,64,280+k*64,536,336+k*64);
        card_stripe2[k]<=box(x1c,y1c,64,280+k*64,70,336+k*64);
    end
    always @(posedge clk_p)for(integer k=0;k<8;k=k+1)visible_cards[k]<=({guide_selected[3],3'b000}+k)<guide_count;
    always @(posedge clk_p)begin level_end<=1272+({4'd0,perf_level}<<1);progress_end<=768+guide_progress;end
    // Independent geometry flags, then a balanced priority mask. No serial
    // chain through every panel/key/card comparator in one pixel clock.
    always @(*)begin
        bg_flags=0;bg_flags[0]=1;
        testkey_any=|testkey_rect2;testkey_down=|(testkey_rect2 & perf_keys);
        testind_any=|testind_rect2;testind_down=|(testind_rect2 & perf_keys);
        card_any=|(card_rect2 & visible_cards);
        card_selected=card_rect2[guide_selected[2:0]] && visible_cards[guide_selected[2:0]];
        card_stripe=card_stripe2[guide_selected[2:0]] && visible_cards[guide_selected[2:0]];
        bg_flags[1]=box(bg_x[0],bg_y[0],40,24,1880,164)||box(bg_x[0],bg_y[0],40,992,1880,1056);
        bg_flags[2]=bg_y[0]==163 && bg_x[0]>=40 && bg_x[0]<1880;
        bg_flags[3]=page_show==0 && (box(bg_x[0],bg_y[0],40,192,1160,576)||box(bg_x[0],bg_y[0],40,608,1160,960)||box(bg_x[0],bg_y[0],1192,192,1880,984));
        bg_flags[4]=page_show==0 && ((box(bg_x[0],bg_y[0],64,288,1088,545)&&bg_y[0][5:0]==32)||
            (box(x2,y2,64,696,1088,929)&&y2[5:0]==32)||(box(x2,y2,1272,304,1784,816)&&(x2==1528||y2==560)));
        bg_flags[5]=page_show==0 && box(bg_x[0],bg_y[0],1272,832,1784,840);
        bg_flags[6]=page_show==0 && bg_x[0]>=1272 && bg_y[0]>=832 && bg_y[0]<840 &&
            (level_lt_hi || (level_eq_hi && level_lt_lo));
        bg_flags[7]=page_show==0 && (border(bg_x[0],bg_y[0],40,192,1160,576)||border(bg_x[0],bg_y[0],40,608,1160,960)||border(bg_x[0],bg_y[0],1192,192,1880,984));
        bg_flags[8]=page_show==1 && (box(bg_x[1],bg_y[1],40,192,1448,960)||box(bg_x[1],bg_y[1],1480,192,1880,960));
        bg_flags[9]=page_show==1 && box(bg_x[1],bg_y[1],96,256,1376,897)&&bg_y[1][6:0]==0;
        bg_flags[10]=page_show==1 && testkey_any;bg_flags[11]=page_show==1 && testkey_down;
        bg_flags[12]=page_show==1 && testind_any;bg_flags[13]=page_show==1 && testind_down;
        bg_flags[14]=page_show==2 && (box(bg_x[1],bg_y[1],40,192,560,960)||box(bg_x[1],bg_y[1],592,192,1880,976));
        bg_flags[15]=page_show==2 && card_any;bg_flags[16]=page_show==2 && card_selected;bg_flags[17]=page_show==2 && card_stripe;
        bg_flags[18]=page_show==2 && box(bg_x[2],bg_y[2],768,256,1792,880);
        bg_flags[19]=bg_flags[18] && !bg_x[2][7];
        bg_flags[20]=bg_flags[18] && (bg_x[2][6:0]==0 || bg_y[2][6:0]==0);
        bg_flags[21]=bg_flags[18] && bg_y[2]>=834 && bg_y[2]<894;
        bg_flags[22]=page_show==2 && box(bg_x[2],bg_y[2],752,862,1808,866);
        bg_flags[23]=page_show==2 && key_region;
        bg_flags[24]=bg_flags[23] && key_expected;
        bg_flags[25]=bg_flags[23] && key_matched;
        bg_flags[26]=bg_flags[23] && key_lane==7;
        bg_flags[27]=bg_flags[23] && (bg_x[3][6:0]<4 || bg_x[3][6:0]>123);
        bg_flags[28]=page_show==2 && ((box(bg_x[3],bg_y[3],64,864,536,896)&&!guide_teach)||(box(bg_x[3],bg_y[3],64,928,536,960)&&guide_teach));
        bg_flags[29]=page_show==2 && box(bg_x[3],bg_y[3],768,982,1792,987);
        bg_flags[30]=page_show==2 && bg_x[3]>=768 && bg_y[3]>=982 && bg_y[3]<987 &&
            (progress_lt_hi || (progress_eq_hi && progress_lt_lo));
        bg_flags[31]=page_show==2 && guide_state==4 && box(bg_x[3],bg_y[3],64,552,536,616);
    end
    function [23:0] background_color(input integer index);
        begin case(index)
            0:background_color=24'h090F19;1:background_color=24'h111D2D;
            2,6:background_color=accent;3,8,14,27:background_color=24'h111C2B;
            4,9:background_color=24'h26384B;5:background_color=24'h203143;7:background_color=24'h304257;
            10:background_color=24'h18283A;11:background_color=24'h245563;12:background_color=24'h3A4A5F;13:background_color=24'h7DE1DA;
            15:background_color=24'h172638;16:background_color=24'h254452;17,30:background_color=24'h70DAD2;
            18:background_color=24'h102332;19:background_color=24'h132737;20:background_color=24'h223C4C;
            21:background_color=24'h1B3542;22:background_color=24'hF6C77E;23:background_color=24'hC8D5DE;
            24:background_color=24'hDFB66F;25:background_color=24'h59BE9C;26,29:background_color=24'h26394B;
            28:background_color=24'h254C57;default:background_color=24'h7D343D;
        endcase end
    endfunction
    reg [24:0] bg_group4[0:7];
    always @(posedge clk_p)begin
        for(integer group=0;group<8;group=group+1)begin
            bg_group4[group]<={|bg_flags3[group*4+:4],
                (background_color(group*4)&{24{bg_flags3[group*4] && !(|bg_flags3[group*4+1+:3])}})|
                (background_color(group*4+1)&{24{bg_flags3[group*4+1] && !(|bg_flags3[group*4+2+:2])}})|
                (background_color(group*4+2)&{24{bg_flags3[group*4+2] && !bg_flags3[group*4+3]}})|
                (background_color(group*4+3)&{24{bg_flags3[group*4+3]}})};
        end
    end
    reg [7:0] bg_group_valid;
    always @(*)begin
        for(integer g=0;g<8;g=g+1)bg_group_valid[g]=bg_group4[g][24];
        background=0;
        for(integer g=0;g<8;g=g+1)
            background=background|(bg_group4[g][23:0]&{24{bg_group_valid[g] && !(|(bg_group_valid>>(g+1)))}});
    end
    reg spectrum4,spectrum_high4,component4,liss4,note_auto4,note_lead4,note_hit4,note_edge4,judgment4,text4;
    reg [23:0] liss_color4,note_color4,text_color4;
    always @(posedge clk_p)begin
        {spectrum4,spectrum_high4,component4,liss4,note_auto4,note_lead4,note_hit4,note_edge4,judgment4,text4}<=
            {spectrum3,spectrum_high3,component3,liss3,note_auto3,note_lead3,note_hit3,note_edge3,judgment3,text3};
        liss_color4<=liss_color3;note_color4<=note_color3;text_color4<=text_color3;
    end
    reg spectrum5,spectrum_high5,component5,liss5,note_auto5,note_lead5,note_hit5,note_edge5,judgment5,text5;
    reg [23:0] liss_color5,note_color5,text_color5;
    always @(posedge clk_p)begin
        background3<=background;
        {spectrum5,spectrum_high5,component5,liss5,note_auto5,note_lead5,note_hit5,note_edge5,judgment5,text5}<=
            {spectrum4,spectrum_high4,component4,liss4,note_auto4,note_lead4,note_hit4,note_edge4,judgment4,text4};
        liss_color5<=liss_color4;note_color5<=note_color4;text_color5<=text_color4;
    end
    always @(*)begin
        rgb=background3;
        if(spectrum5)rgb=spectrum_high5?24'h7DE1DA:24'h3DABB7;
        if(component5)rgb=24'h718FD0;
        if(liss5)rgb=liss_color5;
        if(note_auto5)rgb=24'h354957;
        if(note_lead5)rgb=note_color5;
        if(note_hit5)rgb=24'h75E6BC;
        if(note_edge5)rgb=24'hD5F5EE;
        if(judgment5)rgb=24'hF6C77E;
        if(text5)rgb=text_color5;
    end
    // Separate palette/geometry from fade multiplication at 148.5 MHz.
    reg [23:0] rgb_base,rgb_faded,rgb_direct,rgb_r;
    reg fade_full;
    wire [11:0] fade_r=rgb_base[23:16]*fade_lvl;
    wire [11:0] fade_g=rgb_base[15:8]*fade_lvl;
    wire [11:0] fade_b=rgb_base[7:0]*fade_lvl;
    reg vis_d0,vis_d1,vis_d2,vis_d3,vis_d4,vis_d5,vis_d6,vis_d7,vis_d8,vis_d9;
    reg hs_d0,hs_d1,hs_d2,hs_d3,hs_d4,hs_d5,hs_d6,hs_d7,hs_d8,hs_d9,vs_d0,vs_d1,vs_d2,vs_d3,vs_d4,vs_d5,vs_d6,vs_d7,vs_d8,vs_d9;
    always @(posedge clk_p)begin
        rgb_base<=rgb;
        rgb_faded<={fade_r[11:4],fade_g[11:4],fade_b[11:4]};rgb_direct<=rgb_base;fade_full<=fade_lvl==15;
        rgb_r<=fade_full?rgb_direct:rgb_faded;
        vis_d0<=vis;vis_d1<=vis_d0;vis_d2<=vis_d1;vis_d3<=vis_d2;vis_d4<=vis_d3;vis_d5<=vis_d4;vis_d6<=vis_d5;vis_d7<=vis_d6;vis_d8<=vis_d7;
        hs_d0<=hsync;hs_d1<=hs_d0;hs_d2<=hs_d1;hs_d3<=hs_d2;hs_d4<=hs_d3;hs_d5<=hs_d4;hs_d6<=hs_d5;hs_d7<=hs_d6;hs_d8<=hs_d7;
        vs_d0<=vsync;vs_d1<=vs_d0;vs_d2<=vs_d1;vs_d3<=vs_d2;vs_d4<=vs_d3;vs_d5<=vs_d4;vs_d6<=vs_d5;vs_d7<=vs_d6;vs_d8<=vs_d7;
        vis_d9<=vis_d8;hs_d9<=hs_d8;vs_d9<=vs_d8;
    end
`ifndef SIM_UI3
    dvi_tx_top u_dvi(.pixel_clock(clk_p),.ddr_bit_clock(clk_p5),.reset(dvi_reset),
        .den(vis_d9),.hsync(hs_d9),.vsync(vs_d9),.pixel_data(rgb_r),
        .tmds_clk({tmds_clk_p_0,tmds_clk_n_0}),.tmds_d0({tmds_d_p_0[0],tmds_d_n_0[0]}),
        .tmds_d1({tmds_d_p_0[1],tmds_d_n_0[1]}),.tmds_d2({tmds_d_p_0[2],tmds_d_n_0[2]}));
`endif
endmodule
`default_nettype wire
