`timescale 1ns/1ps
// QSU1: periodic absolute GLOBAL sustain setting, never per-voice locked decay.
// This block has no output to the synth, ADC or QT controller.
module qt_sustain_telemetry #(
 parameter integer CLK_HZ=50000000,BAUD=128000,PERIOD=5000000
)(input wire clk,rst_n,input wire [7:0] sustain_u,input wire enabled,
 input wire [31:0] qt_sample_seq,input wire qt_valid,
 input wire [3:0] qt_mode,qt_error,output wire tx);
 wire source_valid,source_last,source_ready;
 wire [7:0] source_data;
 qt_sustain_telemetry_source #(.PERIOD(PERIOD)) source(
  .clk(clk),.rst_n(rst_n),.sustain_u(sustain_u),.enabled(enabled),
  .qt_sample_seq(qt_sample_seq),.qt_valid(qt_valid),.qt_mode(qt_mode),.qt_error(qt_error),
  .out_valid(source_valid),.out_data(source_data),.out_last(source_last),.out_ready(source_ready));
 jdy_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) uart(
  .clk(clk),.rst_n(rst_n),.valid(source_valid),.data(source_data),.ready(source_ready),.tx(tx));
endmodule

// Byte-stream form used by the complete-frame telemetry arbiter. The 30-byte
// QSU1 payload and CRC are bit-for-bit identical to the established wrapper.
module qt_sustain_telemetry_source #(
 parameter integer PERIOD=5000000
)(input wire clk,rst_n,input wire [7:0] sustain_u,input wire enabled,
 input wire [31:0] qt_sample_seq,input wire qt_valid,
 input wire [3:0] qt_mode,qt_error,
 output wire out_valid,output wire [7:0] out_data,output wire out_last,input wire out_ready);
 reg [223:0] packet;
 reg [63:0] uptime;
 reg [31:0] sequence_number,timer,skipped_periods;
 reg [31:0] seq_d;
 reg valid_d;reg [3:0] mode_d,error_d;reg [1:0] settled;
 reg sending,snapshot_valid;reg [5:0] index;
 reg [15:0] crc;
 wire [7:0] data=index<28 ? packet[index*8+:8] : (index==28 ? crc[7:0] : crc[15:8]);
 assign out_valid=sending;
 assign out_data=data;
 assign out_last=(index==29);
 function [15:0] crc_byte(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer j;begin v=c^{b,8'd0};
   for(j=0;j<8;j=j+1)v=v[15]?(v<<1)^16'h1021:v<<1;
   crc_byte=v;end
 endfunction
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
  uptime<=0;sequence_number<=0;timer<=0;skipped_periods<=0;
  seq_d<=0;valid_d<=0;mode_d<=0;error_d<=0;settled<=0;
  packet<=0;sending<=0;snapshot_valid<=0;index<=0;crc<=16'hffff;
 end else begin
  uptime<=uptime+1'b1;snapshot_valid<=0;
  // The adapter consumes these QT inputs on this same clock. One-cycle QT
  // metadata delay aligns them with the resulting registered sustain_u.
  seq_d<=qt_sample_seq;valid_d<=qt_valid;mode_d<=qt_mode;error_d<=qt_error;
  settled<={settled[0],1'b1};
  if(timer>=PERIOD-1)begin
   timer<=0;
   if(!sending && settled[1])begin
    packet<={4'd0, error_d,4'd0,mode_d,
      4'd0,1'b1,(valid_d && mode_d==2 && error_d==0),settled[1],enabled,
      sustain_u,seq_d,uptime,sequence_number,16'd30,8'd1,8'd1,32'h31555351};
    sequence_number<=sequence_number+1'b1;index<=0;crc<=16'hffff;
    sending<=1;snapshot_valid<=1;
   end else skipped_periods<=skipped_periods+1'b1;
  end else timer<=timer+1'b1;
  if(sending && out_ready)begin
   if(index<28)crc<=crc_byte(crc,data);
   if(index==29)begin sending<=0;index<=0;end
   else index<=index+1'b1;
  end
 end
endmodule
