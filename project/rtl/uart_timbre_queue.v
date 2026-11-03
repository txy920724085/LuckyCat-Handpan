// F9 adds a timbre byte (0..3) before checksum; XOR includes timbre.
// F8 and legacy packets always select bell (0); no global mode state.
// Legacy 1vvv0nnn, or F8 p0 p1 p2 p3 p4 velocity checksum.
// p0..p4 are little-endian 7-bit chunks of a 32-bit DDS phase step.
// p4 <= 15; velocity 1..127; checksum XOR of six payload bytes (not F8).
// High-bit bytes resynchronize immediately. No ACK. Timeout in clk cycles.
module uart_timbre_queue #(parameter integer TIMEOUT_CYCLES=500000)(
 input wire clk,rst_n,enable,byte_valid,frame_error,
 input wire [7:0] byte_data,
 output wire event_valid,input wire event_ready,
 output wire [31:0] phase_step,output wire [6:0] velocity,
 output wire [1:0] timbre,
 output reg error_seen,output reg received_toggle);
 reg [40:0] fifo[0:7];reg [2:0] rd,wr;reg [3:0] count;
 reg [3:0] state;
 reg [31:0] pitch;
 reg [6:0] vel,checksum;
 reg extended;reg [1:0] mode;
 reg [31:0] timer;
 wire legacy=byte_data[7] && !byte_data[3] && byte_data[6:4]!=0;
 wire at_checksum=(state==7 && !extended) || (state==8 && extended);
 wire complete=at_checksum && !byte_data[7] && byte_data[6:0]==checksum
              && pitch!=0 && pitch<=32'h2aaaaaaa && vel!=0;
 wire pop=event_valid && event_ready;
 wire candidate=enable && byte_valid && !frame_error && (legacy || complete);
 wire push=candidate && (count<8 || pop);
 assign event_valid=enable && count!=0;
 assign timbre=fifo[rd][40:39];
 assign phase_step=fifo[rd][38:7];assign velocity=fifo[rd][6:0];
 function [31:0] legacy_step;input [2:0] n;
 begin case(n)
 0:legacy_step=25831026;1:legacy_step=28994347;
 2:legacy_step=30718440;3:legacy_step=34480283;
 4:legacy_step=38702809;5:legacy_step=41004198;
 6:legacy_step=46025656;7:legacy_step=51662052;
 endcase end endfunction
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
 rd<=0;wr<=0;count<=0;state<=0;pitch<=0;vel<=0;checksum<=0;
 extended<=0;mode<=0;timer<=0;error_seen<=0;received_toggle<=0;
 end else begin
 case({push,pop})
 2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:count<=count;
 endcase
 if(pop)rd<=rd+1'b1;
 if(push)begin
 fifo[wr]<=legacy ? {2'b00,legacy_step(byte_data[2:0]),byte_data[6:4],4'b0} : {mode,pitch,vel};
 wr<=wr+1'b1;received_toggle<=~received_toggle;
 end
 if(candidate && !push)error_seen<=1;
 if(!enable)begin state<=0;timer<=0;end
 else if(frame_error)begin state<=0;timer<=0;error_seen<=1;end
 else if(byte_valid)begin
 timer<=0;
 if(byte_data==8'hf8 || byte_data==8'hf9)begin
 if(state!=0)error_seen<=1;
 state<=1;pitch<=0;vel<=0;checksum<=0;mode<=0;extended<=byte_data[0];
 end else if(byte_data[7])begin
 state<=0;
 if(!legacy || state!=0)error_seen<=1;
 end else if(state==0)error_seen<=1;
 else if(at_checksum)begin state<=0;if(!complete)error_seen<=1;end
 else if(state==7 && extended && byte_data>3)begin state<=0;error_seen<=1;end
 else if(state==5 && byte_data[6:4]!=0)begin state<=0;error_seen<=1;end
 else begin
 checksum<=checksum ^ byte_data[6:0];state<=state+1'b1;
 case(state)
 1:pitch[6:0]<=byte_data[6:0];2:pitch[13:7]<=byte_data[6:0];
 3:pitch[20:14]<=byte_data[6:0];4:pitch[27:21]<=byte_data[6:0];
 5:pitch[31:28]<=byte_data[3:0];6:vel<=byte_data[6:0];7:mode<=byte_data[1:0];
 endcase
 end
 end else if(state!=0)begin
 if(timer>=TIMEOUT_CYCLES-1)begin state<=0;timer<=0;error_seen<=1;end
 else timer<=timer+1'b1;
 end
 end
endmodule
