`timescale 1ns/1ps
// QKY1 v2 diagnostic snapshot, 48 bytes, CRC16-CCITT over bytes 0..45.
// Observation only: this module never feeds back into QT, keys, or audio.
module qt_key_telemetry #(parameter integer PERIOD=5000000)(
 input wire clk,rst_n,input wire [31:0] qt_sample_seq,input wire [11:0] qt_keys,
 input wire [7:0] qt_status,input wire [3:0] qt_mode,qt_error,
 input wire healthy,synchronized,input wire [4:0] press_pulse,
 input wire [1:0] selected_timbre,input wire echo_enabled,
 input wire sensor_timbre_seen,input wire [1:0] last_sensor_timbre,
 input wire fault_valid,input wire [7:0] fault_addr,fault_expected,fault_actual,
 input wire [1:0] fault_bus_error,input wire [4:0] fault_state,
 input wire [7:0] fault_last_reg,fault_last_status,input wire [11:0] fault_last_keys,
 input wire [7:0] fault_last_position,
 input wire [7:0] nack_count,mismatch_count,reinit_count,
 output wire out_valid,output wire [7:0] out_data,output wire out_last,input wire out_ready);
 reg [31:0] timer,frame_seq;reg [47:0] cycles;reg [5:0] index;reg sending,pending;
 reg [31:0] s_qt_seq;reg [11:0] s_keys;reg [7:0] s_status;reg [3:0] s_mode,s_error;
 reg s_healthy,s_sync;reg [4:0] s_press;reg [1:0] s_timbre;reg s_echo,s_sensor_seen;reg [1:0] s_sensor_timbre;
 reg s_fault_valid;reg [7:0] s_fault_addr,s_fault_expected,s_fault_actual,s_fault_last_reg,s_fault_last_status,s_fault_last_position;
 reg [1:0] s_fault_bus_error;reg [4:0] s_fault_state;reg [11:0] s_fault_last_keys;
 reg [7:0] s_nack_count,s_mismatch_count,s_reinit_count;
 reg [15:0] crc;
 function [15:0] crc_next;input [15:0] c;input [7:0] d;integer i;reg [15:0] x;begin
  x=c^{d,8'h00};for(i=0;i<8;i=i+1)x=x[15]?(x<<1)^16'h1021:(x<<1);crc_next=x;end endfunction
 wire due=(timer==PERIOD-1) || (press_pulse!=0);
 reg [7:0] payload;
 always @* begin
  case(index)
   0:payload="Q";1:payload="K";2:payload="Y";3:payload="1";4:payload=2;5:payload=4;6:payload=48;7:payload=0;
   8:payload=frame_seq[7:0];9:payload=frame_seq[15:8];10:payload=frame_seq[23:16];11:payload=frame_seq[31:24];
   12:payload=cycles[7:0];13:payload=cycles[15:8];14:payload=cycles[23:16];15:payload=cycles[31:24];16:payload=cycles[39:32];17:payload=cycles[47:40];
   18:payload=s_qt_seq[7:0];19:payload=s_qt_seq[15:8];20:payload=s_qt_seq[23:16];21:payload=s_qt_seq[31:24];
   22:payload=s_keys[7:0];23:payload={4'd0,s_keys[11:8]};24:payload=s_status;25:payload={4'd0,s_mode};26:payload={4'd0,s_error};
   27:payload={4'd0,s_sensor_seen,s_sync,s_healthy,1'b1};28:payload={3'd0,s_press};29:payload={6'd0,s_timbre};30:payload={7'd0,s_echo};31:payload={6'd0,s_sensor_timbre};
   32:payload={7'd0,s_fault_valid};33:payload=s_fault_addr;34:payload=s_fault_expected;35:payload=s_fault_actual;
   36:payload={6'd0,s_fault_bus_error};37:payload={3'd0,s_fault_state};38:payload=s_fault_last_reg;39:payload=s_fault_last_status;
   40:payload=s_fault_last_keys[7:0];41:payload={4'd0,s_fault_last_keys[11:8]};42:payload=s_fault_last_position;
   43:payload=s_nack_count;44:payload=s_mismatch_count;45:payload=s_reinit_count;46:payload=crc[7:0];default:payload=crc[15:8];endcase
 end
 assign out_valid=sending;assign out_data=payload;assign out_last=sending&&(index==47);
 task snapshot;begin s_qt_seq<=qt_sample_seq;s_keys<=qt_keys;s_status<=qt_status;s_mode<=qt_mode;s_error<=qt_error;
  s_healthy<=healthy;s_sync<=synchronized;s_press<=press_pulse;s_timbre<=selected_timbre;s_echo<=echo_enabled;
  s_sensor_seen<=sensor_timbre_seen;s_sensor_timbre<=last_sensor_timbre;
  s_fault_valid<=fault_valid;s_fault_addr<=fault_addr;s_fault_expected<=fault_expected;s_fault_actual<=fault_actual;
  s_fault_bus_error<=fault_bus_error;s_fault_state<=fault_state;s_fault_last_reg<=fault_last_reg;
  s_fault_last_status<=fault_last_status;s_fault_last_keys<=fault_last_keys;s_fault_last_position<=fault_last_position;
  s_nack_count<=nack_count;s_mismatch_count<=mismatch_count;s_reinit_count<=reinit_count;end endtask
 always @(posedge clk or negedge rst_n)if(!rst_n)begin timer<=0;frame_seq<=0;cycles<=0;index<=0;sending<=0;pending<=0;crc<=16'hffff;
  s_qt_seq<=0;s_keys<=0;s_status<=0;s_mode<=0;s_error<=0;s_healthy<=0;s_sync<=0;s_press<=0;s_timbre<=0;s_echo<=0;s_sensor_seen<=0;s_sensor_timbre<=0;
  s_fault_valid<=0;s_fault_addr<=0;s_fault_expected<=0;s_fault_actual<=0;s_fault_bus_error<=0;s_fault_state<=0;
  s_fault_last_reg<=0;s_fault_last_status<=0;s_fault_last_keys<=0;s_fault_last_position<=0;
  s_nack_count<=0;s_mismatch_count<=0;s_reinit_count<=0;
 end else begin cycles<=cycles+1'b1;
  if(timer==PERIOD-1)timer<=0;else timer<=timer+1'b1;
  if(due)begin snapshot();if(sending)pending<=1;else begin sending<=1;index<=0;crc<=16'hffff;frame_seq<=frame_seq+1'b1;end end
  if(sending&&out_ready)begin
   if(index<46)crc<=crc_next(crc,payload);
   if(index==47)begin sending<=0;index<=0;if(pending)begin pending<=0;sending<=1;crc<=16'hffff;frame_seq<=frame_seq+1'b1;snapshot();end end
   else index<=index+1'b1;
  end
 end
endmodule
