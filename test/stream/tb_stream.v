`default_nettype none
`timescale 1ns/1ps

module tb_stream ();
    reg          clk;
    reg          rst_n;
    reg          start;
    reg          reset_engine;

    reg  [7:0]   cs_length;
    reg  [7:0]   msg_length;
    reg  [15:0]  out_length;
    reg          chain_enable;
    reg  [15:0]  chain_count;

    reg  [63:0]  in_word;
    reg          in_word_valid;
    wire         in_word_ready;
    wire         in_word_kind;
    wire [2:0]   in_word_index;
    wire [3:0]   in_word_bytes;

    wire [7:0]   out_byte;
    wire         out_valid;
    reg          out_ready;
    wire         out_last;

    wire         busy;
    wire         done;

    cxof_stream_controller dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .reset_engine  (reset_engine),

        .cs_length     (cs_length),
        .msg_length    (msg_length),
        .out_length    (out_length),
        .chain_enable  (chain_enable),
        .chain_count   (chain_count),

        .in_word       (in_word),
        .in_word_valid (in_word_valid),
        .in_word_ready (in_word_ready),
        .in_word_kind  (in_word_kind),
        .in_word_index (in_word_index),
        .in_word_bytes (in_word_bytes),

        .out_byte      (out_byte),
        .out_valid     (out_valid),
        .out_ready     (out_ready),
        .out_last      (out_last),

        .busy          (busy),
        .done          (done)
    );

    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    initial begin
        $dumpfile("tb_stream.vcd");
        $dumpvars(0, tb_stream);
    end
endmodule
