`timescale 1ns/1ps
// HTE1, 28 bytes, little-endian, CRC16-CCITT over bytes 0..25.
// The input is a one-cycle observation pulse. FIFO pressure never backpressures audio.
module hit_telemetry #(parameter integer DEPTH=16)(
 input wire clk,rst_n,input wire hit_valid,input wire [2:0] hit_channel,
 input wire [6:0] hit_velocity,input wire [15:0] hit_peak,
 output wire out_valid,output wire [7:0] out_data,output wire out_last,input wire out_ready,
 output reg [31:0] accepted_total,output reg [31:0] dropped_total);
 localparam integer AW=$clog2(DEPTH);
 reg [57:0] fifo[0:DEPTH-1]; // seq,peak,velocity,channel
 reg [AW-1:0] wr,rd; reg [AW:0] count;
 reg sending; reg [4:0] index; reg [15:0] crc;
 reg [31:0] frame_seq,frame_accepted,frame_dropped;
 reg [15:0] frame_peak; reg [6:0] frame_velocity; reg [2:0] frame_channel;
 wire pop_start=!sending && count!=0;
 wire can_push=(count<DEPTH)||pop_start;
 function [15:0] crc_byte(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer j;begin v=c^{b,8'd0};for(j=0;j<8;j=j+1)v=v[15]?(v<<1)^16'h1021:v<<1;crc_byte=v;end
 endfunction
 function [7:0] payload_byte(input [4:0] n);
  begin case(n)
   5'd0:payload_byte=8'h48;5'd1:payload_byte=8'h54;5'd2:payload_byte=8'h45;5'd3:payload_byte=8'h31;
   5'd4:payload_byte=8'd1;5'd5:payload_byte=8'd2;5'd6:payload_byte=8'd28;5'd7:payload_byte=8'd0;
   5'd8:payload_byte=frame_seq[7:0];5'd9:payload_byte=frame_seq[15:8];5'd10:payload_byte=frame_seq[23:16];5'd11:payload_byte=frame_seq[31:24];
   5'd12:payload_byte={5'd0,frame_channel};5'd13:payload_byte={1'b0,frame_velocity};5'd14:payload_byte=frame_peak[7:0];5'd15:payload_byte=frame_peak[15:8];
   5'd16:payload_byte=frame_accepted[7:0];5'd17:payload_byte=frame_accepted[15:8];5'd18:payload_byte=frame_accepted[23:16];5'd19:payload_byte=frame_accepted[31:24];
   5'd20:payload_byte=frame_dropped[7:0];5'd21:payload_byte=frame_dropped[15:8];5'd22:payload_byte=frame_dropped[23:16];5'd23:payload_byte=frame_dropped[31:24];
   5'd24:payload_byte=8'd0;5'd25:payload_byte=8'd0;5'd26:payload_byte=crc[7:0];default:payload_byte=crc[15:8];
  endcase end
 endfunction
 assign out_valid=sending;
 assign out_data=payload_byte(index);
 assign out_last=(index==27);
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin wr<=0;rd<=0;count<=0;sending<=0;index<=0;crc<=16'hffff;
  accepted_total<=0;dropped_total<=0;frame_seq<=0;frame_accepted<=0;frame_dropped<=0;
  frame_peak<=0;frame_velocity<=0;frame_channel<=0;end
 else begin
  if(hit_valid)begin
   accepted_total<=accepted_total+1'b1;
   if(can_push)begin fifo[wr]<={accepted_total,hit_peak,hit_velocity,hit_channel};wr<=wr+1'b1;end
   else dropped_total<=dropped_total+1'b1;
  end
  if(pop_start)begin
   frame_seq<=fifo[rd][57:26];frame_peak<=fifo[rd][25:10];frame_velocity<=fifo[rd][9:3];frame_channel<=fifo[rd][2:0];
   frame_accepted<=accepted_total;frame_dropped<=dropped_total;rd<=rd+1'b1;sending<=1;index<=0;crc<=16'hffff;
  end
  case({hit_valid&&can_push,pop_start})
   2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:count<=count;
  endcase
  if(sending&&out_ready)begin
   if(index<26)crc<=crc_byte(crc,out_data);
   if(index==27)begin sending<=0;index<=0;end else index<=index+1'b1;
  end
 end
endmodule
