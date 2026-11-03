`include "modal_v3_params.vh"
// Loudness A/B copy only: Drum-only Q1.15 gain. Baseline is exactly 1.0.
`ifndef DRUM_OUTPUT_GAIN_Q15
`define DRUM_OUTPUT_GAIN_Q15 17'd36766
`endif

// Shared four-lane Stage20 modal engine. All 32 logical voices retain their
// own phases, envelopes, preset, decay mode, noise state and precomputed
// oscillator steps. The arithmetic datapath is used once per logical voice.
module modal_v3_tdm_bank #(
    parameter integer VOICES=32,
    parameter integer INDEX_BITS=$clog2(VOICES)
)(
    input wire clk,rst_n,start,
    input wire new_event,new_modal,
    input wire [1:0] new_timbre,
    input wire [INDEX_BITS-1:0] new_slot,
    input wire [31:0] event_phase_step,
    input wire [6:0] event_velocity,
    input wire [17:0] bend_ratio,
    input wire [15:0] new_hp_d0,new_hp_d1,new_hp_d2,new_hp_d3,
    input wire [23:0] new_ma_c0,new_ma_c1,new_ma_c2,new_ma_c3,
    input wire [23:0] new_dr_c0,new_dr_c1,new_dr_c2,new_dr_c3,
    output wire ready,
    output reg engine_busy,frame_done,overrun,
    output reg [9:0] processing_cycles,
    output reg [VOICES-1:0] active,
    output wire [VOICES*24-1:0] samples
);
    localparam [1:0] E_IDLE=2'd0,E_ATTACK=2'd1,E_DECAY=2'd2;
    localparam [3:0] S_IDLE=0,S_LOAD=1,S_RATIO=2,S_STEP=3,S_BEND=4,
      S_ENV=5,S_LUT=6,S_MODAL=7,S_GAIN=8,S_AMP=9,S_SUM=10,S_DONE=11,
      S_COEF=12,S_OUTGAIN=13;
    reg [3:0] state;
    reg [INDEX_BITS-1:0] voice_index;
    reg event_pending,event_modal;
    reg [1:0] event_timbre_latched;
    reg [INDEX_BITS-1:0] event_slot_latched;
    reg [31:0] event_step_latched;
    reg [6:0] event_velocity_latched;
    reg [17:0] bend_latched;

    reg started[0:VOICES-1];
    reg [1:0] timbre_mem[0:VOICES-1];
    reg decay_mode_mem[0:VOICES-1];
    reg [15:0] gain_mem[0:VOICES-1];
    reg [31:0] step0_mem[0:VOICES-1],step1_mem[0:VOICES-1],step2_mem[0:VOICES-1],step3_mem[0:VOICES-1];
    reg enable0_mem[0:VOICES-1],enable1_mem[0:VOICES-1],enable2_mem[0:VOICES-1],enable3_mem[0:VOICES-1];
    reg [31:0] phase0_mem[0:VOICES-1],phase1_mem[0:VOICES-1],phase2_mem[0:VOICES-1],phase3_mem[0:VOICES-1];
    reg [15:0] level0_mem[0:VOICES-1],level1_mem[0:VOICES-1],level2_mem[0:VOICES-1],level3_mem[0:VOICES-1];
    reg [7:0] frac0_mem[0:VOICES-1],frac1_mem[0:VOICES-1],frac2_mem[0:VOICES-1],frac3_mem[0:VOICES-1];
    reg [1:0] env0_mem[0:VOICES-1],env1_mem[0:VOICES-1],env2_mem[0:VOICES-1],env3_mem[0:VOICES-1];
    reg [7:0] attack_count_mem[0:VOICES-1];
    reg [15:0] amp0_mem[0:VOICES-1],amp1_mem[0:VOICES-1],amp2_mem[0:VOICES-1],amp3_mem[0:VOICES-1];
    reg [23:0] coef0_mem[0:VOICES-1],coef1_mem[0:VOICES-1],coef2_mem[0:VOICES-1],coef3_mem[0:VOICES-1];
    reg [15:0] linear_d0_mem[0:VOICES-1],linear_d1_mem[0:VOICES-1],linear_d2_mem[0:VOICES-1],linear_d3_mem[0:VOICES-1];
    reg [15:0] noise_lfsr_mem[0:VOICES-1],noise_level_mem[0:VOICES-1];
    reg signed [23:0] out_sample[0:VOICES-1];
    reg signed [55:0] voice_wide_reg;
    reg signed [72:0] drum_gain_product_reg;

    genvar gv;
    generate for(gv=0;gv<VOICES;gv=gv+1)begin:pack
        assign samples[gv*24+:24]=out_sample[gv];
    end endgenerate
    assign ready=!engine_busy;

    function [20:0] ratio_value;
        input [1:0] timbre; input [1:0] osc;
        begin case(timbre)
          `V3_TIMBRE_MARIMBA: case(osc)
            0:ratio_value=`V3_MA_RATIO0;1:ratio_value=`V3_MA_RATIO1;
            2:ratio_value=`V3_MA_RATIO2;default:ratio_value=`V3_MA_RATIO3;endcase
          `V3_TIMBRE_DRUM: case(osc)
            0:ratio_value=`V3_DR_RATIO0;1:ratio_value=`V3_DR_RATIO1;
            2:ratio_value=`V3_DR_RATIO2;default:ratio_value=`V3_DR_RATIO3;endcase
          default: case(osc)
            0:ratio_value=`V3_HP_RATIO0;1:ratio_value=`V3_HP_RATIO1;
            2:ratio_value=`V3_HP_RATIO2;default:ratio_value=`V3_HP_RATIO3;endcase
        endcase end
    endfunction
    function [15:0] base_amp;
        input [1:0] timbre; input [1:0] osc;
        begin case(timbre)
          `V3_TIMBRE_MARIMBA: case(osc)
            0:base_amp=`V3_MA_AMP0;1:base_amp=`V3_MA_AMP1;
            2:base_amp=`V3_MA_AMP2;default:base_amp=`V3_MA_AMP3;endcase
          `V3_TIMBRE_DRUM: case(osc)
            0:base_amp=`V3_DR_AMP0;1:base_amp=`V3_DR_AMP1;
            2:base_amp=`V3_DR_AMP2;default:base_amp=`V3_DR_AMP3;endcase
          default: case(osc)
            0:base_amp=`V3_HP_AMP0;1:base_amp=`V3_HP_AMP1;
            2:base_amp=`V3_HP_AMP2;default:base_amp=`V3_HP_AMP3;endcase
        endcase end
    endfunction
    function [23:0] base_coef;
        input [1:0] timbre; input [1:0] osc;
        begin case(timbre)
          `V3_TIMBRE_MARIMBA: case(osc)
            0:base_coef=`V3_MA_DECAY0;1:base_coef=`V3_MA_DECAY1;
            2:base_coef=`V3_MA_DECAY2;default:base_coef=`V3_MA_DECAY3;endcase
          `V3_TIMBRE_DRUM: case(osc)
            0:base_coef=`V3_DR_DECAY0;1:base_coef=`V3_DR_DECAY1;
            2:base_coef=`V3_DR_DECAY2;default:base_coef=`V3_DR_DECAY3;endcase
          default: case(osc)
            0:base_coef=`V3_HP_DECAY0;1:base_coef=`V3_HP_DECAY1;
            2:base_coef=`V3_HP_DECAY2;default:base_coef=`V3_HP_DECAY3;endcase
        endcase end
    endfunction
    function [17:0] amp_slope;
        input [1:0] timbre; input [1:0] osc;
        begin case(timbre)
          `V3_TIMBRE_MARIMBA: case(osc)
            0:amp_slope=`V3_MA_ASLOPE0;1:amp_slope=`V3_MA_ASLOPE1;
            2:amp_slope=`V3_MA_ASLOPE2;default:amp_slope=`V3_MA_ASLOPE3;endcase
          `V3_TIMBRE_DRUM: case(osc)
            0:amp_slope=`V3_DR_ASLOPE0;1:amp_slope=`V3_DR_ASLOPE1;
            2:amp_slope=`V3_DR_ASLOPE2;default:amp_slope=`V3_DR_ASLOPE3;endcase
          default: case(osc)
            0:amp_slope=`V3_HP_ASLOPE0;1:amp_slope=`V3_HP_ASLOPE1;
            2:amp_slope=`V3_HP_ASLOPE2;default:amp_slope=`V3_HP_ASLOPE3;endcase
        endcase end
    endfunction
    function [17:0] decay_slope;
        input [1:0] timbre; input [1:0] osc;
        begin case(timbre)
          `V3_TIMBRE_MARIMBA: case(osc)
            0:decay_slope=`V3_MA_DSLOPE0;1:decay_slope=`V3_MA_DSLOPE1;
            2:decay_slope=`V3_MA_DSLOPE2;default:decay_slope=`V3_MA_DSLOPE3;endcase
          `V3_TIMBRE_DRUM: case(osc)
            0:decay_slope=`V3_DR_DSLOPE0;1:decay_slope=`V3_DR_DSLOPE1;
            2:decay_slope=`V3_DR_DSLOPE2;default:decay_slope=`V3_DR_DSLOPE3;endcase
          default: case(osc)
            0:decay_slope=`V3_HP_DSLOPE0;1:decay_slope=`V3_HP_DSLOPE1;
            2:decay_slope=`V3_HP_DSLOPE2;default:decay_slope=`V3_HP_DSLOPE3;endcase
        endcase end
    endfunction
    function signed [18:0] rounded_q12;
        input signed [26:0] value;
        reg signed [26:0] magnitude;
        begin
          if(value<0)begin magnitude=-value;rounded_q12=-((magnitude+27'sd2048)>>>12);end
          else rounded_q12=(value+27'sd2048)>>>12;
        end
    endfunction
    function [15:0] amp_from_product;
        input [1:0] timbre;input [1:0] osc;input signed [26:0] product;
        reg signed [18:0] adjust;
        reg signed [19:0] value;
        begin
          adjust=rounded_q12(product);value=$signed({1'b0,base_amp(timbre,osc)})+adjust;
          if(value<0)amp_from_product=0;else if(value>65535)amp_from_product=16'hffff;else amp_from_product=value[15:0];
        end
    endfunction
    function [23:0] coef_from_product;
        input [1:0] timbre;input [1:0] osc;input signed [26:0] product;
        reg signed [18:0] adjust;
        reg signed [24:0] deficit,value;
        begin
          adjust=rounded_q12(product);
          deficit=(25'sd8388608-$signed({1'b0,base_coef(timbre,osc)}))-adjust;
          if(deficit<1)deficit=1;
          value=25'sd8388608-deficit;
          coef_from_product=value[23:0];
        end
    endfunction
    function [23:0] coef_from_adjust;
        input [1:0] timbre;input [1:0] osc;input signed [18:0] adjust;
        reg signed [24:0] deficit,value;
        begin
          deficit=(25'sd8388608-$signed({1'b0,base_coef(timbre,osc)}))-adjust;
          if(deficit<1)deficit=1;
          value=25'sd8388608-deficit;
          coef_from_adjust=value[23:0];
        end
    endfunction
    function [31:0] step_from_product;
        input [52:0] product;
        begin
          if(product[52:16]>=37'h080000000)step_from_product=0;
          else step_from_product=product[47:16];
        end
    endfunction
    function [31:0] bent_step;
        input [49:0] product;
        begin
          if(product[49:16]>=34'h080000000)bent_step=32'h7fffffff;
          else bent_step=product[47:16];
        end
    endfunction
    function [15:0] lfsr_advance;
        input [15:0] value;
        begin lfsr_advance={value[14:0],value[15]^value[13]^value[12]^value[10]};end
    endfunction
    function [23:0] linear_next_q8;
        input [15:0] level;input [7:0] fraction;input [15:0] decrement;
        reg [23:0] current;
        begin
          current={level,fraction};
          if(current<={8'd0,decrement})linear_next_q8=24'd0;
          else linear_next_q8=current-{8'd0,decrement};
        end
    endfunction

    reg strike_cur,decay_mode_work;
    reg [1:0] timbre_work;
    reg [15:0] gain_work;
    reg [31:0] p0,p1,p2,p3,s0,s1,s2,s3;
    reg en0,en1,en2,en3;
    reg [15:0] l0,l1,l2,l3,a0,a1,a2,a3,d0,d1,d2,d3;
    reg [7:0] f0,f1,f2,f3;
    reg [23:0] c0,c1,c2,c3;
    reg [1:0] e0,e1,e2,e3;
    reg [7:0] attack_count;
    reg [15:0] noise_lfsr,noise_level;
    reg [52:0] ratio_product0,ratio_product1,ratio_product2,ratio_product3;
    reg signed [26:0] amp_adjust_product0,amp_adjust_product1,amp_adjust_product2,amp_adjust_product3;
    reg signed [26:0] decay_adjust_product0,decay_adjust_product1,decay_adjust_product2,decay_adjust_product3;
    reg signed [18:0] decay_adjust_rounded0,decay_adjust_rounded1,decay_adjust_rounded2,decay_adjust_rounded3;
    reg [49:0] bend_product0,bend_product1,bend_product2,bend_product3;
    reg phase_write_en;
    reg [47:0] decay_product0,decay_product1,decay_product2,decay_product3;
    reg [38:0] noise_decay_product;
    reg [31:0] calc_p0,calc_p1,calc_p2,calc_p3;
    reg [15:0] calc_l0,calc_l1,calc_l2,calc_l3;
    wire signed [16:0] sine_wire0,sine_wire1,sine_wire2,sine_wire3;
    sine_interp si0(.phase(calc_p0),.sample(sine_wire0));
    sine_interp si1(.phase(calc_p1),.sample(sine_wire1));
    sine_interp si2(.phase(calc_p2),.sample(sine_wire2));
    sine_interp si3(.phase(calc_p3),.sample(sine_wire3));
    reg signed [16:0] sine0,sine1,sine2,sine3;
    reg signed [33:0] modal_product0,modal_product1,modal_product2,modal_product3;
    reg signed [34:0] gain_product0,gain_product1,gain_product2,gain_product3;
    reg signed [51:0] amp_product0,amp_product1,amp_product2,amp_product3;
    reg [15:0] lfsr_next;
    reg signed [28:0] noise_amp_product;
    reg signed [32:0] noise_env_product;
    reg signed [33:0] noise_gain_product;
    reg signed [23:0] noise_final;

    wire [7:0] attack_limit=(timbre_work==`V3_TIMBRE_DRUM)?`V3_DR_ATTACK_SAMPLES:
      ((timbre_work==`V3_TIMBRE_MARIMBA)?`V3_MA_ATTACK_SAMPLES:`V3_HP_ATTACK_SAMPLES);
    wire [15:0] attack_step=(timbre_work==`V3_TIMBRE_DRUM)?`V3_DR_ATTACK_STEP:
      ((timbre_work==`V3_TIMBRE_MARIMBA)?`V3_MA_ATTACK_STEP:`V3_HP_ATTACK_STEP);
    wire [15:0] noise_amp=(timbre_work==`V3_TIMBRE_DRUM)?`V3_DR_NOISE_AMP:
      ((timbre_work==`V3_TIMBRE_MARIMBA)?`V3_MA_NOISE_AMP:`V3_HP_NOISE_AMP);
    wire [23:0] noise_coef=(timbre_work==`V3_TIMBRE_DRUM)?`V3_DR_NOISE_DECAY:
      ((timbre_work==`V3_TIMBRE_MARIMBA)?`V3_MA_NOISE_DECAY:`V3_HP_NOISE_DECAY);
    wire [23:0] eq0=decay_product0[46:23],eq1=decay_product1[46:23];
    wire [23:0] eq2=decay_product2[46:23],eq3=decay_product3[46:23];
    wire linear_mode=(decay_mode_work==`V3_DECAY_LINEAR);
    wire [23:0] lq0=linear_next_q8(l0,f0,d0);
    wire [23:0] lq1=linear_next_q8(l1,f1,d1);
    wire [23:0] lq2=linear_next_q8(l2,f2,d2);
    wire [23:0] lq3=linear_next_q8(l3,f3,d3);
    function [15:0] next_level;
      input [15:0] level;input [1:0] est;input [15:0] exp_level;input [15:0] linear_level;input linear_mode;
      input [7:0] acount,alimit;input [15:0] astep;
      reg [16:0] sum;
      begin
        if(est==E_ATTACK)begin
          if(acount+1'b1>=alimit)next_level=16'd32767;
          else begin sum=level+astep;next_level=sum>32767?16'd32767:sum[15:0];end
        end else if(est==E_DECAY)next_level=linear_mode?linear_level:exp_level;
        else next_level=0;
      end
    endfunction
    function [1:0] next_env;
      input [1:0] est;input [7:0] acount,alimit;input decay_empty;
      begin
        if(est==E_ATTACK)next_env=(acount+1'b1>=alimit)?E_DECAY:E_ATTACK;
        else if(est==E_DECAY)next_env=decay_empty?E_IDLE:E_DECAY;
        else next_env=E_IDLE;
      end
    endfunction
    wire [15:0] nl0=next_level(l0,e0,eq0[23:8],lq0[23:8],linear_mode,attack_count,attack_limit,attack_step);
    wire [15:0] nl1=next_level(l1,e1,eq1[23:8],lq1[23:8],linear_mode,attack_count,attack_limit,attack_step);
    wire [15:0] nl2=next_level(l2,e2,eq2[23:8],lq2[23:8],linear_mode,attack_count,attack_limit,attack_step);
    wire [15:0] nl3=next_level(l3,e3,eq3[23:8],lq3[23:8],linear_mode,attack_count,attack_limit,attack_step);
    wire [7:0] nf0=(e0==E_DECAY)?(linear_mode?lq0[7:0]:eq0[7:0]):8'd0;
    wire [7:0] nf1=(e1==E_DECAY)?(linear_mode?lq1[7:0]:eq1[7:0]):8'd0;
    wire [7:0] nf2=(e2==E_DECAY)?(linear_mode?lq2[7:0]:eq2[7:0]):8'd0;
    wire [7:0] nf3=(e3==E_DECAY)?(linear_mode?lq3[7:0]:eq3[7:0]):8'd0;
    wire decay_empty0=linear_mode?(lq0==0):(eq0==0);
    wire decay_empty1=linear_mode?(lq1==0):(eq1==0);
    wire decay_empty2=linear_mode?(lq2==0):(eq2==0);
    wire decay_empty3=linear_mode?(lq3==0):(eq3==0);
    wire [1:0] ne0=next_env(e0,attack_count,attack_limit,decay_empty0);
    wire [1:0] ne1=next_env(e1,attack_count,attack_limit,decay_empty1);
    wire [1:0] ne2=next_env(e2,attack_count,attack_limit,decay_empty2);
    wire [1:0] ne3=next_env(e3,attack_count,attack_limit,decay_empty3);
    wire [15:0] next_noise_level=noise_decay_product[38:23];
    wire signed [54:0] modal_sum={{3{amp_product0[51]}},amp_product0}
       +{{3{amp_product1[51]}},amp_product1}+{{3{amp_product2[51]}},amp_product2}
       +{{3{amp_product3[51]}},amp_product3};
    wire signed [55:0] voice_wide=(modal_sum>>>20)+$signed(noise_final);
    wire signed [72:0] drum_gain_product=$signed(voice_wide)*$signed(`DRUM_OUTPUT_GAIN_Q15);
    wire signed [56:0] drum_gain_rounded=drum_gain_product_reg<0 ?
      -(((-drum_gain_product_reg)+73'sd16384)>>>15) :
      ((drum_gain_product_reg+73'sd16384)>>>15);
    wire signed [56:0] voice_selected=(timbre_work==`V3_TIMBRE_DRUM)?drum_gain_rounded:$signed(voice_wide_reg);

    integer i;
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n)begin
        state<=S_IDLE;voice_index<=0;engine_busy<=0;frame_done<=0;overrun<=0;processing_cycles<=0;
        event_pending<=0;event_modal<=0;event_timbre_latched<=0;event_slot_latched<=0;
        event_step_latched<=0;event_velocity_latched<=0;bend_latched<=18'd65536;active<=0;
        strike_cur<=0;timbre_work<=0;decay_mode_work<=`V3_DECAY_LINEAR;gain_work<=0;p0<=0;p1<=0;p2<=0;p3<=0;s0<=0;s1<=0;s2<=0;s3<=0;
        en0<=0;en1<=0;en2<=0;en3<=0;l0<=0;l1<=0;l2<=0;l3<=0;f0<=0;f1<=0;f2<=0;f3<=0;a0<=0;a1<=0;a2<=0;a3<=0;
        c0<=0;c1<=0;c2<=0;c3<=0;
        d0<=`V3_HP_LINEAR_DECAY0;d1<=`V3_HP_LINEAR_DECAY1;
        d2<=`V3_HP_LINEAR_DECAY2;d3<=`V3_HP_LINEAR_DECAY3;
        e0<=0;e1<=0;e2<=0;e3<=0;attack_count<=0;noise_lfsr<=1;noise_level<=0;
        ratio_product0<=0;ratio_product1<=0;ratio_product2<=0;ratio_product3<=0;
        amp_adjust_product0<=0;amp_adjust_product1<=0;amp_adjust_product2<=0;amp_adjust_product3<=0;
        decay_adjust_product0<=0;decay_adjust_product1<=0;decay_adjust_product2<=0;decay_adjust_product3<=0;
        decay_adjust_rounded0<=0;decay_adjust_rounded1<=0;decay_adjust_rounded2<=0;decay_adjust_rounded3<=0;
        bend_product0<=0;bend_product1<=0;bend_product2<=0;bend_product3<=0;
        phase_write_en<=0;
        decay_product0<=0;decay_product1<=0;decay_product2<=0;decay_product3<=0;noise_decay_product<=0;
        calc_p0<=0;calc_p1<=0;calc_p2<=0;calc_p3<=0;calc_l0<=0;calc_l1<=0;calc_l2<=0;calc_l3<=0;
        sine0<=0;sine1<=0;sine2<=0;sine3<=0;modal_product0<=0;modal_product1<=0;modal_product2<=0;modal_product3<=0;
        gain_product0<=0;gain_product1<=0;gain_product2<=0;gain_product3<=0;
        amp_product0<=0;amp_product1<=0;amp_product2<=0;amp_product3<=0;
        lfsr_next<=1;noise_amp_product<=0;noise_env_product<=0;noise_gain_product<=0;noise_final<=0;
        voice_wide_reg<=0;drum_gain_product_reg<=0;
        for(i=0;i<VOICES;i=i+1)begin
          started[i]<=0;timbre_mem[i]<=0;decay_mode_mem[i]<=`V3_DECAY_LINEAR;gain_mem[i]<=0;step0_mem[i]<=0;step1_mem[i]<=0;step2_mem[i]<=0;step3_mem[i]<=0;
          enable0_mem[i]<=0;enable1_mem[i]<=0;enable2_mem[i]<=0;enable3_mem[i]<=0;
          phase0_mem[i]<=0;phase1_mem[i]<=0;phase2_mem[i]<=0;phase3_mem[i]<=0;
          level0_mem[i]<=0;level1_mem[i]<=0;level2_mem[i]<=0;level3_mem[i]<=0;
          frac0_mem[i]<=0;frac1_mem[i]<=0;frac2_mem[i]<=0;frac3_mem[i]<=0;
          env0_mem[i]<=E_IDLE;env1_mem[i]<=E_IDLE;env2_mem[i]<=E_IDLE;env3_mem[i]<=E_IDLE;
          attack_count_mem[i]<=0;amp0_mem[i]<=0;amp1_mem[i]<=0;amp2_mem[i]<=0;amp3_mem[i]<=0;
          coef0_mem[i]<=0;coef1_mem[i]<=0;coef2_mem[i]<=0;coef3_mem[i]<=0;
          linear_d0_mem[i]<=`V3_HP_LINEAR_DECAY0;linear_d1_mem[i]<=`V3_HP_LINEAR_DECAY1;
          linear_d2_mem[i]<=`V3_HP_LINEAR_DECAY2;linear_d3_mem[i]<=`V3_HP_LINEAR_DECAY3;
          noise_lfsr_mem[i]<=i+16'd1;noise_level_mem[i]<=0;out_sample[i]<=0;
        end
      end else begin
        frame_done<=0;
        phase_write_en<=0;
        if(phase_write_en)begin
          phase0_mem[voice_index]<=p0+bent_step(bend_product0);phase1_mem[voice_index]<=p1+bent_step(bend_product1);
          phase2_mem[voice_index]<=p2+bent_step(bend_product2);phase3_mem[voice_index]<=p3+bent_step(bend_product3);
        end
        if(start&&engine_busy)overrun<=1;
        if(engine_busy)processing_cycles<=processing_cycles+1'b1;
        case(state)
          S_IDLE:if(start)begin
            engine_busy<=1;processing_cycles<=0;voice_index<=0;event_pending<=new_event;
            event_modal<=new_modal;event_timbre_latched<=new_timbre;event_slot_latched<=new_slot;
            event_step_latched<=event_phase_step;event_velocity_latched<=event_velocity;
            bend_latched<=bend_ratio;state<=S_LOAD;
          end
          S_LOAD:begin
            strike_cur<=event_pending&&event_modal&&(event_slot_latched==voice_index);
            if(event_pending&&event_modal&&(event_slot_latched==voice_index))begin
              timbre_work<=event_timbre_latched;
              decay_mode_work<=(event_timbre_latched==`V3_TIMBRE_HANDPAN)?`V3_DECAY_LINEAR:`V3_DECAY_EXP;
              gain_work<={1'b0,event_velocity_latched,8'b0};
              p0<=0;p1<=0;p2<=0;p3<=0;l0<=0;l1<=0;l2<=0;l3<=0;f0<=0;f1<=0;f2<=0;f3<=0;
              d0<=new_hp_d0;d1<=new_hp_d1;d2<=new_hp_d2;d3<=new_hp_d3;
              e0<=E_ATTACK;e1<=E_ATTACK;e2<=E_ATTACK;e3<=E_ATTACK;attack_count<=0;
              noise_lfsr<=((event_timbre_latched==`V3_TIMBRE_DRUM)?`V3_DR_NOISE_SEED:
                ((event_timbre_latched==`V3_TIMBRE_MARIMBA)?`V3_MA_NOISE_SEED:`V3_HP_NOISE_SEED)) ^ (voice_index*16'd257);
              noise_level<=16'd32767;
            end else begin
              timbre_work<=timbre_mem[voice_index];decay_mode_work<=decay_mode_mem[voice_index];gain_work<=gain_mem[voice_index];
              p0<=phase0_mem[voice_index];p1<=phase1_mem[voice_index];p2<=phase2_mem[voice_index];p3<=phase3_mem[voice_index];
              l0<=level0_mem[voice_index];l1<=level1_mem[voice_index];l2<=level2_mem[voice_index];l3<=level3_mem[voice_index];
              f0<=frac0_mem[voice_index];f1<=frac1_mem[voice_index];f2<=frac2_mem[voice_index];f3<=frac3_mem[voice_index];
              e0<=env0_mem[voice_index];e1<=env1_mem[voice_index];e2<=env2_mem[voice_index];e3<=env3_mem[voice_index];
              attack_count<=attack_count_mem[voice_index];noise_lfsr<=noise_lfsr_mem[voice_index];noise_level<=noise_level_mem[voice_index];
              d0<=linear_d0_mem[voice_index];d1<=linear_d1_mem[voice_index];d2<=linear_d2_mem[voice_index];d3<=linear_d3_mem[voice_index];
            end
            s0<=step0_mem[voice_index];s1<=step1_mem[voice_index];s2<=step2_mem[voice_index];s3<=step3_mem[voice_index];
            en0<=enable0_mem[voice_index];en1<=enable1_mem[voice_index];en2<=enable2_mem[voice_index];en3<=enable3_mem[voice_index];
            a0<=amp0_mem[voice_index];a1<=amp1_mem[voice_index];a2<=amp2_mem[voice_index];a3<=amp3_mem[voice_index];
            c0<=coef0_mem[voice_index];c1<=coef1_mem[voice_index];c2<=coef2_mem[voice_index];c3<=coef3_mem[voice_index];
            state<=S_RATIO;
          end
          S_RATIO:begin
            if(strike_cur)begin
              ratio_product0<=event_step_latched*ratio_value(timbre_work,0);
              ratio_product1<=event_step_latched*ratio_value(timbre_work,1);
              ratio_product2<=event_step_latched*ratio_value(timbre_work,2);
              ratio_product3<=event_step_latched*ratio_value(timbre_work,3);
              amp_adjust_product0<=($signed({1'b0,event_velocity_latched,1'b0})-9'sd127)*$signed({1'b0,amp_slope(timbre_work,0)});
              amp_adjust_product1<=($signed({1'b0,event_velocity_latched,1'b0})-9'sd127)*$signed({1'b0,amp_slope(timbre_work,1)});
              amp_adjust_product2<=($signed({1'b0,event_velocity_latched,1'b0})-9'sd127)*$signed({1'b0,amp_slope(timbre_work,2)});
              amp_adjust_product3<=($signed({1'b0,event_velocity_latched,1'b0})-9'sd127)*$signed({1'b0,amp_slope(timbre_work,3)});
              decay_adjust_product0<=($signed({1'b0,event_velocity_latched,1'b0})-9'sd127)*$signed({1'b0,decay_slope(timbre_work,0)});
              decay_adjust_product1<=($signed({1'b0,event_velocity_latched,1'b0})-9'sd127)*$signed({1'b0,decay_slope(timbre_work,1)});
              decay_adjust_product2<=($signed({1'b0,event_velocity_latched,1'b0})-9'sd127)*$signed({1'b0,decay_slope(timbre_work,2)});
              decay_adjust_product3<=($signed({1'b0,event_velocity_latched,1'b0})-9'sd127)*$signed({1'b0,decay_slope(timbre_work,3)});
            end
            state<=S_STEP;
          end
          S_STEP:begin
            if(strike_cur)begin
              s0<=step_from_product(ratio_product0);s1<=step_from_product(ratio_product1);
              s2<=step_from_product(ratio_product2);s3<=step_from_product(ratio_product3);
              en0<=ratio_product0[52:16]<37'h080000000;en1<=ratio_product1[52:16]<37'h080000000;
              en2<=ratio_product2[52:16]<37'h080000000;en3<=ratio_product3[52:16]<37'h080000000;
              step0_mem[voice_index]<=step_from_product(ratio_product0);step1_mem[voice_index]<=step_from_product(ratio_product1);
              step2_mem[voice_index]<=step_from_product(ratio_product2);step3_mem[voice_index]<=step_from_product(ratio_product3);
              enable0_mem[voice_index]<=ratio_product0[52:16]<37'h080000000;enable1_mem[voice_index]<=ratio_product1[52:16]<37'h080000000;
              enable2_mem[voice_index]<=ratio_product2[52:16]<37'h080000000;enable3_mem[voice_index]<=ratio_product3[52:16]<37'h080000000;
              a0<=amp_from_product(timbre_work,0,amp_adjust_product0);a1<=amp_from_product(timbre_work,1,amp_adjust_product1);
              a2<=amp_from_product(timbre_work,2,amp_adjust_product2);a3<=amp_from_product(timbre_work,3,amp_adjust_product3);
              decay_adjust_rounded0<=rounded_q12(decay_adjust_product0);decay_adjust_rounded1<=rounded_q12(decay_adjust_product1);
              decay_adjust_rounded2<=rounded_q12(decay_adjust_product2);decay_adjust_rounded3<=rounded_q12(decay_adjust_product3);
              amp0_mem[voice_index]<=amp_from_product(timbre_work,0,amp_adjust_product0);amp1_mem[voice_index]<=amp_from_product(timbre_work,1,amp_adjust_product1);
              amp2_mem[voice_index]<=amp_from_product(timbre_work,2,amp_adjust_product2);amp3_mem[voice_index]<=amp_from_product(timbre_work,3,amp_adjust_product3);
            end
            state<=S_COEF;
          end
          S_COEF:begin
            if(strike_cur)begin
              if(timbre_work==`V3_TIMBRE_DRUM)begin
                c0<=new_dr_c0;c1<=new_dr_c1;c2<=new_dr_c2;c3<=new_dr_c3;
                coef0_mem[voice_index]<=new_dr_c0;coef1_mem[voice_index]<=new_dr_c1;
                coef2_mem[voice_index]<=new_dr_c2;coef3_mem[voice_index]<=new_dr_c3;
              end else begin
                c0<=new_ma_c0;c1<=new_ma_c1;c2<=new_ma_c2;c3<=new_ma_c3;
                coef0_mem[voice_index]<=new_ma_c0;coef1_mem[voice_index]<=new_ma_c1;
                coef2_mem[voice_index]<=new_ma_c2;coef3_mem[voice_index]<=new_ma_c3;
              end
              linear_d0_mem[voice_index]<=new_hp_d0;linear_d1_mem[voice_index]<=new_hp_d1;
              linear_d2_mem[voice_index]<=new_hp_d2;linear_d3_mem[voice_index]<=new_hp_d3;
              timbre_mem[voice_index]<=timbre_work;decay_mode_mem[voice_index]<=decay_mode_work;gain_mem[voice_index]<=gain_work;started[voice_index]<=1;
            end
            state<=S_BEND;
          end
          S_BEND:begin
            bend_product0<=s0*bend_latched;bend_product1<=s1*bend_latched;
            bend_product2<=s2*bend_latched;bend_product3<=s3*bend_latched;phase_write_en<=1;state<=S_ENV;
          end
          S_ENV:begin
            calc_p0<=p0;calc_p1<=p1;calc_p2<=p2;calc_p3<=p3;
            calc_l0<=en0?l0:0;calc_l1<=en1?l1:0;calc_l2<=en2?l2:0;calc_l3<=en3?l3:0;
            decay_product0<={l0,f0}*c0;decay_product1<={l1,f1}*c1;
            decay_product2<={l2,f2}*c2;decay_product3<={l3,f3}*c3;
            noise_decay_product<=noise_level*noise_coef;lfsr_next<=lfsr_advance(noise_lfsr);
            noise_amp_product<=($signed(lfsr_advance(noise_lfsr))>>>4)*$signed({1'b0,noise_amp});
            state<=S_LUT;
          end
          S_LUT:begin
            sine0<=sine_wire0;sine1<=sine_wire1;sine2<=sine_wire2;sine3<=sine_wire3;
            level0_mem[voice_index]<=nl0;level1_mem[voice_index]<=nl1;level2_mem[voice_index]<=nl2;level3_mem[voice_index]<=nl3;
            frac0_mem[voice_index]<=nf0;frac1_mem[voice_index]<=nf1;frac2_mem[voice_index]<=nf2;frac3_mem[voice_index]<=nf3;
            env0_mem[voice_index]<=ne0;env1_mem[voice_index]<=ne1;env2_mem[voice_index]<=ne2;env3_mem[voice_index]<=ne3;
            if(e0==E_ATTACK)attack_count_mem[voice_index]<=attack_count+1'b1;
            noise_lfsr_mem[voice_index]<=lfsr_next;noise_level_mem[voice_index]<=next_noise_level;
            noise_env_product<=($signed(noise_amp_product)>>>15)*$signed({1'b0,noise_level});
            active[voice_index]<=started[voice_index]||strike_cur;
            state<=S_MODAL;
          end
          S_MODAL:begin
            modal_product0<=sine0*$signed({1'b0,calc_l0});modal_product1<=sine1*$signed({1'b0,calc_l1});
            modal_product2<=sine2*$signed({1'b0,calc_l2});modal_product3<=sine3*$signed({1'b0,calc_l3});
            noise_gain_product<=($signed(noise_env_product)>>>15)*$signed({1'b0,gain_work});state<=S_GAIN;
          end
          S_GAIN:begin
            gain_product0<=($signed(modal_product0)>>>15)*$signed({1'b0,gain_work});
            gain_product1<=($signed(modal_product1)>>>15)*$signed({1'b0,gain_work});
            gain_product2<=($signed(modal_product2)>>>15)*$signed({1'b0,gain_work});
            gain_product3<=($signed(modal_product3)>>>15)*$signed({1'b0,gain_work});
            noise_final<=($signed(noise_gain_product)>>>15)<<<10;state<=S_AMP;
          end
          S_AMP:begin
            amp_product0<=gain_product0*$signed({1'b0,a0});amp_product1<=gain_product1*$signed({1'b0,a1});
            amp_product2<=gain_product2*$signed({1'b0,a2});amp_product3<=gain_product3*$signed({1'b0,a3});state<=S_SUM;
          end
          S_SUM:begin
            voice_wide_reg<=voice_wide;
            drum_gain_product_reg<=drum_gain_product;
            state<=S_OUTGAIN;
          end
          S_OUTGAIN:begin
            if(voice_selected>8388607)out_sample[voice_index]<=24'sh7fffff;
            else if(voice_selected< -8388608)out_sample[voice_index]<=-24'sh800000;
            else out_sample[voice_index]<=voice_selected[23:0];
            if(nl0==0&&nl1==0&&nl2==0&&nl3==0&&next_noise_level==0&&ne0==E_IDLE&&ne1==E_IDLE&&ne2==E_IDLE&&ne3==E_IDLE)begin
              active[voice_index]<=0;started[voice_index]<=0;
            end
            if(voice_index==VOICES-1)state<=S_DONE;
            else begin voice_index<=voice_index+1'b1;state<=S_LOAD;end
          end
          S_DONE:begin engine_busy<=0;frame_done<=1;state<=S_IDLE;end
          default:begin state<=S_IDLE;engine_busy<=0;end
        endcase
      end
    end
endmodule
