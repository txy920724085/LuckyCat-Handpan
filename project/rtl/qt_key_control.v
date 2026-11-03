// Convert QT2120 KEY7..KEY11 levels into one-shot controls.
module qt_key_control #(
 parameter [2:0] KEY_HANDPAN=3'd4, // KEY11
 parameter [2:0] KEY_MARIMBA=3'd3, // KEY10
 parameter [2:0] KEY_DRUM=3'd2, // KEY9
 parameter [2:0] KEY_ECHO=3'd1, // KEY8
 parameter [2:0] KEY_PLUCK=3'd0 // KEY7
)(
 input wire clk,rst_n,
 input wire [31:0] sample_seq,
 input wire [11:0] keys,
 input wire [7:0] status,
 input wire [3:0] mode,error_code,
 output reg [1:0] selected_timbre,
 output reg echo_toggle,
 output reg [4:0] press_pulse,
 output wire healthy_out,output wire synchronized_out
);
 wire healthy=(error_code==0) && ((mode==1)||(mode==2)) && !status[7] && !status[6];
 wire [4:0] key_level=keys[11:7];
 reg [31:0] previous_seq;
 reg have_seq,synchronized;
 assign healthy_out=healthy;
 assign synchronized_out=synchronized;
 reg [4:0] candidate,stable;
 reg candidate_seen;
 wire [4:0] rising_now=key_level & ~stable;
 wire [4:0] timbre_rising_now=rising_now & ~(5'b1<<KEY_ECHO);

 function is_onehot_nonzero;
  input [4:0] value;
  begin
   is_onehot_nonzero=(value!=5'd0) && ((value & (value-1'b1))==5'd0);
  end
 endfunction

 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
  previous_seq<=0;have_seq<=0;synchronized<=0;candidate<=0;stable<=0;
  candidate_seen<=0;selected_timbre<=2'd0;echo_toggle<=0;press_pulse<=0;
 end else begin
  echo_toggle<=0;press_pulse<=0;
  if(!healthy)begin
   // Resynchronize without emitting a press after an I2C fault.
   synchronized<=0;candidate_seen<=0;have_seq<=0;stable<=0;
  end else if(!have_seq || sample_seq!=previous_seq)begin
   previous_seq<=sample_seq;have_seq<=1;
   if(!candidate_seen || key_level!=candidate)begin
    candidate<=key_level;candidate_seen<=1;
   end else begin
    candidate_seen<=0;
    if(!synchronized)begin stable<=key_level;synchronized<=1;end
    else if(key_level!=stable)begin
     stable<=key_level;press_pulse<=rising_now;
     // Ignore an ambiguous simultaneous multi-timbre press.
     if(is_onehot_nonzero(timbre_rising_now))begin
      if(rising_now[KEY_HANDPAN])selected_timbre<=2'd0;
      else if(rising_now[KEY_MARIMBA])selected_timbre<=2'd2;
      else if(rising_now[KEY_DRUM])selected_timbre<=2'd3;
      else if(rising_now[KEY_PLUCK])selected_timbre<=2'd1;
     end
     if(rising_now[KEY_ECHO])echo_toggle<=1;
    end
   end
  end
 end
endmodule
