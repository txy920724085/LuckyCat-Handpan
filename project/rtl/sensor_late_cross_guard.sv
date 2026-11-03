`timescale 1ns/1ps
// Experimental, conditional cross-channel history. No added decision window.
// NOT a physical-hit classifier: very weak intentional cross-channel hits can
// satisfy the same conditions. Recently accepted lanes are exempt.
// Metadata is calculated serially; dense inputs fail open while it is busy.
module sensor_late_cross_guard #(
 parameter integer DYNAMIC_CONFIG=0, ENABLE=0,HISTORY_SCANS=96,REL_SHIFT=4,
 MIN_REFERENCE_PEAK=4096,MAX_SUPPRESSED_PEAK=1024
)(
 input wire clk,rst_n,adc_ready,calibrated,scan_valid,
 input wire [255:0] cfg,
 input wire [7:0] hit_mask,input wire [127:0] peaks,
 output wire [7:0] qualified_hit_mask,
 output wire [127:0] qualified_peaks,
 output wire [7:0] suppressed_mask,
 output wire history_busy,config_error
);
 wire [15:0] history_scans=DYNAMIC_CONFIG?cfg[143:128]:HISTORY_SCANS;
 wire [15:0] min_reference_peak=DYNAMIC_CONFIG?cfg[159:144]:MIN_REFERENCE_PEAK;
 wire [15:0] max_suppressed_peak=DYNAMIC_CONFIG?cfg[175:160]:MAX_SUPPRESSED_PEAK;
 wire [2:0] rel_shift=DYNAMIC_CONFIG?cfg[98:96]:REL_SHIFT;
 wire enabled=DYNAMIC_CONFIG?cfg[193]:ENABLE!=0;
 localparam OK=HISTORY_SCANS>=1 && HISTORY_SCANS<=65535 && REL_SHIFT>=1 && REL_SHIFT<=6 &&
 MIN_REFERENCE_PEAK>=1 && MIN_REFERENCE_PEAK<=65535 && MAX_SUPPRESSED_PEAK>=1 && MAX_SUPPRESSED_PEAK<=65535;
 wire healthy=rst_n && adc_ready && calibrated;
 assign config_error=ENABLE!=0 && !OK;
 generate if((ENABLE==0 && DYNAMIC_CONFIG==0) || !OK)begin:g_bypass
  assign qualified_hit_mask=healthy?hit_mask:8'd0;
  assign qualified_peaks=healthy?peaks:128'd0;
  assign suppressed_mask=0;assign history_busy=0;
 end else begin:g_guard
  reg ref_valid,busy;
  reg [7:0] ref_mask,snapshot_mask;reg [15:0] ref_age,pending_age;
  reg [15:0] ref_peak,maximum,selected_peak;
  reg [127:0] snapshot_peaks;
  reg [3:0] index;
  reg selected_used;
  // Preserve weak repetitions even when another lane replaces the reference.
  reg [7:0] lane_valid;
  reg [127:0] lane_age;
  wire [16:0] lane_effective[0:7];
  wire [7:0] lane_recent;
  wire [16:0] effective_age={1'b0,ref_age}+{16'd0,scan_valid};
  wire [16:0] pending_effective_age={1'b0,pending_age}+{16'd0,scan_valid};
  wire recent=ref_valid && effective_age<history_scans && !busy;
  wire [15:0] max_next=(selected_used && selected_peak>maximum)?selected_peak:maximum;
  reg [7:0] accepted;
  wire [21:0] scaled[0:7];
  for(genvar c=0;c<8;c=c+1)begin:scale
   assign scaled[c]={6'd0,peaks[c*16+:16]}<<rel_shift;
   assign lane_effective[c]={1'b0,lane_age[c*16+:16]}+{16'd0,scan_valid};
   assign lane_recent[c]=lane_valid[c] && lane_effective[c]<history_scans;
  end
  always @*begin
   accepted=healthy?hit_mask:8'd0;
   for(integer c=0;c<8;c=c+1)
    if(recent && !ref_mask[c] && !lane_recent[c] && peaks[c*16+:16]<=max_suppressed_peak && scaled[c]<{6'd0,ref_peak})
     accepted[c]=0;
  end
  // Combinational qualification preserves the original event clock boundary.
  assign qualified_hit_mask=enabled?accepted:(healthy?hit_mask:8'd0);
  assign qualified_peaks=healthy?peaks:128'd0;
  assign suppressed_mask=healthy && enabled?(hit_mask & ~accepted):8'd0;
  assign history_busy=busy;
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)begin
    ref_valid<=0;ref_mask<=0;ref_peak<=0;ref_age<=0;
    busy<=0;snapshot_mask<=0;snapshot_peaks<=0;pending_age<=0;
    maximum<=0;selected_peak<=0;selected_used<=0;index<=0;
    lane_valid<=0;lane_age<={8{16'd65535}};
   end else if(!adc_ready || !calibrated)begin
    ref_valid<=0;ref_mask<=0;ref_peak<=0;ref_age<=0;
    busy<=0;snapshot_mask<=0;snapshot_peaks<=0;pending_age<=0;
    maximum<=0;selected_peak<=0;selected_used<=0;index<=0;
    lane_valid<=0;lane_age<={8{16'd65535}};
   end else begin
    for(integer k=0;k<8;k=k+1)begin
     if(accepted[k])begin lane_valid[k]<=1;lane_age[k*16+:16]<=0;end
     else if(lane_valid[k])begin
      if(lane_effective[k]>=history_scans)begin lane_valid[k]<=0;lane_age[k*16+:16]<=history_scans;end
      else lane_age[k*16+:16]<=lane_effective[k][15:0];
     end
    end
    if(ref_valid)begin
     if(effective_age>=history_scans)begin ref_valid<=0;ref_age<=0;end
     else ref_age<=effective_age[15:0];
    end
    if(|accepted)begin
     // Restart metadata only, never stall/drop an audio input on collision.
     busy<=1;snapshot_mask<=accepted;snapshot_peaks<=peaks;
     pending_age<=0;maximum<=0;selected_used<=0;index<=0;
    end else if(busy)begin
     if(scan_valid && pending_age!=65535)pending_age<=pending_age+1'b1;
     maximum<=max_next;
     if(index<8)begin
      selected_peak<=snapshot_peaks[index*16+:16];selected_used<=snapshot_mask[index];
      index<=index+1'b1;
     end else begin
      selected_used<=0;busy<=0;
      if(max_next>=min_reference_peak && pending_effective_age<history_scans)begin
       ref_valid<=1;ref_peak<=max_next;ref_mask<=snapshot_mask;ref_age<=pending_effective_age[15:0];
      end
     end
    end
   end
  end
 end endgenerate
endmodule
