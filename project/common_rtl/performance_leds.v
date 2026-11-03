// Four-level velocity flash with independent visual decay; not an audio envelope meter.
module performance_leds #(parameter integer TICK_CYCLES=200000)(
 input wire clk,rst_n,trigger,input wire [6:0] velocity,
 input wire heartbeat,fault,output wire [5:0] led_n);
 reg [31:0] tick;
 reg [6:0] level;
 wire [3:0] bar={level>=96,level>=64,level>=32,level!=0};
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin tick<=0;level<=0;end
 else if(trigger)begin level<=velocity;tick<=0;end
 else if(tick==TICK_CYCLES-1)begin
 tick<=0;if(level!=0)level<=level-1'b1;
 end else tick<=tick+1'b1;
 assign led_n=rst_n ? ~{fault,bar,heartbeat} : 6'b111111;
endmodule
