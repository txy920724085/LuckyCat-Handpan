`timescale 1ns/1ps
// ADS8688 diagnostic recorder.  DIAG_MODE=0 emits complete block statistics;
// DIAG_MODE=1 keeps a raw/baseline/peak ring and dumps it only after freeze.
// The byte stream is framed and CRC protected; uart_tx is instantiated by top.
module sensor_diag_capture_jdy31 #(
 parameter integer DIAG_MODE=0,
 parameter integer STATS_BLOCK_SCANS=128,
 parameter integer CAPTURE_DEPTH=1024,
 parameter integer PRE_TRIGGER_SCANS=512,
 parameter integer POST_TRIGGER_SCANS=512,
 parameter integer CAPTURE_TRIGGER=64
)(
 input wire clk,input wire rst_n,
 input wire capture_arm,capture_release,
 output wire frozen,output reg stream_complete,
 output wire [31:0] skipped_scans,
 input wire scan_valid,input wire adc_ready,input wire calibrated,
 input wire [3:0] adc_error,input wire [31:0] scan_count,
 input wire [127:0] samples,input wire [127:0] baselines,
 input wire [127:0] peaks,input wire [7:0] hit_mask,input wire [7:0] active,
 output reg tx_valid,output reg [7:0] tx_data,input wire tx_ready
);
 localparam integer PTR_W=$clog2(CAPTURE_DEPTH);
 localparam integer STATS_PAYLOAD=311;
 localparam integer WAVE_HEADER_PAYLOAD=25;
 localparam integer WAVE_SCAN_PAYLOAD=61,WAVE_FOOTER_PAYLOAD=10;
 localparam [7:0] PKT_STATS=8'h10,PKT_WAVE_HEADER=8'h20,PKT_WAVE_SCAN=8'h21,PKT_WAVE_FOOTER=8'h22;

 reg [47:0] cycle_counter;
 wire [7:0] status_byte={adc_error,calibrated,adc_ready,2'b00};
 wire [15:0] raw[0:7],base[0:7],peak_now[0:7],delta[0:7];
 genvar gg;
 generate for(gg=0;gg<8;gg=gg+1)begin:g_fields
  assign raw[gg]=samples[gg*16+:16];
  assign base[gg]=baselines[gg*16+:16];
  assign peak_now[gg]=peaks[gg*16+:16];
  assign delta[gg]=(raw[gg]>=base[gg])?raw[gg]-base[gg]:base[gg]-raw[gg];
 end endgenerate
 // Trigger reduction is deliberately eight clocks rather than one deep
 // 8-channel comparator tree. ADS scans are thousands of clocks apart.
 reg eval_busy;reg [2:0] eval_channel;reg [15:0] eval_max;reg [7:0] eval_mask;
 reg [15:0] eval_delta[0:7];reg [47:0] eval_timestamp;reg [31:0] eval_scan;
 reg [7:0] eval_status;
 wire [15:0] eval_value=eval_delta[eval_channel];
 wire [15:0] eval_max_next=(eval_value>eval_max)?eval_value:eval_max;
 wire [7:0] eval_mask_next=(eval_value>eval_max)?(8'b1<<eval_channel):
  ((eval_value==eval_max && eval_value!=0)?(eval_mask|(8'b1<<eval_channel)):eval_mask);

 // Complete-block statistics.  The eight histogram bins are:
 // <16,<32,<64,<128,<256,<512,<1024,>=1024 ADC codes.
 reg [15:0] b_last_raw[0:7],b_last_base[0:7],b_last_peak[0:7];
 reg [15:0] b_min_raw[0:7],b_max_raw[0:7],b_min_delta[0:7],b_max_delta[0:7],b_max_peak[0:7];
 reg [31:0] b_sum_raw[0:7];reg [15:0] b_hist[0:7][0:7];
 reg [15:0] s_last_raw[0:7],s_last_base[0:7],s_last_peak[0:7];
 reg [15:0] s_min_raw[0:7],s_max_raw[0:7],s_min_delta[0:7],s_max_delta[0:7],s_max_peak[0:7];
 reg [31:0] s_sum_raw[0:7];reg [15:0] s_hist[0:7][0:7];
 reg [15:0] block_count,s_block_count;reg [31:0] block_scan_start,s_scan_start,s_scan_end;
 reg [47:0] s_timestamp;reg [7:0] block_hit_or,block_active_or,s_hit_or,s_active_or;
 reg [7:0] s_status;
 reg stats_pending;reg [31:0] stats_overruns,s_stats_overruns;
 integer i,j;
 function automatic [2:0] histogram_bin(input [15:0] value);
  begin histogram_bin=(value<16)?0:(value<32)?1:(value<64)?2:(value<128)?3:
   (value<256)?4:(value<512)?5:(value<1024)?6:7;end
 endfunction

 // Waveform record layout, least-significant byte first:
 // timestamp48, scan32, status8, raw[8], baseline[8], peak[8], hit8, active8.
 reg [487:0] capture_mem[0:CAPTURE_DEPTH-1];
 reg [PTR_W-1:0] write_ptr,capture_start,read_ptr;
 reg [PTR_W:0] ring_count;
 reg wave_triggered,wave_frozen,wave_entry_pending,wave_footer_pending;
 reg armed;
 assign frozen=wave_frozen;
 reg [15:0] post_remaining,dump_index;
 reg [487:0] wave_entry;
 reg [47:0] trigger_timestamp;reg [31:0] trigger_scan,dropped_scans;
 reg [15:0] trigger_delta;reg [7:0] trigger_mask;reg [7:0] trigger_status;
 reg [31:0] footer_dropped;reg [47:0] footer_timestamp;
 assign skipped_scans=dropped_scans;

 // Packet serializer: A5 5A, version, type, payload_len LE16, sequence LE32,
 // payload, CRC16-CCITT LE16. CRC covers header and payload.
 reg sending;reg [8:0] tx_index;reg [15:0] payload_length,crc;
 reg [7:0] packet_type;reg [31:0] packet_sequence,current_sequence;
 wire [9:0] packet_last_index=10+payload_length+1;
 function automatic [15:0] crc16_byte(input [15:0] c,input [7:0] d);
  integer k;reg [15:0] v;
  begin v=c^(d<<8);for(k=0;k<8;k=k+1)v=v[15]?(v<<1)^16'h1021:(v<<1);crc16_byte=v;end
 endfunction
 function automatic [7:0] stats_byte(input integer n);
  integer c,o,bn;
  begin
   stats_byte=0;
   if(n<6)stats_byte=s_timestamp[n*8+:8];
   else if(n<10)stats_byte=s_scan_start[(n-6)*8+:8];
   else if(n<14)stats_byte=s_scan_end[(n-10)*8+:8];
   else if(n==14)stats_byte=s_status;
   else if(n<17)stats_byte=s_block_count[(n-15)*8+:8];
   else if(n==17)stats_byte=s_hit_or;
   else if(n==18)stats_byte=s_active_or;
   else if(n<23)stats_byte=s_stats_overruns[(n-19)*8+:8];
   else begin
    c=(n-23)/36;o=(n-23)%36;
    if(o<2)stats_byte=s_last_raw[c][o*8+:8];
    else if(o<4)stats_byte=s_last_base[c][(o-2)*8+:8];
    else if(o<6)stats_byte=s_last_peak[c][(o-4)*8+:8];
    else if(o<8)stats_byte=s_min_raw[c][(o-6)*8+:8];
    else if(o<10)stats_byte=s_max_raw[c][(o-8)*8+:8];
    else if(o<12)stats_byte=s_min_delta[c][(o-10)*8+:8];
    else if(o<14)stats_byte=s_max_delta[c][(o-12)*8+:8];
    else if(o<16)stats_byte=s_max_peak[c][(o-14)*8+:8];
    else if(o<20)stats_byte=s_sum_raw[c][(o-16)*8+:8];
    else begin bn=(o-20)/2;stats_byte=s_hist[c][bn][((o-20)%2)*8+:8];end
   end
  end
 endfunction
 function automatic [7:0] wave_header_byte(input integer n);
  begin
   wave_header_byte=0;
   if(n<6)wave_header_byte=trigger_timestamp[n*8+:8];
   else if(n<10)wave_header_byte=trigger_scan[(n-6)*8+:8];
   else if(n<12)wave_header_byte=CAPTURE_DEPTH[(n-10)*8+:8];
   else if(n<14)wave_header_byte=PRE_TRIGGER_SCANS[(n-12)*8+:8];
   else if(n<16)wave_header_byte=POST_TRIGGER_SCANS[(n-14)*8+:8];
   else if(n==16)wave_header_byte=trigger_mask;
   else if(n<19)wave_header_byte=trigger_delta[(n-17)*8+:8];
   else if(n==19)wave_header_byte=trigger_status;
   else if(n<24)wave_header_byte=8'd0;
   else wave_header_byte=8'd0;
  end
 endfunction
 function automatic [7:0] wave_footer_byte(input integer n);
  begin
   if(n<4)wave_footer_byte=footer_dropped[n*8+:8];
   else wave_footer_byte=footer_timestamp[(n-4)*8+:8];
  end
 endfunction
 function automatic [7:0] payload_byte(input integer n);
  begin
   case(packet_type)
    PKT_STATS:payload_byte=stats_byte(n);
    PKT_WAVE_HEADER:payload_byte=wave_header_byte(n);
    PKT_WAVE_SCAN:payload_byte=wave_entry[n*8+:8];
    PKT_WAVE_FOOTER:payload_byte=wave_footer_byte(n);
    default:payload_byte=0;
   endcase
  end
 endfunction
 reg [7:0] next_byte;integer payload_index;
 always @* begin
  next_byte=0;payload_index=tx_index-10;
  case(tx_index)
   0:next_byte=8'hA5;1:next_byte=8'h5A;2:next_byte=8'h01;3:next_byte=packet_type;
   4:next_byte=payload_length[7:0];5:next_byte=payload_length[15:8];
   6:next_byte=current_sequence[7:0];7:next_byte=current_sequence[15:8];
   8:next_byte=current_sequence[23:16];9:next_byte=current_sequence[31:24];
   default:begin
    if(tx_index<10+payload_length)next_byte=payload_byte(payload_index);
    else if(tx_index==10+payload_length)next_byte=crc[7:0];
    else next_byte=crc[15:8];
   end
  endcase
 end
 always @* begin tx_valid=sending;tx_data=next_byte;end
 task automatic start_packet(input [7:0] kind,input [15:0] length);
  begin sending<=1;packet_type<=kind;payload_length<=length;tx_index<=0;crc<=16'hffff;
   current_sequence<=packet_sequence;packet_sequence<=packet_sequence+1'b1;end
 endtask

 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   armed<=0;stream_complete<=0;
   cycle_counter<=0;sending<=0;tx_index<=0;payload_length<=0;
   crc<=16'hffff;packet_type<=0;packet_sequence<=0;current_sequence<=0;
   block_count<=0;block_scan_start<=0;block_hit_or<=0;block_active_or<=0;
   stats_pending<=0;stats_overruns<=0;s_stats_overruns<=0;s_timestamp<=0;s_scan_start<=0;s_scan_end<=0;
   s_block_count<=0;s_hit_or<=0;s_active_or<=0;s_status<=0;
   write_ptr<=0;capture_start<=0;read_ptr<=0;ring_count<=0;wave_triggered<=0;wave_frozen<=0;
   wave_entry_pending<=0;wave_footer_pending<=0;post_remaining<=0;dump_index<=0;wave_entry<=0;
   trigger_timestamp<=0;trigger_scan<=0;dropped_scans<=0;trigger_delta<=0;trigger_mask<=0;trigger_status<=0;
   footer_dropped<=0;footer_timestamp<=0;
   eval_busy<=0;eval_channel<=0;eval_max<=0;eval_mask<=0;eval_timestamp<=0;eval_scan<=0;eval_status<=0;
   for(i=0;i<8;i=i+1)begin
    b_last_raw[i]<=0;b_last_base[i]<=0;b_last_peak[i]<=0;b_min_raw[i]<=16'hffff;b_max_raw[i]<=0;
    b_min_delta[i]<=16'hffff;b_max_delta[i]<=0;b_max_peak[i]<=0;b_sum_raw[i]<=0;
    s_last_raw[i]<=0;s_last_base[i]<=0;s_last_peak[i]<=0;s_min_raw[i]<=0;s_max_raw[i]<=0;
    s_min_delta[i]<=0;s_max_delta[i]<=0;s_max_peak[i]<=0;s_sum_raw[i]<=0;
    for(j=0;j<8;j=j+1)begin b_hist[i][j]<=0;s_hist[i][j]<=0;end
   end
  end else if(capture_arm || capture_release)begin
   // Release is explicit (COMMIT or ABORT), never a UART-byte handshake.
   // Preserve uptime and global inner packet sequence across capture epochs.
   cycle_counter<=cycle_counter+1'b1;armed<=capture_arm;stream_complete<=0;
   sending<=0;tx_index<=0;crc<=16'hffff;
   write_ptr<=0;capture_start<=0;read_ptr<=0;ring_count<=0;
   wave_triggered<=0;wave_frozen<=0;wave_entry_pending<=0;wave_footer_pending<=0;
   post_remaining<=0;dump_index<=0;dropped_scans<=0;eval_busy<=0;
  end else begin
   cycle_counter<=cycle_counter+1'b1;
   if(sending && tx_ready)begin
    if(tx_index<10+payload_length)crc<=crc16_byte(crc,next_byte);
    if(tx_index==packet_last_index)begin
     sending<=0;tx_index<=0;
     if(packet_type==PKT_STATS)stats_pending<=0;
     else if(packet_type==PKT_WAVE_HEADER)begin
      read_ptr<=capture_start;wave_entry<=capture_mem[capture_start];dump_index<=0;wave_entry_pending<=1;
     end else if(packet_type==PKT_WAVE_SCAN)begin
      if(dump_index==CAPTURE_DEPTH-1)begin
       wave_entry_pending<=0;wave_footer_pending<=1;footer_dropped<=dropped_scans;footer_timestamp<=cycle_counter;
      end else begin
       dump_index<=dump_index+1'b1;read_ptr<=read_ptr+1'b1;
       wave_entry<=capture_mem[read_ptr+1'b1];wave_entry_pending<=1;
      end
     end else if(packet_type==PKT_WAVE_FOOTER)begin
      wave_footer_pending<=0;stream_complete<=1;
     end
    end else tx_index<=tx_index+1'b1;
   end
   if(!sending && !stream_complete && armed)begin
    if(DIAG_MODE==0 && stats_pending)start_packet(PKT_STATS,STATS_PAYLOAD);
    else if(DIAG_MODE==1 && wave_footer_pending)start_packet(PKT_WAVE_FOOTER,WAVE_FOOTER_PAYLOAD);
    else if(DIAG_MODE==1 && wave_frozen && !wave_entry_pending)start_packet(PKT_WAVE_HEADER,WAVE_HEADER_PAYLOAD);
    else if(DIAG_MODE==1 && wave_entry_pending)begin wave_entry_pending<=0;start_packet(PKT_WAVE_SCAN,WAVE_SCAN_PAYLOAD);end
   end

   if(scan_valid && armed)begin
    if(DIAG_MODE==0)begin
     if(block_count==0)block_scan_start<=scan_count;
     block_hit_or<=block_hit_or|hit_mask;block_active_or<=block_active_or|active;
     for(i=0;i<8;i=i+1)begin
      b_last_raw[i]<=raw[i];b_last_base[i]<=base[i];b_last_peak[i]<=peak_now[i];
      if(block_count==0 || raw[i]<b_min_raw[i])b_min_raw[i]<=raw[i];
      if(block_count==0 || raw[i]>b_max_raw[i])b_max_raw[i]<=raw[i];
      if(block_count==0 || delta[i]<b_min_delta[i])b_min_delta[i]<=delta[i];
      if(block_count==0 || delta[i]>b_max_delta[i])b_max_delta[i]<=delta[i];
      if(block_count==0 || peak_now[i]>b_max_peak[i])b_max_peak[i]<=peak_now[i];
      b_sum_raw[i]<=b_sum_raw[i]+raw[i];
      case(histogram_bin(delta[i]))
       0:b_hist[i][0]<=b_hist[i][0]+1'b1;1:b_hist[i][1]<=b_hist[i][1]+1'b1;
       2:b_hist[i][2]<=b_hist[i][2]+1'b1;3:b_hist[i][3]<=b_hist[i][3]+1'b1;
       4:b_hist[i][4]<=b_hist[i][4]+1'b1;5:b_hist[i][5]<=b_hist[i][5]+1'b1;
       6:b_hist[i][6]<=b_hist[i][6]+1'b1;default:b_hist[i][7]<=b_hist[i][7]+1'b1;
      endcase
     end
     if(block_count==STATS_BLOCK_SCANS-1)begin
      if(!stats_pending)begin
       s_timestamp<=cycle_counter;s_scan_start<=block_scan_start;s_scan_end<=scan_count;
       s_block_count<=STATS_BLOCK_SCANS;s_hit_or<=block_hit_or|hit_mask;s_active_or<=block_active_or|active;s_status<=status_byte;
       s_stats_overruns<=stats_overruns;
       for(i=0;i<8;i=i+1)begin
        s_last_raw[i]<=raw[i];s_last_base[i]<=base[i];s_last_peak[i]<=peak_now[i];
        s_min_raw[i]<=(raw[i]<b_min_raw[i])?raw[i]:b_min_raw[i];
        s_max_raw[i]<=(raw[i]>b_max_raw[i])?raw[i]:b_max_raw[i];
        s_min_delta[i]<=(delta[i]<b_min_delta[i])?delta[i]:b_min_delta[i];
        s_max_delta[i]<=(delta[i]>b_max_delta[i])?delta[i]:b_max_delta[i];
        s_max_peak[i]<=(peak_now[i]>b_max_peak[i])?peak_now[i]:b_max_peak[i];
        s_sum_raw[i]<=b_sum_raw[i]+raw[i];
        for(j=0;j<8;j=j+1)s_hist[i][j]<=b_hist[i][j]+((j==histogram_bin(delta[i]))?1:0);
       end
       stats_pending<=1;
      end else stats_overruns<=stats_overruns+1'b1;
      block_count<=0;block_hit_or<=0;block_active_or<=0;
      for(i=0;i<8;i=i+1)begin
       b_min_raw[i]<=16'hffff;b_max_raw[i]<=0;b_min_delta[i]<=16'hffff;b_max_delta[i]<=0;b_max_peak[i]<=0;b_sum_raw[i]<=0;
       for(j=0;j<8;j=j+1)b_hist[i][j]<=0;
      end
     end else block_count<=block_count+1'b1;
    end else if(DIAG_MODE==1)begin
     if(!wave_frozen)begin
      capture_mem[write_ptr]<={active,hit_mask,status_byte,peaks,baselines,samples,scan_count,cycle_counter};
      write_ptr<=write_ptr+1'b1;if(ring_count<CAPTURE_DEPTH)ring_count<=ring_count+1'b1;
      if(!wave_triggered && !eval_busy && calibrated && ring_count>=PRE_TRIGGER_SCANS)begin
       for(i=0;i<8;i=i+1)eval_delta[i]<=delta[i];
       eval_busy<=1;eval_channel<=0;eval_max<=0;eval_mask<=0;
       eval_timestamp<=cycle_counter;eval_scan<=scan_count;eval_status<=status_byte;
      end
      if(wave_triggered)begin
       if(post_remaining<=1)begin wave_frozen<=1;capture_start<=write_ptr+1'b1;post_remaining<=0;end
       else post_remaining<=post_remaining-1'b1;
      end
     end else dropped_scans<=dropped_scans+1'b1;
    end
   end
   if(DIAG_MODE==1 && eval_busy)begin
    eval_max<=eval_max_next;eval_mask<=eval_mask_next;
    if(eval_channel==7)begin
     eval_busy<=0;
     if(!wave_triggered && eval_max_next>=CAPTURE_TRIGGER)begin
      wave_triggered<=1;post_remaining<=POST_TRIGGER_SCANS-1;
      trigger_timestamp<=eval_timestamp;trigger_scan<=eval_scan;trigger_delta<=eval_max_next;
      trigger_mask<=eval_mask_next;trigger_status<=eval_status;
     end
    end else eval_channel<=eval_channel+1'b1;
   end
  end
 end
endmodule
