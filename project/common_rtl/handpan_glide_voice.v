`include "handpan_timbre_params.vh"

// Four-modal additive voice. PRESET_LEGACY_BELL is bit-compatible with the
// former three-oscillator implementation: oscillator 3 is held inactive and
// its amplitude is zero. PRESET_HANDPAN_4OSC uses the MATLAB candidate table.
module handpan_glide_voice #(
    parameter integer PRESET = `PRESET_LEGACY_BELL,
    parameter integer ATTACK_STEP = 256,
    parameter integer DECAY_FUND = 1,
    parameter integer DECAY_SECOND = 3,
    parameter integer DECAY_THIRD = 6
) (
    input wire clk, rst_n, sample_ce, trigger,
    input wire [31:0] phase_step,
    input wire [17:0] bend_ratio,
    input wire [6:0] velocity,
    input wire timbre,
    output reg signed [15:0] sample,
    output wire active,
    output reg rejected,
    output wire [15:0] level_fund, level_second, level_third,
    output wire [15:0] level_fourth
);
    localparam integer IS_HANDPAN = (PRESET == `PRESET_HANDPAN_4OSC);
    localparam integer ACTIVE_ATTACK = IS_HANDPAN ? 168 : ATTACK_STEP;
    localparam [15:0] RATIO0_Q12 = IS_HANDPAN ? `HANDPAN_RATIO0_Q12 : `LEGACY_RATIO0_Q12;
    localparam [15:0] RATIO1_Q12 = IS_HANDPAN ? `HANDPAN_RATIO1_Q12 : `LEGACY_RATIO1_Q12;
    localparam [15:0] RATIO2_Q12 = IS_HANDPAN ? `HANDPAN_RATIO2_Q12 : `LEGACY_RATIO2_Q12;
    localparam [15:0] RATIO3_Q12 = IS_HANDPAN ? `HANDPAN_RATIO3_Q12 : `LEGACY_RATIO3_Q12;
    localparam [15:0] AMP0_Q15 = IS_HANDPAN ? `HANDPAN_AMP0_Q15 : `LEGACY_AMP0_Q15;
    localparam [15:0] AMP1_Q15 = IS_HANDPAN ? `HANDPAN_AMP1_Q15 : `LEGACY_AMP1_Q15;
    localparam [15:0] AMP2_Q15 = IS_HANDPAN ? `HANDPAN_AMP2_Q15 : `LEGACY_AMP2_Q15;
    localparam [15:0] AMP3_Q15 = IS_HANDPAN ? `HANDPAN_AMP3_Q15 : `LEGACY_AMP3_Q15;
    localparam [15:0] DECAY0_Q8 = IS_HANDPAN ? `HANDPAN_DECAY0_Q8 : DECAY_FUND*256;
    localparam [15:0] DECAY1_Q8 = IS_HANDPAN ? `HANDPAN_DECAY1_Q8 : DECAY_SECOND*256;
    localparam [15:0] DECAY2_Q8 = IS_HANDPAN ? `HANDPAN_DECAY2_Q8 : DECAY_THIRD*256;
    localparam [15:0] DECAY3_Q8 = IS_HANDPAN ? `HANDPAN_DECAY3_Q8 : DECAY_THIRD*256;

    reg started;
    reg timbre_latched;
    wire valid_pitch = (phase_step != 0) && (phase_step <= 32'h2aaaaaaa);
    wire strike = trigger && valid_pitch;
    wire note_gate = started || strike;
    reg [31:0] base_step;
    reg [49:0] pitch_product;
    wire [33:0] scaled_pitch=pitch_product[49:16];
    wire [31:0] live_step=(scaled_pitch>34'h02aaaaaaa) ? 32'h2aaaaaaa :
                              (scaled_pitch==0 ? 32'd1 : scaled_pitch[31:0]);

    // Constant-coefficient shift/add keeps the ratio table out of scarce DSPs.
    function [47:0] mul_ratio;
        input [31:0] value;
        input [15:0] ratio_q12;
        integer k;
        reg [47:0] acc;
        begin
            acc=0;
            for(k=0;k<16;k=k+1)
                if(ratio_q12[k]) acc=acc+({16'd0,value} << k);
            mul_ratio=acc;
        end
    endfunction
    function [31:0] ratio_to_step;
        input [47:0] product;
        reg [48:0] rounded;
        begin
            rounded={1'b0,product}+49'd2048;
            ratio_to_step=(rounded[48:12]>37'h07fffffff) ? 32'h7fffffff : rounded[43:12];
        end
    endfunction
    wire [31:0] step0=ratio_to_step(mul_ratio(live_step,RATIO0_Q12));
    wire [31:0] step1=ratio_to_step(mul_ratio(live_step,RATIO1_Q12));
    wire [31:0] step2=ratio_to_step(mul_ratio(live_step,RATIO2_Q12));
    wire [31:0] step3=ratio_to_step(mul_ratio(live_step,RATIO3_Q12));
    // Preserve legacy hierarchical probe names used by existing verification.
    wire [31:0] step_second=step1;
    wire [31:0] step_third=step2;

    always @(posedge clk or negedge rst_n)
    if(!rst_n)begin base_step<=0;pitch_product<=0;end
    else begin
      if(sample_ce && strike)base_step<=phase_step;
      pitch_product<=base_step*bend_ratio;
    end

    wire signed [15:0] s0,s1,s2,s3;
    wire [2:0] st0,st1,st2,st3;
    dds_glide_voice #(.ATTACK_STEP(ACTIVE_ATTACK),.DECAY_STEP(DECAY_FUND),
        .USE_DECAY_Q8(IS_HANDPAN),.DECAY_STEP_Q8(DECAY0_Q8),.SUSTAIN_LEVEL(0),
        .RELEASE_STEP(1),.FIXED_UNITY_GAIN(IS_HANDPAN)) fundamental(
        .clk(clk),.rst_n(rst_n),.sample_ce(sample_ce),.gate(note_gate),.retrigger(strike),
        .phase_step(step0),.velocity(velocity),.sample(s0),.envelope_level(level_fund),.envelope_stage(st0));
    dds_glide_voice #(.ATTACK_STEP(ACTIVE_ATTACK),.DECAY_STEP(DECAY_SECOND),
        .USE_DECAY_Q8(IS_HANDPAN),.DECAY_STEP_Q8(DECAY1_Q8),.SUSTAIN_LEVEL(0),
        .RELEASE_STEP(1),.FIXED_UNITY_GAIN(IS_HANDPAN)) second_partial(
        .clk(clk),.rst_n(rst_n),.sample_ce(sample_ce),.gate(note_gate),.retrigger(strike),
        .phase_step(step1),.velocity(velocity),.sample(s1),.envelope_level(level_second),.envelope_stage(st1));
    dds_glide_voice #(.ATTACK_STEP(ACTIVE_ATTACK),.DECAY_STEP(DECAY_THIRD),
        .USE_DECAY_Q8(IS_HANDPAN),.DECAY_STEP_Q8(DECAY2_Q8),.SUSTAIN_LEVEL(0),
        .RELEASE_STEP(1),.FIXED_UNITY_GAIN(IS_HANDPAN)) third_partial(
        .clk(clk),.rst_n(rst_n),.sample_ce(sample_ce),.gate(note_gate),.retrigger(strike),
        .phase_step(step2),.velocity(velocity),.sample(s2),.envelope_level(level_third),.envelope_stage(st2));
    dds_glide_voice #(.ATTACK_STEP(ACTIVE_ATTACK),.DECAY_STEP(DECAY_THIRD),
        .USE_DECAY_Q8(IS_HANDPAN),.DECAY_STEP_Q8(DECAY3_Q8),.SUSTAIN_LEVEL(0),
        .RELEASE_STEP(1),.FIXED_UNITY_GAIN(IS_HANDPAN)) fourth_partial(
        .clk(clk),.rst_n(rst_n),.sample_ce(sample_ce),.gate(IS_HANDPAN && note_gate),
        .retrigger(IS_HANDPAN && strike),.phase_step(step3),.velocity(velocity),
        .sample(s3),.envelope_level(level_fourth),.envelope_stage(st3));

    function signed [32:0] mul_amp;
        input signed [15:0] value;
        input [15:0] amplitude_q15;
        integer k;
        reg signed [32:0] acc;
        reg signed [32:0] extended_value;
        begin
            acc=0;extended_value={{17{value[15]}},value};
            for(k=0;k<16;k=k+1)
                if(amplitude_q15[k]) acc=acc+(extended_value <<< k);
            mul_amp=acc;
        end
    endfunction
    wire signed [32:0] a0=mul_amp(s0,AMP0_Q15);
    wire signed [32:0] a1=mul_amp(s1,AMP1_Q15);
    wire signed [32:0] a2=mul_amp(s2,AMP2_Q15);
    wire signed [32:0] a3=mul_amp(s3,AMP3_Q15);
    wire signed [34:0] mix_q15={{2{a0[32]}},a0}+{{2{a1[32]}},a1}+
                                 {{2{a2[32]}},a2}+{{2{a3[32]}},a3};
    wire signed [34:0] rounded_q15=mix_q15+
        (mix_q15<0 ? 35'sd16383 : 35'sd16384);
    wire signed [19:0] scaled_mix=(IS_HANDPAN ? rounded_q15 : mix_q15) >>> 15;
    wire signed [17:0] legacy_e0={{2{s0[15]}},s0};
    wire signed [17:0] legacy_e1={{2{s1[15]}},s1};
    wire signed [17:0] legacy_soft=(legacy_e0 <<< 2)+(legacy_e0 <<< 1)+legacy_e1;
    wire signed [17:0] legacy_soft_scaled=legacy_soft >>> 3;
    wire signed [19:0] selected_mix=(!IS_HANDPAN && timbre_latched) ? legacy_soft_scaled : scaled_mix;

    assign active=started && ((level_fund!=0)||(level_second!=0)||(level_third!=0)||
        (IS_HANDPAN && level_fourth!=0)||(st0==1)||(st1==1)||(st2==1)||(IS_HANDPAN && st3==1));

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin started<=0;timbre_latched<=0;rejected<=0;sample<=0;end
        else begin
            rejected<=sample_ce && trigger && !valid_pitch;
            if(sample_ce && strike)begin started<=1;timbre_latched<=timbre;end
            if(selected_mix>32767)sample<=16'sd32767;
            else if(selected_mix < -32768)sample<=-16'sd32768;
            else sample<=selected_mix[15:0];
        end
    end
endmodule
