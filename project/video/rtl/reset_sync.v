module visual_reset_sync(input clk, input async_reset_n, output reset_n);
    (* syn_preserve=1, ASYNC_REG="TRUE" *) reg [2:0] pipe;
    always @(posedge clk or negedge async_reset_n)
        if(!async_reset_n) pipe<=0; else pipe<={pipe[1:0],1'b1};
    assign reset_n=pipe[2];
endmodule
