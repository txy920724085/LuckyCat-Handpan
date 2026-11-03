// Complete-frame lock; the tuning reply cannot splice a telemetry frame.
module tune_frame_mux(
 input wire clk,rst_n,
 input wire a_valid,input wire [7:0] a_data,input wire a_last,output wire a_ready,
 input wire b_valid,input wire [7:0] b_data,input wire b_last,output wire b_ready,
 output wire out_valid,output wire [7:0] out_data,input wire out_ready);
 reg locked,owner;
 wire choice=locked?owner:!a_valid;
 assign out_valid=choice?b_valid:a_valid;
 assign out_data=choice?b_data:a_data;
 assign a_ready=out_ready && out_valid && !choice;
 assign b_ready=out_ready && out_valid && choice;
 wire last=choice?b_last:a_last;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin locked<=0;owner<=0;end
 else if(out_valid)begin
  owner<=choice;
  if(out_ready && last)locked<=0;else locked<=1;
 end
endmodule
