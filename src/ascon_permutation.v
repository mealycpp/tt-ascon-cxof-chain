/*
 * ASCON permutation engine.
 *
 * Iterates the ASCON-p round function for a parameterizable number of rounds.
 * Standard variants:
 *   p[12]: 12 rounds, used for initialization and finalization
 *   p[8]:  8 rounds,  used for absorption and squeezing in some modes (ASCON-CXOF uses p[12])
 *
 * For ASCON-CXOF (NIST SP 800-232), all permutation calls use p[12].
 *
 * Round constants for p[12] (round 0 .. 11):
 *   0xf0, 0xe1, 0xd2, 0xc3, 0xb4, 0xa5, 0x96, 0x87, 0x78, 0x69, 0x5a, 0x4b
 *
 * Interface:
 *   start: pulse high for one cycle to begin
 *   busy:  high while running
 *   done:  pulses high for one cycle when result is on state_out
 */

`default_nettype none

module ascon_permutation (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire [3:0]  num_rounds,    // typically 12 for CXOF
    input  wire [319:0] state_in,

    output reg  [319:0] state_out,
    output reg          busy,
    output reg          done
);

    // Round constants table (p[12] uses indices 0..11)
    function [7:0] round_constant;
        input [3:0] r;
        begin
            case (r)
                4'd0:  round_constant = 8'hf0;
                4'd1:  round_constant = 8'he1;
                4'd2:  round_constant = 8'hd2;
                4'd3:  round_constant = 8'hc3;
                4'd4:  round_constant = 8'hb4;
                4'd5:  round_constant = 8'ha5;
                4'd6:  round_constant = 8'h96;
                4'd7:  round_constant = 8'h87;
                4'd8:  round_constant = 8'h78;
                4'd9:  round_constant = 8'h69;
                4'd10: round_constant = 8'h5a;
                4'd11: round_constant = 8'h4b;
                default: round_constant = 8'h00;
            endcase
        end
    endfunction

    reg [319:0] state_reg;
    reg [3:0]   round_idx;
    reg [3:0]   target_rounds;

    wire [319:0] state_next;
    ascon_round u_round (
        .state_in    (state_reg),
        .round_const (round_constant(round_idx)),
        .state_out   (state_next)
    );

    // FSM: IDLE -> RUN -> DONE_PULSE -> IDLE
    localparam S_IDLE = 2'd0;
    localparam S_RUN  = 2'd1;
    localparam S_DONE = 2'd2;

    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            state_reg     <= 320'd0;
            state_out     <= 320'd0;
            round_idx     <= 4'd0;
            target_rounds <= 4'd0;
            busy          <= 1'b0;
            done          <= 1'b0;
        end else begin
            done <= 1'b0;  // default: pulse off
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        state_reg     <= state_in;
                        round_idx     <= 4'd0;
                        target_rounds <= num_rounds;
                        busy          <= 1'b1;
                        state         <= S_RUN;
                    end
                end
                S_RUN: begin
                    state_reg <= state_next;
                    if (round_idx + 4'd1 == target_rounds) begin
                        state     <= S_DONE;
                    end else begin
                        round_idx <= round_idx + 4'd1;
                    end
                end
                S_DONE: begin
                    state_out <= state_reg;  // capture final state
                    done      <= 1'b1;
                    busy      <= 1'b0;
                    state     <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
