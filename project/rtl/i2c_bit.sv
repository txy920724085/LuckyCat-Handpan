`timescale 1ns/1ps
// Single-master open-drain bit operations; all logic uses clk.
// op: 0 START/repeated START, 1 STOP, 2 WRITE bit, 3 READ bit.
module i2c_bit #(
    parameter integer CLK_HZ=50000000, I2C_HZ=100000,
    parameter integer TIMEOUT_US=2000
)(
    input wire clk, rst, go,
    input wire [1:0] op,
    input wire tx_bit, scl_in, sda_in,
    output reg scl_low, sda_low, done, fault, rx_bit
);
    localparam integer HALF=(CLK_HZ/(2*I2C_HZ)<1)?1:CLK_HZ/(2*I2C_HZ);
    localparam integer LIMIT=(CLK_HZ/1000000)*TIMEOUT_US;
    reg [3:0] state;
    reg [1:0] operation;
    integer timer, watchdog;
    always @(posedge clk) begin
        if(rst) begin
            state<=0; timer<=0; watchdog<=0; operation<=0;
            scl_low<=0; sda_low<=0; done<=0; fault<=0; rx_bit<=1;
        end else begin
            done<=0;
            if(state!=0 && watchdog>=LIMIT) begin
                // A stuck clock cannot produce a legal STOP. Release both lines.
                state<=0; scl_low<=0; sda_low<=0; fault<=1; done<=1;
            end else begin
                if(state!=0) watchdog<=watchdog+1;
                case(state)
                0: if(go) begin
                    operation<=op; fault<=0; timer<=0; watchdog<=0;
                    scl_low<=1;
                    if(op==1) sda_low<=1;
                    else if(op==2) sda_low<=~tx_bit;
                    else sda_low<=0;
                    state<=1;
                end
                1: if(timer>=HALF-1) begin
                    timer<=0; scl_low<=0; state<=2;
                end else timer<=timer+1;
                2: if(scl_in) begin timer<=0; state<=3; end
                3: if(timer>=HALF-1) begin
                    timer<=0;
                    if(operation==0) begin sda_low<=1; state<=4; end
                    else if(operation==1) begin sda_low<=0; state<=5; end
                    else begin
                        rx_bit<=sda_in; scl_low<=1; state<=6;
                    end
                end else timer<=timer+1;
                4: if(timer>=HALF-1) begin
                    scl_low<=1; state<=6; timer<=0;
                end else timer<=timer+1;
                5: if(timer>=HALF-1) begin state<=0; done<=1; end
                   else timer<=timer+1;
                6: begin state<=0; done<=1; end
                default: state<=0;
                endcase
            end
        end
    end
endmodule
