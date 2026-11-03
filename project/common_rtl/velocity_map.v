// P12288_S512 integrated into this isolated board candidate; hardware trial pending.
// Keep all previous outputs through peak=12288. Expand the upper dynamic range.
// No clock/state; no change to event selection, channel, pitch, or ready/valid.
module velocity_map(
 input wire [15:0] peak,
 output wire [6:0] velocity
);
 wire [15:0] excess=peak-16'd12288;
 // This branch is used only for 12289..28159, so excess[13:9] is 0..30.
 wire [6:0] upper_velocity=7'd96+{2'b00,excess[13:9]};
 assign velocity=(peak>=16'd28160)?7'd127:
                 (peak>16'd12288)?upper_velocity:
                 (peak<16'd128)?7'd1:peak[13:7];
endmodule
