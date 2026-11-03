`timescale 1ns/1ps
module dvi_output #(parameter RESET_STAGES=6)(
    input pixel_clk, serial_clk, reset_n, hs, vs, de,
    input [23:0] rgb,
    output tmds_clk_p,tmds_clk_n,
    output [2:0] tmds_d_p,tmds_d_n
);
    wire [9:0] code_b,code_g,code_r;
    wire [2:0] serial;
    // Retiming the high-fanout video reset onto falling PCLK isolates the
    // serializer release path from reset routing throughout the renderer.
    // OSER10 recovery/removal remains checked against BOTH FCLK edges.
    // Fabric registers remain clocked only by PCLK, never by HCLK/FCLK.
    (* syn_preserve=1, ASYNC_REG="TRUE" *) reg [2:0] serial_reset_pipe;
    always @(negedge pixel_clk or negedge reset_n)
        if(!reset_n) serial_reset_pipe<=0;
        else serial_reset_pipe<={serial_reset_pipe[1:0],1'b1};
    // Preserved even-polarity delay also protects fast-corner removal.
    // Final routed recovery/removal at all lanes must pass without exceptions.
    (* syn_keep=1, syn_preserve=1 *) wire [RESET_STAGES:0] serializer_reset_delay;
    assign serializer_reset_delay[0]=!serial_reset_pipe[2];
    genvar reset_stage;
    generate for(reset_stage=0;reset_stage<RESET_STAGES;reset_stage=reset_stage+1) begin: reset_release_delay
        (* syn_keep=1, syn_preserve=1 *) LUT1 #(.INIT(2'b01)) delay_cell(
            .F(serializer_reset_delay[reset_stage+1]),.I0(serializer_reset_delay[reset_stage]));
    end endgenerate
    // DVI control is {VS,HS} on blue, zero on green/red.
    svo_tmds enc_b(.clk(pixel_clk),.resetn(reset_n),.de(de),.ctrl({vs,hs}),.din(rgb[7:0]),.dout(code_b));
    svo_tmds enc_g(.clk(pixel_clk),.resetn(reset_n),.de(de),.ctrl(2'b00),.din(rgb[15:8]),.dout(code_g));
    svo_tmds enc_r(.clk(pixel_clk),.resetn(reset_n),.de(de),.ctrl(2'b00),.din(rgb[23:16]),.dout(code_r));
    wire [29:0] code={code_r,code_g,code_b};
    genvar i;
    generate for(i=0;i<3;i=i+1) begin: lane
        OSER10 ser(.Q(serial[i]),.D0(code[i*10]),.D1(code[i*10+1]),
        .D2(code[i*10+2]),.D3(code[i*10+3]),.D4(code[i*10+4]),
        .D5(code[i*10+5]),.D6(code[i*10+6]),.D7(code[i*10+7]),
        .D8(code[i*10+8]),.D9(code[i*10+9]),.PCLK(pixel_clk),
        .FCLK(serial_clk),.RESET(serializer_reset_delay[RESET_STAGES]));
    end endgenerate
    ELVDS_OBUF outbuf[3:0](.I({pixel_clk,serial}),.O({tmds_clk_p,tmds_d_p}),.OB({tmds_clk_n,tmds_d_n}));
endmodule
