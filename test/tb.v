/*
 * Testbench top for ASCON-CXOF chip.
 *
 * cocotb-compatible. Wires up the Tiny Tapeout top module with all signals
 * exposed so Python test code (test.py) can drive and observe.
 */

`default_nettype none
`timescale 1ns/1ps

module tb ();

    // dump waves
    initial begin
        $dumpfile("tb.vcd");
        $dumpvars(0, tb);
    end

    // signals to top
    reg [7:0]  ui_in;
    wire [7:0] uo_out;
    reg [7:0]  uio_in;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;
    reg        ena;
    reg        clk;
    reg        rst_n;

    // initialize uio inputs
    initial uio_in = 8'h00;

    tt_um_ascon_cxof dut (
        .ui_in  (ui_in),
        .uo_out (uo_out),
        .uio_in (uio_in),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (ena),
        .clk    (clk),
        .rst_n  (rst_n)
    );

endmodule
