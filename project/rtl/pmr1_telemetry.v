`timescale 1ns/1ps
// Passive 8-channel Peak/RMS statistics source. It never backpressures scan_valid.
// RMS is intentionally computed on the PC from the exact 40-bit sum-of-squares.
module pmr1_telemetry #(parameter integer WINDOW_SCANS=128, SNAPSHOT_DEPTH=2)(
 input wire clk,rst_n,input wire scan_valid,input wire [31:0] scan_count,
 input wire [127:0] samples,input wire [127:0] baselines,
 input wire adc_ready,input wire calibrated,input wire [3:0] adc_error,
 output wire out_valid,output wire [7:0] out_data,output wire out_last,input wire out_ready,
 output reg [31:0] dropped_windows,output reg [31:0] completed_windows,
 output reg scan_overrun);
 localparam integer SW=$clog2(SNAPSHOT_DEPTH);
 reg [47:0] cycle_counter,work_timestamp,done_timestamp;
 reg [31:0] work_scan,done_scan;
 reg [7:0] work_status,done_status;
 reg [15:0] work_delta[0:7],peak_acc[0:7];
 reg [39:0] sum_acc[0:7];
 reg [2:0] channel;
 reg busy,window_done;
 reg [15:0] scans_in_window,done_window_count;
 wire [31:0] square=work_delta[channel]*work_delta[channel];
 reg [615:0] fifo[0:SNAPSHOT_DEPTH-1];
 reg [SW-1:0] wr,rd;reg [SW:0] fifo_count;
 reg sending;reg [6:0] byte_index;reg [15:0] crc;
 wire pop_start=!sending && fifo_count!=0;
 wire push_snapshot=window_done;
 reg [31:0] frame_sequence,frame_scan,frame_dropped;
 reg [47:0] frame_timestamp;
 reg [15:0] frame_window;
 reg [7:0] frame_status;
 reg [15:0] frame_peak[0:7];reg [39:0] frame_sum[0:7];
 integer i;
 function [15:0] crc_byte(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer j;begin v=c^{b,8'd0};for(j=0;j<8;j=j+1)v=v[15]?(v<<1)^16'h1021:v<<1;crc_byte=v;end
 endfunction
 function [7:0] payload_byte(input [6:0] n);
  integer c,o;begin
   payload_byte=0;
   case(n)
    0:payload_byte=8'h50;1:payload_byte=8'h4d;2:payload_byte=8'h52;3:payload_byte=8'h31;
    4:payload_byte=1;5:payload_byte=3;6:payload_byte=88;7:payload_byte=0;
    8:payload_byte=frame_sequence[7:0];9:payload_byte=frame_sequence[15:8];
    10:payload_byte=frame_sequence[23:16];11:payload_byte=frame_sequence[31:24];
    12:payload_byte=frame_timestamp[7:0];13:payload_byte=frame_timestamp[15:8];
    14:payload_byte=frame_timestamp[23:16];15:payload_byte=frame_timestamp[31:24];
    16:payload_byte=frame_timestamp[39:32];17:payload_byte=frame_timestamp[47:40];
    18:payload_byte=frame_scan[7:0];19:payload_byte=frame_scan[15:8];
    20:payload_byte=frame_scan[23:16];21:payload_byte=frame_scan[31:24];
    22:payload_byte=frame_window[7:0];23:payload_byte=frame_window[15:8];
    24:payload_byte=frame_status;25:payload_byte=0;
    82:payload_byte=frame_dropped[7:0];83:payload_byte=frame_dropped[15:8];
    84:payload_byte=frame_dropped[23:16];85:payload_byte=frame_dropped[31:24];
    86:payload_byte=crc[7:0];87:payload_byte=crc[15:8];
    default:begin
     if(n>=26 && n<82)begin c=(n-26)/7;o=(n-26)%7;
      if(o<2)payload_byte=frame_peak[c][o*8+:8];
      else payload_byte=frame_sum[c][(o-2)*8+:8];
     end
    end
   endcase
  end
 endfunction
 assign out_valid=sending;assign out_data=payload_byte(byte_index);assign out_last=(byte_index==87);
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
  cycle_counter<=0;work_timestamp<=0;done_timestamp<=0;work_scan<=0;done_scan<=0;
  work_status<=0;done_status<=0;channel<=0;busy<=0;window_done<=0;scans_in_window<=0;done_window_count<=0;
  wr<=0;rd<=0;fifo_count<=0;sending<=0;byte_index<=0;crc<=16'hffff;
  frame_sequence<=0;frame_scan<=0;frame_dropped<=0;frame_timestamp<=0;frame_window<=0;frame_status<=0;
  dropped_windows<=0;completed_windows<=0;scan_overrun<=0;
  for(i=0;i<8;i=i+1)begin work_delta[i]<=0;peak_acc[i]<=0;sum_acc[i]<=0;frame_peak[i]<=0;frame_sum[i]<=0;end
 end else begin
  cycle_counter<=cycle_counter+1'b1;
  if(scan_valid)begin
   if(busy || window_done)scan_overrun<=1;
   else begin
    for(i=0;i<8;i=i+1)
     work_delta[i]<=samples[i*16+:16]>=baselines[i*16+:16]?
       samples[i*16+:16]-baselines[i*16+:16]:baselines[i*16+:16]-samples[i*16+:16];
    work_timestamp<=cycle_counter;work_scan<=scan_count;
    work_status<={adc_error,calibrated,adc_ready,2'b00};channel<=0;busy<=1;
   end
  end
  if(busy)begin
   if(work_delta[channel]>peak_acc[channel])peak_acc[channel]<=work_delta[channel];
   sum_acc[channel]<=sum_acc[channel]+square;
   if(channel==7)begin
    busy<=0;
    if(scans_in_window==WINDOW_SCANS-1)begin
     window_done<=1;done_timestamp<=work_timestamp;done_scan<=work_scan;done_status<=work_status;
     done_window_count<=WINDOW_SCANS;scans_in_window<=0;
    end else scans_in_window<=scans_in_window+1'b1;
   end else channel<=channel+1'b1;
  end
  if(push_snapshot)begin
   fifo[wr][615:584]<=completed_windows;fifo[wr][583:536]<=done_timestamp;
   fifo[wr][535:504]<=done_scan;fifo[wr][503:488]<=done_window_count;fifo[wr][487:480]<=done_status;
   for(i=0;i<8;i=i+1)begin fifo[wr][32+i*56+:16]<=peak_acc[i];fifo[wr][48+i*56+:40]<=sum_acc[i];end
   fifo[wr][31:0]<=dropped_windows+((fifo_count==SNAPSHOT_DEPTH && !pop_start)?1:0);
   wr<=wr+1'b1;completed_windows<=completed_windows+1'b1;window_done<=0;
   for(i=0;i<8;i=i+1)begin peak_acc[i]<=0;sum_acc[i]<=0;end
   if(fifo_count==SNAPSHOT_DEPTH && !pop_start)begin rd<=rd+1'b1;dropped_windows<=dropped_windows+1'b1;end
  end
  case({push_snapshot,pop_start})
   2'b10:if(fifo_count<SNAPSHOT_DEPTH)fifo_count<=fifo_count+1'b1;
   2'b01:fifo_count<=fifo_count-1'b1;
   default:fifo_count<=fifo_count;
  endcase
  if(pop_start)begin
   frame_sequence<=fifo[rd][615:584];frame_timestamp<=fifo[rd][583:536];frame_scan<=fifo[rd][535:504];
   frame_window<=fifo[rd][503:488];frame_status<=fifo[rd][487:480];frame_dropped<=fifo[rd][31:0];
   for(i=0;i<8;i=i+1)begin frame_peak[i]<=fifo[rd][32+i*56+:16];frame_sum[i]<=fifo[rd][48+i*56+:40];end
   rd<=rd+1'b1;sending<=1;byte_index<=0;crc<=16'hffff;
  end
  if(sending&&out_ready)begin
   if(byte_index<86)crc<=crc_byte(crc,out_data);
   if(byte_index==87)begin sending<=0;byte_index<=0;end else byte_index<=byte_index+1'b1;
  end
 end
endmodule
