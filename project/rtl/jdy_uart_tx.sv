// 8N1, one byte per accepted valid/ready handshake.
module jdy_uart_tx #(parameter integer CLK_HZ=50000000,BAUD=128000)(
 input wire clk,rst_n,valid,input wire [7:0] data,
 output wire ready,output reg tx);
 localparam integer DIV=(CLK_HZ+BAUD/2)/BAUD;
 reg [9:0] bits;reg [3:0] index;integer ticks;reg busy;
 assign ready=!busy;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin tx<=1;busy<=0;bits<=0;index<=0;ticks<=0;end
 else if(!busy)begin
 if(valid)begin bits<={1'b1,data,1'b0};tx<=0;busy<=1;index<=0;ticks<=DIV-1;end
 end else if(ticks!=0)ticks<=ticks-1;
 else if(index==9)begin busy<=0;tx<=1;end
 else begin index<=index+1'b1;tx<=bits[index+1'b1];ticks<=DIV-1;end
endmodule

