`timescale 1ns/1ps
// Based on supplied ADS8688_Auto8. No dependency on UART readiness.
module ads8688_stream #(
 parameter integer SPI_HALF_CYCLES=5, RESET_CYCLES=50000,
 WAKE_CYCLES=1000000, RETRY_CYCLES=10000000, HEALTH_SCANS=2560
)(input wire clk,rst, input wire ads_sdo,
 output wire ads_cs_n,ads_sclk,ads_sdi, output reg ads_rst_n,
 output reg [127:0] samples,output reg valid,ready,
 output reg [3:0] error_code, output reg [31:0] scan_count,
 output reg [7:0] last_register_value, output reg [3:0] state);
 localparam RESET=0,WAKE=1,CFG_SEND=2,CFG_WAIT=3,CHECK_SEND=4,
 CHECK_WAIT=5,AUTO_SEND=6,AUTO_WAIT=7,SAMPLE_SEND=8,SAMPLE_WAIT=9,
 PUBLISH=10,RETRY=11;
 reg [31:0] delay_count,health_count;
 reg [3:0] config_index;
 reg read_phase,check_index,start,frame32;
 reg [2:0] channel;
 reg [31:0] tx_data;
 wire done; wire [31:0] rx_data;
 reg [127:0] working;
 function automatic [6:0] address(input [3:0] n);
  case(n) 0,1,11:address=1;10:address=2;12:address=3;
   default:address=7'h05+n-2;endcase
 endfunction
 function automatic [7:0] value(input [3:0] n);
  case(n) 0:value=8'h55;1:value=8'hAA;10,12:value=0;11:value=8'hFF;
   default:value=1;endcase
 endfunction
 ads8688_spi_frame #(.HALF_CYCLES(SPI_HALF_CYCLES)) spi(
 .clk(clk),.reset_n(~rst),.start(start),.tx_data(tx_data),.frame32(frame32),
 .rx_data(rx_data),.done(done),.cs_n(ads_cs_n),.sclk(ads_sclk),.mosi(ads_sdi),.miso(ads_sdo));
 always @(posedge clk) begin
  if(rst) begin
   state<=RESET;ads_rst_n<=0;delay_count<=0;health_count<=0;
   config_index<=0;read_phase<=0;check_index<=0;start<=0;frame32<=0;
   channel<=0;tx_data<=0;samples<=0;working<=0;valid<=0;ready<=0;
   error_code<=0;scan_count<=0;last_register_value<=0;
  end else begin
   start<=0;valid<=0;
   case(state)
    RESET:begin
     ready<=0;ads_rst_n<=0;
     if(delay_count==RESET_CYCLES-1)begin ads_rst_n<=1;delay_count<=0;state<=WAKE;end
     else delay_count<=delay_count+1;
    end
    WAKE:if(delay_count==WAKE_CYCLES-1)begin
     delay_count<=0;config_index<=0;read_phase<=0;state<=CFG_SEND;
    end else delay_count<=delay_count+1;
    CFG_SEND:begin
     tx_data<={address(config_index),~read_phase,(read_phase?8'h00:value(config_index)),16'h0};
     frame32<=0;start<=1;state<=CFG_WAIT;
    end
    CFG_WAIT:if(done)begin
     last_register_value<=rx_data[7:0];
     if(rx_data[7:0]!=value(config_index))begin ready<=0;error_code<=1;delay_count<=0;state<=RETRY;end
     else if(!read_phase)begin read_phase<=1;state<=CFG_SEND;end
     else if(config_index==12)begin check_index<=0;state<=CHECK_SEND;end
     else begin config_index<=config_index+1;read_phase<=0;state<=CFG_SEND;end
    end
    CHECK_SEND:begin
     tx_data<=check_index?32'h02000000:32'h0A000000;
     frame32<=0;start<=1;state<=CHECK_WAIT;
    end
    CHECK_WAIT:if(done)begin
     last_register_value<=rx_data[7:0];
     if(rx_data[7:0]!=(check_index?8'hFF:8'h01))begin ready<=0;error_code<=2;delay_count<=0;state<=RETRY;end
     else if(!check_index)begin check_index<=1;state<=CHECK_SEND;end
     else begin health_count<=0;state<=AUTO_SEND;end
    end
    AUTO_SEND:begin tx_data<=32'hA0000000;frame32<=1;start<=1;state<=AUTO_WAIT;end
    AUTO_WAIT:if(done)begin channel<=0;state<=SAMPLE_SEND;end
    SAMPLE_SEND:begin tx_data<=0;frame32<=1;start<=1;state<=SAMPLE_WAIT;end
    SAMPLE_WAIT:if(done)begin
     working[channel*16+:16]<=rx_data[15:0];
     if(channel==7)state<=PUBLISH;
     else begin channel<=channel+1;state<=SAMPLE_SEND;end
    end
    PUBLISH:begin
     samples<=working;valid<=1;ready<=1;error_code<=0;scan_count<=scan_count+1;
     channel<=0;
     if(health_count>=HEALTH_SCANS-1)begin check_index<=0;state<=CHECK_SEND;end
     else begin health_count<=health_count+1;state<=SAMPLE_SEND;end
    end
    RETRY:if(delay_count==RETRY_CYCLES-1)begin delay_count<=0;state<=RESET;end
     else delay_count<=delay_count+1;
    default:begin state<=RESET;delay_count<=0;ready<=0;end
   endcase
  end
 end
endmodule
