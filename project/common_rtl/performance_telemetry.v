// Passive statistics, periodic coherent snapshot. Never backpressures audio.
// 40-byte status at 10Hz default; 115200 8N1. Not command ACK or acoustic proof.
module performance_telemetry #(parameter integer PERIOD=5000000, CLK_HZ=50000000,BAUD=115200,EXT_STATUS=0)(
 input wire clk,rst_n,input wire [31:0] active_mask,
 input wire allocated,stolen,note_accepted,rx_valid,rx_error,sample_ce,clipped,
 input wire [6:0] velocity,echo_config,input wire [17:0] bend_ratio,
 input wire [6:0] flags,output wire tx,input wire [15:0] extra_flags);
reg [2:0] groups[0:7];reg [5:0] active_count,max_active;
reg [31:0] notes,steals,clip_frames,rx_bytes;
reg [15:0] frame_errors,sequence_number;
reg [6:0] last_velocity;
reg [31:0] timer;reg sending;reg [5:0] index;
reg [319:0] packet;
reg [31:0] mask_d0,mask_d1;
// In sensor builds extra_flags[15:8] is the one-cycle hit mask.  Latch it
// until the next 10 Hz snapshot so the PC can see short detector pulses.
reg [7:0] sensor_hits_latched;
wire [5:0] peak_now=active_count>max_active ? active_count : max_active;
wire tx_ready;
wire [15:0] extended_status=EXT_STATUS ?
 {sensor_hits_latched | extra_flags[15:8],extra_flags[7:0]} : 16'd0;
wire [303:0] payload={extended_status,frame_errors,6'd0,bend_ratio,1'b0,flags,
 1'b0,echo_config,1'b0,last_velocity,rx_bytes,clip_frames,steals,notes,
 mask_d1,2'd0,peak_now,2'd0,active_count,sequence_number,8'd40,8'd1,8'h5a,8'ha5};
reg [7:0] checksum;integer j,g;reg [5:0] count_sum;
always @* begin
 checksum=0;for(j=0;j<38;j=j+1)checksum=checksum^payload[j*8 +: 8];
 count_sum=0;for(j=0;j<8;j=j+1)count_sum=count_sum+groups[j];
end
uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) uart(.clk(clk),.rst_n(rst_n),
 .valid(sending),.data(packet[index*8 +: 8]),.ready(tx_ready),.tx(tx));
always @(posedge clk or negedge rst_n)
if(!rst_n)begin
 for(g=0;g<8;g=g+1)groups[g]<=0;
 mask_d0<=0;mask_d1<=0;active_count<=0;max_active<=0;notes<=0;steals<=0;clip_frames<=0;rx_bytes<=0;
 frame_errors<=0;sequence_number<=0;last_velocity<=0;timer<=0;sending<=0;index<=0;packet<=0;
 sensor_hits_latched<=0;
end else begin
 if(EXT_STATUS)sensor_hits_latched<=sensor_hits_latched|extra_flags[15:8];
 mask_d0<=active_mask;mask_d1<=mask_d0;
 for(g=0;g<8;g=g+1)groups[g]<={2'd0,active_mask[g*4]}+{2'd0,active_mask[g*4+1]}+
                            {2'd0,active_mask[g*4+2]}+{2'd0,active_mask[g*4+3]};
 active_count<=count_sum;
 if(active_count>max_active)max_active<=active_count;
 if(allocated && notes!=32'hffffffff)notes<=notes+1'b1;
 if(stolen && steals!=32'hffffffff)steals<=steals+1'b1;
 if(sample_ce && clipped && clip_frames!=32'hffffffff)clip_frames<=clip_frames+1'b1;
 if(rx_valid && rx_bytes!=32'hffffffff)rx_bytes<=rx_bytes+1'b1;
 if(rx_error && frame_errors!=16'hffff)frame_errors<=frame_errors+1'b1;
 if(note_accepted)last_velocity<=velocity;
 if(timer<PERIOD-1)timer<=timer+1'b1;
 if(timer==PERIOD-1 && !sending && tx_ready)begin
 packet<={8'h0d,checksum,payload};sequence_number<=sequence_number+1'b1;
 sending<=1;index<=0;timer<=0;
 if(EXT_STATUS)sensor_hits_latched<=0;
 end else if(sending && tx_ready)begin
 if(index==39)begin sending<=0;index<=0;end else index<=index+1'b1;
 end
end
endmodule
