/*
 * CRC16-CCITT (poly 0x1021, init 0xFFFF, no reflect, no xorout).
 *
 * Used in the framing protocol for integrity.
 *
 * Match this implementation exactly in the host C driver. The reference Python
 * generator in test/golden/ verifies both sides produce the same value.
 *
 * Streaming interface: feed one byte at a time, get running CRC.
 */

`default_nettype none

module crc16_ccitt (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init,      // pulse to initialize CRC to 0xFFFF
    input  wire        update,    // pulse with valid byte_in
    input  wire [7:0]  byte_in,
    output reg  [15:0] crc
);

    // Combinational byte-wide CRC update.
    function [15:0] crc_byte_update;
        input [15:0] crc_in;
        input [7:0]  data;
        reg   [15:0] c;
        integer i;
        begin
            c = crc_in ^ {data, 8'h00};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[15])
                    c = (c << 1) ^ 16'h1021;
                else
                    c = c << 1;
            end
            crc_byte_update = c;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crc <= 16'hFFFF;
        end else if (init) begin
            crc <= 16'hFFFF;
        end else if (update) begin
            crc <= crc_byte_update(crc, byte_in);
        end
    end

endmodule
