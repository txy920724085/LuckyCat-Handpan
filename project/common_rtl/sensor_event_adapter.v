// Completed hit groups -> one stable ready/valid note at a time.
// All signals share clk (50 MHz in the intended integration).
// hit_mask is a one-clock pulse; peaks[i*16+:16] belongs to CHi.
// Capture the whole group atomically; drain CH0..7 in ascending order.
// The sensor has no backpressure. A full FIFO drops the NEW group and
// increments dropped_groups (saturating), without overwriting older notes.
// FIFO_DEPTH counts hit GROUPS, each of which can contain up to 8 notes.
// Contract: FIFO_DEPTH >= 1. No ADC, touch, UART, timbre or audio logic here.
module sensor_event_adapter #(
    parameter integer FIFO_DEPTH = 16
)(
    input wire clk,
    input wire rst_n,
    input wire [7:0] hit_mask,
    input wire [127:0] peaks,
    output wire event_valid,
    input wire event_ready,
    output wire [31:0] event_phase_step,
    output wire [6:0] event_velocity,
    output wire [2:0] event_channel,
    output wire [15:0] event_peak,
    output reg [31:0] dropped_groups
);
    localparam integer PTR_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
    localparam integer COUNT_W = $clog2(FIFO_DEPTH + 1);
    // Keep masks and peaks in separate arrays. This is behaviorally identical
    // to the original 136-bit group FIFO, while avoiding a wide-memory partial
    // write pattern that the Gowin synthesis RAM inference cannot elaborate.
    reg [7:0] mask_fifo [0:FIFO_DEPTH-1];
    reg [127:0] peaks_fifo [0:FIFO_DEPTH-1];
    reg [PTR_W-1:0] rd_ptr, wr_ptr;
    reg [COUNT_W-1:0] fill;
    integer scan;
    reg found;
    reg [2:0] channel;
    wire [7:0] head_mask = (rst_n && fill != 0) ? mask_fifo[rd_ptr] : 8'd0;
    wire [127:0] head_peaks = (rst_n && fill != 0) ? peaks_fifo[rd_ptr] : 128'd0;
    wire [7:0] selected_bit = 8'b00000001 << channel;
    wire take = event_valid && event_ready;
    wire pop_group = take && ((head_mask & ~selected_bit) == 0);
    wire incoming = rst_n && (hit_mask != 0);
    wire push_group = incoming && ((fill < FIFO_DEPTH) || pop_group);
    wire [31:0] mapped_step;
    wire [6:0] mapped_velocity;

    always @* begin
        channel = 0;
        found = 0;
        for (scan = 0; scan < 8; scan = scan + 1) begin
            if (!found && head_mask[scan]) begin
                channel = scan;
                found = 1;
            end
        end
    end

    assign event_valid = rst_n && (fill != 0);
    assign event_channel = event_valid ? channel : 3'd0;
    assign event_peak = event_valid ? head_peaks[channel*16 +: 16] : 16'd0;
    assign event_phase_step = event_valid ? mapped_step : 32'd0;
    assign event_velocity = event_valid ? mapped_velocity : 7'd0;

    zone_note_map note_map(.channel(channel), .phase_step(mapped_step));
    velocity_map vel_map(.peak(event_peak), .velocity(mapped_velocity));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 0;
            wr_ptr <= 0;
            fill <= 0;
            dropped_groups <= 0;
        end else begin
            // Partial consumption does not free a group slot.
            if (take && !pop_group)
                mask_fifo[rd_ptr] <= head_mask & ~selected_bit;
            if (pop_group)
                rd_ptr <= (rd_ptr == FIFO_DEPTH-1) ? 0 : rd_ptr + 1;
            if (push_group) begin
                mask_fifo[wr_ptr] <= hit_mask;
                peaks_fifo[wr_ptr] <= peaks;
                wr_ptr <= (wr_ptr == FIFO_DEPTH-1) ? 0 : wr_ptr + 1;
            end
            case ({push_group, pop_group})
                2'b10: fill <= fill + 1;
                2'b01: fill <= fill - 1;
                default: fill <= fill;
            endcase
            if (incoming && !push_group && dropped_groups != 32'hffffffff)
                dropped_groups <= dropped_groups + 1'b1;
        end
    end
endmodule
