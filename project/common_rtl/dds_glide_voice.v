// One real-time sine voice with ADSR and velocity. No PCM recording is used.
// All event controls are sampled only on sample_ce.
// A new note requires gate && retrigger: latch pitch/velocity, phase := 0.
// The latched phase_step drives subsequent samples, including the release tail.
// retrigger with gate == 0 is ignored, and has no pitch/velocity side effects.
//
// Output = floor(floor(sine * envelope / 32768) * velocity / 128).
// sine is +/-2047, envelope is 0..32767, velocity is 0..127.
// There are TWO full-rate multiplier registers, not sample-rate registers.
// State updated at a sample_ce edge reaches sample after the SECOND subsequent
// clk edge (40 ns at 50 MHz). Leave >= 3 clk periods between sample_ce pulses
// if every settled sample must be observed. An audio serializer can capture
// the previous settled sample at sample_ce, for a fixed one-frame latency.
// Reset asynchronously clears state and BOTH pipeline stages to silence.
// Reattacking retains envelope level, but phase reset can still cause a click.
// Isolated glide variant: phase_step is live on sample_ce between strikes.
// Unlike dds_voice, pitch is not held; envelope and velocity still latch on strike.
module dds_glide_voice #(
    parameter integer ATTACK_STEP   = 256,
    parameter integer DECAY_STEP    = 8,
    parameter integer USE_DECAY_Q8  = 0,
    parameter integer DECAY_STEP_Q8 = DECAY_STEP * 256,
    parameter integer SUSTAIN_LEVEL = 8192,
    parameter integer RELEASE_STEP = 16,
    parameter integer FIXED_UNITY_GAIN = 0
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_ce,
    input  wire               gate,
    input  wire               retrigger,
    input  wire [31:0]        phase_step,
    input  wire [6:0]         velocity,
    output wire signed [15:0] sample,
    output wire [15:0]        envelope_level,
    output wire [2:0]         envelope_stage
);
    reg [31:0] phase;
    reg [31:0] step_latched;
    reg [6:0] velocity_latched;
    wire signed [15:0] sine_sample;
    wire signed [16:0] level_signed = {1'b0, envelope_level};
    reg signed [32:0] envelope_product;
    reg [6:0] velocity_d1;
    wire signed [15:0] envelope_scaled = envelope_product[30:15];
    wire signed [7:0] velocity_signed = {1'b0, velocity_d1};
    reg signed [23:0] velocity_product;
    reg signed [15:0] unity_sample;

    sine_lut u_lut (.phase_index(phase[31:24]), .sample(sine_sample));
    adsr_envelope #(
        .ATTACK_STEP(ATTACK_STEP), .DECAY_STEP(DECAY_STEP),
        .USE_DECAY_Q8(USE_DECAY_Q8), .DECAY_STEP_Q8(DECAY_STEP_Q8),
        .SUSTAIN_LEVEL(SUSTAIN_LEVEL), .RELEASE_STEP(RELEASE_STEP)
    ) u_envelope (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .gate(gate), .retrigger(retrigger),
        .level(envelope_level), .stage(envelope_stage)
    );

    // Valid ranges guarantee discarded upper bits are sign extensions.
    assign sample = FIXED_UNITY_GAIN ? unity_sample : velocity_product[22:7];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 32'd0;
            step_latched <= 32'd0;
            velocity_latched <= 7'd0;
        end else if (sample_ce) begin
            if (gate && retrigger) begin
                phase <= 32'd0;
                step_latched <= phase_step;
                velocity_latched <= velocity;
            end else begin
                phase <= phase + phase_step;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            envelope_product <= 33'sd0;
            velocity_d1 <= 7'd0;
            velocity_product <= 24'sd0;
            unity_sample <= 16'sd0;
        end else begin
            envelope_product <= sine_sample * level_signed;
            velocity_d1 <= velocity_latched;
            velocity_product <= envelope_scaled * velocity_signed;
            unity_sample <= envelope_scaled;
        end
    end
endmodule
