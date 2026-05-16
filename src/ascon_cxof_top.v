/*
 * ASCON-CXOF top using stream-oriented wrapper.
 *
 * UART/protocol interface stays compatible with the previous register map.
 * Crypto path is now narrow:
 *   register bytes -> 64-bit stream words -> CXOF -> output bytes -> result bytes
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

    localparam BAUD_DIV = 16'd434;

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

    wire        rf_we;
    wire        rf_re;
    wire [7:0]  rf_addr;
    wire [7:0]  rf_wdata;
    wire [7:0]  rf_rdata;
    wire        cmd_start;
    wire        cmd_reset_engine;
    wire        parser_error;

    wire [7:0]  tx_byte;
    wire        tx_send;
    wire        tx_ready;

    protocol_parser u_parser (
        .clk            (clk),
        .rst_n          (rst_n),

        .rx_byte        (rx_byte),
        .rx_valid       (rx_valid),

        .tx_byte        (tx_byte),
        .tx_send        (tx_send),
        .tx_ready       (tx_ready),

        .rf_we          (rf_we),
        .rf_re          (rf_re),
        .rf_addr        (rf_addr),
        .rf_wdata       (rf_wdata),
        .rf_rdata       (rf_rdata),

        .cmd_start      (cmd_start),
        .cmd_reset_eng  (cmd_reset_engine),

        .engine_busy    (busy),
        .engine_done    (done_irq),
        .protocol_error (parser_error),
        .state_dbg      (state_dbg)
    );

    wire [7:0]  cs_length;
    wire [7:0]  msg_length;
    wire [15:0] out_length;
    wire        chain_enable;
    wire [15:0] chain_count;

    wire [63:0] stream_in_word;
    wire        stream_in_valid;
    wire        stream_in_ready;
    wire        stream_in_kind;
    wire [2:0]  stream_in_index;
    wire [3:0]  stream_in_bytes;

    wire [7:0]  stream_out_byte;
    wire        stream_out_valid;
    wire        stream_out_ready;
    wire        stream_out_last;

    stream_register_file u_rf (
        .clk              (clk),
        .rst_n            (rst_n),

        .we               (rf_we),
        .re               (rf_re),
        .addr             (rf_addr),
        .wdata            (rf_wdata),
        .rdata            (rf_rdata),

        .cs_length        (cs_length),
        .msg_length       (msg_length),
        .out_length       (out_length),
        .chain_enable     (chain_enable),
        .chain_count      (chain_count),

        .in_word          (stream_in_word),
        .in_word_valid    (stream_in_valid),
        .in_word_ready    (stream_in_ready),
        .in_word_kind     (stream_in_kind),
        .in_word_index    (stream_in_index),
        .in_word_bytes    (stream_in_bytes),

        .stream_out_byte  (stream_out_byte),
        .stream_out_valid (stream_out_valid),
        .stream_out_ready (stream_out_ready),
        .stream_out_last  (stream_out_last),

        .engine_busy      (busy),
        .engine_done      (done_irq),
        .engine_error     (parser_error)
    );

    cxof_stream_controller u_cxof (
        .clk           (clk),
        .rst_n         (rst_n),

        .start         (cmd_start),
        .reset_engine  (cmd_reset_engine),

        .cs_length     (cs_length),
        .msg_length    (msg_length),
        .out_length    (out_length),
        .chain_enable  (chain_enable),
        .chain_count   (chain_count),

        .in_word       (stream_in_word),
        .in_word_valid (stream_in_valid),
        .in_word_ready (stream_in_ready),
        .in_word_kind  (stream_in_kind),
        .in_word_index (stream_in_index),
        .in_word_bytes (stream_in_bytes),

        .out_byte      (stream_out_byte),
        .out_valid     (stream_out_valid),
        .out_ready     (stream_out_ready),
        .out_last      (stream_out_last),

        .busy          (busy),
        .done          (done_irq)
    );

    assign error = parser_error;

    uart_tx u_uart_tx (
        .clk        (clk),
        .rst_n      (rst_n),
        .baud_div   (BAUD_DIV),
        .byte_in    (tx_byte),
        .send       (tx_send),
        .ready      (tx_ready),
        .tx         (uart_tx)
    );

    reg [23:0] heartbeat_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) heartbeat_cnt <= 24'd0;
        else        heartbeat_cnt <= heartbeat_cnt + 24'd1;
    end

    assign heartbeat = heartbeat_cnt[22];

endmodule
