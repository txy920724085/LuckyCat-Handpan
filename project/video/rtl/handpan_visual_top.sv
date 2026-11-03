module handpan_visual_top(
 input wire clk,reset_n,uart_rx_pin,jdy_rx_pin,ads_sdo,
 inout wire qt_scl,qt_sda,
 output wire ads_cs_n,ads_sclk,ads_sdi,ads_rst_n,ads_daisy,
 output wire dac_bclk,dac_ws,dac_data,pa_en,uart_tx_pin,jdy_tx_pin,
 output wire tmds_clk_p,tmds_clk_n,output wire [2:0] tmds_d_p,tmds_d_n,
 output wire [5:0] led_n);
 wire pcm_ce,hit,echo;
 wire signed [15:0] pcm;
 wire [2:0] channel;
 wire [6:0] velocity;
 wire [1:0] timbre;
 wire [7:0] sustain;
 handpan_sensor_qt_sustain_drum_top instrument(
 .clk(clk),.reset_n(reset_n),.uart_rx_pin(uart_rx_pin),.jdy_rx_pin(jdy_rx_pin),.ads_sdo(ads_sdo),
 .qt_scl(qt_scl),.qt_sda(qt_sda),.ads_cs_n(ads_cs_n),.ads_sclk(ads_sclk),.ads_sdi(ads_sdi),
 .ads_rst_n(ads_rst_n),.ads_daisy(ads_daisy),.dac_bclk(dac_bclk),.dac_ws(dac_ws),.dac_data(dac_data),
 .pa_en(pa_en),.uart_tx_pin(uart_tx_pin),.jdy_tx_pin(jdy_tx_pin),
 .visual_pcm_ce(pcm_ce),.visual_pcm(pcm),.visual_hit(hit),.visual_channel(channel),.visual_velocity(velocity),
 .visual_timbre(timbre),.visual_sustain(sustain),.visual_echo(echo));
 wire pixel_clk,serial_clk,locked,sys_rst_n,pix_rst_n;
 video_clocks clocks(.clk50(clk),.reset_n(reset_n),.pixel_clk(pixel_clk),.serial_clk(serial_clk),.locked(locked));
 visual_reset_sync sysrst(.clk(clk),.async_reset_n(reset_n && locked),.reset_n(sys_rst_n));
 visual_reset_sync pixrst(.clk(pixel_clk),.async_reset_n(reset_n && locked),.reset_n(pix_rst_n));
 wire [11:0] x,y;
 wire hs,vs,de,frame_start;wire [31:0] frames;
 video_timing timing(.pixel_clk(pixel_clk),.reset_n(pix_rst_n),.x(x),.y(y),.hs(hs),.vs(vs),.de(de),.frame_start(frame_start),.frame_count(frames));
 reg [19:0] live_counter;
 reg [22:0] analysis_counter;
 wire live_tick=live_counter==999999;
 reg [63:0] envelopes;
 integer c;
 reg hit_q;reg [2:0] channel_q;reg [7:0] strength;
 always @(posedge clk or negedge sys_rst_n)
 if(!sys_rst_n)begin hit_q<=0;channel_q<=0;strength<=0;end
 else begin hit_q<=hit;channel_q<=channel;strength<={velocity,velocity[6]};end
 always @(posedge clk or negedge sys_rst_n)
 if(!sys_rst_n)begin live_counter<=0;envelopes<=0;end
 else begin
  live_counter<=live_tick?0:live_counter+1'b1;
  if(live_tick)for(c=0;c<8;c=c+1)
   envelopes[c*8+:8]<=(envelopes[c*8+:8]>8)?envelopes[c*8+:8]-8'd8:8'd0;
  if(hit_q && strength>envelopes[channel_q*8+:8])envelopes[channel_q*8+:8]<=strength;
 end
 wire fft_busy,fft_done,frame_busy;
 reg fft_start,frame_send;
 reg [31:0] capture_id;
 wire [255:0] fft_spectrum;
 wire wave_we;wire [7:0] wave_addr;
 wire signed [15:0] wave_min,wave_max;
 wire [31:0] capture_overrun;wire arithmetic_clip;
 always @(posedge clk or negedge sys_rst_n)
 if(!sys_rst_n)begin analysis_counter<=0;fft_start<=0;frame_send<=0;capture_id<=0;end
 else begin
  fft_start<=0;frame_send<=fft_done;
  if(analysis_counter<4999999)analysis_counter<=analysis_counter+1'b1;
  else if(!fft_busy && !frame_busy && !frame_send && !fft_done)begin
   analysis_counter<=0;fft_start<=1;capture_id<=capture_id+1'b1;
  end
 end
 pcm_fft_visual analyzer(.clk(clk),.rst_n(sys_rst_n),.start(fft_start),.pcm_ce(pcm_ce),.pcm(pcm),
 .busy(fft_busy),.done(fft_done),.wave_we(wave_we),.wave_addr(wave_addr),.wave_min(wave_min),.wave_max(wave_max),
 .spectrum(fft_spectrum),.capture_overrun(capture_overrun),.arithmetic_clip(arithmetic_clip));
 wire pressure_valid,spectrum_valid,wave_wr_en,wave_publish,wave_ready,controls_valid,display_ready;
 wire [63:0] pressure_levels;wire [255:0] spectrum_levels;
 wire [7:0] wave_wr_addr;wire signed [15:0] wave_wr_min,wave_wr_max;
 wire [1:0] display_timbre;wire [6:0] display_sustain;wire display_echo;
 wire [31:0] committed_id;
 visual_bridge bridge(.sys_clk(clk),.sys_rst_n(sys_rst_n),.pixel_clk(pixel_clk),.pix_rst_n(pix_rst_n),
 .live_send(live_tick),.live_data({echo,sustain[7:1],timbre,envelopes}),
 .frame_send(frame_send),.frame_spectrum(fft_spectrum),.frame_id(capture_id),.frame_busy(frame_busy),
 .wave_we(wave_we),.wave_addr(wave_addr),.wave_min(wave_min),.wave_max(wave_max),
 .wave_ready(wave_ready),.frame_start(frame_start),.video_de(de),
 .pressure_valid(pressure_valid),.pressure_levels(pressure_levels),.controls_valid(controls_valid),
 .timbre(display_timbre),.sustain(display_sustain),.echo_enabled(display_echo),
 .spectrum_valid(spectrum_valid),.spectrum_levels(spectrum_levels),.wave_wr_en(wave_wr_en),.wave_wr_addr(wave_wr_addr),
 .wave_wr_min(wave_wr_min),.wave_wr_max(wave_wr_max),.wave_publish(wave_publish),.committed_id(committed_id));
 wire [23:0] rgb;wire hs_out,vs_out,de_out;
 music_visualizer #(.WAVE_GAIN_SHIFT(3)) display(.pixel_clk(pixel_clk),.reset_n(pix_rst_n),.wide_panel(1'b1),.x(x),.y(y),
 .hs(hs),.vs(vs),.de(de),.frame_start(frame_start),.pressure_valid(pressure_valid),.pressure_levels(pressure_levels),
 .spectrum_valid(spectrum_valid),.spectrum_levels(spectrum_levels),.wave_wr_en(wave_wr_en),.wave_wr_addr(wave_wr_addr),
 .wave_wr_min(wave_wr_min),.wave_wr_max(wave_wr_max),.wave_publish(wave_publish),.wave_ready(wave_ready),
 .controls_valid(controls_valid),.timbre(display_timbre),.sustain(display_sustain),.echo_enabled(display_echo),
 .rgb(rgb),.hs_out(hs_out),.vs_out(vs_out),.de_out(de_out),.display_ready(display_ready));
 dvi_output #(.RESET_STAGES(6)) output_video(.pixel_clk(pixel_clk),.serial_clk(serial_clk),.reset_n(pix_rst_n),
 .hs(hs_out),.vs(vs_out),.de(de_out),.rgb(rgb),.tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),.tmds_d_p(tmds_d_p),.tmds_d_n(tmds_d_n));
 reg [25:0] heartbeat;
 (* ASYNC_REG="TRUE",syn_preserve=1 *) reg [1:0] frame_sync,ready_sync;
 always @(posedge clk or negedge sys_rst_n)
 if(!sys_rst_n)begin heartbeat<=0;frame_sync<=0;ready_sync<=0;end
 else begin heartbeat<=heartbeat+1'b1;frame_sync<={frame_sync[0],frames[5]};ready_sync<={ready_sync[0],display_ready};end
 assign led_n=~{(capture_overrun!=0)||arithmetic_clip,pa_en,ready_sync[1],frame_sync[1],locked,heartbeat[24]};
endmodule
