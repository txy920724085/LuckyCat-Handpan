// 8N1 receiver, synchronized input, center sampling, bad-stop rejection.
// CLK_HZ/BAUD must be >= 8. Break recovery waits for idle high.
module uart_rx #(parameter integer CLK_HZ=50000000, BAUD=115200)(
 input wire clk,rst_n,rx, output reg [7:0] data,
 output reg valid, output reg framing_error);
 localparam integer DIV=(CLK_HZ+BAUD/2)/BAUD;
 reg meta,sync_rx; reg [2:0] state,bit_index;
 integer count; reg [7:0] shift;
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin meta<=1; sync_rx<=1; end
 else begin meta<=rx; sync_rx<=meta; end
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin state<=0; count<=0; bit_index<=0; shift<=0;
 data<=0; valid<=0; framing_error<=0; end
 else begin
 valid<=0; framing_error<=0;
 case(state)
 0: if(!sync_rx) begin count<=DIV/2-1; state<=1; end
 1: if(count!=0) count<=count-1;
    else if(sync_rx) state<=0;
    else begin count<=DIV-1; bit_index<=0; state<=2; end
 2: if(count!=0) count<=count-1;
    else begin shift[bit_index]<=sync_rx; count<=DIV-1;
      if(bit_index==7) state<=3; else bit_index<=bit_index+1'b1; end
 3: if(count!=0) count<=count-1;
    else if(sync_rx) begin data<=shift; valid<=1; state<=0; end
    else begin framing_error<=1; state<=4; end
 4: if(sync_rx) state<=0;
 default: state<=0;
 endcase
 end
endmodule

