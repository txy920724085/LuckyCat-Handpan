// Collect complete commands independently on the wired and JDY UARTs, then
// replay one command at a time into the existing command parser. This avoids
// byte interleaving when both links are active. The existing downstream
// checksum/state machines remain the authority for accepting or rejecting a
// command. Wired has arbitration priority; JDY is retained until served.
module dual_uart_command_rx #(
 parameter integer CLK_HZ=50000000,
 parameter integer WIRED_BAUD=115200,
 parameter integer JDY_BAUD=128000
)(
 input wire clk,input wire rst_n,
 input wire wired_rx,input wire jdy_rx,
 output reg [7:0] data,output reg valid,output reg framing_error,
 output reg tune_valid,output reg [7:0] tune_data,
 output reg wired_frame_seen,output reg jdy_frame_seen,
 output reg wired_drop,output reg jdy_drop,
 output reg wdy_byte_valid,output reg [7:0] wdy_byte_data,output reg wdy_framing_error
);
 wire [7:0] wb,jb; wire wv,jv,we,je;
 uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(WIRED_BAUD)) u_wired(
  .clk(clk),.rst_n(rst_n),.rx(wired_rx),.data(wb),.valid(wv),.framing_error(we));
 uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(JDY_BAUD)) u_jdy(
  .clk(clk),.rst_n(rst_n),.rx(jdy_rx),.data(jb),.valid(jv),.framing_error(je));

 reg [7:0] wbuf[0:38],jbuf[0:38];
 reg [5:0] wcount,jcount,wneed,jneed;
 reg [21:0] wtimer,jtimer;
 reg wpending,jpending;
 reg source; // 0 wired, 1 JDY
 reg [5:0] send_index,send_length;
 reg send_tune;
 reg sending;
 reg jdy_wdy; reg [5:0] wdy_index; reg [15:0] wdy_length;

 function [5:0] command_length;
  input [7:0] first;
  begin
   case(first)
    8'hfc: command_length=6'd39;
    8'hf9: command_length=6'd9; // note + velocity + timbre + XOR
    8'hfa: command_length=4'd3; // echo
    8'hfb: command_length=4'd5; // bend
    default: command_length=4'd1; // preserve legacy illegal-byte reporting
   endcase
  end
 endfunction

 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   data<=0;valid<=0;framing_error<=0;tune_valid<=0;tune_data<=0;send_tune<=0;wtimer<=0;jtimer<=0;
   wcount<=0;jcount<=0;wneed<=0;jneed<=0;
   wpending<=0;jpending<=0;sending<=0;source<=0;
   send_index<=0;send_length<=0;
   wired_frame_seen<=0;jdy_frame_seen<=0;wired_drop<=0;jdy_drop<=0;
   wdy_byte_valid<=0;wdy_byte_data<=0;wdy_framing_error<=0;
   jdy_wdy<=0;wdy_index<=0;wdy_length<=0;
  end else begin
   valid<=0;tune_valid<=0;framing_error<=0;wired_frame_seen<=0;
   if(wv || wcount==0)wtimer<=0;else wtimer<=wtimer+1'b1;
   if(jv || jcount==0)jtimer<=0;else jtimer<=jtimer+1'b1;
   if(wtimer>=CLK_HZ/20)begin wcount<=0;wtimer<=0;end
   if(jtimer>=CLK_HZ/20)begin jcount<=0;jtimer<=0;end
   jdy_frame_seen<=0;
   wdy_byte_valid<=0;wdy_framing_error<=0;

   if(we)begin framing_error<=1;wcount<=0;end
   if(je) begin
    if(jdy_wdy) begin wdy_framing_error<=1;jdy_wdy<=0;wdy_index<=0;end
    else begin framing_error<=1;jcount<=0;end
   end

   if(wv) begin
    if(wpending || (sending && !source)) wired_drop<=1;
    else begin
     wbuf[wcount]<=wb;
     if(wcount==0) begin
      wneed<=command_length(wb);
      if(command_length(wb)==1) begin wpending<=1;wcount<=0;wired_frame_seen<=1;end
      else wcount<=1;
     end else if(wcount+1==wneed) begin
      wpending<=1;wcount<=0;wired_frame_seen<=1;
     end else wcount<=wcount+1'b1;
    end
   end
   if(jv && (jdy_wdy || (jcount==0 && jb==8'h57))) begin
    wdy_byte_valid<=1;wdy_byte_data<=jb;
    if(!jdy_wdy) begin jdy_wdy<=1;wdy_index<=1;wdy_length<=0;end
    else begin
     if(wdy_index==16)wdy_length[7:0]<=jb;
     if(wdy_index==17)wdy_length[15:8]<=jb;
     if(wdy_index==25+wdy_length)begin jdy_wdy<=0;wdy_index<=0;end
     else wdy_index<=wdy_index+1'b1;
    end
   end else if(jv) begin
    if(jpending || (sending && source)) jdy_drop<=1;
    else begin
     jbuf[jcount]<=jb;
     if(jcount==0) begin
      jneed<=command_length(jb);
      if(command_length(jb)==1) begin jpending<=1;jcount<=0;jdy_frame_seen<=1;end
      else jcount<=1;
     end else if(jcount+1==jneed) begin
      jpending<=1;jcount<=0;jdy_frame_seen<=1;
     end else jcount<=jcount+1'b1;
    end
   end

   if(!sending) begin
    if(wpending) begin
     sending<=1;source<=0;send_index<=0;send_tune<=(wbuf[0]==8'hfc);send_length<=wneed;wpending<=0;
    end else if(jpending) begin
     sending<=1;source<=1;send_index<=0;send_tune<=(jbuf[0]==8'hfc);send_length<=jneed;jpending<=0;
    end
   end else begin
    if(send_tune)begin tune_data<=source ? jbuf[send_index] : wbuf[send_index];tune_valid<=1;end
    else begin data<=source ? jbuf[send_index] : wbuf[send_index];valid<=1;end
    if(send_index+1==send_length) begin sending<=0;send_index<=0;end
    else send_index<=send_index+1'b1;
   end
  end
 end
endmodule
