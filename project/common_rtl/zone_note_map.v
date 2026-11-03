// CH0..7 follow the existing piezo_note_adapter D-minor note table.
// 32-bit phase accumulator, Fs = 48828.125 Hz. Channel is zero-based;
// physical Zone labels / sensor wiring must be confirmed before board use.
module zone_note_map(
    input wire [2:0] channel,
    output reg [31:0] phase_step
);
    always @* begin
        case (channel)
            3'd0: phase_step = 32'd25831026; // D4
            3'd1: phase_step = 32'd28994347; // E4
            3'd2: phase_step = 32'd30718440; // F4
            3'd3: phase_step = 32'd34480283; // G4
            3'd4: phase_step = 32'd38702809; // A4
            3'd5: phase_step = 32'd41004198; // Bb4
            3'd6: phase_step = 32'd46025656; // C5
            3'd7: phase_step = 32'd51662052; // D5
            default: phase_step = 32'd0;
        endcase
    end
endmodule
