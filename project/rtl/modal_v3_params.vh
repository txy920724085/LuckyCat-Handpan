// Stage 20 parameters copied from output_v3/timbre_presets.m.
// Ratios are unsigned Q*.16, amplitudes Q1.15, decays unsigned Q23.
`define V3_TIMBRE_HANDPAN 2'd0
`define V3_TIMBRE_PLUCK 2'd1
`define V3_TIMBRE_MARIMBA 2'd2
`define V3_TIMBRE_DRUM 2'd3
`define V3_DECAY_LINEAR 1'b0
`define V3_DECAY_EXP 1'b1

// Stage18 Q8.8 linear decrements, restored only for the Handpan preset.
`define V3_HP_LINEAR_DECAY0 16'd38
`define V3_HP_LINEAR_DECAY1 16'd72
`define V3_HP_LINEAR_DECAY2 16'd132
`define V3_HP_LINEAR_DECAY3 16'd245

`define V3_HP_RATIO0 21'd65536
`define V3_HP_RATIO1 21'd131072
`define V3_HP_RATIO2 21'd197263
`define V3_HP_RATIO3 21'd289669
`define V3_HP_AMP0 16'd32768
`define V3_HP_AMP1 16'd14746
`define V3_HP_AMP2 16'd7209
`define V3_HP_AMP3 16'd3277
`define V3_HP_DECAY0 24'd8388344
`define V3_HP_DECAY1 24'd8388114
`define V3_HP_DECAY2 24'd8387695
`define V3_HP_DECAY3 24'd8386913
`define V3_HP_ATTACK_SAMPLES 8'd195
`define V3_HP_ATTACK_STEP 16'd168
`define V3_HP_NOISE_AMP 16'd983
`define V3_HP_NOISE_DECAY 24'd8341272
`define V3_HP_NOISE_SEED 16'd1002

`define V3_MA_RATIO0 21'd65536
`define V3_MA_RATIO1 21'd262144
`define V3_MA_RATIO2 21'd602931
`define V3_MA_RATIO3 21'd1094451
`define V3_MA_AMP0 16'd32768
`define V3_MA_AMP1 16'd13763
`define V3_MA_AMP2 16'd5243
`define V3_MA_AMP3 16'd1966
`define V3_MA_DECAY0 24'd8387866
`define V3_MA_DECAY1 24'd8386451
`define V3_MA_DECAY2 24'd8384371
`define V3_MA_DECAY3 24'd8380700
`define V3_MA_ATTACK_SAMPLES 8'd59
`define V3_MA_ATTACK_STEP 16'd555
`define V3_MA_NOISE_AMP 16'd4588
`define V3_MA_NOISE_DECAY 24'd8257779
`define V3_MA_NOISE_SEED 16'd1005

// Big-drum prototype imported from output_v3.  The shared modal engine has
// four physical lanes, so this first FPGA version uses the first four of the
// six reference membrane modes. Ratios are Q*.16 and amplitudes are Q1.15.
`define V3_DR_RATIO0 21'd19661
`define V3_DR_RATIO1 21'd31326
`define V3_DR_RATIO2 21'd42009
`define V3_DR_RATIO3 21'd45154
`define V3_DR_AMP0 16'd32768
`define V3_DR_AMP1 16'd19661
`define V3_DR_AMP2 16'd13107
`define V3_DR_AMP3 16'd9830
`define V3_DR_DECAY0 24'd8388015
`define V3_DR_DECAY1 24'd8387289
`define V3_DR_DECAY2 24'd8386451
`define V3_DR_DECAY3 24'd8385783
`define V3_DR_ATTACK_SAMPLES 8'd122
`define V3_DR_ATTACK_STEP 16'd269
`define V3_DR_NOISE_AMP 16'd11469
`define V3_DR_NOISE_DECAY 24'd8380023
`define V3_DR_NOISE_SEED 16'd1026

// Q12 slopes for amplitude adjustment versus signed delta=(2*velocity-127).
// They implement base_amp*(1+tilt*bandwidth*(2*v-1)).
`define V3_HP_ASLOPE0 18'd0
`define V3_HP_ASLOPE1 18'd55480
`define V3_HP_ASLOPE2 18'd54249
`define V3_HP_ASLOPE3 18'd36995
`define V3_MA_ASLOPE0 18'd0
`define V3_MA_ASLOPE1 18'd66589
`define V3_MA_ASLOPE2 18'd50733
`define V3_MA_ASLOPE3 18'd28534
`define V3_DR_ASLOPE0 18'd0
`define V3_DR_ASLOPE1 18'd28534
`define V3_DR_ASLOPE2 18'd19022
`define V3_DR_ASLOPE3 18'd14267

// Q12 first-order reciprocal slopes for V3 velocity-dependent modal decay.
// deficit_eff ~= deficit * (1-vel_decay*(v-0.5)).
`define V3_HP_DSLOPE0 18'd638
`define V3_HP_DSLOPE1 18'd1195
`define V3_HP_DSLOPE2 18'd2209
`define V3_HP_DSLOPE3 18'd4100
`define V3_MA_DSLOPE0 18'd1197
`define V3_MA_DSLOPE1 18'd3478
`define V3_MA_DSLOPE2 18'd6833
`define V3_MA_DSLOPE3 18'd12753
`define V3_DR_DSLOPE0 18'd23
`define V3_DR_DSLOPE1 18'd50
`define V3_DR_DSLOPE2 18'd82
`define V3_DR_DSLOPE3 18'd99
