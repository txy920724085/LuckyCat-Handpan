// Shared final-output DC blocker. Feedback multiply truncates toward zero.
module audio_dc_block(
    input wire clk,rst_n,sample_ce,
    input wire signed [15:0] sample_in,
    output reg signed [15:0] sample_out,
    output reg clipped
);
    reg signed [15:0] x_prev;
    reg signed [18:0] y_prev;
    wire signed [34:0] feedback_product=y_prev*16'sd32747;
    wire signed [18:0] feedback_q15 = feedback_product<0
        ? -((-feedback_product)>>>15) : (feedback_product>>>15);
    wire signed [19:0] y_next=$signed({{4{sample_in[15]}},sample_in})
                              -$signed({{4{x_prev[15]}},x_prev})
                              +$signed({feedback_q15[18],feedback_q15});
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin x_prev<=0;y_prev<=0;sample_out<=0;clipped<=0;end
        else if(sample_ce)begin
            x_prev<=sample_in;
            if(y_next>20'sd131071)y_prev<=19'sd131071;
            else if(y_next< -20'sd131072)y_prev<=-19'sd131072;
            else y_prev<=y_next[18:0];
            clipped<=(y_next>32767)||(y_next< -32768);
            if(y_next>32767)sample_out<=16'sd32767;
            else if(y_next< -32768)sample_out<=-16'sd32768;
            else sample_out<=y_next[15:0];
        end
    end
endmodule
