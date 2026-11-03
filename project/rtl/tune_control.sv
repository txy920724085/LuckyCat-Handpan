`timescale 1ns/1ps
// Request: FC 54 seq16 op8 values[16]*uint16 CRC16 = 39 bytes.
// Reply: TNR1 version=1 kind=6 length=64 seq16 status8 flags8
// generation32 config256 scan_cycles32 raw_hits32 accepted_hits32 errors16 CRC16.
// CRC16-CCITT-FALSE includes all bytes except the final little-endian CRC.
// All values commit atomically. No host operation backpressures ADC/audio.
module tune_control(
 input wire clk,rst_n,rx_valid,input wire [7:0] rx_data,
 input wire scan_valid,input wire [7:0] raw_hits,input wire accepted_hit,
 input wire adc_ready,calibrated,
 output reg [255:0] cfg,output reg commit,
 output wire tx_valid,output wire [7:0] tx_data,output wire tx_last,input wire tx_ready);
 localparam [255:0] DEFAULTS={16'd0,16'd0,16'd0,16'd3,16'd10,16'd1024,16'd4096,16'd960,
                             16'd256,16'd4,16'd128,16'd512,16'd30,16'd800,16'd40,16'd51};
 reg [5:0] rx_index,tx_index;
 reg [15:0] crc_rx,crc_low,seq;
 reg [7:0] op;
 reg [255:0] candidate;
 reg [2:0] state;
 localparam RECEIVE=0,CHECK=1,SETTLE=2,SEND=3;
 reg [7:0] status;
 reg [31:0] generation,cycles,last_scan,scan_cycles,raw_total,accepted_total;
 reg [15:0] errors;
 reg [495:0] snapshot;
 reg [15:0] crc_tx;
 reg have_applied;
 reg [15:0] applied_seq;
 reg [7:0] applied_op;
 reg [255:0] applied_candidate;
 wire duplicate=have_applied && seq==applied_seq;
 wire values_ok=candidate[15:0]>=1 && candidate[15:0]<=4096 &&
  candidate[31:16]<=4096 && candidate[47:32]>=1 && candidate[47:32]<=60000 &&
  candidate[63:48]>=1 && candidate[63:48]<=60000 &&
  candidate[79:64]>=1 && candidate[95:80]>=1 && candidate[95:80]<candidate[79:64] &&
  candidate[111:96]>=1 && candidate[111:96]<=6 && candidate[127:112]>=1 &&
  candidate[143:128]>=1 && candidate[143:128]<=60000 &&
  candidate[159:144]>=1 && candidate[175:160]<=candidate[159:144] &&
  candidate[191:176]>=1 && candidate[191:176]<=1000 && candidate[207:192]<=3 &&
  candidate[255:208]==0;
 function [15:0] crc_byte(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer k;begin
   v=c^{b,8'd0};for(k=0;k<8;k=k+1)v=v[15]?(v<<1)^16'h1021:v<<1;
   crc_byte=v;
  end
 endfunction
 function [3:0] popcount(input [7:0] mask);
  integer k;begin popcount=0;for(k=0;k<8;k=k+1)popcount=popcount+mask[k];end
 endfunction
 assign tx_valid=state==SEND;
 assign tx_last=tx_index==63;
 assign tx_data=tx_index<62?snapshot[tx_index*8+:8]:(tx_index==62?crc_tx[7:0]:crc_tx[15:8]);
 // snapshot includes bytes 0..61 (496 bits); header bytes are filled below.
 reg [21:0] idle_timer;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
  cfg<=DEFAULTS;commit<=0;state<=RECEIVE;rx_index<=0;tx_index<=0;
  crc_rx<=16'hffff;crc_low<=0;seq<=0;op<=0;candidate<=0;
  generation<=0;cycles<=0;last_scan<=0;scan_cycles<=2665;raw_total<=0;accepted_total<=0;
  errors<=0;status<=0;snapshot<=0;crc_tx<=16'hffff;idle_timer<=0;
  have_applied<=0;applied_seq<=0;applied_op<=0;applied_candidate<=0;
 end else begin
  cycles<=cycles+1'b1;commit<=0;
  raw_total<=raw_total+popcount(raw_hits);
  if(accepted_hit)accepted_total<=accepted_total+1'b1;
  if(scan_valid)begin scan_cycles<=cycles-last_scan;last_scan<=cycles;end
  if(rx_valid || rx_index==0)idle_timer<=0;
  else if(state==RECEIVE)begin
   idle_timer<=idle_timer+1'b1;
   if(idle_timer>=2500000)begin rx_index<=0;crc_rx<=16'hffff;idle_timer<=0;end
  end
  case(state)
   RECEIVE:if(rx_valid)begin
    if(rx_index==0)begin
     if(rx_data==8'hfc)begin crc_rx<=crc_byte(16'hffff,rx_data);rx_index<=1;status<=0;end
    end else begin
     if(rx_index<37)crc_rx<=crc_byte(crc_rx,rx_data);
     if(rx_index==1 && rx_data!=8'h54)status<=1;
     if(rx_index==2)seq[7:0]<=rx_data;
     if(rx_index==3)seq[15:8]<=rx_data;
     if(rx_index==4)op<=rx_data;
     if(rx_index>=5 && rx_index<37)candidate[(rx_index-5)*8+:8]<=rx_data;
     if(rx_index==37)crc_low<={8'd0,rx_data};
     if(rx_index==38)begin
      if({rx_data,crc_low[7:0]}!=crc_rx)status<=2;
      state<=CHECK;rx_index<=0;
     end else rx_index<=rx_index+1'b1;
    end
   end
   CHECK:begin
    state<=SETTLE;
    if(status!=0)errors<=errors+1'b1;
    else if(op>2)begin status<=1;errors<=errors+1'b1;end
    else if(op==1 && !values_ok)begin status<=3;errors<=errors+1'b1;end
    else if(op!=0)begin
     if(duplicate)begin
      if(op!=applied_op || candidate!=applied_candidate)begin status<=4;errors<=errors+1'b1;end
     end else begin
      cfg<=(op==2)?DEFAULTS:candidate;
      commit<=1;generation<=generation+1'b1;
      have_applied<=1;applied_seq<=seq;applied_op<=op;applied_candidate<=candidate;
     end
    end
   end
   SETTLE:begin
    snapshot<={errors,accepted_total,raw_total,scan_cycles,cfg,generation,
       {6'd0,calibrated,adc_ready},status,seq,16'd64,8'd6,8'd1,32'h31524e54};
    tx_index<=0;crc_tx<=16'hffff;state<=SEND;
   end
   SEND:if(tx_ready)begin
    if(tx_index<62)crc_tx<=crc_byte(crc_tx,tx_data);
    if(tx_index==63)begin state<=RECEIVE;crc_rx<=16'hffff;tx_index<=0;end
    else tx_index<=tx_index+1'b1;
   end
  endcase
 end
endmodule
