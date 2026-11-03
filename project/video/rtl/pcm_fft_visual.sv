`timescale 1ns/1ps
`include "asset_paths.vh"
// Passive 1024-sample capture and scaled radix-2 DIT FFT.
// Input samples are signed16. Complex data is signed24 (8 fractional bits).
// Each butterfly divides by two; output is FFT/N. No audio backpressure.
module pcm_fft_visual(
 input wire clk,rst_n,start,pcm_ce,input wire signed [15:0] pcm,
 output wire busy,output reg done,
 output reg wave_we,output reg [7:0] wave_addr,
 output reg signed [15:0] wave_min,wave_max,
 output reg [255:0] spectrum,
 output reg [31:0] capture_overrun,output reg arithmetic_clip);
 localparam IDLE=0,CAP=1,CMUL=2,CSTORE=3,RD=4,RWAIT=5,MUL=6,PRODUCT=7,
  BUTTERFLY=8,STORE=9,ADVANCE=10,SRD=11,SWAIT=12,ABS=13,MAG=14,
  LEAD=15,FRACTION=16,SCALE=17,ACCUM=18,FINISH=19;
 reg [4:0] state;
 reg [9:0] cap_index,j,half,tw_index,tw_step,bin;
 reg [10:0] base,span;
 reg [4:0] band;
 reg [7:0] band_peak,level;
 (* syn_romstyle="block_rom" *) reg signed [15:0] hann[0:1023];
 (* syn_romstyle="block_rom" *) reg signed [17:0] tw_re[0:511],tw_im[0:511];
 reg [9:0] band_end[0:31];
 initial begin
  $readmemh(`HANN_ROM_FILE,hann);$readmemh(`TW_RE_FILE,tw_re);
  $readmemh(`TW_IM_FILE,tw_im);$readmemh(`BAND_END_FILE,band_end);
 end
 reg signed [15:0] cap_sample,win;
 reg signed [31:0] window_product;
 reg signed [17:0] wr,wi;
 reg signed [23:0] ar,ai,br,bi;
 reg signed [41:0] rr,ii,ri,ir;
 reg signed [25:0] tr,ti;
 reg [47:0] write_a,write_b;
 (* syn_ramstyle="block_ram" *) reg [47:0] mem[0:1023];
 reg [47:0] read_a,read_b;
 function [9:0] reverse10(input [9:0] value);
  integer n;begin for(n=0;n<10;n=n+1)reverse10[n]=value[9-n];end
 endfunction
 wire [9:0] address_a=(state==CSTORE)?reverse10(cap_index):
    (state>=SRD)?bin:(base[9:0]+j);
 wire [9:0] address_b=base[9:0]+j+half;
 wire we_a=state==CSTORE || state==STORE;
 wire we_b=state==STORE;
 wire [47:0] data_a=(state==CSTORE)?{window_product[30:7],24'd0}:write_a;
 always @(posedge clk)begin
  // GW5AST DPB supports write-first/no-change, not read-before-write.
  // Read values during STORE are not consumed by the butterfly pipeline.
  if(we_a)begin mem[address_a]<=data_a;read_a<=data_a;end
  else read_a<=mem[address_a];
 end
 always @(posedge clk)begin
  if(we_b)begin mem[address_b]<=write_b;read_b<=write_b;end
  else read_b<=mem[address_b];
 end
 always @(posedge clk)begin
  if(state==CAP && pcm_ce)win<=hann[cap_index];
  if(state==RD)begin wr<=tw_re[tw_index[8:0]];wi<=tw_im[tw_index[8:0]];end
 end
 wire signed [26:0] are={{3{ar[23]}},ar},aie={{3{ai[23]}},ai};
 wire signed [26:0] tre={tr[25],tr},tie={ti[25],ti};
 wire signed [26:0] out_ar=(are+tre)>>>1,out_ai=(aie+tie)>>>1;
 wire signed [26:0] out_br=(are-tre)>>>1,out_bi=(aie-tie)>>>1;
 function [23:0] sat24(input signed [26:0] v);
  begin sat24=(v>8388607)?24'h7fffff:(v< -8388608)?24'h800000:v[23:0];end
 endfunction
 reg signed [15:0] col_min,col_max;
 reg [23:0] abs_r,abs_i;
 reg [24:0] magnitude;
 reg [4:0] lead_bit;
 reg [8:0] log_q4;
 reg [12:0] scaled_level;
 wire [7:0] candidate=(level>band_peak)?level:band_peak;
 wire [7:0] old_level=spectrum[band*8+:8];
 wire [7:0] falling_level=(old_level>24)?old_level-8'd24:8'd0;
 // Five-level leading-bit encoder instead of a 25-comparator priority chain.
 function [4:0] leading(input [24:0] v);
  reg [31:0] w;reg [4:0] n;begin
   w={7'd0,v};n=0;
   if(w[31:16]!=0)begin w=w>>16;n=n+16;end
   if(w[15:8]!=0)begin w=w>>8;n=n+8;end
   if(w[7:4]!=0)begin w=w>>4;n=n+4;end
   if(w[3:2]!=0)begin w=w>>2;n=n+2;end
   if(w[1])n=n+1;leading=n;
  end
 endfunction
 reg [24:0] mantissa;
 always @*mantissa=(lead_bit>=4)?magnitude>>(lead_bit-4):magnitude<<(4-lead_bit);
 assign busy=state!=IDLE;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
  state<=IDLE;cap_index<=0;j<=0;half<=1;tw_index<=0;tw_step<=512;base<=0;span<=2;
  bin<=1;band<=0;band_peak<=0;level<=0;done<=0;spectrum<=0;
  wave_we<=0;wave_addr<=0;wave_min<=0;wave_max<=0;col_min<=0;col_max<=0;
  cap_sample<=0;window_product<=0;ar<=0;ai<=0;br<=0;bi<=0;
  rr<=0;ii<=0;ri<=0;ir<=0;tr<=0;ti<=0;write_a<=0;write_b<=0;
  abs_r<=0;abs_i<=0;magnitude<=0;lead_bit<=0;log_q4<=0;scaled_level<=0;
  capture_overrun<=0;arithmetic_clip<=0;
 end else begin
  done<=0;wave_we<=0;
  if(pcm_ce && (state==CMUL || state==CSTORE))capture_overrun<=capture_overrun+1'b1;
  case(state)
   IDLE:if(start)begin state<=CAP;cap_index<=0;arithmetic_clip<=0;end
   CAP:if(pcm_ce)begin
    cap_sample<=pcm;state<=CMUL;
    if(cap_index[1:0]==0)begin col_min<=pcm;col_max<=pcm;end
    else begin
     if(pcm<col_min)col_min<=pcm;if(pcm>col_max)col_max<=pcm;
     if(cap_index[1:0]==3)begin
      wave_addr<=cap_index[9:2];wave_min<=pcm<col_min?pcm:col_min;
      wave_max<=pcm>col_max?pcm:col_max;wave_we<=1;
     end
    end
   end
   CMUL:begin window_product<=cap_sample*win;state<=CSTORE;end
   CSTORE:begin
    if(cap_index==1023)begin half<=1;span<=2;base<=0;j<=0;tw_index<=0;tw_step<=512;state<=RD;end
    else begin cap_index<=cap_index+1'b1;state<=CAP;end
   end
   RD:state<=RWAIT;
   RWAIT:begin ar<=$signed(read_a[47:24]);ai<=$signed(read_a[23:0]);
    br<=$signed(read_b[47:24]);bi<=$signed(read_b[23:0]);state<=MUL;end
   MUL:begin rr<=br*wr;ii<=bi*wi;ri<=br*wi;ir<=bi*wr;state<=PRODUCT;end
   PRODUCT:begin
    tr<=($signed({rr[41],rr})-$signed({ii[41],ii}))>>>17;
    ti<=($signed({ri[41],ri})+$signed({ir[41],ir}))>>>17;state<=BUTTERFLY;
   end
   BUTTERFLY:begin
    write_a<={sat24(out_ar),sat24(out_ai)};write_b<={sat24(out_br),sat24(out_bi)};
    if(out_ar>8388607 || out_ar< -8388608 || out_ai>8388607 || out_ai< -8388608 ||
       out_br>8388607 || out_br< -8388608 || out_bi>8388607 || out_bi< -8388608)arithmetic_clip<=1;
    state<=STORE;
   end
   STORE:state<=ADVANCE;
   ADVANCE:begin
    state<=RD;
    if(j+1<half)begin j<=j+1'b1;tw_index<=tw_index+tw_step;end
    else begin
     j<=0;tw_index<=0;
     if(base+span<1024)base<=base+span;
     else if(half==512)begin bin<=1;band<=0;band_peak<=0;state<=SRD;end
     else begin base<=0;half<=half<<1;span<=span<<1;tw_step<=tw_step>>1;end
    end
   end
   SRD:state<=SWAIT;
   SWAIT:state<=ABS;
   ABS:begin
    abs_r<=read_a[47]?(~read_a[47:24]+1'b1):read_a[47:24];
    abs_i<=read_a[23]?(~read_a[23:0]+1'b1):read_a[23:0];state<=MAG;
   end
   MAG:begin magnitude<=(abs_r>abs_i)?({1'b0,abs_r}+({1'b0,abs_i}>>1)):
                                              ({1'b0,abs_i}+({1'b0,abs_r}>>1));state<=LEAD;end
   LEAD:begin lead_bit<=leading(magnitude);state<=FRACTION;end
   FRACTION:begin log_q4<={lead_bit,4'b0}+{5'd0,mantissa[3:0]};state<=SCALE;end
   SCALE:begin
    // Fixed -60 dB floor and full-scale reference; never per-frame normalize.
    scaled_level<=(log_q4>176)?(log_q4-9'd176)*6'd51:13'd0;
    state<=ACCUM;
   end
   ACCUM:begin
    // The scale product was registered on the preceding edge.
    level<=(magnitude>=25'd2097152)?8'd255:(scaled_level>=8160?8'd255:scaled_level[12:5]);
    state<=FINISH;
   end
   FINISH:begin
    if(bin==band_end[band])begin
     spectrum[band*8+:8]<=(candidate>=old_level)?candidate:
                              ((candidate>falling_level)?candidate:falling_level);
     band_peak<=0;
     if(band==31)begin done<=1;state<=IDLE;end
     else begin band<=band+1'b1;bin<=bin+1'b1;state<=SRD;end
    end else begin band_peak<=candidate;bin<=bin+1'b1;state<=SRD;end
   end
   default:state<=IDLE;
  endcase
 end
endmodule
