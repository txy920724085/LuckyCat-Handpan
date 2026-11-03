`timescale 1ns/1ps
// Isolated experiment, NOT instantiated in any board top/build.
// ENABLE=0 is combinational healthy-input bypass. ENABLE=1 collects detector
// hit groups for DECISION_SCANS subsequent scan_valid pulses after first hit.
// Same-channel hits in one bucket merge by maximum (a known fast-repeat limit).
// A three-register pipeline then selects ALL channels satisfying a relative
// amplitude floor; this is not winner-takes-all and not a physical classifier.
// A weak real simultaneous hit below the fraction can also be rejected.
// No downstream backpressure. Collection can restart while prior result drains.
module sensor_crosstalk_filter #(
 parameter integer DYNAMIC_CONFIG=0, ENABLE=0, DECISION_SCANS=16, REL_SHIFT=4, ABS_MIN=256
)(
 input wire clk,rst_n,adc_ready,calibrated,scan_valid,
 input wire [255:0] cfg,
 input wire [7:0] hit_mask,input wire [127:0] peaks,
 output wire [7:0] qualified_hit_mask,
 output wire [127:0] qualified_peaks,
 output wire collecting,output wire config_error
);
 wire [15:0] decision_scans=DYNAMIC_CONFIG?cfg[31:16]:DECISION_SCANS;
 wire [2:0] rel_shift=DYNAMIC_CONFIG?cfg[98:96]:REL_SHIFT;
 wire [15:0] abs_min=DYNAMIC_CONFIG?cfg[127:112]:ABS_MIN;
 wire enabled=DYNAMIC_CONFIG?cfg[192]:ENABLE!=0;
 localparam OK=(DECISION_SCANS>=1 && REL_SHIFT>=1 && REL_SHIFT<=6 && ABS_MIN>=1 && ABS_MIN<=65535);
 generate if(ENABLE==0 && DYNAMIC_CONFIG==0)begin:g_bypass
  assign qualified_hit_mask=(rst_n && adc_ready && calibrated)?hit_mask:8'd0;
  assign qualified_peaks=(rst_n && adc_ready && calibrated)?peaks:128'd0;
  assign collecting=0;assign config_error=0;
 end else begin:g_filter
  localparam CW=DYNAMIC_CONFIG?16:((DECISION_SCANS<2)?1:$clog2(DECISION_SCANS+1));
  reg active;reg [CW-1:0] remaining;
  reg [7:0] acc_mask;reg [127:0] acc_peaks;
  reg [127:0] merged_peaks;wire [7:0] merged_mask=acc_mask|hit_mask;
  reg v1,v2;reg [7:0] m1,m2;reg [127:0] p1,p2;
  reg [15:0] maximum_q;reg [7:0] out_mask;reg [127:0] out_peaks;
  wire close_now=(active && scan_valid && remaining==1) || (enabled && decision_scans==0 && hit_mask!=0);
  wire [15:0] m01=(p1[15:0]>p1[31:16])?p1[15:0]:p1[31:16];
  wire [15:0] m23=(p1[47:32]>p1[63:48])?p1[47:32]:p1[63:48];
  wire [15:0] m45=(p1[79:64]>p1[95:80])?p1[79:64]:p1[95:80];
  wire [15:0] m67=(p1[111:96]>p1[127:112])?p1[111:96]:p1[127:112];
  wire [15:0] m03=(m01>m23)?m01:m23;
  wire [15:0] m47=(m45>m67)?m45:m67;
  wire [15:0] maximum=(m03>m47)?m03:m47;
  wire [21:0] scaled[0:7];
  genvar g;
  for(g=0;g<8;g=g+1)begin:scale
   assign scaled[g]={6'd0,p2[g*16+:16]}<<rel_shift;
  end
  integer c;
  always @*begin
   merged_peaks=acc_peaks;
   for(integer k=0;k<8;k=k+1)if(hit_mask[k])begin
    if(!acc_mask[k] || peaks[k*16+:16]>acc_peaks[k*16+:16])
     merged_peaks[k*16+:16]=peaks[k*16+:16];
   end
  end
  assign collecting=active;assign config_error=!OK;
  assign qualified_hit_mask=!(rst_n && adc_ready && calibrated)?8'd0:
      !enabled?hit_mask:out_mask;
  assign qualified_peaks=enabled?out_peaks:peaks;
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)begin
    active<=0;remaining<=0;acc_mask<=0;acc_peaks<=0;
    v1<=0;v2<=0;m1<=0;m2<=0;p1<=0;p2<=0;maximum_q<=0;out_mask<=0;out_peaks<=0;
   end else if(!adc_ready || !calibrated || !OK)begin
    active<=0;remaining<=0;acc_mask<=0;acc_peaks<=0;
    v1<=0;v2<=0;m1<=0;m2<=0;p1<=0;p2<=0;maximum_q<=0;out_mask<=0;out_peaks<=0;
   end else begin
    out_mask<=0;out_peaks<=0;
    v1<=close_now;v2<=v1;
    if(close_now)begin m1<=merged_mask;p1<=merged_peaks;end
    if(v1)begin m2<=m1;p2<=p1;maximum_q<=maximum;end
    if(v2)for(c=0;c<8;c=c+1)begin
     if(m2[c] && p2[c*16+:16]>=abs_min && scaled[c]>={6'd0,maximum_q})begin
      out_mask[c]<=1;out_peaks[c*16+:16]<=p2[c*16+:16];
     end
    end
    if(close_now)begin
     active<=0;remaining<=0;acc_mask<=0;acc_peaks<=0;
    end else if(active)begin
     acc_mask<=merged_mask;acc_peaks<=merged_peaks;
     if(scan_valid)remaining<=remaining-1'b1;
    end else if(enabled && decision_scans!=0 && hit_mask!=0)begin
     active<=1;remaining<=decision_scans;acc_mask<=hit_mask;
     for(c=0;c<8;c=c+1)acc_peaks[c*16+:16]<=hit_mask[c]?peaks[c*16+:16]:16'd0;
    end
   end
  end
 end endgenerate
endmodule
