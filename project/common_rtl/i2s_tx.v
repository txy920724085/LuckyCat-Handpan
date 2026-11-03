// Philips I2S master transmitter.
// 16-bit signed samples are sent MSB first in 32-bit slots. The unused
// low 16 bits are zero. LRCLK changes one BCLK before each channel MSB.
// All state remains in the clk domain; bclk is an output, not an RTL clock.
module i2s_tx #(
    parameter integer HALF_BCLK_CYCLES = 8
) (
    input wire clk,
    input wire rst_n,
    input wire sample_valid,
    input wire signed [15:0] sample_left,
    input wire signed [15:0] sample_right,
    output reg i2s_bclk,
    output reg i2s_lrclk,
    output reg i2s_sdout
);
    localparam integer CW = (HALF_BCLK_CYCLES <= 1) ? 1 : $clog2(HALF_BCLK_CYCLES);
    reg [CW-1:0] half_count;
    reg [5:0] rise_index;
    reg running;
    reg [15:0] left_hold, right_hold;
    reg [15:0] left_pending, right_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half_count <= 0;
            rise_index <= 0;
            running <= 0;
            left_hold <= 0;
            right_hold <= 0;
            left_pending <= 0;
            right_pending <= 0;
            i2s_bclk <= 0;
            i2s_lrclk <= 1;
            i2s_sdout <= 0;
        end else begin
            if (sample_valid) begin
                left_pending <= sample_left;
                right_pending <= sample_right;
                if (!running) begin
                    running <= 1;
                    half_count <= 0;
                    rise_index <= 0;
                    left_hold <= sample_left;
                    right_hold <= sample_right;
                    i2s_bclk <= 0;
                    i2s_lrclk <= 0;
                    i2s_sdout <= 0;
                end
            end
            if (running) begin
                if (half_count == HALF_BCLK_CYCLES-1) begin
                    half_count <= 0;
                    i2s_bclk <= ~i2s_bclk;
                    // Old bclk=1 means this clk edge creates a BCLK falling
                    // edge. SDATA and LRCLK only change here.
                    if (i2s_bclk) begin
                        if (rise_index == 6'd63) begin
                            rise_index <= 0;
                            i2s_lrclk <= 0;
                            i2s_sdout <= 0;
                            if (sample_valid) begin
                                left_hold <= sample_left;
                                right_hold <= sample_right;
                            end else begin
                                left_hold <= left_pending;
                                right_hold <= right_pending;
                            end
                        end else begin
                            rise_index <= rise_index + 1'b1;
                            if (rise_index <= 6'd15)
                                i2s_sdout <= left_hold[15-rise_index];
                            else if (rise_index == 6'd31) begin
                                i2s_lrclk <= 1;
                                i2s_sdout <= 0;
                            end else if (rise_index >= 6'd32 && rise_index <= 6'd47)
                                i2s_sdout <= right_hold[47-rise_index];
                            else
                                i2s_sdout <= 0;
                        end
                    end
                end else
                    half_count <= half_count + 1'b1;
            end
        end
    end
endmodule
