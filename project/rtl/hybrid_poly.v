// Isolated revision: snapshot -> groups of four -> one-hot dispatch.
// VOICES=4/8/16/32. sample_ce spacing >= clog2(VOICES)+8 clocks.
// Events handshake on input sample_ce; voice/allocated pulse occurs 3 clocks
// later. Payload is latched at handshake and may change immediately after it.
// All voices advance together at the delayed sample_ce (including no-event).
module hybrid_poly #(
 parameter integer VOICES=32, ATTACK_STEP=256, DECAY_FUND=1,
 DECAY_SECOND=3, DECAY_THIRD=6,
 HANDPAN_PRESET=0, HANDPAN_TDM=0, MODAL_V3=0,
 INDEX_BITS=$clog2(VOICES), SUM_BITS=16+INDEX_BITS,
 MIX_SHIFT=INDEX_BITS, MIX_ROUND=0)(
 input wire clk,rst_n,sample_ce,event_valid,
 input wire [31:0] event_phase_step,input wire [6:0] event_velocity,
 input wire [1:0] event_timbre,
 input wire [17:0] bend_ratio,
 input wire [15:0] sustain_hp_d0,sustain_hp_d1,sustain_hp_d2,sustain_hp_d3,
 input wire [23:0] sustain_ma_c0,sustain_ma_c1,sustain_ma_c2,sustain_ma_c3,
 input wire [23:0] sustain_dr_c0,sustain_dr_c1,sustain_dr_c2,sustain_dr_c3,
 input wire [8:0] sustain_ks_loss,
 output wire event_ready,output reg signed [15:0] sample,
 output reg [VOICES-1:0] active_mask,
 output reg [INDEX_BITS-1:0] allocated_voice,
 output reg allocated_pulse,rejected_pulse,stolen_pulse,
 output wire bank_overrun,pitch_clamped,output wire mixer_clipped);
 localparam GROUPS=VOICES/4;
 reg [2:0] ce_pipe;
 reg [VOICES-1:0] free_snapshot,dispatch;
 reg [31:0] pitch_snapshot;
 reg [6:0] velocity_snapshot;
 reg [1:0] timbre_snapshot;
 reg [15:0] hp_d0_snapshot,hp_d1_snapshot,hp_d2_snapshot,hp_d3_snapshot;
 reg [23:0] ma_c0_snapshot,ma_c1_snapshot,ma_c2_snapshot,ma_c3_snapshot;
 reg [23:0] dr_c0_snapshot,dr_c1_snapshot,dr_c2_snapshot,dr_c3_snapshot;
 reg [8:0] ks_loss_snapshot;
 reg accept_snapshot,steal_dispatch;
 reg [INDEX_BITS-1:0] steal_next,selected_dispatch,choice;
 reg [GROUPS-1:0] group_free;
 reg [1:0] group_slot[0:GROUPS-1];
 reg [31:0] pitch_group[0:GROUPS-1];
 reg [6:0] velocity_group[0:GROUPS-1];
 reg [1:0] timbre_group[0:GROUPS-1];
 wire [VOICES-1:0] voice_active;
 wire signed [15:0] voice_sample[0:VOICES-1];
 wire [VOICES-1:0] bell_active,pluck_active;
 wire signed [15:0] bell_sample[0:VOICES-1];
 wire [VOICES*16-1:0] pluck_samples;
 wire [VOICES*24-1:0] modal_v3_samples;
 wire signed [23:0] modal_v3_sample[0:VOICES-1];
 reg [VOICES-1:0] pluck_mode;
 wire bank_ready;
 wire handpan_ready,handpan_engine_busy,handpan_frame_done,handpan_overrun;
 wire [9:0] handpan_cycles;
 wire string_overrun;reg deadline_missed;
 assign bank_overrun=string_overrun|deadline_missed;
 wire valid_pitch=event_phase_step!=0 && event_phase_step<=32'h2aaaaaaa;
 wire snapshot_is_pluck=(timbre_snapshot==2'd1);
 assign event_ready=rst_n && sample_ce && (ce_pipe==0) && bank_ready && handpan_ready;
 integer g,i,scan;reg found;
 always @* begin
 choice=steal_next;found=0;
 for(scan=0;scan<GROUPS;scan=scan+1)
 if(!found && group_free[scan])begin
 choice=scan*4+group_slot[scan];found=1;
 end
 end
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
 ce_pipe<=0;free_snapshot<=0;dispatch<=0;pitch_snapshot<=0;velocity_snapshot<=0;
 timbre_snapshot<=0;accept_snapshot<=0;steal_dispatch<=0;steal_next<=0;selected_dispatch<=0;
 hp_d0_snapshot<=38;hp_d1_snapshot<=72;hp_d2_snapshot<=132;hp_d3_snapshot<=245;
 ma_c0_snapshot<=8387866;ma_c1_snapshot<=8386451;ma_c2_snapshot<=8384371;ma_c3_snapshot<=8380700;
 dr_c0_snapshot<=8388015;dr_c1_snapshot<=8387289;dr_c2_snapshot<=8386451;dr_c3_snapshot<=8385783;
 ks_loss_snapshot<=508;
 active_mask<=0;allocated_voice<=0;allocated_pulse<=0;rejected_pulse<=0;
 pluck_mode<=0;
 deadline_missed<=0;
 stolen_pulse<=0;group_free<=0;
 for(g=0;g<GROUPS;g=g+1)begin group_slot[g]<=0;pitch_group[g]<=0;velocity_group[g]<=0;timbre_group[g]<=0;end
 end else begin
 if(sample_ce && (!bank_ready || !handpan_ready))deadline_missed<=1;
 ce_pipe<={ce_pipe[1:0],sample_ce && (ce_pipe==0) && bank_ready && handpan_ready};
 allocated_pulse<=0;stolen_pulse<=0;
 rejected_pulse<=event_ready && event_valid && !valid_pitch;
 if(event_ready)begin
 free_snapshot<=~active_mask | ~voice_active;
 pitch_snapshot<=event_phase_step;velocity_snapshot<=event_velocity;timbre_snapshot<=event_timbre;
 hp_d0_snapshot<=sustain_hp_d0;hp_d1_snapshot<=sustain_hp_d1;hp_d2_snapshot<=sustain_hp_d2;hp_d3_snapshot<=sustain_hp_d3;
 ma_c0_snapshot<=sustain_ma_c0;ma_c1_snapshot<=sustain_ma_c1;ma_c2_snapshot<=sustain_ma_c2;ma_c3_snapshot<=sustain_ma_c3;
 dr_c0_snapshot<=sustain_dr_c0;dr_c1_snapshot<=sustain_dr_c1;dr_c2_snapshot<=sustain_dr_c2;dr_c3_snapshot<=sustain_dr_c3;
 ks_loss_snapshot<=sustain_ks_loss;
 accept_snapshot<=event_valid && valid_pitch;
 end
 if(ce_pipe[0])begin
 for(g=0;g<GROUPS;g=g+1)begin
 group_free[g]<=|free_snapshot[g*4 +: 4];
 if(free_snapshot[g*4])group_slot[g]<=0;
 else if(free_snapshot[g*4+1])group_slot[g]<=1;
 else if(free_snapshot[g*4+2])group_slot[g]<=2;
 else group_slot[g]<=3;
 pitch_group[g]<=pitch_snapshot;velocity_group[g]<=velocity_snapshot;timbre_group[g]<=timbre_snapshot;
 end
 end
 if(ce_pipe[1])begin
 for(i=0;i<VOICES;i=i+1)dispatch[i]<=accept_snapshot && choice==i;
 selected_dispatch<=choice;steal_dispatch<=accept_snapshot && (group_free==0);
 end
 if(ce_pipe[2])begin
 for(i=0;i<VOICES;i=i+1)if(!voice_active[i])active_mask[i]<=0;
 if(accept_snapshot)begin
 pluck_mode[selected_dispatch]<=snapshot_is_pluck;
 active_mask[selected_dispatch]<=1;allocated_voice<=selected_dispatch;
 allocated_pulse<=1;stolen_pulse<=steal_dispatch;
 if(steal_dispatch)steal_next<=selected_dispatch+1'b1;
 end
 end
 end
 ks_shared_bank #(.VOICES(VOICES)) strings(.clk(clk),.rst_n(rst_n),.sample_ce(ce_pipe[2]),
 .new_event(accept_snapshot),.new_pluck(snapshot_is_pluck),.new_slot(selected_dispatch),
 .phase_step(pitch_snapshot),.velocity(velocity_snapshot),.bend_ratio(bend_ratio),
 .new_loss(ks_loss_snapshot),
 .ready(bank_ready),.active(pluck_active),.samples(pluck_samples),.overrun(string_overrun),.clamped(pitch_clamped));
 genvar v;
 generate if(HANDPAN_TDM && MODAL_V3)begin:g_v3_tdm
 modal_v3_tdm_bank #(.VOICES(VOICES),.INDEX_BITS(INDEX_BITS)) u_modal_v3(
 .clk(clk),.rst_n(rst_n),.start(ce_pipe[2]),
 .new_event(accept_snapshot),.new_modal(!snapshot_is_pluck),
 .new_timbre(timbre_snapshot),.new_slot(selected_dispatch),
 .event_phase_step(pitch_snapshot),.event_velocity(velocity_snapshot),.bend_ratio(bend_ratio),
 .new_hp_d0(hp_d0_snapshot),.new_hp_d1(hp_d1_snapshot),.new_hp_d2(hp_d2_snapshot),.new_hp_d3(hp_d3_snapshot),
 .new_ma_c0(ma_c0_snapshot),.new_ma_c1(ma_c1_snapshot),.new_ma_c2(ma_c2_snapshot),.new_ma_c3(ma_c3_snapshot),
 .new_dr_c0(dr_c0_snapshot),.new_dr_c1(dr_c1_snapshot),.new_dr_c2(dr_c2_snapshot),.new_dr_c3(dr_c3_snapshot),
 .ready(handpan_ready),.engine_busy(handpan_engine_busy),.frame_done(handpan_frame_done),
 .overrun(handpan_overrun),.processing_cycles(handpan_cycles),.active(bell_active),.samples(modal_v3_samples));
 for(v=0;v<VOICES;v=v+1)begin:g_v3_sample
 assign modal_v3_sample[v]=$signed(modal_v3_samples[v*24+:24]);
 assign bell_sample[v]=modal_v3_sample[v][15:0];
 end
 end else if(HANDPAN_TDM)begin:g_tdm
 wire [VOICES*16-1:0] tdm_samples;
 handpan_tdm_bank #(.VOICES(VOICES),.INDEX_BITS(INDEX_BITS)) u_handpan_tdm(
 .clk(clk),.rst_n(rst_n),.start(ce_pipe[2]),
 .new_event(accept_snapshot),.new_handpan(!timbre_snapshot[0]),.new_slot(selected_dispatch),
 .event_phase_step(pitch_snapshot),.event_velocity(velocity_snapshot),.bend_ratio(bend_ratio),
 .ready(handpan_ready),.engine_busy(handpan_engine_busy),.frame_done(handpan_frame_done),
 .overrun(handpan_overrun),.processing_cycles(handpan_cycles),.active(bell_active),.samples(tdm_samples));
 for(v=0;v<VOICES;v=v+1)begin:g_tdm_sample
 assign bell_sample[v]=$signed(tdm_samples[v*16+:16]);
 assign modal_v3_sample[v]={{8{tdm_samples[v*16+15]}},tdm_samples[v*16+:16]};
 end
 end else begin:g_parallel
 assign handpan_ready=1'b1;
 assign handpan_engine_busy=1'b0;
 assign handpan_frame_done=1'b0;
 assign handpan_overrun=1'b0;
 assign handpan_cycles=10'd0;
 for(v=0;v<VOICES;v=v+1)begin:g_voice
 handpan_glide_voice #(.PRESET(HANDPAN_PRESET),.ATTACK_STEP(ATTACK_STEP),.DECAY_FUND(DECAY_FUND),
 .DECAY_SECOND(DECAY_SECOND),.DECAY_THIRD(DECAY_THIRD)) u_voice(
 .clk(clk),.rst_n(rst_n),.sample_ce(ce_pipe[2]),.trigger(dispatch[v] && !timbre_group[v/4][0]),
 .phase_step(pitch_group[v/4]),.velocity(velocity_group[v/4]),.timbre(1'b0),
 .bend_ratio(bend_ratio),
 .sample(bell_sample[v]),.active(bell_active[v]),
 .rejected(),.level_fund(),.level_second(),.level_third());
 assign modal_v3_sample[v]={{8{bell_sample[v][15]}},bell_sample[v]};
 end
 end
 for(v=0;v<VOICES;v=v+1)begin:g_select
 assign voice_sample[v]=pluck_mode[v] ? $signed(pluck_samples[v*16+:16]) : bell_sample[v];
 assign voice_active[v]=pluck_mode[v] ? pluck_active[v] : bell_active[v];
 end endgenerate
 localparam integer WIDE_SUM_BITS=24+INDEX_BITS;
 // V3 MATLAB uses 7 for single-note normalized WAVs. Real 32-voice hardware
 // needs three more headroom bits; wide accumulation keeps the discarded
 // low-level information until this one final rounded conversion.
 localparam integer EFFECTIVE_SHIFT=MODAL_V3?10:MIX_SHIFT;
 wire signed [WIDE_SUM_BITS-1:0] tree[1:2*VOICES-1];
 generate for(v=0;v<VOICES;v=v+1)begin:leaves
 wire signed [23:0] selected_wide = MODAL_V3
   ? (pluck_mode[v] ? ($signed({{8{pluck_samples[v*16+15]}},pluck_samples[v*16+:16]})<<<8) : modal_v3_sample[v])
   : {{8{voice_sample[v][15]}},voice_sample[v]};
 assign tree[VOICES+v]={{INDEX_BITS{selected_wide[23]}},selected_wide};
 end
 for(v=1;v<VOICES;v=v+1)begin:nodes
 reg signed [WIDE_SUM_BITS-1:0] sum;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)sum<=0;else sum<=$signed(tree[2*v])+$signed(tree[2*v+1]);
 assign tree[v]=sum;
 end endgenerate
 // Compile-time numeric mode. Keep legacy floor division by default.
 // One guard bit prevents rounding-bias addition from overflowing.
 wire signed [WIDE_SUM_BITS:0] mix_wide={tree[1][WIDE_SUM_BITS-1],tree[1]};
 wire signed [WIDE_SUM_BITS:0] scaled;
 generate if((MIX_ROUND || MODAL_V3) && EFFECTIVE_SHIFT>0)begin:round_mix
 localparam signed [WIDE_SUM_BITS:0] HALF=(1 << (EFFECTIVE_SHIFT-1));
 wire signed [WIDE_SUM_BITS:0] biased=mix_wide+(mix_wide<0 ? HALF-1'b1 : HALF);
 assign scaled=biased >>> EFFECTIVE_SHIFT; // nearest, ties away from zero
 end else begin:truncate_mix
 assign scaled=mix_wide >>> EFFECTIVE_SHIFT;
 end endgenerate
 assign mixer_clipped=(scaled>32767 || scaled < -32768);
 always @(posedge clk or negedge rst_n)
 if(!rst_n)sample<=0;
 else if(sample_ce)begin
 if(scaled>32767)sample<=16'sd32767;
 else if(scaled < -32768)sample<=-16'sd32768;
 else sample<=scaled[15:0];
 end
endmodule
