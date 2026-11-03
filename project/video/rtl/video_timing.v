`timescale 1ns/1ps
// Continuous raster. Coordinates always include blanking; never stall the scan.
module video_timing #(
    parameter H_ACTIVE=640, H_FP=16, H_SYNC=96, H_BP=48,
    parameter V_ACTIVE=480, V_FP=10, V_SYNC=2, V_BP=33,
    parameter H_POL=0, V_POL=0
)(
    input pixel_clk, reset_n,
    output reg [11:0] x, y,
    output hs, vs, de, frame_start,
    output reg [31:0] frame_count
);
    localparam HT=H_ACTIVE+H_FP+H_SYNC+H_BP;
    localparam VT=V_ACTIVE+V_FP+V_SYNC+V_BP;
    assign de=(x<H_ACTIVE)&&(y<V_ACTIVE);
    assign hs=((x>=H_ACTIVE+H_FP)&&(x<H_ACTIVE+H_FP+H_SYNC)) ? H_POL : !H_POL;
    assign vs=((y>=V_ACTIVE+V_FP)&&(y<V_ACTIVE+V_FP+V_SYNC)) ? V_POL : !V_POL;
    // First pixel of vertical blank: ownership changes while no pixels are read.
    assign frame_start=(x==0)&&(y==V_ACTIVE);
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin x<=0; y<=0; frame_count<=0; end
        else if (x==HT-1) begin
            x<=0;
            if(y==VT-1) begin y<=0; frame_count<=frame_count+1'b1; end
            else y<=y+1'b1;
        end else x<=x+1'b1;
    end
endmodule
