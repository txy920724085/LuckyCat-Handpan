`timescale 1ns/1ps
// JDY handover receiver, renamed and reset adapted to the wave reset domain.
module jdy_uart_rx #(parameter integer CLK_HZ=50000000,BAUD=128000)(
 input wire clk,rst_n,rx,output reg [7:0] data,output reg valid,framing_error);
 localparam integer DIV=(CLK_HZ+BAUD/2)/BAUD;
 (* ASYNC_REG="TRUE" *) reg [1:0] sync=2'b11;
 reg [1:0] state;integer timer;reg [2:0] bit_index;reg [7:0] shift;
 always @(posedge clk)begin
  if(!rst_n)begin sync<=3;state<=0;timer<=0;bit_index<=0;shift<=0;data<=0;valid<=0;framing_error<=0;end
  else begin
   sync<={sync[0],rx};valid<=0;framing_error<=0;
   case(state)
   0:if(!sync[1])begin timer<=DIV/2-1;state<=1;end
   1:if(timer!=0)timer<=timer-1;
     else if(!sync[1])begin timer<=DIV-1;bit_index<=0;state<=2;end else state<=0;
   2:if(timer!=0)timer<=timer-1;
     else begin shift[bit_index]<=sync[1];timer<=DIV-1;
      if(bit_index==7)state<=3;else bit_index<=bit_index+1'b1;end
   3:if(timer!=0)timer<=timer-1;
     else begin if(sync[1])begin data<=shift;valid<=1;end else framing_error<=1;state<=0;end
   endcase
  end
 end
endmodule
