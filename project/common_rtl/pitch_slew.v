// Q16 frequency-ratio ramp, at most 128 LSB/sample (~10.49ms per octave up).
module pitch_slew(input wire clk,rst_n,sample_ce,
 input wire [17:0] target,output reg [17:0] ratio);
wire [17:0] safe_target=target<32768 ? 18'd32768 :
                          target>131072 ? 18'd131072 : target;
always @(posedge clk or negedge rst_n)
if(!rst_n)ratio<=18'd65536;
else if(sample_ce)begin
 if(safe_target>ratio)ratio<=safe_target-ratio>128 ? ratio+18'd128 : safe_target;
 else if(safe_target<ratio)ratio<=ratio-safe_target>128 ? ratio-18'd128 : safe_target;
end
endmodule
