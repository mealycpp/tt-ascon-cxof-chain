/*
 * ASCON-CXOF top: wires together UART, protocol parser, register file,
 * and the CXOF mode controller.
 *
 * Data flow on RX side:
 *   uart_rx -> protocol_parser -> register_file -> cxof_controller
 *
 * Data flow on TX side:
 *   cxof_controller -> register_file (result) -> protocol_parser -> uart_tx
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
    // At 50 MHz core clock, 115200 baud gives divider 50_000_000 / 115200 = 434.0
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
    wire        rf_re;
    wire [7:0]  rf_addr;
    wire [7:0]  rf_wdata;
    wire [7:0]  rf_rdata;
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

    // ----- register file (256-bit cs/msg buffers) -----
    wire [255:0] cs_data;
    wire [7:0]   cs_length;
    wire [255:0] msg_data;
    wire [7:0]   msg_length;
    wire [15:0]  out_length;
    wire         chain_enable;
    wire [15:0]  chain_count;

    wire [255:0] result_data;
    wire         result_valid;

    // ----- Software-controlled chain wrapper -----
    // chain_enable=0:
    //   one normal ASCON-CXOF(cs,msg) pass.
    //
    // chain_enable=1:
    //   run chain_count passes.
    //   pass 0 uses software msg.
    //   pass 1..N use previous 32-byte digest as msg.
    //
    // chain_count=0 is treated as 1.
    wire [255:0] core_result_data;
    wire         core_result_valid;
    wire         core_busy;
    wire         core_done;

    reg  [1:0]   chain_state;
    reg  [15:0]  passes_left;
    reg          use_feedback;
    reg  [255:0] chain_feedback_msg;
    reg          core_start;
    reg          final_result_valid;

    localparam [1:0] CH_IDLE      = 2'd0;
    localparam [1:0] CH_CORE      = 2'd1;
    localparam [1:0] CH_PREP_NEXT = 2'd2;

    wire [15:0] requested_passes =
        (chain_enable && (chain_count != 16'd0)) ? chain_count : 16'd1;

    wire [255:0] msg_data_to_eng =
        use_feedback ? chain_feedback_msg : msg_data;

    wire [7:0] msg_length_to_eng =
        use_feedback ? 8'd32 : msg_length;

    assign result_data  = core_result_data;
    assign result_valid = final_result_valid;

    assign done_irq = final_result_valid;
    assign busy     = (chain_state != CH_IDLE) | core_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chain_state        <= CH_IDLE;
            passes_left        <= 16'd0;
            use_feedback       <= 1'b0;
            chain_feedback_msg <= 256'd0;
            core_start         <= 1'b0;
            final_result_valid <= 1'b0;
        end else begin
            core_start         <= 1'b0;
            final_result_valid <= 1'b0;

            if (cmd_reset_engine) begin
                chain_state        <= CH_IDLE;
                passes_left        <= 16'd0;
                use_feedback       <= 1'b0;
                chain_feedback_msg <= 256'd0;
            end else begin
                case (chain_state)
                    CH_IDLE: begin
                        if (cmd_start) begin
                            passes_left  <= requested_passes;
                            use_feedback <= 1'b0;
                            core_start   <= 1'b1;
                            chain_state  <= CH_CORE;
                        end
                    end

                    CH_CORE: begin
                        if (core_result_valid) begin
                            chain_feedback_msg <= core_result_data;

                            if (passes_left <= 16'd1) begin
                                chain_state        <= CH_IDLE;
                                passes_left        <= 16'd0;
                                use_feedback       <= 1'b0;
                                final_result_valid <= 1'b1;
                            end else begin
                                passes_left  <= passes_left - 16'd1;
                                use_feedback <= 1'b1;
                                chain_state  <= CH_PREP_NEXT;
                            end
                        end
                    end

                    CH_PREP_NEXT: begin
                        core_start  <= 1'b1;
                        chain_state <= CH_CORE;
                    end

                    default: begin
                        chain_state <= CH_IDLE;
                    end
                endcase
            end
        end
    end

    register_file u_rf (
        .clk            (clk),
        .rst_n          (rst_n),

        .we             (rf_we),
        .re             (rf_re),
        .addr           (rf_addr),
        .wdata          (rf_wdata),
        .rdata          (rf_rdata),

        .cs_data        (cs_data),
        .cs_length      (cs_length),
        .msg_data       (msg_data),
        .msg_length     (msg_length),
        .out_length     (out_length),
        .chain_enable   (chain_enable),
        .chain_count    (chain_count),
        .result_data    (result_data),
        .result_valid   (result_valid),

        .engine_busy    (busy),
        .engine_done    (done_irq),
        .engine_error   (parser_error)
    );

    // ----- CXOF engine -----
    cxof_controller u_cxof (
        .clk            (clk),
        .rst_n          (rst_n),

        .start          (core_start),
        .reset_engine   (cmd_reset_engine),

        .cs_data        (cs_data),
        .cs_length      (cs_length),
        .msg_data       (msg_data_to_eng),
        .msg_length     (msg_length_to_eng),
        .out_length     (out_length),

        .result_data    (core_result_data),
        .result_valid   (core_result_valid),

        .busy           (core_busy),
        .done           (core_done)
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
    assign heartbeat = heartbeat_cnt[22];

endmodule
