// Power-of-two master gain with widened arithmetic and signed saturation.
// No automatic gain changes: preserves velocity dynamics and avoids pumping.
module audio_gain(input wire signed [15:0] sample_in,
 input wire [1:0] gain_shift,
 output reg signed [15:0] sample_out, output reg clipped);
 wire signed [18:0] extended={{3{sample_in[15]}},sample_in};
 wire signed [18:0] amplified=extended <<< gain_shift;
 always @* begin
  clipped=0;
  if(amplified>19'sd32767)begin sample_out=16'sh7fff;clipped=1;end
  else if(amplified < -19'sd32768)begin sample_out=16'sh8000;clipped=1;end
  else sample_out=amplified[15:0];
 end
endmodule
