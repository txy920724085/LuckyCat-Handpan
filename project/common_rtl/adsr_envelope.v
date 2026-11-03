// Sample-rate ADSR envelope for the next lesson.
// level is unsigned Q1.15-like magnitude: 0..32767.
// Parameters are level increments per sample_ce and must be positive.
module adsr_envelope #(
    parameter integer ATTACK_STEP   = 256,
    parameter integer DECAY_STEP    = 8,
    parameter integer USE_DECAY_Q8  = 0,
    parameter integer DECAY_STEP_Q8 = DECAY_STEP * 256,
    parameter integer SUSTAIN_LEVEL = 8192,
    parameter integer RELEASE_STEP  = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_ce,
    input  wire        gate,
    input  wire        retrigger,
    output reg  [15:0] level,
    output reg  [2:0]  stage
);
    localparam [2:0] IDLE    = 3'd0;
    localparam [2:0] ATTACK  = 3'd1;
    localparam [2:0] DECAY   = 3'd2;
    localparam [2:0] SUSTAIN = 3'd3;
    localparam [2:0] RELEASE = 3'd4;
    localparam integer MAX_LEVEL = 32767;

    reg gate_d;
    reg [7:0] decay_fraction;
    // Keep arithmetic at the integer parameter width, then explicitly select
    // the result width only inside the branches protected by saturation.
    wire [31:0] attack_value  = {16'd0, level} + ATTACK_STEP;
    wire [31:0] decay_value   = {16'd0, level} - DECAY_STEP;
    wire [31:0] release_value = {16'd0, level} - RELEASE_STEP;
    wire [23:0] decay_q8_value = {level, decay_fraction} - DECAY_STEP_Q8;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            level  <= 16'd0;
            stage  <= IDLE;
            gate_d <= 1'b0;
            decay_fraction <= 8'd0;
        end else if (sample_ce) begin
            gate_d <= gate;

            // A held-high gate can start a fresh attack using retrigger.
            // Keep the current level; downstream phase policy is independent.
            // Retrigger is ignored when gate is low.
            if (gate && (!gate_d || retrigger)) begin
                stage <= ATTACK;
                decay_fraction <= 8'd0;
            end else if (!gate && gate_d) begin
                if (level == 0)
                    stage <= IDLE;
                else
                    stage <= RELEASE;
            end else begin
                case (stage)
                    IDLE: begin
                        level <= 16'd0;
                        decay_fraction <= 8'd0;
                    end

                    ATTACK: begin
                        if ((ATTACK_STEP >= MAX_LEVEL) ||
                            (level >= MAX_LEVEL - ATTACK_STEP)) begin
                            level <= MAX_LEVEL;
                            decay_fraction <= 8'd0;
                            if (SUSTAIN_LEVEL >= MAX_LEVEL)
                                stage <= SUSTAIN;
                            else
                                stage <= DECAY;
                        end else begin
                            level <= attack_value[15:0];
                        end
                    end

                    DECAY: begin
                        if (USE_DECAY_Q8 && SUSTAIN_LEVEL == 0) begin
                            if ({level, decay_fraction} <= DECAY_STEP_Q8) begin
                                level <= 16'd0;
                                decay_fraction <= 8'd0;
                                stage <= SUSTAIN;
                            end else begin
                                level <= decay_q8_value[23:8];
                                decay_fraction <= decay_q8_value[7:0];
                            end
                        end else if ((SUSTAIN_LEVEL >= MAX_LEVEL) ||
                            (level <= SUSTAIN_LEVEL) ||
                            (DECAY_STEP >= MAX_LEVEL) ||
                            (level - SUSTAIN_LEVEL <= DECAY_STEP)) begin
                            level <= SUSTAIN_LEVEL;
                            decay_fraction <= 8'd0;
                            stage <= SUSTAIN;
                        end else begin
                            level <= decay_value[15:0];
                        end
                    end

                    SUSTAIN: begin
                        level <= SUSTAIN_LEVEL;
                        decay_fraction <= 8'd0;
                    end

                    RELEASE: begin
                        if ((RELEASE_STEP >= MAX_LEVEL) ||
                            (level <= RELEASE_STEP)) begin
                            level <= 16'd0;
                            decay_fraction <= 8'd0;
                            stage <= IDLE;
                        end else begin
                            level <= release_value[15:0];
                        end
                    end

                    default: begin
                        level <= 16'd0;
                        decay_fraction <= 8'd0;
                        stage <= IDLE;
                    end
                endcase
            end
        end
    end
endmodule
