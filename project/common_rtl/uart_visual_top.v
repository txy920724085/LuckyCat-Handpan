module uart_visual_top(
 input wire clk,reset_n,uart_rx_pin,output wire [5:0] led_n,
 output wire dac_bclk,dac_ws,dac_data,pa_en,uart_tx_pin);
 uart_telemetry_top #(.VISUAL_LEDS(1)) u_core(
 .clk(clk),.reset_n(reset_n),.uart_rx_pin(uart_rx_pin),.led_n(led_n),
 .dac_bclk(dac_bclk),.dac_ws(dac_ws),.dac_data(dac_data),
 .pa_en(pa_en),.uart_tx_pin(uart_tx_pin));
endmodule
