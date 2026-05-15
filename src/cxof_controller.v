/*
 * ASCON-CXOF mode controller.
 *
 * Direct port of the ASCON team's official C reference
 * (https://github.com/ascon/ascon-c, crypto_cxof/asconcxof128/ref/hash.c).
 *
 * Algorithm:
 *   1. state = (IV, 0, 0, 0, 0); P12
 *   2. x[0] ^= cslen*8 (bit-length encoding); P12
 *   3. while cs_remaining >= 8: x[0] ^= LOADBYTES(cs,8); P12; advance 8 bytes
 *   4. x[0] ^= LOADBYTES(cs, cs_remaining) ^ PAD(cs_remaining); P12   (ALWAYS)
 *   5. while msg_remaining >= 8: x[0] ^= LOADBYTES(msg,8); P12; advance 8 bytes
 *   6. x[0] ^= LOADBYTES(msg, msg_remaining) ^ PAD(msg_remaining); P12  (ALWAYS)
 *   7. while out_remaining > 8: emit x[0] (8 bytes); P12; advance
 *   8. emit x[0] (out_remaining bytes); DONE
 *
 * Byte order (matches C reference's LOADBYTES on little-endian host):
 *   byte 0 of input -> x0[7:0]    (LSB end of word)
 *   byte 1          -> x0[15:8]
 *   ...
 *   byte 7          -> x0[63:56]
 *
 * State layout (matches new ascon_round.v):
 *   cxof_state[63:0]    = x0  (rate)
 *   cxof_state[127:64]  = x1
 *   cxof_state[191:128] = x2
 *   cxof_state[255:192] = x3
 *   cxof_state[319:256] = x4
 */

`default_nettype none

module cxof_controller (
    input  wire         clk,
    input  wire         rst_n,

    // Control
    input  wire         start,
    input  wire         reset_engine,

    // Inputs from register file (byte 0 of each is at bits [7:0])
    input  wire [255:0] cs_data,
    input  wire [7:0]   cs_length,
    input  wire [255:0] msg_data,
    input  wire [7:0]   msg_length,
    input  wire [15:0]  out_length,
    input  wire         chain_enable,
    input  wire [15:0]  chain_count,

    // Output
    output reg  [255:0] result_data,
    output reg          result_valid,

    // Status
    output reg          busy,
    output reg          done
);

    // ----- ASCON-CXOF128 IV (CORRECTED) -----
    // ASCON_CXOF_VARIANT = 4        -> 0x04 at bit  0  (byte 0)
    // ASCON_PA_ROUNDS = 12          -> 0x0C at bit 16  (low nibble of byte 2)
    // ASCON_HASH_PB_ROUNDS = 12     -> 0xC0 at bit 20  (high nibble of byte 2)
    // ASCON_HASH_RATE = 8           -> 0x08 at bit 40  (byte 5)
    // Combined byte layout (byte 7..byte 0):
    //   00 00 08 00 00 CC 00 04
    // = 64'h0000080000CC0004
    localparam [63:0] CXOF128_IV = 64'h0000_0800_00CC_0004;

    // ----- Permutation interface -----
    reg          perm_start;
    reg  [3:0]   perm_rounds;
    reg  [319:0] perm_state_in;
    wire [319:0] perm_state_out;
    wire         perm_busy;
    wire         perm_done;

    ascon_permutation u_perm (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (perm_start),
        .num_rounds (perm_rounds),
        .state_in   (perm_state_in),
        .state_out  (perm_state_out),
        .busy       (perm_busy),
        .done       (perm_done)
    );

    // suppress unused warning
    wire _unused = &{perm_busy, 1'b0};

    // ----- PAD(i) lookup: returns 0x01 << (8*i) -----
    function [63:0] pad_val;
        input [3:0] i;
        begin
            case (i[2:0])
                3'd0: pad_val = 64'h0000_0000_0000_0001;
                3'd1: pad_val = 64'h0000_0000_0000_0100;
                3'd2: pad_val = 64'h0000_0000_0001_0000;
                3'd3: pad_val = 64'h0000_0000_0100_0000;
                3'd4: pad_val = 64'h0000_0001_0000_0000;
                3'd5: pad_val = 64'h0000_0100_0000_0000;
                3'd6: pad_val = 64'h0001_0000_0000_0000;
                3'd7: pad_val = 64'h0100_0000_0000_0000;
                default: pad_val = 64'h0;
            endcase
        end
    endfunction

    // ----- MASK(n): returns mask for first n bytes (n=0..7) -----
    function [63:0] mask_n;
        input [3:0] n;
        begin
            case (n[2:0])
                3'd0: mask_n = 64'h0000_0000_0000_0000;
                3'd1: mask_n = 64'h0000_0000_0000_00FF;
                3'd2: mask_n = 64'h0000_0000_0000_FFFF;
                3'd3: mask_n = 64'h0000_0000_00FF_FFFF;
                3'd4: mask_n = 64'h0000_0000_FFFF_FFFF;
                3'd5: mask_n = 64'h0000_00FF_FFFF_FFFF;
                3'd6: mask_n = 64'h0000_FFFF_FFFF_FFFF;
                3'd7: mask_n = 64'h00FF_FFFF_FFFF_FFFF;
                default: mask_n = 64'h0;
            endcase
        end
    endfunction

    // ----- FSM states -----
    localparam S_IDLE         = 4'd0;
    localparam S_INIT_KICK    = 4'd1;
    localparam S_INIT_WAIT    = 4'd2;
    localparam S_LEN_KICK     = 4'd3;
    localparam S_LEN_WAIT     = 4'd4;
    localparam S_CS_KICK      = 4'd5;
    localparam S_CS_WAIT      = 4'd6;
    localparam S_CS_FIN_KICK  = 4'd7;
    localparam S_CS_FIN_WAIT  = 4'd8;
    localparam S_MSG_KICK     = 4'd9;
    localparam S_MSG_WAIT     = 4'd10;
    localparam S_MSG_FIN_KICK = 4'd11;
    localparam S_MSG_FIN_WAIT = 4'd12;
    localparam S_SQ_KICK      = 4'd13;
    localparam S_SQ_WAIT      = 4'd14;
    localparam S_FINISH       = 4'd15;

    reg [3:0]   state;
    reg [319:0] cxof_state;
    reg [255:0] cs_shift;
    reg [255:0] msg_shift;
    reg [7:0]   cs_remaining;
    reg [7:0]   msg_remaining;
    reg [15:0]  out_remaining;
    reg [4:0]   squeeze_idx;
    reg [15:0]  passes_left;

    wire [15:0] requested_passes =
        (chain_enable && (chain_count != 16'd0)) ? chain_count : 16'd1;

    wire [15:0] effective_out_length =
        (out_length > 16'd32) ? 16'd32 : out_length;

    // In chain mode, every pass produces a full 32-byte digest.
    wire [15:0] chain_pass_out_length =
        chain_enable ? 16'd32 : effective_out_length;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            cxof_state    <= 320'd0;
            cs_shift      <= 256'd0;
            msg_shift     <= 256'd0;
            cs_remaining  <= 8'd0;
            msg_remaining <= 8'd0;
            out_remaining <= 16'd0;
            squeeze_idx   <= 5'd0;
            passes_left   <= 16'd0;
            result_data   <= 256'd0;
            result_valid  <= 1'b0;
            busy          <= 1'b0;
            done          <= 1'b0;
            perm_start    <= 1'b0;
            perm_rounds   <= 4'd12;
            perm_state_in <= 320'd0;
        end else if (reset_engine) begin
            state         <= S_IDLE;
            busy          <= 1'b0;
            done          <= 1'b0;
            result_valid  <= 1'b0;
            passes_left   <= 16'd0;
            perm_start    <= 1'b0;
        end else begin
            perm_start   <= 1'b0;
            done         <= 1'b0;
            result_valid <= 1'b0;

            case (state)

                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        cxof_state    <= {256'd0, CXOF128_IV};
                        cs_shift      <= cs_data;
                        msg_shift     <= msg_data;
                        cs_remaining  <= cs_length;
                        msg_remaining <= msg_length;
                        out_remaining <= chain_pass_out_length;
                        squeeze_idx   <= 5'd0;
                        passes_left   <= requested_passes;
                        result_valid  <= 1'b0;
                        result_data   <= 256'd0;
                        busy          <= 1'b1;
                        state         <= S_INIT_KICK;
                    end
                end

                S_INIT_KICK: begin
                    perm_state_in <= cxof_state;
                    perm_rounds   <= 4'd12;
                    perm_start    <= 1'b1;
                    state         <= S_INIT_WAIT;
                end
                S_INIT_WAIT: begin
                    if (perm_done) begin
                        cxof_state <= perm_state_out;
                        state      <= S_LEN_KICK;
                    end
                end

                S_LEN_KICK: begin
                    perm_state_in <= {cxof_state[319:64],
                                      cxof_state[63:0] ^ {52'd0, cs_remaining, 3'b000}};
                    perm_rounds   <= 4'd12;
                    perm_start    <= 1'b1;
                    state         <= S_LEN_WAIT;
                end
                S_LEN_WAIT: begin
                    if (perm_done) begin
                        cxof_state <= perm_state_out;
                        state      <= (cs_remaining >= 8'd8) ? S_CS_KICK : S_CS_FIN_KICK;
                    end
                end

                S_CS_KICK: begin
                    perm_state_in <= {cxof_state[319:64],
                                      cxof_state[63:0] ^ cs_shift[63:0]};
                    perm_rounds   <= 4'd12;
                    perm_start    <= 1'b1;
                    state         <= S_CS_WAIT;
                end
                S_CS_WAIT: begin
                    if (perm_done) begin
                        cxof_state   <= perm_state_out;
                        cs_shift     <= {64'd0, cs_shift[255:64]};
                        cs_remaining <= cs_remaining - 8'd8;
                        if ((cs_remaining - 8'd8) >= 8'd8)
                            state <= S_CS_KICK;
                        else
                            state <= S_CS_FIN_KICK;
                    end
                end

                S_CS_FIN_KICK: begin
                    perm_state_in <= {cxof_state[319:64],
                                      cxof_state[63:0]
                                      ^ (cs_shift[63:0] & mask_n(cs_remaining[3:0]))
                                      ^ pad_val(cs_remaining[3:0])};
                    perm_rounds   <= 4'd12;
                    perm_start    <= 1'b1;
                    state         <= S_CS_FIN_WAIT;
                end
                S_CS_FIN_WAIT: begin
                    if (perm_done) begin
                        cxof_state <= perm_state_out;
                        state      <= (msg_remaining >= 8'd8) ? S_MSG_KICK : S_MSG_FIN_KICK;
                    end
                end

                S_MSG_KICK: begin
                    perm_state_in <= {cxof_state[319:64],
                                      cxof_state[63:0] ^ msg_shift[63:0]};
                    perm_rounds   <= 4'd12;
                    perm_start    <= 1'b1;
                    state         <= S_MSG_WAIT;
                end
                S_MSG_WAIT: begin
                    if (perm_done) begin
                        cxof_state    <= perm_state_out;
                        msg_shift     <= {64'd0, msg_shift[255:64]};
                        msg_remaining <= msg_remaining - 8'd8;
                        if ((msg_remaining - 8'd8) >= 8'd8)
                            state <= S_MSG_KICK;
                        else
                            state <= S_MSG_FIN_KICK;
                    end
                end

                S_MSG_FIN_KICK: begin
                    perm_state_in <= {cxof_state[319:64],
                                      cxof_state[63:0]
                                      ^ (msg_shift[63:0] & mask_n(msg_remaining[3:0]))
                                      ^ pad_val(msg_remaining[3:0])};
                    perm_rounds   <= 4'd12;
                    perm_start    <= 1'b1;
                    state         <= S_MSG_FIN_WAIT;
                end
                S_MSG_FIN_WAIT: begin
                    if (perm_done) begin
                        cxof_state <= perm_state_out;
                        state      <= S_SQ_KICK;
                    end
                end

                S_SQ_KICK: begin
                    case (squeeze_idx)
                        5'd0:  result_data[63:0]    <= cxof_state[63:0];
                        5'd8:  result_data[127:64]  <= cxof_state[63:0];
                        5'd16: result_data[191:128] <= cxof_state[63:0];
                        5'd24: result_data[255:192] <= cxof_state[63:0];
                        default: ;
                    endcase
                    if (out_remaining > 16'd8) begin
                        perm_state_in <= cxof_state;
                        perm_rounds   <= 4'd12;
                        perm_start    <= 1'b1;
                        squeeze_idx   <= squeeze_idx + 5'd8;
                        out_remaining <= out_remaining - 16'd8;
                        state         <= S_SQ_WAIT;
                    end else begin
                        state <= S_FINISH;
                    end
                end
                S_SQ_WAIT: begin
                    if (perm_done) begin
                        cxof_state <= perm_state_out;
                        state      <= S_SQ_KICK;
                    end
                end

                S_FINISH: begin
                    if (passes_left > 16'd1) begin
                        // Internal chained mode:
                        // previous 32-byte digest becomes the next message.
                        // This avoids a top-level 256-bit feedback register/mux.
                        passes_left   <= passes_left - 16'd1;
                        cxof_state    <= {256'd0, CXOF128_IV};
                        cs_shift      <= cs_data;
                        msg_shift     <= result_data;
                        cs_remaining  <= cs_length;
                        msg_remaining <= 8'd32;
                        out_remaining <= 16'd32;
                        squeeze_idx   <= 5'd0;
                        result_data   <= 256'd0;
                        busy          <= 1'b1;
                        done          <= 1'b0;
                        state         <= S_INIT_KICK;
                    end else begin
                        result_valid <= 1'b1;
                        busy         <= 1'b0;
                        done         <= 1'b1;
                        state        <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
