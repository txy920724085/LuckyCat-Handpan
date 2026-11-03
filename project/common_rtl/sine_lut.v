// Quarter-wave ROM generated from round(2047*sin(pi*i/128)), i=0..64.
// First lesson: 256 phase points, intentionally modest amplitude.
module sine_lut (input wire [7:0] phase_index, output wire signed [15:0] sample);
    wire [6:0] table_index = phase_index[6] ? (7'd64 - {1'b0,phase_index[5:0]})
                                                : {1'b0,phase_index[5:0]};
    reg signed [15:0] magnitude;
    always @* begin
        case (table_index)
            7'd0: magnitude = 16'sd0;
            7'd1: magnitude = 16'sd50;
            7'd2: magnitude = 16'sd100;
            7'd3: magnitude = 16'sd151;
            7'd4: magnitude = 16'sd201;
            7'd5: magnitude = 16'sd251;
            7'd6: magnitude = 16'sd300;
            7'd7: magnitude = 16'sd350;
            7'd8: magnitude = 16'sd399;
            7'd9: magnitude = 16'sd449;
            7'd10: magnitude = 16'sd497;
            7'd11: magnitude = 16'sd546;
            7'd12: magnitude = 16'sd594;
            7'd13: magnitude = 16'sd642;
            7'd14: magnitude = 16'sd690;
            7'd15: magnitude = 16'sd737;
            7'd16: magnitude = 16'sd783;
            7'd17: magnitude = 16'sd830;
            7'd18: magnitude = 16'sd875;
            7'd19: magnitude = 16'sd920;
            7'd20: magnitude = 16'sd965;
            7'd21: magnitude = 16'sd1009;
            7'd22: magnitude = 16'sd1052;
            7'd23: magnitude = 16'sd1095;
            7'd24: magnitude = 16'sd1137;
            7'd25: magnitude = 16'sd1179;
            7'd26: magnitude = 16'sd1219;
            7'd27: magnitude = 16'sd1259;
            7'd28: magnitude = 16'sd1299;
            7'd29: magnitude = 16'sd1337;
            7'd30: magnitude = 16'sd1375;
            7'd31: magnitude = 16'sd1411;
            7'd32: magnitude = 16'sd1447;
            7'd33: magnitude = 16'sd1483;
            7'd34: magnitude = 16'sd1517;
            7'd35: magnitude = 16'sd1550;
            7'd36: magnitude = 16'sd1582;
            7'd37: magnitude = 16'sd1614;
            7'd38: magnitude = 16'sd1644;
            7'd39: magnitude = 16'sd1674;
            7'd40: magnitude = 16'sd1702;
            7'd41: magnitude = 16'sd1729;
            7'd42: magnitude = 16'sd1756;
            7'd43: magnitude = 16'sd1781;
            7'd44: magnitude = 16'sd1805;
            7'd45: magnitude = 16'sd1828;
            7'd46: magnitude = 16'sd1850;
            7'd47: magnitude = 16'sd1871;
            7'd48: magnitude = 16'sd1891;
            7'd49: magnitude = 16'sd1910;
            7'd50: magnitude = 16'sd1927;
            7'd51: magnitude = 16'sd1944;
            7'd52: magnitude = 16'sd1959;
            7'd53: magnitude = 16'sd1973;
            7'd54: magnitude = 16'sd1986;
            7'd55: magnitude = 16'sd1997;
            7'd56: magnitude = 16'sd2008;
            7'd57: magnitude = 16'sd2017;
            7'd58: magnitude = 16'sd2025;
            7'd59: magnitude = 16'sd2032;
            7'd60: magnitude = 16'sd2037;
            7'd61: magnitude = 16'sd2041;
            7'd62: magnitude = 16'sd2045;
            7'd63: magnitude = 16'sd2046;
            7'd64: magnitude = 16'sd2047;
            default: magnitude = 16'sd0;
        endcase
    end
    assign sample = phase_index[7] ? -magnitude : magnitude;
endmodule
