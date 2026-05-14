/*
 * Copyright (c) 2026 REPLACE_WITH_YOUR_NAME
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Tapeout wrapper for ASCON-CXOF hash chain accelerator.
 * Matches the ttsky-verilog-template top-level interface.
 */

`default_nettype none

module tt_um_ascon_cxof_chain (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    // ----- pin assignments -----
    wire uart_rx     = ui_in[0];
    wire ext_clk_en  = ui_in[1];
    wire ext_clk     = ui_in[2];

    wire uart_tx;
    wire done_irq;
    wire busy;
    wire error;
    wire [1:0] state_dbg;
    wire heartbeat;
    wire rx_active;

    assign uo_out[0] = uart_tx;
    assign uo_out[1] = done_irq;
    assign uo_out[2] = busy;
    assign uo_out[3] = error;
    assign uo_out[4] = state_dbg[0];
    assign uo_out[5] = state_dbg[1];
    assign uo_out[6] = heartbeat;
    assign uo_out[7] = rx_active;

    // bidirectional pins all configured as inputs (uio_oe = 0)
    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    // ----- clock selection -----
    // For tomorrow's ship, just use the TT clock directly. ext_clk option is
    // future-proofing for benchmarking at different frequencies via PYNQ.
    wire core_clk = clk;  // keep simple; ignore ext_clk_en for now

    // suppress unused warnings
    wire _unused = &{ena, ext_clk_en, ext_clk, uio_in, 1'b0};

    // ----- instantiate the real top -----
    ascon_cxof_top u_top (
        .clk        (core_clk),
        .rst_n      (rst_n),
        .uart_rx    (uart_rx),
        .uart_tx    (uart_tx),
        .done_irq   (done_irq),
        .busy       (busy),
        .error      (error),
        .state_dbg  (state_dbg),
        .heartbeat  (heartbeat),
        .rx_active  (rx_active)
    );

endmodule
