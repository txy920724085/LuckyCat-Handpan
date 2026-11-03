// Isolated revision: snapshot -> groups of four -> one-hot dispatch.
// VOICES=4/8/16/32. sample_ce spacing >= clog2(VOICES)+8 clocks.
// Events handshake on input sample_ce; voice/allocated pulse occurs 3 clocks
// later. Payload is latched at handshake and may change immediately after it.
// All voices advance together at the delayed sample_ce (including no-event).
module handpan_glide_poly #(
 parameter integer VOICES=32, ATTACK_STEP=256, DECAY_FUND=1,
 DECAY_SECOND=3, DECAY_THIRD=6,
 INDEX_BITS=$clog2(VOICES), SUM_BITS=16+INDEX_BITS,
 MIX_SHIFT=INDEX_BITS, MIX_ROUND=0)(
 input wire clk,rst_n,sample_ce,event_valid,
 input wire [31:0] event_phase_step,input wire [6:0] event_velocity,
 input wire event_timbre,
 input wire [17:0] bend_ratio,
 output wire event_ready,output reg signed [15:0] sample,
 output reg [VOICES-1:0] active_mask,
 output reg [INDEX_BITS-1:0] allocated_voice,
 output reg allocated_pulse,rejected_pulse,stolen_pulse,output wire mixer_clipped);
 localparam GROUPS=VOICES/4;
 reg [2:0] ce_pipe;
 reg [VOICES-1:0] free_snapshot,dispatch;
 reg [31:0] pitch_snapshot;
 reg [6:0] velocity_snapshot;
 reg timbre_snapshot;
 reg accept_snapshot,steal_dispatch;
 reg [INDEX_BITS-1:0] steal_next,selected_dispatch,choice;
 reg [GROUPS-1:0] group_free;
 reg [1:0] group_slot[0:GROUPS-1];
 reg [31:0] pitch_group[0:GROUPS-1];
 reg [6:0] velocity_group[0:GROUPS-1];
 reg timbre_group[0:GROUPS-1];
 wire [VOICES-1:0] voice_active;
 wire signed [15:0] voice_sample[0:VOICES-1];
 wire valid_pitch=event_phase_step!=0 && event_phase_step<=32'h2aaaaaaa;
 assign event_ready=rst_n && sample_ce && (ce_pipe==0);
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
 active_mask<=0;allocated_voice<=0;allocated_pulse<=0;rejected_pulse<=0;
 stolen_pulse<=0;group_free<=0;
 for(g=0;g<GROUPS;g=g+1)begin group_slot[g]<=0;pitch_group[g]<=0;velocity_group[g]<=0;timbre_group[g]<=0;end
 end else begin
 ce_pipe<={ce_pipe[1:0],sample_ce && (ce_pipe==0)};
 allocated_pulse<=0;stolen_pulse<=0;
 rejected_pulse<=event_ready && event_valid && !valid_pitch;
 if(event_ready)begin
 free_snapshot<=~active_mask | ~voice_active;
 pitch_snapshot<=event_phase_step;velocity_snapshot<=event_velocity;timbre_snapshot<=event_timbre;
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
 active_mask[selected_dispatch]<=1;allocated_voice<=selected_dispatch;
 allocated_pulse<=1;stolen_pulse<=steal_dispatch;
 if(steal_dispatch)steal_next<=selected_dispatch+1'b1;
 end
 end
 end
 genvar v;
 generate for(v=0;v<VOICES;v=v+1)begin:g_voice
 handpan_glide_voice #(.ATTACK_STEP(ATTACK_STEP),.DECAY_FUND(DECAY_FUND),
 .DECAY_SECOND(DECAY_SECOND),.DECAY_THIRD(DECAY_THIRD)) u_voice(
 .clk(clk),.rst_n(rst_n),.sample_ce(ce_pipe[2]),.trigger(dispatch[v]),
 .phase_step(pitch_group[v/4]),.velocity(velocity_group[v/4]),.timbre(timbre_group[v/4]),
 .bend_ratio(bend_ratio),
 .sample(voice_sample[v]),.active(voice_active[v]),
 .rejected(),.level_fund(),.level_second(),.level_third());
 end endgenerate
 wire signed [SUM_BITS-1:0] tree[1:2*VOICES-1];
 generate for(v=0;v<VOICES;v=v+1)begin:leaves
 assign tree[VOICES+v]={{INDEX_BITS{voice_sample[v][15]}},voice_sample[v]};
 end
 for(v=1;v<VOICES;v=v+1)begin:nodes
 reg signed [SUM_BITS-1:0] sum;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)sum<=0;else sum<=$signed(tree[2*v])+$signed(tree[2*v+1]);
 assign tree[v]=sum;
 end endgenerate
 // Compile-time numeric mode. Keep legacy floor division by default.
 // One guard bit prevents rounding-bias addition from overflowing.
 wire signed [SUM_BITS:0] mix_wide={tree[1][SUM_BITS-1],tree[1]};
 wire signed [SUM_BITS:0] scaled;
 generate if(MIX_ROUND && MIX_SHIFT>0)begin:round_mix
 localparam signed [SUM_BITS:0] HALF=(1 << (MIX_SHIFT-1));
 wire signed [SUM_BITS:0] biased=mix_wide+(mix_wide<0 ? HALF-1'b1 : HALF);
 assign scaled=biased >>> MIX_SHIFT; // nearest, ties away from zero
 end else begin:truncate_mix
 assign scaled=mix_wide >>> MIX_SHIFT;
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
