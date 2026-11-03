`timescale 1ns/1ps
// Bounded command decoder. Commands carry at most12 payload bytes.
// CRC-32/ISO-HDLC: reflected EDB88320, init/xorout FFFFFFFF (zlib).
module jdy_frame_rx #(parameter integer GAP_CYCLES=10000000)(
 input wire clk,rst_n,byte_valid,framing_error,input wire [7:0] byte_data,
 output reg cmd_valid,output reg [7:0] cmd_type,output reg [63:0] cmd_id,
 output reg [15:0] cmd_seq,cmd_length,output reg [31:0] cmd_offset,
 output reg [95:0] cmd_payload,output reg [31:0] errors);
 reg [7:0] mem[0:33];integer index,length,gap,i;
 reg [31:0] crc,received_crc;
 function automatic [31:0] crc_byte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer k;begin v=c^b;for(k=0;k<8;k=k+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crc_byte=v;end
 endfunction
 function automatic [7:0] magic(input integer n);
  case(n)0:magic="W";1:magic="D";2:magic="Y";default:magic="1";endcase
 endfunction
 always @(posedge clk)begin
  cmd_valid<=0;
  if(!rst_n)begin index<=0;length<=0;gap<=0;crc<=32'hffffffff;received_crc<=0;errors<=0;
   cmd_type<=0;cmd_id<=0;cmd_seq<=0;cmd_length<=0;cmd_offset<=0;cmd_payload<=0;end
  else if(framing_error || (index!=0 && gap>=GAP_CYCLES-1))begin index<=0;gap<=0;crc<=32'hffffffff;errors<=errors+1;end
  else if(byte_valid)begin
   gap<=0;
   if(index<4)begin
    if(byte_data==magic(index))begin mem[index]<=byte_data;crc<=crc_byte(crc,byte_data);index<=index+1;end
    else begin
     index<=(byte_data=="W")?1:0;crc<=(byte_data=="W")?crc_byte(32'hffffffff,byte_data):32'hffffffff;
     if(byte_data=="W")mem[0]<=byte_data;
    end
   end else begin
    if(index<22+length)begin mem[index]<=byte_data;crc<=crc_byte(crc,byte_data);end
    else received_crc[(index-22-length)*8+:8]<=byte_data;
    if(index==17)begin
     if(mem[4]!=1 || byte_data!=0 || mem[16]>12)begin
      index<=0;crc<=32'hffffffff;errors<=errors+1;
     end else begin length<=mem[16];index<=index+1;end
    end else if(index==25+length)begin
     index<=0;crc<=32'hffffffff;
     if({byte_data,received_crc[23:0]}==~crc)begin
      cmd_valid<=1;cmd_type<=mem[5];cmd_length<=length;
      for(i=0;i<8;i=i+1)cmd_id[i*8+:8]<=mem[6+i];
      cmd_seq<={mem[15],mem[14]};cmd_offset<={mem[21],mem[20],mem[19],mem[18]};
      for(i=0;i<12;i=i+1)cmd_payload[i*8+:8]<=(i<length)?mem[22+i]:0;
     end else errors<=errors+1;
    end else index<=index+1;
   end
  end else if(index!=0)gap<=gap+1;
 end
endmodule
