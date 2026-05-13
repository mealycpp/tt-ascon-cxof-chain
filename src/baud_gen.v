/*
 * Baud-rate tick generator.
 *
 * Produces a one-cycle pulse every `baud_div` core-clock cycles, at the
 * bit-rate frequency. For oversampling (RX), use a divider equal to
 * clock_hz / (16 * baud), and the RX module samples mid-bit on every
 * 16th tick — but we keep this simpler: pulse at exactly the baud rate.
 *
 * At 25 MHz core, baud_div = 217 gives ~115200 baud (0.16% error).
 * For RX 16x oversampling, we use a separate divider of ~14 (217/16) inside RX.
 */

`default_nettype none

module baud_gen #(
    parameter WIDTH = 16
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [WIDTH-1:0] divisor,
    output reg              tick
);

    reg [WIDTH-1:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= {WIDTH{1'b0}};
            tick <= 1'b0;
        end else if (cnt == divisor - 1) begin
            cnt  <= {WIDTH{1'b0}};
            tick <= 1'b1;
        end else begin
            cnt  <= cnt + {{(WIDTH-1){1'b0}}, 1'b1};
            tick <= 1'b0;
        end
    end

endmodule
