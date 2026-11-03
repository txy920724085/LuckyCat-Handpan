// Separate louder board build; existing dual-timbre top is unchanged.
module uart_hybrid_top #(parameter integer STARTUP_FRAMES=4883, VOICES=32, ECHO_ADDR_BITS=14,
 parameter integer QT_TELEMETRY_PERIOD=5000000,
 parameter integer STATUS_PERIOD=5000000, VISUAL_LEDS=1,
 parameter [1:0] GAIN_SHIFT=2'd3,
 parameter integer AUDIO_NUMERIC_MODE=0,
 parameter integer HANDPAN_PRESET=0, parameter integer HANDPAN_TDM=0,
 parameter integer MODAL_V3=0, parameter integer DC_BLOCK_ENABLE=0,
 parameter integer MIX_SHIFT=(AUDIO_NUMERIC_MODE==1 ? 2 : $clog2(VOICES)),
 parameter integer MIX_ROUND=(AUDIO_NUMERIC_MODE==1),
 parameter [1:0] MASTER_GAIN_SHIFT=(AUDIO_NUMERIC_MODE==1 ? 2'd0 : GAIN_SHIFT),
 parameter integer SENSOR_INPUT_ENABLE=0,
 parameter integer SENSOR_FILTER_ENABLE=0,SENSOR_FILTER_SCANS=16,SENSOR_FILTER_SHIFT=4,
 parameter integer SENSOR_LATE_GUARD_ENABLE=0,
 parameter integer PMR_ENABLE=0,
 parameter integer QT_SUSTAIN_ENABLE=0,
 parameter integer QT_SUSTAIN_INVERT=0)(
 input wire clk,reset_n,uart_rx_pin,jdy_rx_pin,
 output wire [5:0] led_n,
 output wire dac_bclk,dac_ws,dac_data,pa_en,uart_tx_pin,jdy_tx_pin,
 output wire i2s_bclk,i2s_lrclk,i2s_sdout,
 input wire [7:0] sensor_hit_mask,
 input wire [127:0] sensor_peaks,
 input wire sensor_scan_valid,
 input wire sensor_adc_ready,
 input wire sensor_calibrated,
 input wire [3:0] sensor_adc_error,
 input wire [31:0] qt_sample_seq,
 input wire qt_valid,
 input wire [3:0] qt_mode,qt_error,
 input wire [7:0] qt_status,
 input wire [11:0] qt_keys,
 input wire signed [9:0] qt_step,
 input wire qt_fault_valid,input wire [7:0] qt_fault_addr,qt_fault_expected,qt_fault_actual,
 input wire [1:0] qt_fault_bus_error,input wire [4:0] qt_fault_state,
 input wire [7:0] qt_fault_last_reg,qt_fault_last_status,input wire [11:0] qt_fault_last_keys,
 input wire [7:0] qt_fault_last_position,
 input wire [7:0] qt_nack_count,qt_mismatch_count,qt_reinit_count,
 input wire pmr_valid,input wire [7:0] pmr_data,input wire pmr_last,output wire pmr_ready,
 input wire wave_stream_valid,input wire [7:0] wave_stream_data,input wire wave_stream_complete,
 input wire wave_frozen,input wire [31:0] wave_skipped_scans,output wire wave_stream_ready,
 output wire wave_capture_arm,output wire wave_capture_release,
 output wire [31:0] sensor_dropped_groups,output wire sensor_recalibrate_req,
 output wire [255:0] tune_config,output wire tune_commit,
 output wire visual_pcm_ce,output wire signed [15:0] visual_pcm,
 output wire visual_hit,output wire [2:0] visual_channel,output wire [6:0] visual_velocity,
 output wire [1:0] visual_timbre,output wire [7:0] visual_sustain,output wire visual_echo
);
 wire tune_rx_valid;wire [7:0] tune_rx_data;
 wire tune_tx_valid,tune_tx_last,tune_tx_ready;wire [7:0] tune_tx_data;
  wire rst_n,frame_ce,rx_valid,rx_error,event_valid,event_ready,error_seen,received;
 wire sensor_config_rst_n=rst_n && !tune_commit;
 wire wired_frame_seen,jdy_frame_seen,wired_drop,jdy_drop;
 wire wdy_rx_valid,wdy_rx_error;wire [7:0] wdy_rx_data;
 wire [1:0] timbre;wire clipped;
 wire gain_clipped,mixer_clipped,dc_clipped;
 assign clipped=gain_clipped|mixer_clipped|dc_clipped;
 wire note_valid,note_error,control_error,echo_clip,echo_overrun;
 wire [7:0] note_data; wire [6:0] echo_config;
 wire signed [15:0] echo_sample;
 wire pass_valid,bend_cancel,bend_error;wire [7:0] pass_data;
 wire [17:0] uart_bend_target,bend_ratio;
 wire [7:0] sustain_u;
 wire [1:0] selected_timbre;
 wire echo_key_toggle;wire [4:0] key_press_pulse;
 wire key_healthy,key_synchronized;
 reg sensor_timbre_seen;reg [1:0] last_sensor_timbre;
 wire [15:0] hp_d0,hp_d1,hp_d2,hp_d3;
 wire [23:0] ma_c0,ma_c1,ma_c2,ma_c3;
 wire [23:0] dr_c0,dr_c1,dr_c2,dr_c3;
 wire [8:0] ks_loss;
 wire [7:0] rx_byte; wire [31:0] step; wire [6:0] velocity;
 wire uart_queue_valid,uart_queue_ready;
 wire [31:0] uart_queue_step;
 wire [6:0] uart_queue_velocity;
 wire [1:0] uart_queue_timbre;
 wire sensor_telem_valid;
 wire [2:0] sensor_telem_channel;
 wire [6:0] sensor_telem_velocity;
 wire [15:0] sensor_telem_peak;
 wire signed [15:0] audio_sample,louder_sample,dac_sample;
 wire [VOICES-1:0] active;
 wire allocated,stolen;
 wire bank_overrun,pitch_clamped;
 wire [15:0] telemetry_extra=SENSOR_INPUT_ENABLE ?
  {sensor_hit_mask,sensor_adc_error,sensor_calibrated,sensor_adc_ready,
   pitch_clamped,bank_overrun} :
  {14'd0,pitch_clamped,bank_overrun};
 wire [31:0] status_mask={{(32-VOICES){1'b0}},active};
 reg [23:0] heartbeat;
 reg [12:0] startup;
 reg clip_seen;
 wire ready=(startup==STARTUP_FRAMES);
 assign visual_pcm_ce=frame_ce;assign visual_pcm=ready?dac_sample:16'sd0;
 assign visual_hit=sensor_telem_valid;assign visual_channel=sensor_telem_channel;
 assign visual_velocity=sensor_telem_velocity;assign visual_timbre=selected_timbre;
 assign visual_sustain=sustain_u;assign visual_echo=echo_config[6];

 reset_sync u_reset(.clk(clk),.reset_btn(~reset_n),.rst_n(rst_n));
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin heartbeat<=0;startup<=0;clip_seen<=0;end
 else begin heartbeat<=heartbeat+1'b1;
 if(frame_ce && !ready) startup<=startup+1'b1;
 if(frame_ce && ready && clipped)clip_seen<=1;
 end
 dual_uart_command_rx u_command_rx(.clk(clk),.rst_n(rst_n),
 .wired_rx(uart_rx_pin),.jdy_rx(jdy_rx_pin),.data(rx_byte),
 .tune_valid(tune_rx_valid),.tune_data(tune_rx_data),
 .valid(rx_valid),.framing_error(rx_error),
 .wired_frame_seen(wired_frame_seen),.jdy_frame_seen(jdy_frame_seen),
 .wired_drop(wired_drop),.jdy_drop(jdy_drop),
 .wdy_byte_valid(wdy_rx_valid),.wdy_byte_data(wdy_rx_data),.wdy_framing_error(wdy_rx_error));
 tune_control u_tune(.clk(clk),.rst_n(rst_n),.rx_valid(tune_rx_valid),.rx_data(tune_rx_data),
 .scan_valid(sensor_scan_valid),.raw_hits(sensor_hit_mask),.accepted_hit(sensor_telem_valid),
 .adc_ready(sensor_adc_ready),.calibrated(sensor_calibrated),.cfg(tune_config),.commit(tune_commit),
 .tx_valid(tune_tx_valid),.tx_data(tune_tx_data),.tx_last(tune_tx_last),.tx_ready(tune_tx_ready));
 uart_glide_control u_bend(.clk(clk),.rst_n(rst_n),.enable(ready),
 .byte_valid(rx_valid),.frame_error(rx_error),.byte_data(rx_byte),
 .pass_valid(pass_valid),.cancel(bend_cancel),.pass_data(pass_data),
 .target(uart_bend_target),.error_seen(bend_error));
 generate if(QT_SUSTAIN_ENABLE)begin:g_qt_sustain
 qt_sustain_adapter #(.INVERT_DIRECTION(QT_SUSTAIN_INVERT),.RESET_VALUE(8'd128)) u_qt_sustain(
 .clk(clk),.rst_n(rst_n),.sample_seq(qt_sample_seq),.valid(qt_valid),
 .mode(qt_mode),.error_code(qt_error),.step(qt_step),.sustain_u(sustain_u));
 end else begin:g_no_qt_sustain
 assign sustain_u=8'd128;
 end endgenerate
 qt_key_control u_qt_keys(.clk(clk),.rst_n(rst_n),.sample_seq(qt_sample_seq),
 .keys(qt_keys),.status(qt_status),.mode(qt_mode),.error_code(qt_error),
 .selected_timbre(selected_timbre),.echo_toggle(echo_key_toggle),.press_pulse(key_press_pulse),
 .healthy_out(key_healthy),.synchronized_out(key_synchronized));
 sustain_param_rom u_sustain_rom(.sustain_u(sustain_u),
 .hp_d0(hp_d0),.hp_d1(hp_d1),.hp_d2(hp_d2),.hp_d3(hp_d3),
 .ma_c0(ma_c0),.ma_c1(ma_c1),.ma_c2(ma_c2),.ma_c3(ma_c3),.ks_loss(ks_loss));
 drum_sustain_rom u_drum_sustain_rom(.sustain_u(sustain_u),
 .dr_c0(dr_c0),.dr_c1(dr_c1),.dr_c2(dr_c2),.dr_c3(dr_c3));
 pitch_slew u_slew(.clk(clk),.rst_n(rst_n),.sample_ce(frame_ce),
 .target(uart_bend_target),.ratio(bend_ratio));
 uart_echo_control u_control(.clk(clk),.rst_n(rst_n),.enable(ready && !bend_cancel),.toggle_pulse(echo_key_toggle),
 .byte_valid(pass_valid),.frame_error(rx_error),.byte_data(pass_data),
 .note_valid(note_valid),.note_error(note_error),.note_data(note_data),
 .config_value(echo_config),.control_error(control_error));
 uart_timbre_queue u_events(.clk(clk),.rst_n(rst_n),.enable(ready && !note_error && !bend_cancel),
 .byte_valid(note_valid),.frame_error(rx_error),.byte_data(note_data),
 .event_valid(uart_queue_valid),.event_ready(uart_queue_ready),.phase_step(uart_queue_step),
 .velocity(uart_queue_velocity),.timbre(uart_queue_timbre),.error_seen(error_seen),.received_toggle(received));
 // Optional sensor integration at the event boundary only. Board wrappers
 // keep the original direct UART path unless they explicitly enable this.
 generate if(SENSOR_INPUT_ENABLE)begin:g_sensor_input
 wire sensor_valid,sensor_ready,uart_ready;
 wire [31:0] sensor_step;
 wire [6:0] sensor_velocity;
 wire [2:0] sensor_channel;
 wire [15:0] sensor_peak;
 reg uart_valid;
 reg [40:0] uart_payload;
 // The existing UART parser gates queue valid during cancel/error cycles.
 // A one-entry holding register makes its output a persistent ready/valid
 // source for the arbiter, even if a bend packet cancels a partial command.
 assign uart_queue_ready=ready && (!uart_valid || uart_ready);
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin uart_valid<=0;uart_payload<=0;end
 else if(ready && (!uart_valid || uart_ready))begin
 uart_valid<=uart_queue_valid;
 if(uart_queue_valid)uart_payload<={uart_queue_step,uart_queue_velocity,uart_queue_timbre};
 end
 // Candidate-only insertion. Preserve the original startup policy and keep
 // UART events outside the sensor filter. Legacy users default to bypass.
 wire [7:0] sensor_qualified_mask;
 wire [127:0] sensor_qualified_peaks;
 if(SENSOR_FILTER_ENABLE!=0)begin:g_crosstalk
 sensor_crosstalk_filter #(.DYNAMIC_CONFIG(1),.ENABLE(1),.DECISION_SCANS(SENSOR_FILTER_SCANS),
 .REL_SHIFT(SENSOR_FILTER_SHIFT),.ABS_MIN(256)) u_filter(
 .clk(clk),.rst_n(sensor_config_rst_n),.cfg(tune_config),.adc_ready(ready && sensor_adc_ready),
 .calibrated(sensor_calibrated),.scan_valid(sensor_scan_valid),
 .hit_mask(ready ? sensor_hit_mask : 8'd0),.peaks(sensor_peaks),
 .qualified_hit_mask(sensor_qualified_mask),.qualified_peaks(sensor_qualified_peaks),
 .collecting(),.config_error());
 end else begin:g_crosstalk_bypass
 assign sensor_qualified_mask=ready ? sensor_hit_mask : 8'd0;
 assign sensor_qualified_peaks=sensor_peaks;
 end
 wire [7:0] sensor_late_mask,sensor_late_suppressed;
 wire [127:0] sensor_late_peaks;
 sensor_late_cross_guard #(.DYNAMIC_CONFIG(1),.ENABLE(SENSOR_LATE_GUARD_ENABLE),.HISTORY_SCANS(96),
 .REL_SHIFT(4),.MIN_REFERENCE_PEAK(4096),.MAX_SUPPRESSED_PEAK(1024)) u_late_guard(
 .clk(clk),.rst_n(sensor_config_rst_n),.cfg(tune_config),.adc_ready(ready && sensor_adc_ready),.calibrated(sensor_calibrated),
 .scan_valid(sensor_scan_valid),.hit_mask(sensor_qualified_mask),.peaks(sensor_qualified_peaks),
 .qualified_hit_mask(sensor_late_mask),.qualified_peaks(sensor_late_peaks),
 .suppressed_mask(sensor_late_suppressed),.history_busy(),.config_error());
 // Register the qualification result before the FIFO's wide write enables.
 // This also isolates runtime relative-shift logic from FIFO pop/space logic.
 reg [7:0] sensor_fifo_mask;reg [127:0] sensor_fifo_peaks;
 always @(posedge clk or negedge sensor_config_rst_n)
 if(!sensor_config_rst_n)begin sensor_fifo_mask<=0;sensor_fifo_peaks<=0;end
 else begin sensor_fifo_mask<=sensor_late_mask;sensor_fifo_peaks<=sensor_late_peaks;end
 sensor_event_adapter u_sensor_events(.clk(clk),.rst_n(sensor_config_rst_n),
 .hit_mask(sensor_fifo_mask),.peaks(sensor_fifo_peaks),
 .event_valid(sensor_valid),.event_ready(sensor_ready),
 .event_phase_step(sensor_step),.event_velocity(sensor_velocity),
 .event_channel(sensor_channel),.event_peak(sensor_peak),.dropped_groups(sensor_dropped_groups));
 event_arbiter u_event_arbiter(.clk(clk),.rst_n(sensor_config_rst_n),
 .sensor_valid(sensor_valid),.sensor_phase_step(sensor_step),
 .sensor_velocity(sensor_velocity),.sensor_timbre(selected_timbre),.sensor_ready(sensor_ready),
 .uart_valid(uart_valid),.uart_phase_step(uart_payload[40:9]),
 .uart_velocity(uart_payload[8:2]),.uart_timbre(uart_payload[1:0]),.uart_ready(uart_ready),
 .event_valid(event_valid),.event_ready(event_ready && ready),
 .event_phase_step(step),.event_velocity(velocity),.event_timbre(timbre));
 assign sensor_telem_valid=sensor_valid && sensor_ready;
 assign sensor_telem_channel=sensor_channel;
 assign sensor_telem_velocity=sensor_velocity;
 assign sensor_telem_peak=sensor_peak;
 end else begin:g_uart_only
 assign event_valid=uart_queue_valid;
 assign uart_queue_ready=event_ready;
 assign step=uart_queue_step;
 assign velocity=uart_queue_velocity;
 assign timbre=uart_queue_timbre;
 assign sensor_dropped_groups=32'd0;
 assign sensor_telem_valid=1'b0;
 assign sensor_telem_channel=3'd0;
 assign sensor_telem_velocity=7'd0;
 assign sensor_telem_peak=16'd0;
 end endgenerate
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin sensor_timbre_seen<=0;last_sensor_timbre<=0;end
 else if(sensor_telem_valid)begin sensor_timbre_seen<=1;last_sensor_timbre<=selected_timbre;end
 hybrid_poly #(.VOICES(VOICES),.HANDPAN_PRESET(HANDPAN_PRESET),.HANDPAN_TDM(HANDPAN_TDM),.MODAL_V3(MODAL_V3),.MIX_SHIFT(MIX_SHIFT),.MIX_ROUND(MIX_ROUND)) u_synth(.clk(clk),.rst_n(rst_n),.sample_ce(frame_ce),
 .bend_ratio(bend_ratio),
 .sustain_hp_d0(hp_d0),.sustain_hp_d1(hp_d1),.sustain_hp_d2(hp_d2),.sustain_hp_d3(hp_d3),
 .sustain_ma_c0(ma_c0),.sustain_ma_c1(ma_c1),.sustain_ma_c2(ma_c2),.sustain_ma_c3(ma_c3),.sustain_ks_loss(ks_loss),
 .sustain_dr_c0(dr_c0),.sustain_dr_c1(dr_c1),.sustain_dr_c2(dr_c2),.sustain_dr_c3(dr_c3),
 .event_valid(event_valid),.event_ready(event_ready),.event_phase_step(step),
 .event_velocity(velocity),.event_timbre(timbre),.sample(audio_sample),.active_mask(active),
 .allocated_voice(),.allocated_pulse(allocated),.rejected_pulse(),.stolen_pulse(stolen),
 .bank_overrun(bank_overrun),.pitch_clamped(pitch_clamped),.mixer_clipped(mixer_clipped));
 audio_echo #(.ADDR_BITS(ECHO_ADDR_BITS)) u_echo(.clk(clk),.rst_n(rst_n),.sample_ce(frame_ce),
 .enable(echo_config[6]),.delay_select(echo_config[5:4]),.feedback(echo_config[3:2]),
 .wet(echo_config[1:0]),.sample_in(audio_sample),.sample_out(echo_sample),
 .clipped(echo_clip),.overrun(echo_overrun));
 audio_gain u_gain(.sample_in(echo_sample),.gain_shift(MASTER_GAIN_SHIFT),
 .sample_out(louder_sample),.clipped(gain_clipped));
 generate if(DC_BLOCK_ENABLE)begin:g_dc
 audio_dc_block u_dc(.clk(clk),.rst_n(rst_n),.sample_ce(frame_ce),.sample_in(louder_sample),.sample_out(dac_sample),.clipped(dc_clipped));
 end else begin:g_no_dc
 assign dac_sample=louder_sample;assign dc_clipped=1'b0;
 end endgenerate
 pt8211_tx u_dac(.clk(clk),.rst_n(rst_n),
 .sample_left(ready ? dac_sample : 16'sd0),
 .sample_right(ready ? dac_sample : 16'sd0),
 .bclk(dac_bclk),.ws(dac_ws),.sdata(dac_data),.frame_ce(frame_ce));
 i2s_tx u_i2s(.clk(clk),.rst_n(rst_n),.sample_valid(frame_ce),
 .sample_left(ready ? dac_sample : 16'sd0),
 .sample_right(ready ? dac_sample : 16'sd0),
 .i2s_bclk(i2s_bclk),.i2s_lrclk(i2s_lrclk),.i2s_sdout(i2s_sdout));
 assign pa_en=rst_n && ready;
 performance_telemetry #(.PERIOD(STATUS_PERIOD),.EXT_STATUS(1)) u_status(.clk(clk),.rst_n(rst_n),
 .active_mask(status_mask),.allocated(allocated),.stolen(stolen),
 .note_accepted(event_valid && event_ready),.rx_valid(rx_valid),.rx_error(rx_error),
 .sample_ce(frame_ce && ready),.clipped(clipped),.velocity(velocity),
 .echo_config(echo_config),.bend_ratio(bend_ratio),
 .flags({ready,clip_seen,echo_overrun,echo_clip,bend_error,control_error,error_seen}),
 .extra_flags(telemetry_extra),.tx(uart_tx_pin));
 wire qsu_valid,qsu_last,qsu_ready,hit_valid,hit_last,hit_ready,key_valid,key_last,key_ready,telem_valid,telem_last,telem_ready;
 wire wdy_valid,wdy_last,wdy_ready,wdy_active,wdy_hold;wire [7:0] wdy_data;
 wire [7:0] wdy_cmd_type;wire [63:0] wdy_cmd_id;wire [15:0] wdy_cmd_seq,wdy_cmd_length;
 wire [31:0] wdy_cmd_offset,wdy_rx_errors,wdy_retries;wire [95:0] wdy_cmd_payload;
 wire wdy_cmd_valid;wire [3:0] wdy_state;
 wire [7:0] qsu_data,hit_data,key_data,telem_data;
 wire [31:0] hit_accepted_total,hit_dropped_total;
 qt_sustain_telemetry_source #(.PERIOD(QT_TELEMETRY_PERIOD)) u_qt_telemetry(
 .clk(clk),.rst_n(rst_n),.sustain_u(sustain_u),.enabled(QT_SUSTAIN_ENABLE!=0),
 .qt_sample_seq(qt_sample_seq),.qt_valid(qt_valid),.qt_mode(qt_mode),
 .qt_error(qt_error),.out_valid(qsu_valid),.out_data(qsu_data),.out_last(qsu_last),.out_ready(qsu_ready));
 hit_telemetry #(.DEPTH(16)) u_hit_telemetry(.clk(clk),.rst_n(rst_n),
 .hit_valid(sensor_telem_valid),.hit_channel(sensor_telem_channel),
 .hit_velocity(sensor_telem_velocity),.hit_peak(sensor_telem_peak),
 .out_valid(hit_valid),.out_data(hit_data),.out_last(hit_last),.out_ready(hit_ready),
 .accepted_total(hit_accepted_total),.dropped_total(hit_dropped_total));
 qt_key_telemetry #(.PERIOD(QT_TELEMETRY_PERIOD)) u_key_diag(
 .clk(clk),.rst_n(rst_n),.qt_sample_seq(qt_sample_seq),.qt_keys(qt_keys),
 .qt_status(qt_status),.qt_mode(qt_mode),.qt_error(qt_error),
 .healthy(key_healthy),.synchronized(key_synchronized),.press_pulse(key_press_pulse),
 .selected_timbre(selected_timbre),.echo_enabled(echo_config[6]),
 .sensor_timbre_seen(sensor_timbre_seen),.last_sensor_timbre(last_sensor_timbre),
 .fault_valid(qt_fault_valid),.fault_addr(qt_fault_addr),.fault_expected(qt_fault_expected),
 .fault_actual(qt_fault_actual),.fault_bus_error(qt_fault_bus_error),.fault_state(qt_fault_state),
 .fault_last_reg(qt_fault_last_reg),.fault_last_status(qt_fault_last_status),
 .fault_last_keys(qt_fault_last_keys),.fault_last_position(qt_fault_last_position),
 .nack_count(qt_nack_count),.mismatch_count(qt_mismatch_count),.reinit_count(qt_reinit_count),
 .out_valid(key_valid),.out_data(key_data),.out_last(key_last),.out_ready(key_ready));
 jdy_frame_rx u_wdy_rx(.clk(clk),.rst_n(rst_n),.byte_valid(wdy_rx_valid),
 .framing_error(wdy_rx_error),.byte_data(wdy_rx_data),.cmd_valid(wdy_cmd_valid),
 .cmd_type(wdy_cmd_type),.cmd_id(wdy_cmd_id),.cmd_seq(wdy_cmd_seq),
 .cmd_length(wdy_cmd_length),.cmd_offset(wdy_cmd_offset),.cmd_payload(wdy_cmd_payload),.errors(wdy_rx_errors));
 jdy_block_transport #(.BLOCK_BYTES(64),.RECALIBRATION_ENABLE(SENSOR_INPUT_ENABLE)) u_wdy_transport(.clk(clk),.rst_n(rst_n),
 .stream_valid(wave_stream_valid),.stream_data(wave_stream_data),.stream_ready(wave_stream_ready),
 .stream_complete(wave_stream_complete),.frozen(wave_frozen),.skipped_scans(wave_skipped_scans),
 .capture_arm(wave_capture_arm),.capture_release(wave_capture_release),
 .cmd_valid(wdy_cmd_valid),.cmd_type(wdy_cmd_type),.cmd_id(wdy_cmd_id),.cmd_seq(wdy_cmd_seq),
 .cmd_length(wdy_cmd_length),.cmd_offset(wdy_cmd_offset),.cmd_payload(wdy_cmd_payload),
 .tx_valid(wdy_valid),.tx_data(wdy_data),.tx_last(wdy_last),.tx_ready(wdy_ready),
 .recalibration_adc_ready(sensor_adc_ready),.recalibration_calibrated(sensor_calibrated),.recalibration_request(sensor_recalibrate_req),
 .hold_error(wdy_hold),.active(wdy_active),.retries(wdy_retries),.state(wdy_state));
 telemetry_frame_mux u_telemetry_mux(.clk(clk),.rst_n(rst_n),
 .q_valid(qsu_valid),.q_data(qsu_data),.q_last(qsu_last),.q_ready(qsu_ready),
 .h_valid(hit_valid),.h_data(hit_data),.h_last(hit_last),.h_ready(hit_ready),
 .k_valid(key_valid),.k_data(key_data),.k_last(key_last),.k_ready(key_ready),
 .w_valid(wdy_valid),.w_data(wdy_data),.w_last(wdy_last),.w_ready(wdy_ready),
 // PMR remains live while WDY1 is merely armed/waiting for a trigger.  Once a
 // frozen capture starts transfer, pause only at a complete PMR frame boundary.
 .p_valid(PMR_ENABLE ? pmr_valid : 1'b0),.p_data(pmr_data),.p_last(pmr_last),
 .p_pause(wdy_active && wave_frozen),.p_ready(pmr_ready),
 .out_valid(telem_valid),.out_data(telem_data),.out_last(telem_last),.out_ready(telem_ready));
 wire physical_valid,physical_ready;wire [7:0] physical_data;
 tune_frame_mux u_tune_mux(.clk(clk),.rst_n(rst_n),
 .a_valid(tune_tx_valid),.a_data(tune_tx_data),.a_last(tune_tx_last),.a_ready(tune_tx_ready),
 .b_valid(telem_valid),.b_data(telem_data),.b_last(telem_last),.b_ready(telem_ready),
 .out_valid(physical_valid),.out_data(physical_data),.out_ready(physical_ready));
 jdy_uart_tx u_jdy_tx(.clk(clk),.rst_n(rst_n),.valid(physical_valid),.data(physical_data),.ready(physical_ready),.tx(jdy_tx_pin));
 generate if(VISUAL_LEDS)begin: visual
 performance_leds u_leds(.clk(clk),.rst_n(rst_n),
 .trigger(event_valid && event_ready),.velocity(velocity),.heartbeat(heartbeat[23]),
 .fault(error_seen|control_error|bend_error|clip_seen|echo_clip|echo_overrun|bank_overrun|pitch_clamped),.led_n(led_n));
 end else begin: legacy
 assign led_n=~{error_seen|control_error|bend_error|clip_seen|echo_clip|echo_overrun,active[3:0],heartbeat[23]};
 end endgenerate
endmodule
