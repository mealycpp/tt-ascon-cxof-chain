/*
 * Single round of the ASCON permutation.
 *
 * The ASCON-p permutation operates on a 320-bit state organized as five
 * 64-bit words: S = (x0, x1, x2, x3, x4).
 *
 * Convention (matches the ASCON team's official C reference):
 *   x0 = state[63:0]      (the rate word - where absorption happens)
 *   x1 = state[127:64]
 *   x2 = state[191:128]
 *   x3 = state[255:192]
 *   x4 = state[319:256]
 *
 * Each round applies:
 *   1. pC: add round constant to x2
 *   2. pS: nonlinear S-box layer (5-bit S-box applied bitwise across 64 lanes)
 *   3. pL: linear diffusion (rotation-based mixing within each word)
 *
 * Reference: NIST SP 800-232 (Aug 2025), and Dobraunig et al., "ASCON v1.2",
 * Journal of Cryptology 34:33 (2021).
 *
 * This is combinational — one round per cycle. The CXOF controller
 * sequences the rounds.
 */

`default_nettype none

module ascon_round (
    input  wire [319:0] state_in,
    input  wire [7:0]   round_const,
    output wire [319:0] state_out
);

    // Unpack the 320-bit state into five 64-bit words.
    // x0 at the LSB end (matches C reference's s.x[0]).
    wire [63:0] x0_in, x1_in, x2_in, x3_in, x4_in;
    assign x0_in = state_in[63:0];
    assign x1_in = state_in[127:64];
    assign x2_in = state_in[191:128];
    assign x3_in = state_in[255:192];
    assign x4_in = state_in[319:256];

    // ---- pC: add round constant to x2 (lowest 8 bits of x2) ----
    wire [63:0] x0_c, x1_c, x2_c, x3_c, x4_c;
    assign x0_c = x0_in;
    assign x1_c = x1_in;
    assign x2_c = {x2_in[63:8], x2_in[7:0] ^ round_const};
    assign x3_c = x3_in;
    assign x4_c = x4_in;

    // ---- pS: nonlinear S-box layer (bitsliced form) ----
    //   x0 ^= x4;  x4 ^= x3;  x2 ^= x1
    //   ti = (~xi) & x(i+1 mod 5)
    //   xi ^= t(i+1 mod 5)
    //   x1 ^= x0;  x0 ^= x4;  x3 ^= x2;  x2 = ~x2
    wire [63:0] s0_a, s2_a, s4_a;
    assign s0_a = x0_c ^ x4_c;
    assign s4_a = x4_c ^ x3_c;
    assign s2_a = x2_c ^ x1_c;
    wire [63:0] s1_a_p = x1_c;
    wire [63:0] s3_a_p = x3_c;

    wire [63:0] t0, t1, t2, t3, t4;
    assign t0 = (~s0_a)   & s1_a_p;
    assign t1 = (~s1_a_p) & s2_a;
    assign t2 = (~s2_a)   & s3_a_p;
    assign t3 = (~s3_a_p) & s4_a;
    assign t4 = (~s4_a)   & s0_a;

    wire [63:0] s0_b, s1_b, s2_b, s3_b, s4_b;
    assign s0_b = s0_a   ^ t1;
    assign s1_b = s1_a_p ^ t2;
    assign s2_b = s2_a   ^ t3;
    assign s3_b = s3_a_p ^ t4;
    assign s4_b = s4_a   ^ t0;

    wire [63:0] s0_c, s1_c, s2_c, s3_c, s4_c;
    assign s1_c = s1_b ^ s0_b;
    assign s0_c = s0_b ^ s4_b;
    assign s3_c = s3_b ^ s2_b;
    assign s2_c = ~s2_b;
    assign s4_c = s4_b;

    // ---- pL: linear diffusion ----
    //   x0 ^= rotr(x0, 19) ^ rotr(x0, 28)
    //   x1 ^= rotr(x1, 61) ^ rotr(x1, 39)
    //   x2 ^= rotr(x2, 1)  ^ rotr(x2, 6)
    //   x3 ^= rotr(x3, 10) ^ rotr(x3, 17)
    //   x4 ^= rotr(x4, 7)  ^ rotr(x4, 41)
    function [63:0] rotr64;
        input [63:0] x;
        input [5:0]  n;
        begin
            rotr64 = (x >> n) | (x << (7'd64 - {1'b0, n}));
        end
    endfunction

    wire [63:0] x0_l, x1_l, x2_l, x3_l, x4_l;
    assign x0_l = s0_c ^ rotr64(s0_c, 6'd19) ^ rotr64(s0_c, 6'd28);
    assign x1_l = s1_c ^ rotr64(s1_c, 6'd61) ^ rotr64(s1_c, 6'd39);
    assign x2_l = s2_c ^ rotr64(s2_c, 6'd1 ) ^ rotr64(s2_c, 6'd6 );
    assign x3_l = s3_c ^ rotr64(s3_c, 6'd10) ^ rotr64(s3_c, 6'd17);
    assign x4_l = s4_c ^ rotr64(s4_c, 6'd7 ) ^ rotr64(s4_c, 6'd41);

    // Repack with x0 at LSB end
    assign state_out = {x4_l, x3_l, x2_l, x1_l, x0_l};

endmodule
