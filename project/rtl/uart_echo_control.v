// FA config config^55; config = {enable,delay[1:0],feedback[1:0],wet[1:0]}.
// Other packets pass to the existing note parser; FA cancels a partial note.
module uart_echo_control #(
 parameter integer TIMEOUT_CYCLES=500000,
 parameter [6:0] PHYSICAL_ECHO_DEFAULT=7'd106
)(
 input wire clk,rst_n,enable,byte_valid,frame_error,toggle_pulse,input wire [7:0] byte_data,
 output reg note_valid,note_error,output reg [7:0] note_data,
 output reg [6:0] config_value,output reg control_error);
 reg [1:0] state;reg [6:0] pending;reg [31:0] timer;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin state<=0;pending<=0;timer<=0;note_valid<=0;note_error<=0;
 note_data<=0;config_value<=0;control_error<=0;end
 else begin
 note_valid<=0;note_error<=0;
 if(!enable)begin state<=0;timer<=0;end
 else if(frame_error)begin state<=0;timer<=0;note_error<=1;control_error<=1;end
 else if(byte_valid)begin
 timer<=0;
 if(byte_data==8'hfa)begin state<=1;note_error<=1;end
 else if(byte_data[7])begin
 if(state!=0)control_error<=1;
 state<=0;note_data<=byte_data;note_valid<=1;
 end else if(state==1)begin pending<=byte_data[6:0];state<=2;end
 else if(state==2)begin
 if(byte_data[6:0]==(pending^7'h55))config_value<=pending;
 else control_error<=1;
 state<=0;
 end else begin note_data<=byte_data;note_valid<=1;end
 end else if(state!=0)begin
 if(timer==TIMEOUT_CYCLES-1)begin state<=0;timer<=0;control_error<=1;end
 else timer<=timer+1'b1;
 end
 // A valid UART FA completion wins if both controls occur in one clock.
 if(toggle_pulse && !(byte_valid && state==2 && byte_data[6:0]==(pending^7'h55)))begin
  if(config_value[6])config_value[6]<=1'b0;
  else if(config_value[5:0]==0)config_value<=PHYSICAL_ECHO_DEFAULT;
  else config_value[6]<=1'b1;
 end
 end
endmodule
