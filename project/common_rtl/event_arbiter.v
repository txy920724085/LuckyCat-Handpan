// Sensor-priority arbitration for two ready/valid event producers.
// All ports share clk; reset is active-low. Producers must hold valid and
// payload until THEIR ready is asserted on a rising clock edge.
// Priority applies when selecting a new event. Once an event is stalled,
// its source and payload are locked until acceptance: a late sensor event
// cannot preempt a UART event already offered to the downstream consumer.
// No event is consumed early or buffered independently of its producer.
module event_arbiter(
    input wire clk,
    input wire rst_n,
    input wire sensor_valid,
    input wire [31:0] sensor_phase_step,
    input wire [6:0] sensor_velocity,
    input wire [1:0] sensor_timbre,
    output wire sensor_ready,
    input wire uart_valid,
    input wire [31:0] uart_phase_step,
    input wire [6:0] uart_velocity,
    input wire [1:0] uart_timbre,
    output wire uart_ready,
    output reg event_valid,
    input wire event_ready,
    output reg [31:0] event_phase_step,
    output reg [6:0] event_velocity,
    output reg [1:0] event_timbre
);
    reg locked, locked_sensor;
    reg [40:0] held_event;
    reg selected_sensor;

    always @* begin
        event_valid = 1'b0;
        event_phase_step = 32'd0;
        event_velocity = 7'd0;
        event_timbre = 2'd0;
        selected_sensor = 1'b0;
        if (rst_n) begin
            if (locked) begin
                event_valid = 1'b1;
                selected_sensor = locked_sensor;
                {event_phase_step,event_velocity,event_timbre} = held_event;
            end else if (sensor_valid) begin
                event_valid = 1'b1;
                selected_sensor = 1'b1;
                event_phase_step = sensor_phase_step;
                event_velocity = sensor_velocity;
                event_timbre = sensor_timbre;
            end else if (uart_valid) begin
                event_valid = 1'b1;
                event_phase_step = uart_phase_step;
                event_velocity = uart_velocity;
                event_timbre = uart_timbre;
            end
        end
    end

    // Exactly one producer is acknowledged, on the downstream acceptance.
    assign sensor_ready = rst_n && event_valid && event_ready && selected_sensor;
    assign uart_ready = rst_n && event_valid && event_ready && !selected_sensor;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            locked <= 1'b0;
            locked_sensor <= 1'b0;
            held_event <= 41'd0;
        end else if (locked) begin
            if (event_ready) locked <= 1'b0;
        end else if (event_valid && !event_ready) begin
            locked <= 1'b1;
            locked_sensor <= selected_sensor;
            held_event <= {event_phase_step,event_velocity,event_timbre};
        end
    end
endmodule
