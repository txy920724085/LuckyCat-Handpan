// Mono real-time delay before master gain. RAM is never reset in a loop.
// Settings commit at sample_ce; a change discards the old tail.
// sample_out settles one clk after accepted sample_ce; spacing >= 3 clocks.
// delay_select 0/1/2 = DEPTH/4, DEPTH/2, DEPTH samples (3 aliases 2).
// feedback/wet 0/1/2 = 0, 1/4, 1/2 (3 aliases 2).
module audio_echo #(parameter integer ADDR_BITS=14)(
 input wire clk,rst_n,sample_ce,enable,
 input wire [1:0] delay_select,feedback,wet,
 input wire signed [15:0] sample_in,
 output reg signed [15:0] sample_out,
 output reg clipped,output reg overrun);
 localparam integer DEPTH=1<<ADDR_BITS;
 reg signed [15:0] ram[0:DEPTH-1];
 reg signed [15:0] delayed,dry;
 reg [ADDR_BITS-1:0] pointer;
 reg [ADDR_BITS:0] filled;
 reg [6:0] settings;
 reg pending,history_valid;
 wire [6:0] requested={enable,delay_select,feedback,wet};
 wire change_settings=requested!=settings;
 wire [ADDR_BITS:0] length=(settings[5:4]==0) ? DEPTH/4 :
                                  (settings[5:4]==1) ? DEPTH/2 : DEPTH;
 function signed [17:0] attenuate;
 input signed [15:0] x;input [1:0] amount;
 reg signed [17:0] magnitude;
 begin
 magnitude=x;
 if(x<0)magnitude=-magnitude;
 if(amount==0)magnitude=0;
 else if(amount==1)magnitude=magnitude >>> 2;
 else magnitude=magnitude >>> 1;
 attenuate=(x<0) ? -magnitude : magnitude;
 end endfunction
 function signed [15:0] saturate;
 input signed [17:0] x;
 begin
 if(x>32767)saturate=16'sh7fff;
 else if(x < -32768)saturate=16'sh8000;
 else saturate=x[15:0];
 end endfunction
 wire signed [15:0] echo_sample=history_valid ? delayed : 16'sd0;
 wire signed [17:0] dry_wide={{2{dry[15]}},dry};
 wire signed [17:0] stored=dry_wide+attenuate(echo_sample,settings[3:2]);
 wire signed [17:0] mixed=dry_wide+attenuate(echo_sample,settings[1:0]);
 // Separate synchronous RAM process for block-RAM inference.
 always @(posedge clk)begin
 if(rst_n && sample_ce && !pending && !change_settings && enable)
 delayed<=ram[pointer];
 if(rst_n && pending)ram[pointer]<=saturate(stored);
 end
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
 pointer<=0;filled<=0;settings<=0;pending<=0;history_valid<=0;
 dry<=0;sample_out<=0;clipped<=0;overrun<=0;
 end else begin
 if(pending)begin
 sample_out<=saturate(mixed);
 if(stored>32767 || stored < -32768 || mixed>32767 || mixed < -32768)clipped<=1;
 pointer<=(pointer==length-1) ? 0 : pointer+1'b1;
 if(filled<length)filled<=filled+1'b1;
 pending<=0;
 end
 if(sample_ce)begin
 if(pending)overrun<=1;
 else if(change_settings)begin
 settings<=requested;pointer<=0;filled<=0;history_valid<=0;
 sample_out<=sample_in;
 end else if(!enable)sample_out<=sample_in;
 else begin
 dry<=sample_in;history_valid<=filled>=length;pending<=1;
 end
 end
 end
endmodule
