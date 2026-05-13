/*
 * Register file.
 *
 * Address map (byte-addressed, accessed from the protocol parser):
 *
 *   0x00       STATUS       (R)   bit0=done, bit1=busy, bit2=error, bit3=result_valid
 *   0x01       CONTROL      (W)   bit0=start, bit1=reset_engine
 *   0x02       CS_LENGTH    (R/W) customization string length in bytes (0..32)
 *   0x03       MSG_LENGTH   (R/W) message length in bytes (0..32)
 *   0x04-0x05  OUT_LENGTH   (R/W) requested output length, little-endian
 *   0x10-0x2F  CS_DATA      (R/W) 32 bytes of customization string
 *   0x30-0x4F  MSG_DATA     (R/W) 32 bytes of message
 *   0x50-0x6F  RESULT       (R)   32 bytes of output (read after done)
 *   0x80       VERSION      (R)   constant 0x01 (protocol version)
 *   0x81       CHIP_ID      (R)   constant 0xAC ("AsCon")
 *
 * All multi-byte fields are little-endian on the wire.
 */

`default_nettype none

module register_file (
    input  wire         clk,
    input  wire         rst_n,

    // Protocol parser port
    input  wire         we,
    input  wire         re,
    input  wire [7:0]   addr,
    input  wire [7:0]   wdata,
    output reg  [7:0]   rdata,

    // Engine-facing outputs
    output reg  [319:0] cs_data,
    output reg  [7:0]   cs_length,
    output reg  [319:0] msg_data,
    output reg  [7:0]   msg_length,
    output reg  [15:0]  out_length,

    // Engine result inputs
    input  wire [255:0] result_data,
    input  wire         result_valid,

    // Status flags
    input  wire         engine_busy,
    input  wire         engine_done,
    input  wire         engine_error
);

    // Cached result snapshot — when engine pulses result_valid, we latch it
    reg [255:0] result_latched;
    reg         result_present;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_latched <= 256'd0;
            result_present <= 1'b0;
        end else begin
            if (result_valid) begin
                result_latched <= result_data;
                result_present <= 1'b1;
            end
            // result_present cleared when engine starts a new operation
            // (handled via the control register write below)
        end
    end

    // Local copies of CS_DATA, MSG_DATA stored as flat 320-bit regs
    // (byte 0 is MSB, matching the ASCON convention)

    // helper: write byte at index i (0..31) into a 320-bit register
    function [319:0] write_byte_32;
        input [319:0] cur;
        input [7:0]   idx;
        input [7:0]   data;
        reg   [319:0] mask;
        reg   [319:0] insert;
        reg   [8:0]   shift_amt;   // 9 bits to hold 0..255 safely
        begin
            shift_amt = 9'd312 - {1'b0, idx, 3'b0};  // bit position of byte idx (MSB-first)
            mask      = 320'hff << shift_amt;
            insert    = {312'd0, data} << shift_amt;
            write_byte_32 = (cur & ~mask) | insert;
        end
    endfunction

    // helper: read byte at index i (0..31) from a 320-bit register
    function [7:0] read_byte_32;
        input [319:0] cur;
        input [7:0]   idx;
        reg   [8:0]   shift_amt;
        begin
            shift_amt = 9'd312 - {1'b0, idx, 3'b0};
            read_byte_32 = (cur >> shift_amt) & 320'hff;
        end
    endfunction

    // helper: read byte from result (256 bits = 32 bytes)
    function [7:0] read_byte_result;
        input [255:0] cur;
        input [7:0]   idx;
        reg   [8:0]   shift_amt;
        begin
            shift_amt = 9'd248 - {1'b0, idx, 3'b0};
            read_byte_result = (cur >> shift_amt) & 256'hff;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs_data    <= 320'd0;
            cs_length  <= 8'd0;
            msg_data   <= 320'd0;
            msg_length <= 8'd0;
            out_length <= 16'd0;
            rdata      <= 8'd0;
        end else begin
            // ---- writes ----
            if (we) begin
                case (addr)
                    8'h01: begin
                        // CONTROL register write — handled at top level via cmd_start.
                        // Clearing result_present is also done by the parser via cmd_reset.
                    end
                    8'h02: cs_length  <= wdata;
                    8'h03: msg_length <= wdata;
                    8'h04: out_length[7:0]  <= wdata;
                    8'h05: out_length[15:8] <= wdata;
                    default: begin
                        if (addr >= 8'h10 && addr <= 8'h2F) begin
                            cs_data <= write_byte_32(cs_data, addr - 8'h10, wdata);
                        end else if (addr >= 8'h30 && addr <= 8'h4F) begin
                            msg_data <= write_byte_32(msg_data, addr - 8'h30, wdata);
                        end
                    end
                endcase
            end

            // ---- reads ----
            if (re) begin
                case (addr)
                    8'h00: rdata <= {4'd0, result_present, engine_error, engine_busy, engine_done};
                    8'h02: rdata <= cs_length;
                    8'h03: rdata <= msg_length;
                    8'h04: rdata <= out_length[7:0];
                    8'h05: rdata <= out_length[15:8];
                    8'h80: rdata <= 8'h01;
                    8'h81: rdata <= 8'hAC;
                    default: begin
                        if (addr >= 8'h10 && addr <= 8'h2F)
                            rdata <= read_byte_32(cs_data, addr - 8'h10);
                        else if (addr >= 8'h30 && addr <= 8'h4F)
                            rdata <= read_byte_32(msg_data, addr - 8'h30);
                        else if (addr >= 8'h50 && addr <= 8'h6F)
                            rdata <= read_byte_result(result_latched, addr - 8'h50);
                        else
                            rdata <= 8'h00;
                    end
                endcase
            end
        end
    end

endmodule
