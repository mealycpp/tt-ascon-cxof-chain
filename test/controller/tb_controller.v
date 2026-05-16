`default_nettype none
`timescale 1ns/1ps

module tb_controller ();
    reg          clk;
    reg          rst_n;
    reg          start;
    reg          reset_engine;
    reg  [255:0] cs_data;
    reg  [7:0]   cs_length;
    reg  [255:0] msg_data;
    reg  [7:0]   msg_length;
    reg  [15:0]  out_length;
    reg          chain_enable;
    reg  [15:0]  chain_count;
    wire [255:0] result_data;
    wire         result_valid;
    wire         busy;
    wire         done;

    cxof_controller dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .reset_engine (reset_engine),
        .cs_data      (cs_data),
        .cs_length    (cs_length),
        .msg_data     (msg_data),
        .msg_length   (msg_length),
        .out_length   (out_length),
        .chain_enable (chain_enable),
        .chain_count  (chain_count),
        .result_data  (result_data),
        .result_valid (result_valid),
        .busy         (busy),
        .done         (done)
    );

    initial begin
        $dumpfile("tb_controller.vcd");
        $dumpvars(0, tb_controller);
    end
endmodule
