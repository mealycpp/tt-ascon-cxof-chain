/*
 * UART receiver, 8-N-1, with 16x oversampling for clean mid-bit detection.
 *
 * baud_div is the bit-period divider (clock_hz / baud_rate).
 * Internally, we tick at 16x to sample mid-bit.
 *
 * Standard 8-N-1 frame: START(0) + 8 data bits LSB-first + STOP(1).
 *
 * Output:
 *   byte_out: latched byte
 *   byte_valid: pulses high for one cycle when a byte is received
 *   rx_active: high during reception (for visual debug)
 */

`default_nettype none

module uart_rx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] baud_div,    // bit-period in core clocks
    input  wire        rx,
    output reg  [7:0]  byte_out,
    output reg         byte_valid,
    output reg         rx_active
);

    // synchronize rx into clk domain (2-FF synchronizer)
    reg rx_sync_0, rx_sync_1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync_0 <= 1'b1;
            rx_sync_1 <= 1'b1;
        end else begin
            rx_sync_0 <= rx;
            rx_sync_1 <= rx_sync_0;
        end
    end

    // oversample divider (16x faster than bit rate)
    // tick_div = baud_div / 16; for baud_div=217, tick_div ~= 14 (rounding error tolerable)
    wire [15:0] tick_div = {4'd0, baud_div[15:4]};   // div by 16
    reg  [15:0] tick_cnt;
    reg         os_tick;     // oversample tick (16x baud)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= 16'd0;
            os_tick  <= 1'b0;
        end else if (tick_cnt == tick_div - 1) begin
            tick_cnt <= 16'd0;
            os_tick  <= 1'b1;
        end else begin
            tick_cnt <= tick_cnt + 16'd1;
            os_tick  <= 1'b0;
        end
    end

    // FSM
    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [3:0]  os_counter;   // counts oversample ticks within a bit (0..15)
    reg [3:0]  bit_idx;      // 0..7 for data bits
    reg [7:0]  shift_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            os_counter <= 4'd0;
            bit_idx    <= 4'd0;
            shift_reg  <= 8'd0;
            byte_out   <= 8'd0;
            byte_valid <= 1'b0;
            rx_active  <= 1'b0;
        end else begin
            byte_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    rx_active <= 1'b0;
                    if (!rx_sync_1) begin
                        // start bit detected (falling edge); wait half a bit to sample mid
                        os_counter <= 4'd0;
                        rx_active  <= 1'b1;
                        state      <= S_START;
                    end
                end
                S_START: begin
                    if (os_tick) begin
                        if (os_counter == 4'd7) begin
                            // mid-bit of start bit; verify it's still low
                            if (!rx_sync_1) begin
                                os_counter <= 4'd0;
                                bit_idx    <= 4'd0;
                                state      <= S_DATA;
                            end else begin
                                // spurious start; abort
                                state <= S_IDLE;
                            end
                        end else begin
                            os_counter <= os_counter + 4'd1;
                        end
                    end
                end
                S_DATA: begin
                    if (os_tick) begin
                        if (os_counter == 4'd15) begin
                            // mid-bit of this data bit; sample
                            os_counter <= 4'd0;
                            shift_reg  <= {rx_sync_1, shift_reg[7:1]};  // LSB first
                            if (bit_idx == 4'd7) begin
                                state <= S_STOP;
                            end else begin
                                bit_idx <= bit_idx + 4'd1;
                            end
                        end else begin
                            os_counter <= os_counter + 4'd1;
                        end
                    end
                end
                S_STOP: begin
                    if (os_tick) begin
                        if (os_counter == 4'd15) begin
                            // mid-bit of stop bit
                            if (rx_sync_1) begin
                                // good stop bit; emit byte
                                byte_out   <= shift_reg;
                                byte_valid <= 1'b1;
                            end
                            // ignore framing error for now
                            state <= S_IDLE;
                        end else begin
                            os_counter <= os_counter + 4'd1;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
