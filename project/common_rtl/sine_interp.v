// 256-entry sine ROM with V3 phase interpolation.
module sine_interp(
    input wire [31:0] phase,
    output wire signed [16:0] sample
);
    wire signed [15:0] a,b;
    wire [7:0] next_index=phase[31:24]+8'd1;
    wire signed [16:0] difference=$signed({b[15],b})-$signed({a[15],a});
    wire signed [25:0] product=difference*$signed({1'b0,phase[23:16]});
    sine_lut u_a(.phase_index(phase[31:24]),.sample(a));
    sine_lut u_b(.phase_index(next_index),.sample(b));
    assign sample=$signed({a[15],a})+(product>>>8);
endmodule
