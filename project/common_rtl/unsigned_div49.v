// Restoring divider, 49 clocks, quotient floor(numerator/denominator).
module unsigned_div49(input wire clk,rst_n,start,input wire [48:0] numerator,
 input wire [31:0] denominator,output reg [48:0] quotient,output reg busy,done);
 reg [48:0] shift;reg [32:0] remainder;reg [31:0] divisor;reg [5:0] count;
 wire [33:0] trial={remainder,shift[48]};
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin quotient<=0;busy<=0;done<=0;shift<=0;remainder<=0;divisor<=1;count<=0;end
 else begin
 done<=0;
 if(start && !busy)begin shift<=numerator;remainder<=0;divisor<=denominator;count<=49;busy<=1;end
 else if(busy)begin
 if(trial>={2'd0,divisor})begin remainder<=trial-divisor;shift<={shift[47:0],1'b1};end
 else begin remainder<=trial[32:0];shift<={shift[47:0],1'b0};end
 if(count==1)begin quotient<={shift[47:0],trial>={2'd0,divisor}};busy<=0;done<=1;end
 else count<=count-1'b1;
 end
 end
endmodule
