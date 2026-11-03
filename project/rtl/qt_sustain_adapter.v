// Persistent QT2120 relative-motion sustain controller.
// Release/re-touch never resets sustain_u; the QT driver supplies step=0 on
// the first valid sample after touch, so control resumes without a jump.
module qt_sustain_adapter #(
 parameter integer INVERT_DIRECTION=0,
 parameter [7:0] RESET_VALUE=8'd128
)(
 input wire clk,rst_n,
 input wire [31:0] sample_seq,
 input wire valid,
 input wire [3:0] mode,error_code,
 input wire signed [9:0] step,
 output reg [7:0] sustain_u
);
 reg have_seq;
 reg [31:0] previous_seq;
 integer signed_step;
 integer candidate;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
   have_seq<=0;previous_seq<=0;sustain_u<=RESET_VALUE;
 end else if(!have_seq)begin
   have_seq<=1;previous_seq<=sample_seq;
 end else if(sample_seq!=previous_seq)begin
   previous_seq<=sample_seq;
   // Errors, calibration and release hold the last setting. Only an
   // explicitly valid touched sample changes the persistent control value.
   if(error_code==0 && mode==2 && valid)begin
     signed_step=INVERT_DIRECTION ? -$signed(step) : $signed(step);
     candidate=$signed({1'b0,sustain_u})+signed_step;
     if(candidate>255)sustain_u<=8'd255;
     else if(candidate<0)sustain_u<=8'd0;
     else sustain_u<=candidate[7:0];
   end
 end
endmodule

