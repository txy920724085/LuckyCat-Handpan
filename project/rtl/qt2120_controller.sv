`timescale 1ns/1ps
module qt2120_controller #(
    parameter integer CLK_HZ=50000000, I2C_HZ=100000,
    parameter integer BOOT_MS=300, RESET_WAIT_MS=300,
    parameter integer CAL_TIMEOUT_MS=3000, CAL_POLL_MS=5, POLL_MS=20,
    parameter integer HEALTH_POLLS=50,
    parameter integer HEALTH_RETRIES=3
)(
    input wire clk,rst,scl_pin,sda_pin,
    output wire scl_low,sda_low,
    output reg [7:0] chip_id,firmware,status,position,last_reg,
    output reg [11:0] keys,
    output reg valid,
    output reg [3:0] mode,error_code,
    output reg [31:0] sample_seq,
    output reg signed [9:0] step,
    output reg fault_valid,
    output reg [7:0] fault_addr,fault_expected,fault_actual,fault_last_reg,
    output reg [1:0] fault_bus_error,
    output reg [4:0] fault_state,
    output reg [7:0] fault_last_status,fault_last_position,
    output reg [11:0] fault_last_keys,
    output reg [7:0] nack_count,mismatch_count,reinit_count
);
    reg start, read_cmd;
    reg [7:0] reg_addr,wdata;
    reg [2:0] read_len;
    wire busy,done;
    wire [1:0] bus_error;
    wire [31:0] rdata;
    i2c_register #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ)) master(
        .clk(clk),.rst(rst),.start(start),.read_cmd(read_cmd),.reg_addr(reg_addr),
        .wdata(wdata),.read_len(read_len),.scl_pin(scl_pin),.sda_pin(sda_pin),
        .scl_low(scl_low),.sda_low(sda_low),.busy(busy),.done(done),.error(bus_error),.rdata(rdata));
    reg [4:0] state;
    reg [5:0] cfg_index;
    reg [2:0] health_key;
    reg [1:0] health_retry;
    integer timer,cal_timer,health_count;
    reg saw_cal,have_previous;
    reg [7:0] previous;
    wire signed [9:0] difference=$signed({2'b00,rdata[31:24]})-$signed({2'b00,previous});
    function automatic [7:0] cfg_addr(input [5:0] index);
        if(index<8) cfg_addr=8+index;
        else if(index<20) cfg_addr=8'h1C+index-8;
        else if(index<32) cfg_addr=8'h10+index-20;
        else cfg_addr=8'h28+index-32;
    endfunction
    function automatic [7:0] cfg_value(input [5:0] index);
        if(index<8) begin
            case(index)
            0:cfg_value=1;1:cfg_value=20;2:cfg_value=5;3:cfg_value=4;
            4:cfg_value=255;5:cfg_value=25;6:cfg_value=8'hC0;default:cfg_value=0;
            endcase
        end else if(index<20) cfg_value=(index<11 || index>=15)?0:1;
        else if(index<32) cfg_value=10;
        else cfg_value=0;
    endfunction
    // This task schedules a one-cycle command pulse, not a generated clock.
    task automatic issue(input rd,input [7:0] addr,input [7:0] data,input [2:0] n);
        begin start<=1;read_cmd<=rd;reg_addr<=addr;wdata<=data;read_len<=n;last_reg<=addr;end
    endtask
    task automatic fatal(input [3:0] code,input [3:0] display_mode);
        begin error_code<=code;mode<=display_mode;valid<=0;have_previous<=0;step<=0;keys<=0;state<=31;end
    endtask
    // Preserve the first observed health-check failure for telemetry.  A
    // transient I2C NACK is retried; a persistent bus failure reinitializes the
    // QT controller rather than permanently latching state 31.
    task automatic health_snapshot(input [7:0] expected,input [7:0] actual,input [1:0] berr);
        begin
            if(!fault_valid) begin
                fault_valid<=1;fault_addr<=last_reg;fault_expected<=expected;fault_actual<=actual;
                fault_bus_error<=berr;fault_state<=state;fault_last_reg<=last_reg;
                fault_last_status<=status;fault_last_keys<=keys;fault_last_position<=position;
            end
        end
    endtask
    task automatic health_terminal_snapshot(input [7:0] expected,input [7:0] actual,input [1:0] berr);
        begin
            fault_valid<=1;fault_addr<=last_reg;fault_expected<=expected;fault_actual<=actual;
            fault_bus_error<=berr;fault_state<=state;fault_last_reg<=last_reg;
            fault_last_status<=status;fault_last_keys<=keys;fault_last_position<=position;
        end
    endtask
    task automatic health_recover(input [3:0] code,input [7:0] expected,input [7:0] actual,input [1:0] berr);
        begin
            health_terminal_snapshot(expected,actual,berr);reinit_count<=reinit_count+1'b1;
            error_code<=code;mode<=6;valid<=0;have_previous<=0;step<=0;keys<=0;
            state<=0;cfg_index<=0;health_key<=0;health_retry<=0;
            timer<=0;cal_timer<=0;health_count<=0;saw_cal<=0;
        end
    endtask
    always @(posedge clk) begin
        if(rst) begin
            state<=0;cfg_index<=0;health_key<=0;health_retry<=0;timer<=0;cal_timer<=0;health_count<=0;
            start<=0;read_cmd<=0;reg_addr<=0;wdata<=0;read_len<=1;
            chip_id<=0;firmware<=0;status<=0;position<=0;last_reg<=0;keys<=0;
            valid<=0;mode<=0;error_code<=0;sample_seq<=0;step<=0;
            saw_cal<=0;have_previous<=0;previous<=0;
            fault_valid<=0;fault_addr<=0;fault_expected<=0;fault_actual<=0;fault_bus_error<=0;
            fault_state<=0;fault_last_reg<=0;fault_last_status<=0;fault_last_keys<=0;fault_last_position<=0;
            nack_count<=0;mismatch_count<=0;reinit_count<=0;
        end else begin
            start<=0;
            if(state>=14 && state<=16) cal_timer<=cal_timer+1;
            if(state>=14 && state<=16 && cal_timer>=(CLK_HZ/1000)*CAL_TIMEOUT_MS)
                fatal(5,6);
            else case(state)
            0: if(timer>=(CLK_HZ/1000)*BOOT_MS-1) begin timer<=0;state<=1;end
               else timer<=timer+1;
            1: begin issue(1,0,0,2);state<=2;end
            2: if(done) begin
                if(bus_error!=0) fatal({2'b00,bus_error},6);
                else begin
                    chip_id<=rdata[7:0];firmware<=rdata[15:8];
                    if(rdata[7:0]!=8'h3E) fatal(3,6);else state<=3;
                end
            end
            3: begin issue(0,7,1,1);state<=4;end
            4: if(done) begin
                if(bus_error!=0) fatal({2'b00,bus_error},6);
                else begin timer<=0;state<=5;end
            end
            5: if(timer>=(CLK_HZ/1000)*RESET_WAIT_MS-1) begin timer<=0;state<=6;end
               else timer<=timer+1;
            6: begin issue(1,0,0,2);state<=7;end
            7: if(done) begin
                if(bus_error!=0) fatal({2'b00,bus_error},6);
                else if(rdata[7:0]!=8'h3E) fatal(3,6);
                else begin chip_id<=rdata[7:0];firmware<=rdata[15:8];cfg_index<=0;state<=8;end
            end
            8: begin issue(0,cfg_addr(cfg_index),cfg_value(cfg_index),1);state<=9;end
            9: if(done) begin
                if(bus_error!=0) fatal({2'b00,bus_error},6);else state<=10;
            end
            10: begin issue(1,cfg_addr(cfg_index),0,1);state<=11;end
            11: if(done) begin
                if(bus_error!=0) fatal({2'b00,bus_error},6);
                else if(rdata[7:0]!=cfg_value(cfg_index)) fatal(4,6);
                else if(cfg_index==43) state<=12;
                else begin cfg_index<=cfg_index+1'b1;state<=8;end
            end
            12: begin issue(0,6,1,1);mode<=3;valid<=0;state<=13;end
            13: if(done) begin
                if(bus_error!=0) fatal({2'b00,bus_error},6);
                else begin timer<=0;cal_timer<=0;saw_cal<=0;state<=14;end
            end
            14: if(timer>=(CLK_HZ/1000)*CAL_POLL_MS-1) begin timer<=0;state<=15;end
                else timer<=timer+1;
            15: begin issue(1,2,0,1);state<=16;end
            16: if(done) begin
                if(bus_error!=0) fatal({2'b00,bus_error},6);
                else begin
                    status<=rdata[7:0];
                    if(rdata[7]) begin saw_cal<=1;state<=14;end
                    else if(saw_cal) begin mode<=1;error_code<=0;timer<=0;state<=17;end
                    else state<=14;
                end
            end
            17: if(timer>=(CLK_HZ/1000)*POLL_MS-1) begin timer<=0;state<=18;end
                else timer<=timer+1;
            18: begin issue(1,2,0,4);state<=19;end
            19: if(done) begin
                sample_seq<=sample_seq+1'b1;step<=0;
                if(bus_error!=0) begin
                    error_code<={2'b00,bus_error};mode<=5;valid<=0;status<=0;
                    keys<=0;have_previous<=0;state<=17;
                end else begin
                    error_code<=0;status<=rdata[7:0];keys<=rdata[19:8];position<=rdata[31:24];
                    valid<=rdata[1] && !rdata[7] && !rdata[6];
                    if(rdata[7] || rdata[6] || !rdata[1]) have_previous<=0;
                    if(rdata[7]) mode<=3;
                    else if(rdata[6]) mode<=4;
                    else if(!rdata[1]) mode<=1;
                    else begin
                        mode<=2;
                        if(have_previous) begin
                            if(difference>127) step<=difference-10'sd256;
                            else if(difference < -128) step<=difference+10'sd256;
                            else step<=difference;
                        end
                        previous<=rdata[31:24];have_previous<=1;
                    end
                    if(health_count>=HEALTH_POLLS-1) begin health_count<=0;health_retry<=0;state<=20;end
                    else begin health_count<=health_count+1;state<=17;end
                end
            end
            20: begin issue(1,0,0,1);state<=21;end
            21: if(done) begin
                if(bus_error!=0) begin
                    nack_count<=nack_count+1'b1;health_snapshot(8'h3E,rdata[7:0],bus_error);
                    if(health_retry<HEALTH_RETRIES-1) begin health_retry<=health_retry+1'b1;state<=20;end
                    else health_recover({2'b00,bus_error},8'h3E,rdata[7:0],bus_error);
                end else if(rdata[7:0]!=8'h3E) begin
                    mismatch_count<=mismatch_count+1'b1;health_snapshot(8'h3E,rdata[7:0],0);
                    if(health_retry<HEALTH_RETRIES-1)begin health_retry<=health_retry+1'b1;state<=20;end
                    else health_recover(6,8'h3E,rdata[7:0],0);
                end
                else begin health_retry<=0;state<=22;end
            end
            22: begin issue(1,8,0,1);state<=23;end
            23: if(done) begin
                if(bus_error!=0) begin
                    nack_count<=nack_count+1'b1;health_snapshot(8'h01,rdata[7:0],bus_error);
                    if(health_retry<HEALTH_RETRIES-1) begin health_retry<=health_retry+1'b1;state<=22;end
                    else health_recover({2'b00,bus_error},8'h01,rdata[7:0],bus_error);
                end else if(rdata[7:0]!=1) begin
                    mismatch_count<=mismatch_count+1'b1;health_snapshot(8'h01,rdata[7:0],0);
                    if(health_retry<HEALTH_RETRIES-1)begin health_retry<=health_retry+1'b1;state<=22;end
                    else health_recover(6,8'h01,rdata[7:0],0);
                end
                else begin health_retry<=0;state<=24;end
            end
            24: begin issue(1,14,0,1);state<=25;end
            25: if(done) begin
                if(bus_error!=0) begin
                    nack_count<=nack_count+1'b1;health_snapshot(8'hC0,rdata[7:0],bus_error);
                    if(health_retry<HEALTH_RETRIES-1) begin health_retry<=health_retry+1'b1;state<=24;end
                    else health_recover({2'b00,bus_error},8'hC0,rdata[7:0],bus_error);
                end else if(rdata[7:0]!=8'hC0) begin
                    mismatch_count<=mismatch_count+1'b1;health_snapshot(8'hC0,rdata[7:0],0);
                    if(health_retry<HEALTH_RETRIES-1)begin health_retry<=health_retry+1'b1;state<=24;end
                    else health_recover(6,8'hC0,rdata[7:0],0);
                end
                else begin health_retry<=0;health_key<=0;state<=26;end
            end
            26: begin issue(1,8'h23+health_key,0,1);state<=27;end
            27: if(done)begin
                if(bus_error!=0) begin
                    nack_count<=nack_count+1'b1;health_snapshot(8'h00,rdata[7:0],bus_error);
                    if(health_retry<HEALTH_RETRIES-1) begin health_retry<=health_retry+1'b1;state<=26;end
                    else health_recover({2'b00,bus_error},8'h00,rdata[7:0],bus_error);
                end else if(rdata[7:0]!=0) begin
                    mismatch_count<=mismatch_count+1'b1;health_snapshot(8'h00,rdata[7:0],0);
                    if(health_retry<HEALTH_RETRIES-1)begin health_retry<=health_retry+1'b1;state<=26;end
                    else health_recover(6,8'h00,rdata[7:0],0);
                end
                else if(health_key==4)begin health_retry<=0;state<=17;end
                else begin health_retry<=0;health_key<=health_key+1'b1;state<=26;end
            end
            31: valid<=0; // Latched fatal error; reset only with finger removed.
            default: fatal(6,6);
            endcase
        end
    end
endmodule
