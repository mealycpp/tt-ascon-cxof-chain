/*
 * UART transmitter, 8-N-1.
 *
 * Standard frame: START(0) + 8 data bits LSB-first + STOP(1).
 *
 * Interface:
 *   byte_in: byte to send
 *   send:    pulse high for one cycle to load and start (ignored if not ready)
 *   ready:   high when idle and ready to accept a new byte
 *   tx:      serial output (idles high)
 *
 * Single always block — no multi-driver races on `cnt`.
 */

`default_nettype none

module uart_tx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] baud_div,
    input  wire [7:0]  byte_in,
    input  wire        send,
    output reg         ready,
    output reg         tx
);

    // FSM
    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [3:0]  bit_idx;
    reg [7:0]  shift;
    reg [15:0] cnt;

    // A "bit_tick" is the moment cnt wraps; only meaningful when not in IDLE.
    wire bit_tick = (cnt == baud_div - 16'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            bit_idx <= 4'd0;
            shift   <= 8'd0;
            tx      <= 1'b1;
            ready   <= 1'b1;
            cnt     <= 16'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx    <= 1'b1;
                    ready <= 1'b1;
                    cnt   <= 16'd0;          // hold counter at 0 while idle
                    if (send) begin
                        shift <= byte_in;
                        ready <= 1'b0;
                        cnt   <= 16'd0;      // ensure first bit is full width
                        state <= S_START;
                    end
                end
                S_START: begin
                    tx <= 1'b0;
                    if (bit_tick) begin
                        cnt     <= 16'd0;
                        bit_idx <= 4'd0;
                        state   <= S_DATA;
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end
                S_DATA: begin
                    tx <= shift[0];
                    if (bit_tick) begin
                        cnt   <= 16'd0;
                        shift <= {1'b0, shift[7:1]};
                        if (bit_idx == 4'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 4'd1;
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end
                S_STOP: begin
                    tx <= 1'b1;
                    if (bit_tick) begin
                        cnt   <= 16'd0;
                        ready <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
