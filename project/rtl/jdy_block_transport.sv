`timescale 1ns/1ps
module jdy_block_transport #(
 parameter integer BLOCK_BYTES=256,TIMEOUT_CYCLES=50000000,MAX_RETRIES=5,RECALIBRATION_ENABLE=0
)(input wire clk,rst_n,
 input wire stream_valid,input wire [7:0] stream_data,output wire stream_ready,
 input wire stream_complete,frozen,input wire [31:0] skipped_scans,
 output reg capture_arm,capture_release,
 input wire cmd_valid,input wire [7:0] cmd_type,input wire [63:0] cmd_id,
 input wire [15:0] cmd_seq,cmd_length,input wire [31:0] cmd_offset,
 input wire [95:0] cmd_payload,
 output wire tx_valid,output reg [7:0] tx_data,output wire tx_last,input wire tx_ready,
 output wire hold_error,output reg active,output reg [31:0] retries,
 output reg [3:0] state,
 input wire recalibration_adc_ready,recalibration_calibrated,
 output reg recalibration_request);
 localparam IDLE=0,FILL=1,SEND=2,DRAIN=3,WAIT_ACK=4,WAIT_COMMIT=5,HOLD=6,RECAL=7;
 localparam DATA=8'h81,END_PACKET=8'h82,COMMIT_ACK=8'h83,ARM_ACK=8'h84,ABORT_ACK=8'h85,STATUS=8'h86,RECAL_ACK=8'h87;
 reg recal_pending,recal_low_seen,last_recal_valid;reg [1:0] last_recal_status;
 wire valid_recal=RECALIBRATION_ENABLE!=0 && cmd_valid && cmd_type==7 && cmd_id!=0 && cmd_seq==0 && cmd_offset==0 && cmd_length==4 && cmd_payload[31:0]==32'h314c4143;
 reg [7:0] block_mem[0:BLOCK_BYTES-1];
 reg [63:0] transfer_id;reg [15:0] block_seq,block_len;
 reg [31:0] offset,total,stream_crc,tx_crc;
 // Length/counter ranges are bounded by the maximum legal frame.
 localparam integer MAX_PAYLOAD=(BLOCK_BYTES>12)?BLOCK_BYTES:12;
 localparam integer LEN_W=$clog2(MAX_PAYLOAD+1);
 localparam integer FILL_W=$clog2(BLOCK_BYTES+1);
 localparam integer INDEX_W=$clog2(MAX_PAYLOAD+26);
 reg [7:0] frame_type;reg [LEN_W-1:0] frame_len;reg [15:0] frame_seq;
 reg [31:0] frame_offset;reg [95:0] control_payload;
 reg [FILL_W-1:0] fill_count;
 reg [INDEX_W-1:0] tx_index;
 integer timer,retry_count;
 reg [3:0] after_send;reg hold_end,committed;
 assign hold_error=(state==HOLD);
 assign stream_ready=active && state==FILL && fill_count<BLOCK_BYTES;
 assign tx_valid=(state==SEND);
 assign tx_last=(state==SEND) && (tx_index==25+frame_len);
 function automatic [31:0] crc_byte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer k;begin v=c^b;for(k=0;k<8;k=k+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crc_byte=v;end
 endfunction
 task automatic start_frame(input [7:0] kind,input [15:0] len,seq,
     input [31:0] off,input [3:0] next_state);
  begin frame_type<=kind;frame_len<=len;frame_seq<=seq;frame_offset<=off;
   tx_index<=0;tx_crc<=32'hffffffff;state<=SEND;after_send<=next_state;end
 endtask
 task automatic send_end;
  begin control_payload<={~stream_crc,16'd0,block_seq,total};
   start_frame(END_PACKET,12,block_seq,total,WAIT_COMMIT);end
 endtask
 always @*begin
  tx_data=0;
  case(tx_index)
  0:tx_data="W";1:tx_data="D";2:tx_data="Y";3:tx_data="1";
  4:tx_data=1;5:tx_data=frame_type;
  6,7,8,9,10,11,12,13:tx_data=transfer_id[(tx_index-6)*8+:8];
  14:tx_data=frame_seq[7:0];15:tx_data=frame_seq[15:8];
  16:tx_data=16'(frame_len);17:tx_data=16'(frame_len)>>8;
  18,19,20,21:tx_data=frame_offset[(tx_index-18)*8+:8];
  default:if(tx_index<22+frame_len)begin
    if(frame_type==DATA)tx_data=block_mem[tx_index-22];
    else tx_data=control_payload[(tx_index-22)*8+:8];
   end else tx_data=(~tx_crc)>>((tx_index-22-frame_len)*8);
  endcase
 end
 always @(posedge clk)begin
  capture_arm<=0;capture_release<=0;recalibration_request<=0;
  if(!rst_n)begin
   state<=IDLE;active<=0;committed<=0;recal_pending<=0;recal_low_seen<=0;last_recal_valid<=0;last_recal_status<=0;transfer_id<=0;block_seq<=0;block_len<=0;
   offset<=0;total<=0;stream_crc<=32'hffffffff;tx_crc<=32'hffffffff;
   frame_type<=0;frame_len<=0;frame_seq<=0;frame_offset<=0;control_payload<=0;
   fill_count<=0;tx_index<=0;timer<=0;retry_count<=0;retries<=0;after_send<=IDLE;hold_end<=0;
  end else begin
   if(recal_pending && !recalibration_calibrated)recal_low_seen<=1;
   case(state)
   IDLE:if(cmd_valid)begin
    if(valid_recal && !frozen && !active)begin
     transfer_id<=cmd_id;committed<=0;
     if(last_recal_valid && cmd_id==transfer_id)begin
      control_payload<={94'd0,last_recal_status};start_frame(RECAL_ACK,1,0,0,IDLE);
     end else if(!recalibration_adc_ready)begin
      last_recal_valid<=1;last_recal_status<=2;
      control_payload<=96'd2;start_frame(RECAL_ACK,1,0,0,IDLE);
     end else begin
      last_recal_valid<=1;last_recal_status<=0;recal_pending<=1;recal_low_seen<=0;
      recalibration_request<=1;control_payload<=0;start_frame(RECAL_ACK,1,0,0,RECAL);
     end
    end else if(cmd_type==1 && cmd_length==0 && cmd_seq==0 && cmd_offset==0 && cmd_id!=0 && cmd_id!=transfer_id)begin
     transfer_id<=cmd_id;last_recal_valid<=0;active<=1;committed<=0;capture_arm<=1;
     total<=0;offset<=0;block_seq<=0;fill_count<=0;stream_crc<=32'hffffffff;
     retry_count<=0;start_frame(ARM_ACK,0,0,0,FILL);
    end else if(cmd_type==3 && committed && cmd_id==transfer_id && cmd_length==12 &&
                cmd_seq==block_seq && cmd_offset==total &&
                cmd_payload=={~stream_crc,16'd0,block_seq,total})
     begin control_payload<={~stream_crc,16'd0,block_seq,total};start_frame(COMMIT_ACK,12,block_seq,total,IDLE);end
    else if(cmd_type==4 && cmd_length==0 && cmd_id==transfer_id)
     start_frame(ABORT_ACK,0,block_seq,offset,IDLE);
   end
   FILL:begin
    if(stream_valid && stream_ready)begin
     block_mem[fill_count]<=stream_data;fill_count<=fill_count+1;
     stream_crc<=crc_byte(stream_crc,stream_data);total<=total+1;
     if(fill_count==BLOCK_BYTES-1)begin
      block_len<=BLOCK_BYTES;retry_count<=0;hold_end<=0;
      start_frame(DATA,BLOCK_BYTES,block_seq,offset,WAIT_ACK);
     end
    end else if(stream_complete)begin
     if(fill_count!=0)begin block_len<=fill_count;retry_count<=0;hold_end<=0;
      start_frame(DATA,fill_count,block_seq,offset,WAIT_ACK);end
     else begin
      control_payload<={~stream_crc,16'd0,block_seq,total};retry_count<=0;hold_end<=1;
      send_end;
     end
    end
    if(!stream_valid && cmd_valid && (cmd_type==1 || cmd_type==5) && cmd_id==transfer_id && cmd_length==0 && cmd_seq==0 && cmd_offset==0)
     start_frame(ARM_ACK,0,0,0,FILL);
   end
   SEND:if(tx_ready)begin
    if(tx_index<22+frame_len)tx_crc<=crc_byte(tx_crc,tx_data);
    if(tx_index==25+frame_len)state<=DRAIN;else tx_index<=tx_index+1;
   end
   // The last SEND byte was already accepted when entering DRAIN.  The frame
   // mux intentionally deasserts wdy_ready whenever tx_valid is low, so DRAIN
   // must not wait for another ready handshake that can never occur.
   DRAIN:begin state<=after_send;timer<=0;end
   WAIT_ACK,WAIT_COMMIT:begin
    if(timer>=TIMEOUT_CYCLES-1)begin
     if(retry_count>=MAX_RETRIES)state<=HOLD;
     else begin retry_count<=retry_count+1;retries<=retries+1;
      if(state==WAIT_ACK)start_frame(DATA,block_len,block_seq,offset,WAIT_ACK);
      else send_end;
     end
    end else timer<=timer+1;
    if(cmd_valid && cmd_id==transfer_id)begin
     if(cmd_type==5 && cmd_length==0)begin
      retry_count<=0;
      if(state==WAIT_ACK)start_frame(DATA,block_len,block_seq,offset,WAIT_ACK);
      else send_end;
     end else if(state==WAIT_ACK && cmd_type==2 && cmd_length==0 && cmd_seq==block_seq && cmd_offset==offset)begin
      offset<=offset+block_len;block_seq<=block_seq+1;fill_count<=0;retry_count<=0;state<=FILL;
     end else if(state==WAIT_COMMIT && cmd_type==3 && cmd_length==12 && cmd_seq==block_seq &&
         cmd_offset==total && cmd_payload=={~stream_crc,16'd0,block_seq,total})begin
      capture_release<=1;active<=0;committed<=1;
      control_payload<={~stream_crc,16'd0,block_seq,total};
      start_frame(COMMIT_ACK,12,block_seq,total,IDLE);
     end
    end
   end
   RECAL:begin
    if(!recalibration_adc_ready)begin
     recal_pending<=0;last_recal_status<=2;control_payload<=96'd2;
     start_frame(RECAL_ACK,1,0,0,IDLE);
    end else if(recal_low_seen && recalibration_calibrated)begin
     recal_pending<=0;last_recal_status<=1;control_payload<=96'd1;
     start_frame(RECAL_ACK,1,0,0,IDLE);
    end else if(timer>=TIMEOUT_CYCLES-1)begin
     recal_pending<=0;last_recal_status<=3;control_payload<=96'd3;
     start_frame(RECAL_ACK,1,0,0,IDLE);
    end else timer<=timer+1;
   end
   HOLD:if(cmd_valid && cmd_id==transfer_id)begin
    if(cmd_type==5 && cmd_length==0)begin
     retry_count<=0;
     if(hold_end)send_end;
     else start_frame(DATA,block_len,block_seq,offset,WAIT_ACK);
    end else if(hold_end && cmd_type==3 && cmd_length==12 && cmd_seq==block_seq &&
                cmd_offset==total && cmd_payload=={~stream_crc,16'd0,block_seq,total})begin
     capture_release<=1;active<=0;committed<=1;
     control_payload<={~stream_crc,16'd0,block_seq,total};
     start_frame(COMMIT_ACK,12,block_seq,total,IDLE);
    end
   end
   default:begin state<=HOLD;end
   endcase
   // ABORT only at packet boundaries. It never acts on a partial/unverified command.
   if(cmd_valid && active && cmd_type==4 && cmd_length==0 && cmd_id==transfer_id && state!=SEND && state!=DRAIN)begin
    capture_release<=1;active<=0;committed<=0;control_payload<=0;
    start_frame(ABORT_ACK,0,block_seq,offset,IDLE);
   end
   if(!recal_pending && cmd_valid && cmd_type==6 && cmd_length==0 && (!active || cmd_id==transfer_id) &&
      state!=SEND && state!=DRAIN && (state!=FILL || !stream_valid))begin
    control_payload<={retries,skipped_scans,8'(state),7'd0,stream_complete,7'd0,frozen,7'd0,active};
    start_frame(STATUS,12,block_seq,offset,state);
   end
  end
 end
endmodule
