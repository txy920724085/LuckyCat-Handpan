// Separate louder board build; existing dual-timbre top is unchanged.
module uart_telemetry_top #(parameter integer STARTUP_FRAMES=4883, VOICES=32, ECHO_ADDR_BITS=14,
 parameter integer STATUS_PERIOD=5000000, VISUAL_LEDS=0,
 parameter [1:0] GAIN_SHIFT=2'd3)(
 input wire clk,reset_n,uart_rx_pin,
 output wire [5:0] led_n,
 output wire dac_bclk,dac_ws,dac_data,pa_en,uart_tx_pin);
 wire rst_n,frame_ce,rx_valid,rx_error,event_valid,event_ready,error_seen,received;
 wire timbre,clipped;
 wire note_valid,note_error,control_error,echo_clip,echo_overrun;
 wire [7:0] note_data; wire [6:0] echo_config;
 wire signed [15:0] echo_sample;
 wire pass_valid,bend_cancel,bend_error;wire [7:0] pass_data;
 wire [17:0] bend_target,bend_ratio;
 wire [7:0] rx_byte; wire [31:0] step; wire [6:0] velocity;
 wire signed [15:0] audio_sample,louder_sample;
 wire [VOICES-1:0] active;
 wire allocated,stolen;
 wire [31:0] status_mask={{(32-VOICES){1'b0}},active};
 reg [23:0] heartbeat;
 reg [12:0] startup;
 reg clip_seen;
 wire ready=(startup==STARTUP_FRAMES);
 reset_sync u_reset(.clk(clk),.reset_btn(~reset_n),.rst_n(rst_n));
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin heartbeat<=0;startup<=0;clip_seen<=0;end
 else begin heartbeat<=heartbeat+1'b1;
 if(frame_ce && !ready) startup<=startup+1'b1;
 if(frame_ce && ready && clipped)clip_seen<=1;
 end
 uart_rx u_rx(.clk(clk),.rst_n(rst_n),.rx(uart_rx_pin),.data(rx_byte),
 .valid(rx_valid),.framing_error(rx_error));
 uart_glide_control u_bend(.clk(clk),.rst_n(rst_n),.enable(ready),
 .byte_valid(rx_valid),.frame_error(rx_error),.byte_data(rx_byte),
 .pass_valid(pass_valid),.cancel(bend_cancel),.pass_data(pass_data),
 .target(bend_target),.error_seen(bend_error));
 pitch_slew u_slew(.clk(clk),.rst_n(rst_n),.sample_ce(frame_ce),
 .target(bend_target),.ratio(bend_ratio));
 uart_echo_control u_control(.clk(clk),.rst_n(rst_n),.enable(ready && !bend_cancel),
 .byte_valid(pass_valid),.frame_error(rx_error),.byte_data(pass_data),
 .note_valid(note_valid),.note_error(note_error),.note_data(note_data),
 .config_value(echo_config),.control_error(control_error));
 uart_timbre_queue u_events(.clk(clk),.rst_n(rst_n),.enable(ready && !note_error && !bend_cancel),
 .byte_valid(note_valid),.frame_error(rx_error),.byte_data(note_data),
 .event_valid(event_valid),.event_ready(event_ready),.phase_step(step),
 .velocity(velocity),.timbre(timbre),.error_seen(error_seen),.received_toggle(received));
 handpan_glide_poly #(.VOICES(VOICES)) u_synth(.clk(clk),.rst_n(rst_n),.sample_ce(frame_ce),
 .bend_ratio(bend_ratio),
 .event_valid(event_valid),.event_ready(event_ready),.event_phase_step(step),
 .event_velocity(velocity),.event_timbre(timbre),.sample(audio_sample),.active_mask(active),
 .allocated_voice(),.allocated_pulse(allocated),.rejected_pulse(),.stolen_pulse(stolen));
 audio_echo #(.ADDR_BITS(ECHO_ADDR_BITS)) u_echo(.clk(clk),.rst_n(rst_n),.sample_ce(frame_ce),
 .enable(echo_config[6]),.delay_select(echo_config[5:4]),.feedback(echo_config[3:2]),
 .wet(echo_config[1:0]),.sample_in(audio_sample),.sample_out(echo_sample),
 .clipped(echo_clip),.overrun(echo_overrun));
 audio_gain u_gain(.sample_in(echo_sample),.gain_shift(GAIN_SHIFT),
 .sample_out(louder_sample),.clipped(clipped));
 pt8211_tx u_dac(.clk(clk),.rst_n(rst_n),
 .sample_left(ready ? louder_sample : 16'sd0),
 .sample_right(ready ? louder_sample : 16'sd0),
 .bclk(dac_bclk),.ws(dac_ws),.sdata(dac_data),.frame_ce(frame_ce));
 assign pa_en=rst_n && ready;
 performance_telemetry #(.PERIOD(STATUS_PERIOD)) u_status(.clk(clk),.rst_n(rst_n),
 .active_mask(status_mask),.allocated(allocated),.stolen(stolen),
 .note_accepted(event_valid && event_ready),.rx_valid(rx_valid),.rx_error(rx_error),
 .sample_ce(frame_ce && ready),.clipped(clipped),.velocity(velocity),
 .echo_config(echo_config),.bend_ratio(bend_ratio),
 .flags({ready,clip_seen,echo_overrun,echo_clip,bend_error,control_error,error_seen}),
 .extra_flags(16'd0),.tx(uart_tx_pin));
 generate if(VISUAL_LEDS)begin: visual
 performance_leds u_leds(.clk(clk),.rst_n(rst_n),
 .trigger(event_valid && event_ready),.velocity(velocity),.heartbeat(heartbeat[23]),
 .fault(error_seen|control_error|bend_error|clip_seen|echo_clip|echo_overrun),.led_n(led_n));
 end else begin: legacy
 assign led_n=~{error_seen|control_error|bend_error|clip_seen|echo_clip|echo_overrun,active[3:0],heartbeat[23]};
 end endgenerate
endmodule
