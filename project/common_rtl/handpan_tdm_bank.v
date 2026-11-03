`include "handpan_timbre_params.vh"

// Four physical modal lanes shared across VOICES logical Handpan voices.
// Each logical voice retains independent phase, envelope and base-pitch state.
// A frame takes 6*VOICES+2 clocks from start acceptance through frame_done.
module handpan_tdm_bank #(
    parameter integer VOICES=32,
    parameter integer INDEX_BITS=$clog2(VOICES)
)(
    input wire clk,rst_n,start,
    input wire new_event,new_handpan,
    input wire [INDEX_BITS-1:0] new_slot,
    input wire [31:0] event_phase_step,
    input wire [6:0] event_velocity,
    input wire [17:0] bend_ratio,
    output wire ready,
    output reg engine_busy,frame_done,overrun,
    output reg [9:0] processing_cycles,
    output reg [VOICES-1:0] active,
    output wire [VOICES*16-1:0] samples
);
    localparam [2:0] IDLE=3'd0,ATTACK=3'd1,DECAY=3'd2,SUSTAIN=3'd3;
    localparam [2:0] S_LOAD=3'd1,S_RATIO=3'd2,S_UPDATE=3'd3,
                     S_DDS=3'd4,S_AMP=3'd5,S_SUM=3'd6,S_DONE=3'd7;

    reg [2:0] state;
    reg [INDEX_BITS-1:0] voice_index;
    reg event_pending,event_is_handpan;
    reg [INDEX_BITS-1:0] event_slot_latched;
    reg [31:0] event_step_latched;
    reg [17:0] bend_latched;

    reg started[0:VOICES-1];
    reg [31:0] base_step[0:VOICES-1];
    reg [31:0] phase0[0:VOICES-1],phase1[0:VOICES-1],phase2[0:VOICES-1],phase3[0:VOICES-1];
    reg [15:0] level0[0:VOICES-1],level1[0:VOICES-1],level2[0:VOICES-1],level3[0:VOICES-1];
    reg [7:0] frac0[0:VOICES-1],frac1[0:VOICES-1],frac2[0:VOICES-1],frac3[0:VOICES-1];
    reg [2:0] env0[0:VOICES-1],env1[0:VOICES-1],env2[0:VOICES-1],env3[0:VOICES-1];
    reg signed [15:0] out_sample[0:VOICES-1];

    genvar gv;
    generate for(gv=0;gv<VOICES;gv=gv+1)begin:pack_samples
        assign samples[gv*16+:16]=out_sample[gv];
    end endgenerate
    assign ready=!engine_busy;

    reg strike_cur;
    reg [31:0] p0,p1,p2,p3;
    reg [15:0] l0,l1,l2,l3;
    reg [7:0] f0,f1,f2,f3;
    reg [2:0] e0,e1,e2,e3;
    reg [49:0] pitch_product;
    wire [33:0] scaled_pitch=pitch_product[49:16];
    wire [31:0] live_step=(scaled_pitch>34'h02aaaaaaa)?32'h2aaaaaaa:
                          (scaled_pitch==0?32'd1:scaled_pitch[31:0]);

    reg [47:0] ratio_product0,ratio_product1,ratio_product2,ratio_product3;
    function [31:0] ratio_step;
        input [47:0] product;
        reg [48:0] rounded;
        begin
            rounded={1'b0,product}+49'd2048;
            ratio_step=(rounded[48:12]>37'h07fffffff)?32'h7fffffff:rounded[43:12];
        end
    endfunction
    wire [31:0] step0=ratio_step(ratio_product0);
    wire [31:0] step1=ratio_step(ratio_product1);
    wire [31:0] step2=ratio_step(ratio_product2);
    wire [31:0] step3=ratio_step(ratio_product3);

    function [26:0] envelope_next;
        input [15:0] level;
        input [7:0] fraction;
        input [2:0] env_state;
        input strike;
        input [15:0] decay_q8;
        reg [23:0] q8_value;
        begin
            q8_value={level,fraction};
            if(strike) envelope_next={ATTACK,level,8'd0};
            else case(env_state)
                IDLE: envelope_next={IDLE,16'd0,8'd0};
                ATTACK: begin
                    if(level>=16'd32599) envelope_next={DECAY,16'd32767,8'd0};
                    else envelope_next={ATTACK,level+16'd168,fraction};
                end
                DECAY: begin
                    if(q8_value<=decay_q8) envelope_next={SUSTAIN,16'd0,8'd0};
                    else begin q8_value=q8_value-decay_q8;envelope_next={DECAY,q8_value};end
                end
                default: envelope_next={SUSTAIN,16'd0,8'd0};
            endcase
        end
    endfunction
    wire [26:0] ne0=envelope_next(l0,f0,e0,strike_cur,`HANDPAN_DECAY0_Q8);
    wire [26:0] ne1=envelope_next(l1,f1,e1,strike_cur,`HANDPAN_DECAY1_Q8);
    wire [26:0] ne2=envelope_next(l2,f2,e2,strike_cur,`HANDPAN_DECAY2_Q8);
    wire [26:0] ne3=envelope_next(l3,f3,e3,strike_cur,`HANDPAN_DECAY3_Q8);
    wire [31:0] np0=strike_cur?32'd0:p0+step0;
    wire [31:0] np1=strike_cur?32'd0:p1+step1;
    wire [31:0] np2=strike_cur?32'd0:p2+step2;
    wire [31:0] np3=strike_cur?32'd0:p3+step3;

    reg [31:0] calc_p0,calc_p1,calc_p2,calc_p3;
    reg [15:0] calc_l0,calc_l1,calc_l2,calc_l3;
    wire signed [15:0] sine0,sine1,sine2,sine3;
    sine_lut lut0(.phase_index(calc_p0[31:24]),.sample(sine0));
    sine_lut lut1(.phase_index(calc_p1[31:24]),.sample(sine1));
    sine_lut lut2(.phase_index(calc_p2[31:24]),.sample(sine2));
    sine_lut lut3(.phase_index(calc_p3[31:24]),.sample(sine3));
    reg signed [32:0] env_product0,env_product1,env_product2,env_product3;
    wire signed [15:0] modal0=env_product0[30:15];
    wire signed [15:0] modal1=env_product1[30:15];
    wire signed [15:0] modal2=env_product2[30:15];
    wire signed [15:0] modal3=env_product3[30:15];
    reg signed [32:0] amp_product0,amp_product1,amp_product2,amp_product3;
    wire signed [34:0] mix_q15={{2{amp_product0[32]}},amp_product0}+
                                 {{2{amp_product1[32]}},amp_product1}+
                                 {{2{amp_product2[32]}},amp_product2}+
                                 {{2{amp_product3[32]}},amp_product3};
    wire signed [34:0] rounded_q15=mix_q15+(mix_q15<0?35'sd16383:35'sd16384);
    wire signed [19:0] scaled_mix=rounded_q15>>>15;
    wire next_active=(started[voice_index]||strike_cur) &&
        (ne0[23:8]!=0||ne1[23:8]!=0||ne2[23:8]!=0||ne3[23:8]!=0||
         ne0[26:24]==ATTACK||ne1[26:24]==ATTACK||ne2[26:24]==ATTACK||ne3[26:24]==ATTACK);

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            state<=0;voice_index<=0;event_pending<=0;event_is_handpan<=0;
            event_slot_latched<=0;event_step_latched<=0;bend_latched<=18'd65536;
            engine_busy<=0;frame_done<=0;overrun<=0;processing_cycles<=0;active<=0;
            strike_cur<=0;p0<=0;p1<=0;p2<=0;p3<=0;l0<=0;l1<=0;l2<=0;l3<=0;
            f0<=0;f1<=0;f2<=0;f3<=0;e0<=0;e1<=0;e2<=0;e3<=0;pitch_product<=0;
            ratio_product0<=0;ratio_product1<=0;ratio_product2<=0;ratio_product3<=0;
            calc_p0<=0;calc_p1<=0;calc_p2<=0;calc_p3<=0;
            calc_l0<=0;calc_l1<=0;calc_l2<=0;calc_l3<=0;
            env_product0<=0;env_product1<=0;env_product2<=0;env_product3<=0;
            amp_product0<=0;amp_product1<=0;amp_product2<=0;amp_product3<=0;
            for(i=0;i<VOICES;i=i+1)begin
                started[i]<=0;base_step[i]<=0;
                phase0[i]<=0;phase1[i]<=0;phase2[i]<=0;phase3[i]<=0;
                level0[i]<=0;level1[i]<=0;level2[i]<=0;level3[i]<=0;
                frac0[i]<=0;frac1[i]<=0;frac2[i]<=0;frac3[i]<=0;
                env0[i]<=IDLE;env1[i]<=IDLE;env2[i]<=IDLE;env3[i]<=IDLE;
                out_sample[i]<=0;
            end
        end else begin
            frame_done<=0;
            if(start && engine_busy)overrun<=1;
            if(engine_busy)processing_cycles<=processing_cycles+1'b1;
            case(state)
                0:if(start)begin
                    engine_busy<=1;processing_cycles<=0;voice_index<=0;
                    event_pending<=new_event;event_is_handpan<=new_handpan;
                    event_slot_latched<=new_slot;event_step_latched<=event_phase_step;
                    bend_latched<=bend_ratio;state<=S_LOAD;
                end
                S_LOAD:begin
                    strike_cur<=event_pending&&event_is_handpan&&(event_slot_latched==voice_index);
                    p0<=phase0[voice_index];p1<=phase1[voice_index];
                    p2<=phase2[voice_index];p3<=phase3[voice_index];
                    l0<=level0[voice_index];l1<=level1[voice_index];
                    l2<=level2[voice_index];l3<=level3[voice_index];
                    f0<=frac0[voice_index];f1<=frac1[voice_index];
                    f2<=frac2[voice_index];f3<=frac3[voice_index];
                    e0<=env0[voice_index];e1<=env1[voice_index];
                    e2<=env2[voice_index];e3<=env3[voice_index];
                    pitch_product<=base_step[voice_index]*bend_latched;
                    if(event_pending&&event_is_handpan&&(event_slot_latched==voice_index))begin
                        base_step[voice_index]<=event_step_latched;started[voice_index]<=1;
                    end
                    state<=S_RATIO;
                end
                S_RATIO:begin
                    ratio_product0<=live_step*`HANDPAN_RATIO0_Q12;
                    ratio_product1<=live_step*`HANDPAN_RATIO1_Q12;
                    ratio_product2<=live_step*`HANDPAN_RATIO2_Q12;
                    ratio_product3<=live_step*`HANDPAN_RATIO3_Q12;
                    state<=S_UPDATE;
                end
                S_UPDATE:begin
                    calc_p0<=np0;calc_p1<=np1;calc_p2<=np2;calc_p3<=np3;
                    calc_l0<=ne0[23:8];calc_l1<=ne1[23:8];calc_l2<=ne2[23:8];calc_l3<=ne3[23:8];
                    phase0[voice_index]<=np0;phase1[voice_index]<=np1;
                    phase2[voice_index]<=np2;phase3[voice_index]<=np3;
                    level0[voice_index]<=ne0[23:8];level1[voice_index]<=ne1[23:8];
                    level2[voice_index]<=ne2[23:8];level3[voice_index]<=ne3[23:8];
                    frac0[voice_index]<=ne0[7:0];frac1[voice_index]<=ne1[7:0];
                    frac2[voice_index]<=ne2[7:0];frac3[voice_index]<=ne3[7:0];
                    env0[voice_index]<=ne0[26:24];env1[voice_index]<=ne1[26:24];
                    env2[voice_index]<=ne2[26:24];env3[voice_index]<=ne3[26:24];
                    active[voice_index]<=next_active;state<=S_DDS;
                end
                S_DDS:begin
                    env_product0<=sine0*$signed({1'b0,calc_l0});
                    env_product1<=sine1*$signed({1'b0,calc_l1});
                    env_product2<=sine2*$signed({1'b0,calc_l2});
                    env_product3<=sine3*$signed({1'b0,calc_l3});
                    state<=S_AMP;
                end
                S_AMP:begin
                    amp_product0<=modal0*$signed({1'b0,`HANDPAN_AMP0_Q15});
                    amp_product1<=modal1*$signed({1'b0,`HANDPAN_AMP1_Q15});
                    amp_product2<=modal2*$signed({1'b0,`HANDPAN_AMP2_Q15});
                    amp_product3<=modal3*$signed({1'b0,`HANDPAN_AMP3_Q15});
                    state<=S_SUM;
                end
                S_SUM:begin
                    if(scaled_mix>32767)out_sample[voice_index]<=16'sd32767;
                    else if(scaled_mix < -32768)out_sample[voice_index]<=-16'sd32768;
                    else out_sample[voice_index]<=scaled_mix[15:0];
                    if(voice_index==VOICES-1)state<=S_DONE;
                    else begin voice_index<=voice_index+1'b1;state<=S_LOAD;end
                end
                S_DONE:begin engine_busy<=0;frame_done<=1;state<=0;end
                default:begin state<=0;engine_busy<=0;end
            endcase
        end
    end
    wire unused_velocity=^event_velocity;
endmodule
