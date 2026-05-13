/*
 * ASCON-CXOF top: glue between UART/protocol/register file and the CXOF engine.
 *
 * Data flow:
 *   uart_rx -> uart_rx_inst -> protocol_parser -> register_file -> cxof_controller -> ascon_permutation
 *                                                        ^                                |
 *                                                        |                                v
 *                                                        +--- result_out <----------------+
 *   protocol_parser <- register_file <- result_out
 *   protocol_parser -> uart_tx_inst -> uart_tx
 */

`default_nettype none

module ascon_cxof_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        uart_rx,
    output wire        uart_tx,
    output wire        done_irq,
    output wire        busy,
    output wire        error,
    output wire [1:0]  state_dbg,
    output wire        heartbeat,
    output wire        rx_active
);

    // ----- parameters -----
    // Baud-rate parameter: at 25 MHz core clock, 115200 baud gives divider ~217.
    // 25_000_000 / 115200 = 217.01 (~0.16% error, well within UART tolerance)
    localparam BAUD_DIV = 16'd434;

    // ----- UART RX -> framing parser -----
    wire [7:0] rx_byte;
    wire       rx_valid;

    uart_rx u_uart_rx (
        .clk        (clk),
        .rst_n      (rst_n),
        .baud_div   (BAUD_DIV),
        .rx         (uart_rx),
        .byte_out   (rx_byte),
        .byte_valid (rx_valid),
        .rx_active  (rx_active)
    );

    // ----- protocol parser <-> register file -----
    wire        rf_we;
    wire [7:0]  rf_addr;
    wire [7:0]  rf_wdata;
    wire [7:0]  rf_rdata;
    wire        rf_re;
    wire        cmd_start;
    wire        cmd_reset_engine;
    wire        parser_error;

    // ----- TX side -----
    wire [7:0]  tx_byte;
    wire        tx_send;
    wire        tx_ready;

    protocol_parser u_parser (
        .clk            (clk),
        .rst_n          (rst_n),

        // RX from UART
        .rx_byte        (rx_byte),
        .rx_valid       (rx_valid),

        // TX to UART
        .tx_byte        (tx_byte),
        .tx_send        (tx_send),
        .tx_ready       (tx_ready),

        // Register file interface
        .rf_we          (rf_we),
        .rf_re          (rf_re),
        .rf_addr        (rf_addr),
        .rf_wdata       (rf_wdata),
        .rf_rdata       (rf_rdata),

        // Engine control signals
        .cmd_start      (cmd_start),
        .cmd_reset_eng  (cmd_reset_engine),

        // Status
        .engine_busy    (busy),
        .engine_done    (done_irq),
        .protocol_error (parser_error),
        .state_dbg      (state_dbg)
    );

    // ----- register file -----
    // Holds: status, command, output length, customization string, message, result
    wire [319:0] cs_data;       // customization string (up to 32 bytes = 256 bits)
    wire [7:0]   cs_length;
    wire [319:0] msg_data;      // message input (up to 32 bytes = 256 bits)
    wire [7:0]   msg_length;
    wire [15:0]  out_length;    // requested output length in bytes
    wire [255:0] result_data;   // 32 bytes of output (could expand if needed)
    wire         result_valid;

    register_file u_rf (
        .clk            (clk),
        .rst_n          (rst_n),

        // Parser-facing port
        .we             (rf_we),
        .re             (rf_re),
        .addr           (rf_addr),
        .wdata          (rf_wdata),
        .rdata          (rf_rdata),

        // Engine-facing ports
        .cs_data        (cs_data),
        .cs_length      (cs_length),
        .msg_data       (msg_data),
        .msg_length     (msg_length),
        .out_length     (out_length),
        .result_data    (result_data),
        .result_valid   (result_valid),

        // Status flags driven by engine
        .engine_busy    (busy),
        .engine_done    (done_irq),
        .engine_error   (parser_error)
    );

    // ----- CXOF engine -----
    cxof_controller u_cxof (
        .clk            (clk),
        .rst_n          (rst_n),

        // Control
        .start          (cmd_start),
        .reset_engine   (cmd_reset_engine),

        // Inputs from register file
        .cs_data        (cs_data),
        .cs_length      (cs_length),
        .msg_data       (msg_data),
        .msg_length     (msg_length),
        .out_length     (out_length),

        // Output to register file
        .result_data    (result_data),
        .result_valid   (result_valid),

        // Status
        .busy           (busy),
        .done           (done_irq)
    );

    // ----- error aggregator -----
    assign error = parser_error;

    // ----- TX UART -----
    uart_tx u_uart_tx (
        .clk        (clk),
        .rst_n      (rst_n),
        .baud_div   (BAUD_DIV),
        .byte_in    (tx_byte),
        .send       (tx_send),
        .ready      (tx_ready),
        .tx         (uart_tx)
    );

    // ----- heartbeat (visible activity indicator) -----
    reg [23:0] heartbeat_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) heartbeat_cnt <= 24'd0;
        else        heartbeat_cnt <= heartbeat_cnt + 24'd1;
    end
    assign heartbeat = heartbeat_cnt[22];  // ~3 Hz at 25 MHz, visible blink

endmodule
