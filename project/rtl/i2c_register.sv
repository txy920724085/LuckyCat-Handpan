`timescale 1ns/1ps
// QT2120 register transaction: one-byte write or 1..4 byte read.
// rdata[7:0] is the FIRST received byte. Every normal transaction ends in STOP.
module i2c_register #(
    parameter integer CLK_HZ=50000000, I2C_HZ=100000,
    parameter integer TIMEOUT_US=2000
)(
    input wire clk, rst, start, read_cmd,
    input wire [7:0] reg_addr, wdata,
    input wire [2:0] read_len,
    input wire scl_pin, sda_pin,
    output wire scl_low, sda_low,
    output reg busy, done,
    output reg [1:0] error, // 0 OK, 1 NACK, 2 timeout/bus stuck
    output reg [31:0] rdata
);
    (* ASYNC_REG="TRUE" *) reg [1:0] scl_sync, sda_sync;
    always @(posedge clk) begin
        if(rst) begin scl_sync<=3; sda_sync<=3; end
        else begin scl_sync<={scl_sync[0],scl_pin}; sda_sync<={sda_sync[0],sda_pin}; end
    end
    reg bit_go, tx_bit;
    reg [1:0] bit_op;
    wire bit_done, bit_fault, rx_bit;
    i2c_bit #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ),.TIMEOUT_US(TIMEOUT_US)) bit_unit(
        .clk(clk),.rst(rst),.go(bit_go),.op(bit_op),.tx_bit(tx_bit),
        .scl_in(scl_sync[1]),.sda_in(sda_sync[1]),
        .scl_low(scl_low),.sda_low(sda_low),.done(bit_done),.fault(bit_fault),.rx_bit(rx_bit));
    reg [4:0] state;
    reg reading;
    reg [7:0] address, value, byte_out;
    reg [2:0] length, bit_index, byte_index;
    reg [1:0] phase;
    integer free_timer;
    localparam integer LIMIT=(CLK_HZ/1000000)*TIMEOUT_US;
    always @(posedge clk) begin
        if(rst) begin
            state<=0; busy<=0; done<=0; error<=0; rdata<=0;
            bit_go<=0; bit_op<=0; tx_bit<=1; reading<=0; address<=0;
            value<=0; byte_out<=0; length<=1; bit_index<=7;
            byte_index<=0; phase<=0; free_timer<=0;
        end else begin
            bit_go<=0; done<=0;
            case(state)
            0: if(start) begin
                busy<=1; error<=0; rdata<=0; reading<=read_cmd;
                address<=reg_addr; value<=wdata;
                length<=(read_len>=1 && read_len<=4)?read_len:1;
                free_timer<=0; state<=1;
            end
            1: if(scl_sync[1] && sda_sync[1]) state<=2;
               else if(free_timer>=LIMIT) begin error<=2; state<=17; end
               else free_timer<=free_timer+1;
            2: begin bit_op<=0; bit_go<=1; state<=3; end
            3: if(bit_done) begin
                if(bit_fault) begin error<=2; state<=17; end
                else begin byte_out<=8'h38; bit_index<=7; phase<=0; state<=4; end
            end
            4: begin bit_op<=2; tx_bit<=byte_out[bit_index]; bit_go<=1; state<=5; end
            5: if(bit_done) begin
                if(bit_fault) begin error<=2; state<=17; end
                else if(bit_index==0) state<=6;
                else begin bit_index<=bit_index-1'b1; state<=4; end
            end
            6: begin bit_op<=3; bit_go<=1; state<=7; end
            7: if(bit_done) begin
                if(bit_fault) begin error<=2; state<=17; end
                else if(rx_bit) begin error<=1; state<=15; end
                else state<=8;
            end
            8: begin
                bit_index<=7;
                case(phase)
                0: begin byte_out<=address; phase<=1; state<=4; end
                1: if(reading) state<=9;
                   else begin byte_out<=value; phase<=2; state<=4; end
                2: state<=15;
                3: begin byte_index<=0; state<=11; end
                endcase
            end
            9: begin bit_op<=0; bit_go<=1; state<=10; end
            10: if(bit_done) begin
                if(bit_fault) begin error<=2; state<=17; end
                else begin byte_out<=8'h39; phase<=3; bit_index<=7; state<=4; end
            end
            11: begin bit_op<=3; bit_go<=1; state<=12; end
            12: if(bit_done) begin
                if(bit_fault) begin error<=2; state<=17; end
                else begin
                    rdata[byte_index*8+bit_index]<=rx_bit;
                    if(bit_index==0) state<=13;
                    else begin bit_index<=bit_index-1'b1; state<=11; end
                end
            end
            13: begin
                bit_op<=2; tx_bit<=(byte_index==length-1'b1); bit_go<=1; state<=14;
            end
            14: if(bit_done) begin
                if(bit_fault) begin error<=2; state<=17; end
                else if(byte_index==length-1'b1) state<=15;
                else begin byte_index<=byte_index+1'b1; bit_index<=7; state<=11; end
            end
            15: begin bit_op<=1; bit_go<=1; state<=16; end
            16: if(bit_done) begin if(bit_fault) error<=2; state<=17; end
            17: begin busy<=0; done<=1; state<=0; end
            default: state<=0;
            endcase
        end
    end
endmodule
