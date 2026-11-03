`timescale 1ns/1ps
// Locks ownership for a complete frame. QSU1 and HTE1 stay ahead of the
// diagnostic stream; PMR1 may be dropped at its own source under congestion.
module telemetry_frame_mux(
 input wire clk,rst_n,
 input wire q_valid,input wire [7:0] q_data,input wire q_last,output wire q_ready,
 input wire h_valid,input wire [7:0] h_data,input wire h_last,output wire h_ready,
 input wire k_valid,input wire [7:0] k_data,input wire k_last,output wire k_ready,
 input wire w_valid,input wire [7:0] w_data,input wire w_last,output wire w_ready,
 input wire p_valid,input wire [7:0] p_data,input wire p_last,input wire p_pause,output wire p_ready,
 output wire out_valid,output wire [7:0] out_data,output wire out_last,input wire out_ready);
 localparam Q=0,H=1,K=2,W=3,P=4;
 reg locked;reg [2:0] selected;
 // A pause request may suppress only the next PMR frame.  If PMR already owns
 // the mux, it must remain valid through p_last or the frame lock deadlocks.
 wire p_effective_valid=p_valid && (!p_pause || (locked && selected==P));
 wire [2:0] choice=locked?selected:(q_valid?Q:(h_valid?H:(k_valid?K:(w_valid?W:P))));
 assign out_valid=(choice==Q)?q_valid:(choice==H)?h_valid:(choice==K)?k_valid:(choice==W)?w_valid:p_effective_valid;
 assign out_data=(choice==Q)?q_data:(choice==H)?h_data:(choice==K)?k_data:(choice==W)?w_data:p_data;
 assign out_last=(choice==Q)?q_last:(choice==H)?h_last:(choice==K)?k_last:(choice==W)?w_last:p_last;
 assign q_ready=out_ready&&out_valid&&(choice==Q);
 assign h_ready=out_ready&&out_valid&&(choice==H);
 assign k_ready=out_ready&&out_valid&&(choice==K);
 assign w_ready=out_ready&&out_valid&&(choice==W);
 assign p_ready=out_ready&&out_valid&&(choice==P);
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin locked<=0;selected<=Q;end
 else if(!locked)begin
  if(out_valid)begin
   selected<=choice;
   if(out_ready && out_last)locked<=0;
   else locked<=1;
  end
 end else if(out_valid && out_ready && out_last)locked<=0;
endmodule
