`timescale 1ns/1ps
// Bundled-data toggle handshakes. Producer holds data/RAM until ACK.
// Live pressure/controls and paired spectrum/wave frames are independent.
module visual_bridge(
 input wire sys_clk,sys_rst_n,pixel_clk,pix_rst_n,
 input wire live_send,input wire [73:0] live_data,
 input wire frame_send,input wire [255:0] frame_spectrum,input wire [31:0] frame_id,
 output wire frame_busy,
 input wire wave_we,input wire [7:0] wave_addr,input wire signed [15:0] wave_min,wave_max,
 input wire wave_ready,frame_start,video_de,
 output reg pressure_valid,output reg [63:0] pressure_levels,
 output reg controls_valid,output reg [1:0] timbre,output reg [6:0] sustain,output reg echo_enabled,
 output reg spectrum_valid,output reg [255:0] spectrum_levels,
 output reg wave_wr_en,output reg [7:0] wave_wr_addr,
 output reg signed [15:0] wave_wr_min,wave_wr_max,output reg wave_publish,
 output reg [31:0] committed_id);
 (* syn_preserve=1 *) reg [73:0] live_hold;
 (* syn_preserve=1 *) reg [255:0] spectrum_hold;
 (* syn_preserve=1 *) reg [31:0] id_hold;
 reg live_req,frame_req,live_ack,frame_ack;
 (* ASYNC_REG="TRUE",syn_preserve=1 *) reg [1:0] live_req_sync,frame_req_sync,live_ack_sync,frame_ack_sync;
 assign frame_busy=frame_req!=frame_ack_sync[1];
 always @(posedge sys_clk or negedge sys_rst_n)
 if(!sys_rst_n)begin
  live_req<=0;frame_req<=0;live_hold<=0;spectrum_hold<=0;id_hold<=0;
  live_ack_sync<=0;frame_ack_sync<=0;
 end else begin
  live_ack_sync<={live_ack_sync[0],live_ack};frame_ack_sync<={frame_ack_sync[0],frame_ack};
  if(live_send && live_req==live_ack_sync[1])begin live_hold<=live_data;live_req<=!live_req;end
  if(frame_send && !frame_busy)begin spectrum_hold<=frame_spectrum;id_hold<=frame_id;frame_req<=!frame_req;end
 end
 (* syn_ramstyle="block_ram" *) reg [31:0] columns[0:255];
 reg [7:0] read_addr;
 reg [31:0] read_data;
 always @(posedge sys_clk)if(wave_we)columns[wave_addr]<={wave_min,wave_max};
 always @(posedge pixel_clk)read_data<=columns[read_addr];
 reg [2:0] state;
 localparam IDLE=0,FETCH=1,WRITE=2,PUBLISH=3,BLANK=4,ACK=5;
 reg [7:0] index;
 reg [255:0] spectrum_sample;
 reg [31:0] id_sample;
 always @(posedge pixel_clk or negedge pix_rst_n)
 if(!pix_rst_n)begin
  live_req_sync<=0;frame_req_sync<=0;live_ack<=0;frame_ack<=0;
  pressure_valid<=0;pressure_levels<=0;controls_valid<=0;timbre<=0;sustain<=0;echo_enabled<=0;
  spectrum_valid<=0;spectrum_levels<=0;wave_wr_en<=0;wave_wr_addr<=0;
  wave_wr_min<=0;wave_wr_max<=0;wave_publish<=0;read_addr<=0;index<=0;
  state<=IDLE;spectrum_sample<=0;id_sample<=0;committed_id<=0;
 end else begin
  live_req_sync<={live_req_sync[0],live_req};frame_req_sync<={frame_req_sync[0],frame_req};
  pressure_valid<=0;controls_valid<=0;spectrum_valid<=0;wave_wr_en<=0;wave_publish<=0;
  if(live_req_sync[1]!=live_ack)begin
   {echo_enabled,sustain,timbre,pressure_levels}<=live_hold;
   pressure_valid<=1;controls_valid<=1;live_ack<=live_req_sync[1];
  end
  case(state)
   IDLE:if(frame_req_sync[1]!=frame_ack && wave_ready)begin
    spectrum_sample<=spectrum_hold;id_sample<=id_hold;index<=0;read_addr<=0;state<=FETCH;
   end
   FETCH:state<=WRITE;
   WRITE:begin
    wave_wr_en<=1;wave_wr_addr<=index;
    wave_wr_min<=$signed(read_data[31:16]);wave_wr_max<=$signed(read_data[15:0]);
    if(index==255)state<=PUBLISH;
    else begin index<=index+1'b1;read_addr<=index+1'b1;state<=FETCH;end
   end
   // Active video guarantees at least horizontal blanking before vblank.
   // Therefore spectrum_latest and wave_pending reach the renderer together
   // before frame_start, including the final RAM write's registered latency.
   PUBLISH:if(video_de)begin
    wave_publish<=1;spectrum_valid<=1;spectrum_levels<=spectrum_sample;state<=BLANK;
   end
   BLANK:if(frame_start)begin committed_id<=id_sample;state<=ACK;end
   ACK:begin frame_ack<=frame_req_sync[1];state<=IDLE;end
   default:state<=IDLE;
  endcase
 end
endmodule
