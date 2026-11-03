// 32 independent string histories, shared arithmetic. One frame per >=1024 clocks.
// Full ring initialization on pluck avoids stale reads when live delay changes.
// Loudness A/B copy only: Q1.15 output gain defaults to the accepted baseline.
`ifndef PLUCK_OUTPUT_GAIN_Q15
`define PLUCK_OUTPUT_GAIN_Q15 17'd46286
`endif
module ks_shared_bank #(parameter VOICES=32, INDEX_BITS=$clog2(VOICES))(
 input wire clk,rst_n,sample_ce,new_event,new_pluck,
 input wire [INDEX_BITS-1:0] new_slot,input wire [31:0] phase_step,
 input wire [6:0] velocity,input wire [17:0] bend_ratio,
 input wire [8:0] new_loss,
 output wire ready,output reg [VOICES-1:0] active,
 output wire [VOICES*16-1:0] samples,output reg overrun,clamped);
 localparam [25:0] MIN_PERIOD=26'd557056,MAX_PERIOD=26'd33456128; // 8.5..510.5
 reg signed [15:0] ram[0:VOICES*512-1];
 reg [INDEX_BITS+8:0] address;
 reg signed [15:0] ram_read;
 reg [4:0] state;reg [INDEX_BITS-1:0] slot,chosen;
 reg [25:0] period[0:VOICES-1],delay_q[0:VOICES-1];
 reg [8:0] pointer[0:VOICES-1];reg [6:0] strength[0:VOICES-1];
 reg [8:0] loss_code[0:VOICES-1];
 reg signed [15:0] previous[0:VOICES-1],out_sample[0:VOICES-1];
 reg [15:0] cycle_peak[0:VOICES-1];
 reg pending;reg [6:0] pending_velocity;
 reg [17:0] inverse;
 reg [8:0] fill_index,fill_length;reg signed [15:0] excitation,up_step,down_step;
 // Reuse the iterative dividers for excitation slopes instead of a large
 // single-cycle variable division. Both slopes finish in parallel.
 wire slope_start=state==16;
 wire div_start=(sample_ce && ready) || slope_start;
 wire [48:0] quotient,inv_quotient;wire div_done,inv_done;
 unsigned_div49 note_div(clk,rst_n,div_start,slope_start?49'd4096:49'h1000000000000,
 slope_start?{26'd0,fill_length[8:3]}:(phase_step==0?32'd1:phase_step),quotient,,div_done);
 unsigned_div49 bend_div(clk,rst_n,div_start,slope_start?49'd4096:49'h100000000,
 slope_start?({23'd0,fill_length}-{26'd0,fill_length[8:3]}):{14'd0,bend_ratio==0?18'd65536:bend_ratio},inv_quotient,,inv_done);
 reg [43:0] product;
 wire [43:0] scaled_period=product>>16;
 wire [25:0] bounded_period=scaled_period<MIN_PERIOD?MIN_PERIOD:scaled_period>MAX_PERIOD?MAX_PERIOD:scaled_period[25:0];
 wire [25:0] target_delay=bounded_period-26'd32768;
 reg [25:0] target_registered;
 wire [25:0] current_delay=delay_q[slot];
 // At most 1/16 sample change per audio sample; continuous fractional read position.
 wire [25:0] next_delay=target_registered>current_delay ?
 ((target_registered-current_delay>26'd4096)?current_delay+26'd4096:target_registered):
 ((current_delay-target_registered>26'd4096)?current_delay-26'd4096:target_registered);
 wire [8:0] read_position=pointer[slot]-current_delay[24:16];
 wire [8:0] older_position=address[8:0]-1'b1;
 reg [15:0] lfsr;wire signed [15:0] noise={{4{lfsr[11]}},lfsr[11:0]};
 reg [15:0] fraction;reg signed [15:0] tap_a,interpolated,average,feedback;
 reg signed [33:0] interpolation_product;reg signed [23:0] output_product;
 wire signed [16:0] difference=$signed(ram_read)-$signed(tap_a);
 wire signed [33:0] correction=interpolation_product<0?-((-interpolation_product)>>>16):interpolation_product>>>16;
 wire signed [34:0] interpolated_now=$signed(tap_a)+correction;
 wire signed [35:0] sum=interpolated_now+$signed(previous[slot]);
 wire signed [25:0] loss_product=average*$signed({1'b0,loss_code[slot]});
 wire signed [24:0] loss=loss_product<0?-((-loss_product)>>>9):loss_product>>>9;
 wire signed [23:0] audible=output_product<0?-((-output_product)>>>7):output_product>>>7;
 wire signed [40:0] audible_gain_product=$signed(audible)*$signed(`PLUCK_OUTPUT_GAIN_Q15);
 wire signed [24:0] audible_boosted=audible_gain_product<0 ?
   -(((-audible_gain_product)+41'sd16384)>>>15) :
   ((audible_gain_product+41'sd16384)>>>15);
 wire signed [15:0] audible_limited=audible_boosted>32767 ? 16'sd32767 :
   (audible_boosted< -32768 ? -16'sd32768 : audible_boosted[15:0]);
 wire [15:0] magnitude=feedback<0?-feedback:feedback;
 wire [15:0] peak=magnitude>cycle_peak[slot]?magnitude:cycle_peak[slot];
 assign ready=state==0;
 genvar g;generate for(g=0;g<VOICES;g=g+1)begin:outputs
 assign samples[g*16+:16]=out_sample[g];end endgenerate
 // Memory has no reset: new plucks initialize their entire 512-word region.
 always @(posedge clk)begin
 ram_read<=ram[address];
 if(state==17)ram[{chosen,fill_index}]<=fill_index<fill_length ? excitation+(noise>>>4):16'sd0;
 if(state==12 && active[slot])ram[{slot,pointer[slot]}]<=feedback;
 end
 integer i;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin
 active<=0;state<=0;slot<=0;chosen<=0;pending<=0;pending_velocity<=0;inverse<=65536;
 product<=0;target_registered<=0;address<=0;fill_index<=0;fill_length<=8;excitation<=0;up_step<=0;down_step<=0;lfsr<=16'hace1;
 fraction<=0;tap_a<=0;interpolated<=0;average<=0;feedback<=0;interpolation_product<=0;output_product<=0;
 overrun<=0;clamped<=0;
 for(i=0;i<VOICES;i=i+1)begin period[i]<=MIN_PERIOD;delay_q[i]<=524288;pointer[i]<=0;strength[i]<=0;loss_code[i]<=9'd508;previous[i]<=0;out_sample[i]<=0;cycle_peak[i]<=0;end
 end else begin
 if(sample_ce && !ready)overrun<=1;
 case(state)
 0:if(sample_ce)begin
 pending<=new_event && new_pluck && velocity!=0;chosen<=new_slot;pending_velocity<=velocity;slot<=0;state<=1;
 if(new_event)begin active[new_slot]<=0;out_sample[new_slot]<=0;end
 end
 1:if(div_done && inv_done)begin
 inverse<=inv_quotient[17:0];
 if(pending)begin
 period[chosen]<=quotient<MIN_PERIOD?MIN_PERIOD:quotient>MAX_PERIOD?MAX_PERIOD:quotient[25:0];
 if(quotient<MIN_PERIOD || quotient>MAX_PERIOD)clamped<=1;
 state<=14;
 end else state<=3;
 end
 14:begin product<=period[chosen]*inverse;state<=15;end
 15:begin
 delay_q[chosen]<=target_delay;fill_length<=target_delay[24:16];pointer[chosen]<=target_delay[24:16];
 if(scaled_period<MIN_PERIOD || scaled_period>MAX_PERIOD)clamped<=1;
 strength[chosen]<=pending_velocity;loss_code[chosen]<=new_loss;previous[chosen]<=0;cycle_peak[chosen]<=0;
 fill_index<=0;excitation<=-2048;lfsr<=16'hace1;state<=16;
 end
 16:state<=20;
 20:if(div_done && inv_done)begin up_step<=quotient[15:0];down_step<=inv_quotient[15:0];state<=17;end
 17:begin
 if(fill_index<(fill_length>>3))excitation<=excitation+up_step;else excitation<=excitation-down_step;
 lfsr<={lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
 if(fill_index==511)begin active[chosen]<=1;slot<=0;state<=3;end else fill_index<=fill_index+1'b1;
 end
 3:begin product<=period[slot]*inverse;state<=4;end
 4:begin
 target_registered<=target_delay;
 if(active[slot] && (scaled_period<MIN_PERIOD || scaled_period>MAX_PERIOD))clamped<=1;
 state<=18;
 end
 18:begin delay_q[slot]<=next_delay;fraction<=next_delay[15:0];state<=19;end
 19:begin address<={slot,read_position};state<=6;end
 6:state<=7;
 7:begin tap_a<=ram_read;address<={slot,older_position};state<=8;end
 8:state<=9;
 9:begin interpolation_product<=difference*$signed({1'b0,fraction});state<=10;end
 10:begin interpolated<=interpolated_now[15:0];average<=sum<0?-((-sum)>>>1):sum>>>1;state<=11;end
 11:begin feedback<=loss[15:0];output_product<=interpolated*$signed({1'b0,strength[slot]});state<=12;end
 12:begin
 if(active[slot])begin
 previous[slot]<=interpolated;out_sample[slot]<=audible_limited;pointer[slot]<=pointer[slot]+1'b1;
 if(pointer[slot]==511)begin cycle_peak[slot]<=0;if(peak==0)begin active[slot]<=0;out_sample[slot]<=0;end end
 else cycle_peak[slot]<=peak;
 end else out_sample[slot]<=0;
 state<=13;
 end
 13:if(slot==VOICES-1)state<=0;else begin slot<=slot+1'b1;state<=3;end
 default:state<=0;
 endcase
 end
endmodule
