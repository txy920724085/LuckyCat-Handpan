`timescale 1ns/1ps
module knock_detector #(
 parameter integer CAL_SCANS=128, ON_CODES=256, OFF_CODES=128,
 PEAK_SCANS=6, REFRACTORY_SCANS=80, QUIET_SCANS=3,
 RECOVERY_ENABLE=1, RECOVERY_SPAN=256, BASELINE_DECIMATE=1, DYNAMIC_CONFIG=0,
 PIPELINED=0
)(input wire clk,rst,ready,valid,input wire [127:0] samples,
 input wire [255:0] cfg,input wire cfg_commit,
 output reg calibrated, output reg [7:0] hit_mask,active,
 output wire [127:0] baselines,peaks,output wire [255:0] counts);
 integer warmup,i;
 wire [15:0] peak_scans=DYNAMIC_CONFIG?cfg[15:0]:PEAK_SCANS;
 wire [15:0] refractory_scans=DYNAMIC_CONFIG?cfg[47:32]:REFRACTORY_SCANS;
 wire [15:0] quiet_scans=DYNAMIC_CONFIG?cfg[63:48]:QUIET_SCANS;
 wire [15:0] on_codes=DYNAMIC_CONFIG?cfg[79:64]:ON_CODES;
 wire [15:0] off_codes=DYNAMIC_CONFIG?cfg[95:80]:OFF_CODES;
 wire [15:0] baseline_decimate=DYNAMIC_CONFIG?cfg[191:176]:BASELINE_DECIMATE;
 reg [15:0] baseline_div;
 wire baseline_tick=(baseline_div>=baseline_decimate-1);
 wire config_change=DYNAMIC_CONFIG && cfg_commit;
 // Experiment only: atomic all-eight-channel same-direction stable recovery.
 reg [9:0] recover_scans;
 reg [31:0] recover_sum[0:7];
 reg [15:0] recover_min[0:7],recover_max[0:7];
 wire [7:0] blocked,signed_up,span_ok;
 wire eligible_now=(&blocked) && ((&signed_up) || !(|signed_up));
 wire eligible,all_spans_ok;
 wire commit_recovery=RECOVERY_ENABLE!=0 && eligible && all_spans_ok && recover_scans==511 && baseline_tick;

 reg signed [24:0] base_q[0:7];
 reg [15:0] peak[0:7],running_peak[0:7];
 reg [31:0] count[0:7];
 reg [1:0] stage[0:7];
 localparam COUNT_W=DYNAMIC_CONFIG?16:32;
 reg [COUNT_W-1:0] window_count[0:7],refractory[0:7],quiet[0:7];
 wire [15:0] raw[0:7],base_code[0:7],magnitude[0:7];
 wire scan_valid;
 // Board ADC scans are 2665 clocks apart. Three stages break the raw ->
 // absolute difference -> all-channel recovery -> wide clock-enable cone.
 // PIPELINED requires at least four clocks between scans, including after
 // a configuration change. It adds 60 ns at 50 MHz, never an extra scan.
 generate if(PIPELINED)begin:g_pipeline
  reg [2:0] valid_pipe;
  reg [15:0] raw0[0:7],raw1[0:7],raw2[0:7],mag1[0:7],mag2[0:7];
  reg eligible2,spans2;
  wire [7:0] block1,up1,span1;
  for(genvar p=0;p<8;p=p+1)begin:lane
   assign raw[p]=raw2[p];assign magnitude[p]=mag2[p];
   assign block1[p]=stage[p]==3 && mag1[p]>=off_codes;
   assign up1[p]=raw1[p]>=base_code[p];
   assign span1[p]=((raw1[p]>recover_max[p]?raw1[p]:recover_max[p])-
                    (raw1[p]<recover_min[p]?raw1[p]:recover_min[p]))<=RECOVERY_SPAN;
   always @(posedge clk)begin
    raw0[p]<=samples[p*16+:16];raw1[p]<=raw0[p];raw2[p]<=raw1[p];
    mag1[p]<=(raw0[p]>=base_code[p])?raw0[p]-base_code[p]:base_code[p]-raw0[p];
    mag2[p]<=mag1[p];
   end
  end
  always @(posedge clk)begin
   if(rst || !ready || config_change)valid_pipe<=0;
   else valid_pipe<={valid_pipe[1:0],valid};
   eligible2<=(&block1) && ((&up1) || !(|up1));spans2<=&span1;
  end
  assign scan_valid=valid_pipe[2];assign eligible=eligible2;assign all_spans_ok=spans2;
 end else begin:g_direct
  for(genvar p=0;p<8;p=p+1)begin:lane
   assign raw[p]=samples[p*16+:16];
   assign magnitude[p]=(raw[p]>=base_code[p])?raw[p]-base_code[p]:base_code[p]-raw[p];
  end
  assign scan_valid=valid;assign eligible=eligible_now;assign all_spans_ok=&span_ok;
 end endgenerate
 for(genvar r=0;r<8;r=r+1)begin:observe
  assign blocked[r]=stage[r]==3 && magnitude[r]>=off_codes;
  assign signed_up[r]=raw[r]>=base_code[r];
  assign span_ok[r]=((raw[r]>recover_max[r]?raw[r]:recover_max[r])-
                     (raw[r]<recover_min[r]?raw[r]:recover_min[r]))<=RECOVERY_SPAN;
 end

 for(genvar g=0;g<8;g=g+1)begin:ch
  assign base_code[g]=base_q[g][23:8];
  assign baselines[g*16+:16]=base_code[g];
  assign peaks[g*16+:16]=peak[g];
  assign counts[g*32+:32]=count[g];
 end
 always @(posedge clk)begin
  hit_mask<=0;
  if(rst)begin
   calibrated<=0;warmup<=0;active<=0;recover_scans<=0;baseline_div<=0;
   for(i=0;i<8;i=i+1)begin
    base_q[i]<=25'sd8388608;peak[i]<=0;running_peak[i]<=0;count[i]<=0;
    stage[i]<=0;window_count[i]<=0;refractory[i]<=0;quiet[i]<=0;
    recover_sum[i]<=0;recover_min[i]<=0;recover_max[i]<=0;
   end
  end else if(!ready)begin
   calibrated<=0;warmup<=0;active<=0;recover_scans<=0;baseline_div<=0;
   for(i=0;i<8;i=i+1)begin stage[i]<=0;peak[i]<=0;running_peak[i]<=0;quiet[i]<=0;end
  end else if(config_change)begin
   active<=0;recover_scans<=0;baseline_div<=0;
   // Keep baselines and lifetime counters; reset all partial decisions.
   if(!calibrated)warmup<=0;
   for(i=0;i<8;i=i+1)begin
    stage[i]<=0;window_count[i]<=0;refractory[i]<=0;quiet[i]<=0;running_peak[i]<=0;
   end
  end else if(scan_valid)begin
   if(baseline_tick)baseline_div<=0;else baseline_div<=baseline_div+1'b1;
   if(!calibrated)begin
    if(baseline_tick)begin
    for(i=0;i<8;i=i+1)begin
     if(warmup==0)base_q[i]<=$signed({1'b0,raw[i],8'h00});
     else base_q[i]<=base_q[i]+(($signed({1'b0,raw[i],8'h00})-base_q[i])>>>4);
    end
    if(warmup>=CAL_SCANS-1)calibrated<=1;
    else warmup<=warmup+1;
    end
   end else begin
    if(RECOVERY_ENABLE==0 || !eligible)recover_scans<=0;
    else if(baseline_tick)begin
    if(recover_scans==0 || !all_spans_ok)begin
     recover_scans<=1;
     for(integer j=0;j<8;j=j+1)begin
      recover_sum[j]<={16'd0,raw[j]};recover_min[j]<=raw[j];recover_max[j]<=raw[j];
     end
    end else if(commit_recovery)recover_scans<=0;
    else begin
     recover_scans<=recover_scans+1'b1;
     for(integer j=0;j<8;j=j+1)begin
      recover_sum[j]<=recover_sum[j]+{16'd0,raw[j]};
      if(raw[j]<recover_min[j])recover_min[j]<=raw[j];
      if(raw[j]>recover_max[j])recover_max[j]<=raw[j];
     end
    end
    end
    for(i=0;i<8;i=i+1)begin
    case(stage[i])
     0:begin
      active[i]<=0;
      if(magnitude[i]>=on_codes && peak_scans==1)begin
       peak[i]<=magnitude[i];hit_mask[i]<=1;count[i]<=count[i]+1;
       refractory[i]<=0;quiet[i]<=0;stage[i]<=2;
      end else if(magnitude[i]>=on_codes)begin
       running_peak[i]<=magnitude[i];window_count[i]<=1;active[i]<=1;stage[i]<=1;
      end else if(magnitude[i]<off_codes && baseline_tick)
       base_q[i]<=base_q[i]+(($signed({1'b0,raw[i],8'h00})-base_q[i])>>>8);
     end
     1:begin
      if(magnitude[i]>running_peak[i])running_peak[i]<=magnitude[i];
      if(window_count[i]>=peak_scans-1)begin
       peak[i]<=(magnitude[i]>running_peak[i])?magnitude[i]:running_peak[i];
       hit_mask[i]<=1;count[i]<=count[i]+1;active[i]<=0;
       refractory[i]<=0;quiet[i]<=0;stage[i]<=2;
      end else window_count[i]<=window_count[i]+1;
     end
     2:begin
      if(refractory[i]>=refractory_scans-1)begin quiet[i]<=0;stage[i]<=3;end
      else refractory[i]<=refractory[i]+1;
     end
     3:begin
      if(commit_recovery)begin
       base_q[i]<=$signed((recover_sum[i]+{16'd0,raw[i]})>>1);
       quiet[i]<=0;
      end else if(magnitude[i]<off_codes)begin
       if(quiet[i]>=quiet_scans-1)begin stage[i]<=0;quiet[i]<=0;end
       else quiet[i]<=quiet[i]+1;
      end else quiet[i]<=0;
     end
    endcase
   end
   end
  end
 end
endmodule

