// Asynchronous assertion, two-clock synchronous release.
// reset_btn is HIGH when reset is requested; board wrappers invert reset_n.
module reset_sync (
    input  wire clk,
    input  wire reset_btn,
    output wire rst_n
);
    reg [1:0] release_ff = 2'b00;
    always @(posedge clk or posedge reset_btn) begin
        if (reset_btn)
            release_ff <= 2'b00;
        else
            release_ff <= {release_ff[0], 1'b1};
    end
    assign rst_n = release_ff[1];
endmodule
