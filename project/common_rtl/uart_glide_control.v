// FB r0 r1 r2 xor; little-endian 7-bit Q16 ratio, checksum=55^r0^r1^r2.
// Pass all other packets downstream. Cancel partial downstream packets on FB.
module uart_glide_control #(parameter integer TIMEOUT_CYCLES=500000)(
 input wire clk,rst_n,enable,byte_valid,frame_error,input wire [7:0] byte_data,
 output reg pass_valid,cancel,output reg [7:0] pass_data,
 output reg [17:0] target,output reg error_seen);
reg [2:0] state;reg [6:0] a,b,c;reg [31:0] timer;
wire [20:0] assembled={c,b,a};
always @(posedge clk or negedge rst_n)
if(!rst_n)begin state<=0;a<=0;b<=0;c<=0;timer<=0;pass_valid<=0;
 cancel<=0;pass_data<=0;target<=65536;error_seen<=0;end
else begin
 pass_valid<=0;cancel<=0;
 if(!enable)begin state<=0;timer<=0;end
 else if(frame_error)begin state<=0;timer<=0;cancel<=1;error_seen<=1;end
 else if(byte_valid)begin
 timer<=0;
 if(byte_data==8'hfb)begin state<=1;cancel<=1;end
 else if(byte_data[7])begin
 if(state!=0)error_seen<=1;
 state<=0;pass_valid<=1;pass_data<=byte_data;
 end else case(state)
 1:begin a<=byte_data[6:0];state<=2;end
 2:begin b<=byte_data[6:0];state<=3;end
 3:begin c<=byte_data[6:0];state<=4;end
 4:begin
 if(byte_data[6:0]==(7'h55^a^b^c) && assembled>=32768 && assembled<=131072)
 target<=assembled[17:0];else error_seen<=1;
 state<=0;
 end
 default:begin pass_valid<=1;pass_data<=byte_data;end
 endcase
 end else if(state!=0)begin
 if(timer==TIMEOUT_CYCLES-1)begin state<=0;timer<=0;error_seen<=1;end
 else timer<=timer+1'b1;
 end
end
endmodule
