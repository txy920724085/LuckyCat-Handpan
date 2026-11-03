// Independent drum candidate: QT2120 controls persistent Note-On sustain.
// Existing Sustain/Bend RTL and bitstreams remain untouched.
module handpan_sensor_qt_sustain_drum_top #(
 parameter integer QT_SUSTAIN_INVERT=0,
 parameter integer SENSOR_FILTER_ENABLE=1,SENSOR_FILTER_SCANS=16,SENSOR_FILTER_SHIFT=4,
 parameter integer SENSOR_LATE_GUARD_ENABLE=1
)(
 input wire clk,reset_n,uart_rx_pin,jdy_rx_pin,ads_sdo,
 inout wire qt_scl,qt_sda,
 output wire ads_cs_n,ads_sclk,ads_sdi,ads_rst_n,ads_daisy,
 output wire dac_bclk,dac_ws,dac_data,pa_en,uart_tx_pin,jdy_tx_pin
,
 output wire visual_pcm_ce,output wire signed [15:0] visual_pcm,
 output wire visual_hit,output wire [2:0] visual_channel,output wire [6:0] visual_velocity,
 output wire [1:0] visual_timbre,output wire [7:0] visual_sustain,output wire visual_echo
);
 wire rst_n;
 wire qt_scl_low,qt_sda_low,qt_valid;
 wire [7:0] qt_chip_id,qt_firmware,qt_status,qt_position,qt_last_reg;
 wire [11:0] qt_keys;
 wire [3:0] qt_mode,qt_error;
 wire [31:0] qt_sample_seq;
 wire signed [9:0] qt_step;
 wire qt_fault_valid;
 wire [7:0] qt_fault_addr,qt_fault_expected,qt_fault_actual,qt_fault_last_reg;
 wire [1:0] qt_fault_bus_error;wire [4:0] qt_fault_state;
 wire [7:0] qt_fault_last_status,qt_fault_last_position;wire [11:0] qt_fault_last_keys;
 wire [7:0] qt_nack_count,qt_mismatch_count,qt_reinit_count;
 wire [5:0] unused_led_n;
 wire [127:0] unused_samples,unused_peaks;
 wire [7:0] unused_hits;
 wire [31:0] unused_dropped;
 reset_sync u_qt_reset(.clk(clk),.reset_btn(~reset_n),.rst_n(rst_n));
 assign qt_scl=qt_scl_low ? 1'b0 : 1'bz;
 assign qt_sda=qt_sda_low ? 1'b0 : 1'bz;
 qt2120_controller u_qt(
 .clk(clk),.rst(~rst_n),.scl_pin(qt_scl),.sda_pin(qt_sda),
 .scl_low(qt_scl_low),.sda_low(qt_sda_low),.chip_id(qt_chip_id),
 .firmware(qt_firmware),.status(qt_status),.position(qt_position),
 .last_reg(qt_last_reg),.keys(qt_keys),.valid(qt_valid),.mode(qt_mode),
 .error_code(qt_error),.sample_seq(qt_sample_seq),.step(qt_step),
 .fault_valid(qt_fault_valid),.fault_addr(qt_fault_addr),.fault_expected(qt_fault_expected),
 .fault_actual(qt_fault_actual),.fault_bus_error(qt_fault_bus_error),.fault_state(qt_fault_state),
 .fault_last_reg(qt_fault_last_reg),.fault_last_status(qt_fault_last_status),
 .fault_last_keys(qt_fault_last_keys),.fault_last_position(qt_fault_last_position),
 .nack_count(qt_nack_count),.mismatch_count(qt_mismatch_count),.reinit_count(qt_reinit_count));
 ads8688_hybrid_top #(.SENSOR_FILTER_ENABLE(SENSOR_FILTER_ENABLE),
 .SENSOR_LATE_GUARD_ENABLE(SENSOR_LATE_GUARD_ENABLE),.SENSOR_FILTER_SCANS(SENSOR_FILTER_SCANS),.SENSOR_FILTER_SHIFT(SENSOR_FILTER_SHIFT),.QT_SUSTAIN_ENABLE(1),.QT_SUSTAIN_INVERT(QT_SUSTAIN_INVERT)) u_system(
 .visual_pcm_ce(visual_pcm_ce),.visual_pcm(visual_pcm),.visual_hit(visual_hit),
 .visual_channel(visual_channel),.visual_velocity(visual_velocity),.visual_timbre(visual_timbre),
 .visual_sustain(visual_sustain),.visual_echo(visual_echo),
 .clk(clk),.reset_n(reset_n),.uart_rx_pin(uart_rx_pin),.jdy_rx_pin(jdy_rx_pin),.ads_sdo(ads_sdo),
 .ads_cs_n(ads_cs_n),.ads_sclk(ads_sclk),.ads_sdi(ads_sdi),
 .ads_rst_n(ads_rst_n),.ads_daisy(ads_daisy),.led_n(unused_led_n),
 .dac_bclk(dac_bclk),.dac_ws(dac_ws),.dac_data(dac_data),.pa_en(pa_en),
 .uart_tx_pin(uart_tx_pin),.jdy_tx_pin(jdy_tx_pin),.adc_sample_valid(),.adc_ready(),
 .detector_calibrated(),.adc_error(),.adc_samples(unused_samples),
 .peaks(unused_peaks),.hit_mask(unused_hits),.sensor_dropped_groups(unused_dropped),
 .qt_sample_seq(qt_sample_seq),.qt_valid(qt_valid),.qt_mode(qt_mode),
 .qt_error(qt_error),.qt_status(qt_status),.qt_keys(qt_keys),.qt_step(qt_step),
 .qt_fault_valid(qt_fault_valid),.qt_fault_addr(qt_fault_addr),.qt_fault_expected(qt_fault_expected),
 .qt_fault_actual(qt_fault_actual),.qt_fault_bus_error(qt_fault_bus_error),.qt_fault_state(qt_fault_state),
 .qt_fault_last_reg(qt_fault_last_reg),.qt_fault_last_status(qt_fault_last_status),
 .qt_fault_last_keys(qt_fault_last_keys),.qt_fault_last_position(qt_fault_last_position),
 .qt_nack_count(qt_nack_count),.qt_mismatch_count(qt_mismatch_count),.qt_reinit_count(qt_reinit_count));
endmodule

