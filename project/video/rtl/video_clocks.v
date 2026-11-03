module video_clocks(input clk50,reset_n,output pixel_clk,serial_clk,locked);
    wire pll_lock;
    Video_PLL pll(.clkin(clk50),.init_clk(clk50),.reset(!reset_n),.clkout0(serial_clk),.lock(pll_lock));
    // The serializer/CLKDIV use the dedicated HCLK path. Do not place fabric
    // synchronizer flip-flops on HCLK; synchronize reset in the pixel domain.
    assign locked=pll_lock;
    CLKDIV div5(.CLKOUT(pixel_clk),.HCLKIN(serial_clk),.RESETN(locked),.CALIB(1'b0));
    defparam div5.DIV_MODE="5";
endmodule
