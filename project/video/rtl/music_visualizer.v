`include "asset_paths.vh"
// All application inputs use pixel_clk. Commit display state in vertical blank.
// This module accepts analyzed data; it neither samples sensors nor computes FFT.
module music_visualizer #(parameter integer WAVE_GAIN_SHIFT=0)(
    input pixel_clk, reset_n,
    input wide_panel,
    input [11:0] x,y,
    input hs,vs,de,frame_start,
    input pressure_valid,
    input [63:0] pressure_levels,
    input spectrum_valid,
    input [255:0] spectrum_levels,
    input wave_wr_en,
    input [7:0] wave_wr_addr,
    input signed [15:0] wave_wr_min,wave_wr_max,
    input wave_publish,
    output wave_ready,
    input controls_valid,
    input [1:0] timbre,
    input [6:0] sustain,
    input echo_enabled,
    output reg [23:0] rgb,
    output reg hs_out,vs_out,de_out,
    output reg display_ready
);
    reg [63:0] pressure_latest,pressure_frame;
    reg [255:0] spectrum_latest,spectrum_frame;
    reg [1:0] timbre_latest,timbre_frame;
    reg [6:0] sustain_latest,sustain_frame;
    reg echo_latest,echo_frame;
    reg front_bank,wave_pending,wide_frame;
    (* syn_ramstyle="block_ram" *) reg [31:0] wave_mem[0:511];
    reg [31:0] wave_read;
    assign wave_ready=reset_n && !wave_pending;
    always @(posedge pixel_clk) begin
        if(wave_wr_en && wave_ready)
            wave_mem[{!front_bank,wave_wr_addr}]<={wave_wr_min,wave_wr_max};
        wave_read<=wave_mem[{front_bank,x[8:1]-8'd32}];
    end
    always @(posedge pixel_clk or negedge reset_n) begin
        if(!reset_n) begin
            pressure_latest<=0;pressure_frame<=0;spectrum_latest<=0;spectrum_frame<=0;
            timbre_latest<=0;timbre_frame<=0;sustain_latest<=80;sustain_frame<=80;
            echo_latest<=1;echo_frame<=1;
            front_bank<=0;wave_pending<=0;display_ready<=0;wide_frame<=1;
        end else begin
            if(pressure_valid) pressure_latest<=pressure_levels;
            if(spectrum_valid) spectrum_latest<=spectrum_levels;
            if(controls_valid) begin timbre_latest<=timbre;sustain_latest<=sustain;echo_latest<=echo_enabled;end
            if(wave_publish && wave_ready) wave_pending<=1;
            if(frame_start) begin
                wide_frame<=wide_panel;
                pressure_frame<=pressure_valid ? pressure_levels : pressure_latest;
                spectrum_frame<=spectrum_valid ? spectrum_levels : spectrum_latest;
                timbre_frame<=controls_valid ? timbre : timbre_latest;
                sustain_frame<=controls_valid ? sustain : sustain_latest;
                echo_frame<=controls_valid ? echo_enabled : echo_latest;
                if(wave_pending) begin front_bank<=!front_bank;wave_pending<=0;display_ready<=1;end
            end
        end
    end

    (* syn_romstyle="block_rom" *) reg [3:0] pan_rom[0:65535];
    // Byte-packed hex initialization is preserved by Gowin synthesis.
    // The former scalar readmemb atlas was optimized to a constant on hardware.
    (* syn_romstyle="block_rom" *) reg [7:0] ui_rom[0:8191];
    initial begin $readmemh(`PAN_ROM_FILE,pan_rom);$readmemh(`UI_ROM_FILE,ui_rom);end
    wire [11:0] pan_x=x-12'd192,pan_y=y-12'd144;
    function [8:0] correct_pan_x;
        input [7:0] source_x;
        input wide;
        begin
            if(!wide) correct_pan_x={1'b1,source_x};
            else begin
                case(source_x)
`include "pan_aspect_map.vh"
                endcase
            end
        end
    endfunction
    wire [8:0] corrected_x=correct_pan_x(pan_x[7:0],wide_frame);
    wire pan_region=x>=192 && x<448 && y>=144 && y<400 && corrected_x[8];
    wire music_region=x>=64 && x<576;
    wire [8:0] local_x=x[8:0]-9'd64;
    reg [8:0] ui_x;
    reg [6:0] ui_y;
    reg ui_region;
    always @* begin
        ui_x=x[8:0];ui_y=y[6:0];ui_region=(x<512 && y<64);
        if(x>=72 && x<168 && y>=48 && y<64) begin
            ui_x=x[8:0]-9'd72;ui_y=7'd64+{1'b0,timbre_frame,4'b0}+(y[6:0]-7'd48);ui_region=1;
        end else if(x>=416 && x<448 && y>=48 && y<64) begin
            ui_x=9'd128+(x[8:0]-9'd416);ui_y=7'd64+(echo_frame ? 7'd0 : 7'd16)+(y[6:0]-7'd48);ui_region=1;
        end
    end
    reg [3:0] pan_index;
    reg [7:0] ui_word;
    reg [2:0] ui_bit_index;
    wire ui_bit=ui_word[ui_bit_index];
    always @(posedge pixel_clk) begin
        pan_index<=pan_rom[{pan_y[7:0],corrected_x[7:0]}];
        ui_word<=ui_rom[{ui_y,ui_x[8:3]}];
        ui_bit_index<=ui_x[2:0];
    end
    reg [11:0] x1,y1;
    reg hs1,vs1,de1,pan1,ui1,music1,wave1;
    reg [8:0] local_x1;
    reg [7:0] pressure1,spectrum1;
    reg [4:0] spectrum_index1;
    always @(posedge pixel_clk or negedge reset_n) begin
        if(!reset_n) begin
            x1<=0;y1<=0;hs1<=1;vs1<=1;de1<=0;pan1<=0;ui1<=0;music1<=0;
            wave1<=0;local_x1<=0;pressure1<=0;spectrum1<=0;spectrum_index1<=0;
        end else begin
            x1<=x;y1<=y;hs1<=hs;vs1<=vs;de1<=de;pan1<=pan_region;ui1<=ui_region;
            music1<=music_region;wave1<=display_ready;local_x1<=local_x;
            pressure1<=pressure_frame[local_x[8:6]*8+:8];
            spectrum1<=spectrum_frame[local_x[8:4]*8+:8];
            spectrum_index1<=local_x[8:4];
        end
    end
    function [23:0] pan_color;
        input [3:0] index;
        begin
            case(index)
                0:pan_color=24'h020507;1:pan_color=24'h0b1116;2:pan_color=24'h101a20;
                3:pan_color=24'h16232a;4:pan_color=24'h1d2c33;5:pan_color=24'h26353b;
                6:pan_color=24'h303f44;7:pan_color=24'h3a484b;8:pan_color=24'h465154;
                9:pan_color=24'h525b5a;10:pan_color=24'h60675f;11:pan_color=24'h707366;
                12:pan_color=24'h838071;13:pan_color=24'h96907b;14:pan_color=24'hab9f87;
                default:pan_color=24'hbfb09a;
            endcase
        end
    endfunction
    function [23:0] spectrum_color;
        input [4:0] index;
        begin
            case(index)
`include "spectrum_palette.vh"
            endcase
        end
    endfunction
    wire [6:0] pressure_height={1'b0,pressure1[7:2]}+{2'b0,pressure1[7:3]};
    wire [6:0] spectrum_height=spectrum1[7:1];
    // Fixed view gain only: keep raw min/max samples in RAM and preserve
    // audio/FFT amplitudes. Saturation bounds the drawing inside its strip.
    function signed [16:0] wave_offset;
        input signed [15:0] sample;
        reg signed [31:0] expanded;
        begin
            expanded=$signed(sample);expanded=expanded<<<WAVE_GAIN_SHIFT;
            if(expanded>32767)wave_offset=17'sd31;
            else if(expanded< -32768)wave_offset=-17'sd32;
            else wave_offset=expanded>>>10;
        end
    endfunction
    wire signed [16:0] wave_y_top=17'sd266-wave_offset($signed(wave_read[15:0]));
    wire signed [16:0] wave_y_bottom=17'sd266-wave_offset($signed(wave_read[31:16]));
    reg [23:0] color;
    always @* begin
        color=pan1 ? pan_color(pan_index) : 24'h020507;
        if(music1 && local_x1[5:0]>=16 && local_x1[5:0]<48 && y1>=96 && y1<96+pressure_height)
            color=(y1>=94+pressure_height) ? 24'hb0ffef : 24'h65d9c9;
        if(music1 && local_x1[3:0]>=1 && local_x1[3:0]<15 && y1<456 && y1>=456-spectrum_height)
            color=spectrum_color(spectrum_index1);
        if(music1 && wave1 && y1>=228 && y1<305 &&
            $signed({1'b0,y1})>=wave_y_top && $signed({1'b0,y1})<=wave_y_bottom)
            color=24'hb2fff0;
        if(x1>=280 && x1<344 && y1>=55 && y1<59)
            color=(x1-280 < sustain_frame[6:1]) ? 24'h63d8cb : 24'h18353d;
        if(ui1 && ui_bit) color=24'hd7e8ed;
    end
    always @(posedge pixel_clk or negedge reset_n)
        if(!reset_n) begin rgb<=0;hs_out<=1;vs_out<=1;de_out<=0;end
        else begin rgb<=de1 ? color : 24'd0;hs_out<=hs1;vs_out<=vs1;de_out<=de1;end
endmodule
