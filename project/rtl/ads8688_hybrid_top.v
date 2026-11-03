// Logical integration wrapper, not a pin-assigned board build.
// Imports the teammate's ADC/detector unchanged and keeps the Stage20B audio
// subsystem as a child instance. No touch controller is included.
module ads8688_hybrid_top #(
 parameter integer STARTUP_FRAMES=4883,VOICES=32,ECHO_ADDR_BITS=14,
 ADC_SPI_HALF_CYCLES=5,ADC_RESET_CYCLES=50000,ADC_WAKE_CYCLES=1000000,
 ADC_RETRY_CYCLES=10000000,ADC_HEALTH_SCANS=2560,
 CAL_SCANS=128,PEAK_SCANS=51,REFRACTORY_SCANS=800,QUIET_SCANS=30,
 QT_SUSTAIN_ENABLE=0,QT_SUSTAIN_INVERT=0,
 SENSOR_FILTER_ENABLE=1,SENSOR_FILTER_SCANS=16,SENSOR_FILTER_SHIFT=4,SENSOR_LATE_GUARD_ENABLE=0
)(
 input wire clk,reset_n,uart_rx_pin,jdy_rx_pin,ads_sdo,
 output wire ads_cs_n,ads_sclk,ads_sdi,ads_rst_n,ads_daisy,
 output wire [5:0] led_n,
 output wire dac_bclk,dac_ws,dac_data,pa_en,uart_tx_pin,jdy_tx_pin,
 output wire adc_sample_valid,adc_ready,detector_calibrated,
 output wire [3:0] adc_error,
 output wire [127:0] adc_samples,peaks,
 output wire [7:0] hit_mask,
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
 output wire [31:0] sensor_dropped_groups
,
 output wire visual_pcm_ce,output wire signed [15:0] visual_pcm,
 output wire visual_hit,output wire [2:0] visual_channel,output wire [6:0] visual_velocity,
 output wire [1:0] visual_timbre,output wire [7:0] visual_sustain,output wire visual_echo
);
 wire rst_n;
 wire [255:0] tune_config; wire tune_commit;
 reg [3:0] monitor_div;
 wire monitor_valid=adc_sample_valid && monitor_div==0;
 always @(posedge clk) if(!rst_n)monitor_div<=0;
 else if(adc_sample_valid)monitor_div<=(monitor_div==9)?0:monitor_div+1'b1;
 wire detector_recalibrate_req;
 wire [31:0] adc_scan_count;
 wire [7:0] adc_last_register;
 wire [3:0] adc_state;
 wire [127:0] baselines;
 wire [255:0] counts;
 wire [7:0] detector_active;
 wire pmr_valid,pmr_last,pmr_ready;wire [7:0] pmr_data;
 wire wave_valid,wave_ready,wave_complete,wave_frozen,wave_arm,wave_release;
 wire [7:0] wave_data;wire [31:0] wave_skipped;
 wire [31:0] pmr_dropped,pmr_completed;wire pmr_scan_overrun;
 reset_sync u_sensor_reset(.clk(clk),.reset_btn(~reset_n),.rst_n(rst_n));
 assign ads_daisy=1'b0;

 ads8688_stream #(.SPI_HALF_CYCLES(ADC_SPI_HALF_CYCLES),
 .RESET_CYCLES(ADC_RESET_CYCLES),.WAKE_CYCLES(ADC_WAKE_CYCLES),
 .RETRY_CYCLES(ADC_RETRY_CYCLES),.HEALTH_SCANS(ADC_HEALTH_SCANS)) u_adc(
 .clk(clk),.rst(~rst_n),.ads_sdo(ads_sdo),.ads_cs_n(ads_cs_n),
 .ads_sclk(ads_sclk),.ads_sdi(ads_sdi),.ads_rst_n(ads_rst_n),
 .samples(adc_samples),.valid(adc_sample_valid),.ready(adc_ready),
 .error_code(adc_error),.scan_count(adc_scan_count),
 .last_register_value(adc_last_register),.state(adc_state));

 knock_detector #(.PIPELINED(1),.DYNAMIC_CONFIG(1),.BASELINE_DECIMATE(10),.CAL_SCANS(CAL_SCANS),.PEAK_SCANS(PEAK_SCANS),
 .REFRACTORY_SCANS(REFRACTORY_SCANS),.QUIET_SCANS(QUIET_SCANS)) u_detector(
 .clk(clk),.cfg(tune_config),.cfg_commit(tune_commit),.rst(~rst_n),.ready(adc_ready && !detector_recalibrate_req),.valid(adc_sample_valid),.samples(adc_samples),
 .calibrated(detector_calibrated),.hit_mask(hit_mask),.active(detector_active),
 .baselines(baselines),.peaks(peaks),.counts(counts));

 // Passive scan observer. At scan_valid, samples and the combinational
 // baseline outputs both refer to the detector's pre-update baseline state.
 pmr1_telemetry #(.WINDOW_SCANS(128),.SNAPSHOT_DEPTH(2)) u_pmr1(
 .clk(clk),.rst_n(rst_n),.scan_valid(monitor_valid),.scan_count(adc_scan_count),
 .samples(adc_samples),.baselines(baselines),.adc_ready(adc_ready),
 .calibrated(detector_calibrated),.adc_error(adc_error),
 .out_valid(pmr_valid),.out_data(pmr_data),.out_last(pmr_last),.out_ready(pmr_ready),
 .dropped_windows(pmr_dropped),.completed_windows(pmr_completed),.scan_overrun(pmr_scan_overrun));

 sensor_diag_capture_jdy31 #(.DIAG_MODE(1),.CAPTURE_DEPTH(1024),
 .PRE_TRIGGER_SCANS(512),.POST_TRIGGER_SCANS(512),.CAPTURE_TRIGGER(128)) u_wave_capture(
 .clk(clk),.rst_n(rst_n),.capture_arm(wave_arm),.capture_release(wave_release),
 .frozen(wave_frozen),.stream_complete(wave_complete),.skipped_scans(wave_skipped),
 .scan_valid(adc_sample_valid),.adc_ready(adc_ready),.calibrated(detector_calibrated),
 .adc_error(adc_error),.scan_count(adc_scan_count),.samples(adc_samples),.baselines(baselines),
 .peaks(peaks),.hit_mask(hit_mask),.active(detector_active),
 .tx_valid(wave_valid),.tx_data(wave_data),.tx_ready(wave_ready));

 uart_hybrid_top #(.STARTUP_FRAMES(STARTUP_FRAMES),.VOICES(VOICES),
 .ECHO_ADDR_BITS(ECHO_ADDR_BITS),.AUDIO_NUMERIC_MODE(1),
 .HANDPAN_TDM(1),.MODAL_V3(1),.DC_BLOCK_ENABLE(1),.SENSOR_INPUT_ENABLE(1),
 .PMR_ENABLE(1),.SENSOR_FILTER_ENABLE(SENSOR_FILTER_ENABLE),
 .SENSOR_LATE_GUARD_ENABLE(SENSOR_LATE_GUARD_ENABLE),.SENSOR_FILTER_SCANS(SENSOR_FILTER_SCANS),.SENSOR_FILTER_SHIFT(SENSOR_FILTER_SHIFT),
 .QT_SUSTAIN_ENABLE(QT_SUSTAIN_ENABLE),.QT_SUSTAIN_INVERT(QT_SUSTAIN_INVERT)) u_audio(
 .visual_pcm_ce(visual_pcm_ce),.visual_pcm(visual_pcm),.visual_hit(visual_hit),
 .visual_channel(visual_channel),.visual_velocity(visual_velocity),.visual_timbre(visual_timbre),
 .visual_sustain(visual_sustain),.visual_echo(visual_echo),
 .tune_config(tune_config),.tune_commit(tune_commit),
 .clk(clk),.reset_n(reset_n),.uart_rx_pin(uart_rx_pin),.jdy_rx_pin(jdy_rx_pin),.led_n(led_n),
 .dac_bclk(dac_bclk),.dac_ws(dac_ws),.dac_data(dac_data),.pa_en(pa_en),.uart_tx_pin(uart_tx_pin),.jdy_tx_pin(jdy_tx_pin),
 .i2s_bclk(),.i2s_lrclk(),.i2s_sdout(),
 .sensor_hit_mask((adc_ready && detector_calibrated) ? hit_mask : 8'd0),
 .sensor_recalibrate_req(detector_recalibrate_req),
 .sensor_peaks(peaks),.sensor_scan_valid(adc_sample_valid),.sensor_adc_ready(adc_ready),
 .sensor_calibrated(detector_calibrated),.sensor_adc_error(adc_error),
 .qt_sample_seq(qt_sample_seq),.qt_valid(qt_valid),.qt_mode(qt_mode),
 .qt_error(qt_error),.qt_status(qt_status),.qt_keys(qt_keys),.qt_step(qt_step),
 .qt_fault_valid(qt_fault_valid),.qt_fault_addr(qt_fault_addr),.qt_fault_expected(qt_fault_expected),
 .qt_fault_actual(qt_fault_actual),.qt_fault_bus_error(qt_fault_bus_error),.qt_fault_state(qt_fault_state),
 .qt_fault_last_reg(qt_fault_last_reg),.qt_fault_last_status(qt_fault_last_status),
 .qt_fault_last_keys(qt_fault_last_keys),.qt_fault_last_position(qt_fault_last_position),
 .qt_nack_count(qt_nack_count),.qt_mismatch_count(qt_mismatch_count),.qt_reinit_count(qt_reinit_count),
 .pmr_valid(pmr_valid),.pmr_data(pmr_data),.pmr_last(pmr_last),.pmr_ready(pmr_ready),
 .wave_stream_valid(wave_valid),.wave_stream_data(wave_data),.wave_stream_complete(wave_complete),
 .wave_frozen(wave_frozen),.wave_skipped_scans(wave_skipped),.wave_stream_ready(wave_ready),
 .wave_capture_arm(wave_arm),.wave_capture_release(wave_release),
 .sensor_dropped_groups(sensor_dropped_groups));
endmodule
