// PT8211-S onboard DAC: Japanese / right-justified, 16 bits per channel.
// NOT standard Philips I2S: there is NO dummy clock before the MSB.
// PT8211 WS=1 is LEFT, WS=0 is RIGHT. DIN sampled on rising BCK.
// See SOURCES.md for the primary datasheet and board schematic.
// Single clock implementation: all logic runs on clk, not on generated BCK.
module pt8211_tx #(
    parameter integer HALF_BCLK_CYCLES = 16
) (
    input wire clk,
    input wire rst_n,
    input wire signed [15:0] sample_left,
    input wire signed [15:0] sample_right,
    output reg bclk,
    output reg ws,
    output reg sdata,
    output wire frame_ce
);
    localparam integer CW = (HALF_BCLK_CYCLES <= 1) ? 1 : $clog2(HALF_BCLK_CYCLES);
    reg [CW-1:0] half_count;
    reg [4:0] bit_index;
    reg [15:0] left_hold, right_hold;
    assign frame_ce = rst_n && bclk && (half_count == HALF_BCLK_CYCLES-1)
                              && (bit_index == 31);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half_count <= 0;
            bit_index <= 31;
            bclk <= 0;
            ws <= 0;
            sdata <= 0;
            left_hold <= 0;
            right_hold <= 0;
        end else if (half_count == HALF_BCLK_CYCLES-1) begin
            half_count <= 0;
            bclk <= ~bclk;
            if (bclk) begin
                bit_index <= bit_index + 1'b1;
                if (bit_index == 31) begin
                    left_hold <= sample_left;
                    right_hold <= sample_right;
                    ws <= 1;
                    sdata <= sample_left[15];
                end else if (bit_index == 15) begin
                    ws <= 0;
                    sdata <= right_hold[15];
                end else if (bit_index < 15)
                    sdata <= left_hold[14-bit_index];
                else
                    sdata <= right_hold[30-bit_index];
            end
        end else
            half_count <= half_count + 1'b1;
    end
endmodule
