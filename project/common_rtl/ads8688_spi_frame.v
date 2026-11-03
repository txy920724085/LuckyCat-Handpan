`timescale 1ns/1ps
// All logic uses the 50 MHz system clock. SCLK is an output, NOT a logic clock.
module ads8688_spi_frame #(parameter integer HALF_CYCLES=5)(
    input wire clk, input wire reset_n, input wire start,
    input wire [31:0] tx_data, input wire frame32, output reg [31:0] rx_data,
    output reg done, output reg cs_n, output reg sclk,
    output reg mosi, input wire miso
);
    // SDO changes after a falling SCLK edge. Capture the PREVIOUS, settled
    // value at each falling event. At 5 MHz the previous SDO bit has a full
    // 200 ns SCLK period before this capture; the 40 ns input pipeline must
    // remain present. FPGA I/O / board delay still needs physical validation.
    (* ASYNC_REG="TRUE" *) reg miso_meta, miso_sync;
    always @(posedge clk) begin
        if(!reset_n) begin miso_meta<=0; miso_sync<=0; end
        else begin miso_meta<=miso; miso_sync<=miso_meta; end
    end
    localparam IDLE=0, SETUP=1, SHIFT=2, HOLD=3, GAP=4;
    reg [2:0] state;
    reg [31:0] divider;
    reg [4:0] bit_index;
    reg [31:0] tx_latch;
    reg [5:0] remaining;
    always @(posedge clk) begin
        if(!reset_n) begin
            state<=IDLE; divider<=0; remaining<=0; bit_index<=31; tx_latch<=0;
            rx_data<=0; done<=0; cs_n<=1; sclk<=0; mosi<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    cs_n<=0; sclk<=0; mosi<=0;
                    tx_latch<=tx_data; rx_data<=0; bit_index<=31;
                    remaining<=frame32 ? 32 : 24;
                    divider<=0; state<=SETUP;
                end
                SETUP: if(divider==HALF_CYCLES-1) begin
                    divider<=0; state<=SHIFT;
                    sclk<=1; mosi<=tx_latch[31];
                end else divider<=divider+1'b1;
                SHIFT: if(divider==HALF_CYCLES-1) begin
                    divider<=0;
                    if(!sclk) begin
                        sclk<=1; mosi<=tx_latch[bit_index];
                    end else begin
                        sclk<=0;
                        rx_data<={rx_data[30:0],miso_sync};
                        remaining<=remaining-1'b1;
                        if(remaining==1) state<=HOLD;
                        else bit_index<=bit_index-1'b1;
                    end
                end else divider<=divider+1'b1;
                HOLD: if(divider==HALF_CYCLES-1) begin
                    divider<=0; cs_n<=1; mosi<=0; state<=GAP;
                end else divider<=divider+1'b1;
                GAP: if(divider==HALF_CYCLES-1) begin
                    divider<=0; done<=1; state<=IDLE;
                end else divider<=divider+1'b1;
                default: begin state<=IDLE; cs_n<=1; sclk<=0; end
            endcase
        end
    end
endmodule
