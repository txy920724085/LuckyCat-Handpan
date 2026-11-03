create_clock -name sys_clk -period 20.000 -waveform {0 10} [get_ports {clk}]

// Preserve the stable PT8211 board-output constraints.
set_output_delay -clock [get_clocks {sys_clk}] -max 5.000 [get_ports {dac_bclk dac_ws dac_data}]
set_output_delay -clock [get_clocks {sys_clk}] -min 0.000 [get_ports {dac_bclk dac_ws dac_data}]

// Asynchronous board inputs are synchronized/decoded in the 50 MHz domain.
set_false_path -from [get_ports {reset_n uart_rx_pin jdy_rx_pin ads_sdo}]
set_false_path -to [get_ports {pa_en}]

// Conservative launch-to-pad budget inherited from the teammate's 500 kHz
// ADS8688 project. This is not a complete source-synchronous board model.
set_max_delay 15.000 -to [get_ports {ads_cs_n ads_sclk ads_sdi ads_rst_n}]

create_generated_clock -name serial_clk -source [get_ports {clk}] -multiply_by 63 -divide_by 25 [get_pins {clocks/pll/u_pll/PLL_inst/CLKOUT0}]
create_generated_clock -name pixel_clk -source [get_pins {clocks/pll/u_pll/PLL_inst/CLKOUT0}] -divide_by 5 [get_pins {clocks/div5/CLKOUT}]
// The ONLY audio/video data crossings are the bundled-data handshake bridge,
// true dual-clock waveform RAM and synchronized diagnostic bits. Treat those
// business domains as asynchronous. Pixel <-> serial remains related/timed.
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {pixel_clk serial_clk}]
// PLL lock assertion is asynchronous; reset is released by domain-local pipes.
set_false_path -to [get_pins {pixrst/pipe*_s0/CLEAR sysrst/pipe*_s0/CLEAR clocks/div5/RESETN}]
report_timing -recovery -max_paths 2000
report_timing -removal -max_paths 2000
