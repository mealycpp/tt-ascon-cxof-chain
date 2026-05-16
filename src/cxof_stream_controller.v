/*
 * Streaming ASCON-CXOF controller.
 *
 * This module removes the wide register-file crypto interface:
 *   no cs_data[255:0]
 *   no msg_data[255:0]
 *   no result_latched[255:0]
 *
 * Input is pulled as 64-bit words using in_word_ready/in_word_valid.
 * Output is pushed as bytes using out_valid/out_ready.
 */

`default_nettype none

module cxof_stream_controller (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire        reset_engine,

    input  wire [7:0]  cs_length,
    input  wire [7:0]  msg_length,
    input  wire [15:0] out_length,
    input  wire        chain_enable,
    input  wire [15:0] chain_count,

    input  wire [63:0] in_word,
    input  wire        in_word_valid,
    output reg         in_word_ready,
    output reg         in_word_kind,   // 0 = CS, 1 = MSG
    output reg  [3:0]  in_word_bytes,  // requested useful bytes, 1..8

    output reg  [7:0]  out_byte,
    output reg         out_valid,
    input  wire        out_ready,
    output reg         out_last,

    output reg         busy,
    output reg         done
);

    localparam [63:0] CXOF128_IV = 64'h0000_0800_00CC_0004;

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

    wire _unused = &{perm_busy, 1'b0};

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
                default: pad_val = 64'd0;
            endcase
        end
    endfunction

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
                default: mask_n = 64'd0;
            endcase
        end
    endfunction

    function [63:0] chain_word_at;
        input [255:0] data;
        input [2:0] idx;
        begin
            case (idx[1:0])
                2'd0: chain_word_at = data[63:0];
                2'd1: chain_word_at = data[127:64];
                2'd2: chain_word_at = data[191:128];
                2'd3: chain_word_at = data[255:192];
                default: chain_word_at = 64'd0;
            endcase
        end
    endfunction

    localparam S_IDLE          = 5'd0;
    localparam S_INIT_KICK     = 5'd1;
    localparam S_INIT_WAIT     = 5'd2;
    localparam S_LEN_KICK      = 5'd3;
    localparam S_LEN_WAIT      = 5'd4;
    localparam S_REQ_CS_FULL   = 5'd5;
    localparam S_CS_KICK       = 5'd6;
    localparam S_CS_WAIT       = 5'd7;
    localparam S_REQ_CS_FIN    = 5'd8;
    localparam S_CS_FIN_KICK   = 5'd9;
    localparam S_CS_FIN_WAIT   = 5'd10;
    localparam S_REQ_MSG_FULL  = 5'd11;
    localparam S_MSG_KICK      = 5'd12;
    localparam S_MSG_WAIT      = 5'd13;
    localparam S_REQ_MSG_FIN   = 5'd14;
    localparam S_MSG_FIN_KICK  = 5'd15;
    localparam S_MSG_FIN_WAIT  = 5'd16;
    localparam S_SQ_PREP       = 5'd17;
    localparam S_OUT_SEND      = 5'd18;
    localparam S_SQ_PERM_KICK  = 5'd19;
    localparam S_SQ_PERM_WAIT  = 5'd20;
    localparam S_PASS_FINISH   = 5'd21;
    localparam S_OUT_LOAD      = 5'd22;

    reg [4:0]   state;
    reg [319:0] cxof_state;
    reg [63:0]  cur_word;

    reg [7:0]   cs_remaining;
    reg [7:0]   msg_remaining;
    reg [2:0]   msg_word_idx;
    reg         msg_chain_source;

    reg [15:0]  out_remaining;
    reg [15:0]  passes_left;
    reg [255:0] chain_digest;
    reg [4:0]   squeeze_idx;
    reg [63:0]  squeeze_word;
    reg [3:0]   byte_idx;
    reg [3:0]   bytes_this_word;

    wire [15:0] requested_passes =
        (chain_enable && (chain_count != 16'd0)) ? chain_count : 16'd1;

    wire [15:0] effective_out_length =
        (out_length > 16'd32) ? 16'd32 : out_length;

    wire [15:0] pass_out_length =
        chain_enable ? 16'd32 : effective_out_length;

    wire final_pass = (passes_left <= 16'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            cxof_state       <= 320'd0;
            cur_word         <= 64'd0;
            cs_remaining     <= 8'd0;
            msg_remaining    <= 8'd0;
            msg_word_idx     <= 3'd0;
            msg_chain_source <= 1'b0;
            out_remaining    <= 16'd0;
            passes_left      <= 16'd0;
            chain_digest     <= 256'd0;
            squeeze_idx      <= 5'd0;
            squeeze_word     <= 64'd0;
            byte_idx         <= 4'd0;
            bytes_this_word  <= 4'd0;

            perm_start       <= 1'b0;
            perm_rounds      <= 4'd12;
            perm_state_in    <= 320'd0;

            in_word_ready    <= 1'b0;
            in_word_kind     <= 1'b0;
            in_word_bytes    <= 4'd0;

            out_byte         <= 8'd0;
            out_valid        <= 1'b0;
            out_last         <= 1'b0;

            busy             <= 1'b0;
            done             <= 1'b0;
        end else if (reset_engine) begin
            state         <= S_IDLE;
            busy          <= 1'b0;
            done          <= 1'b0;
            perm_start    <= 1'b0;
            in_word_ready <= 1'b0;
            out_valid     <= 1'b0;
            out_last      <= 1'b0;
        end else begin
            perm_start    <= 1'b0;
            in_word_ready <= 1'b0;
            done          <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy      <= 1'b0;
                    out_valid <= 1'b0;
                    out_last  <= 1'b0;
                    if (start) begin
                        busy             <= 1'b1;
                        cs_remaining     <= cs_length;
                        msg_remaining    <= msg_length;
                        msg_word_idx     <= 3'd0;
                        msg_chain_source <= 1'b0;
                        out_remaining    <= pass_out_length;
                        passes_left      <= requested_passes;
                        squeeze_idx      <= 5'd0;
                        state            <= S_INIT_KICK;
                    end
                end

                S_INIT_KICK: begin
                    perm_state_in <= {256'd0, CXOF128_IV};
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
                                      cxof_state[63:0] ^ {53'd0, cs_remaining, 3'b000}};
                    perm_rounds   <= 4'd12;
                    perm_start    <= 1'b1;
                    state         <= S_LEN_WAIT;
                end

                S_LEN_WAIT: begin
                    if (perm_done) begin
                        cxof_state <= perm_state_out;
                        if (cs_remaining >= 8'd8)
                            state <= S_REQ_CS_FULL;
                        else if (cs_remaining[2:0] != 3'd0)
                            state <= S_REQ_CS_FIN;
                        else begin
                            cur_word <= 64'd0;
                            state    <= S_CS_FIN_KICK;
                        end
                    end
                end

                S_REQ_CS_FULL: begin
                    in_word_ready <= 1'b1;
                    in_word_kind  <= 1'b0;
                    in_word_bytes <= 4'd8;
                    if (in_word_valid) begin
                        cur_word      <= in_word;
                        in_word_ready <= 1'b0;
                        state         <= S_CS_KICK;
                    end
                end

                S_CS_KICK: begin
                    perm_state_in <= {cxof_state[319:64],
                                      cxof_state[63:0] ^ cur_word};
                    perm_rounds   <= 4'd12;
                    perm_start    <= 1'b1;
                    state         <= S_CS_WAIT;
                end

                S_CS_WAIT: begin
                    if (perm_done) begin
                        cxof_state   <= perm_state_out;
                        cs_remaining <= cs_remaining - 8'd8;
                        if ((cs_remaining - 8'd8) >= 8'd8)
                            state <= S_REQ_CS_FULL;
                        else if ((cs_remaining - 8'd8) != 8'd0)
                            state <= S_REQ_CS_FIN;
                        else begin
                            cur_word <= 64'd0;
                            state    <= S_CS_FIN_KICK;
                        end
                    end
                end

                S_REQ_CS_FIN: begin
                    in_word_ready <= 1'b1;
                    in_word_kind  <= 1'b0;
                    in_word_bytes <= {1'b0, cs_remaining[2:0]};
                    if (in_word_valid) begin
                        cur_word      <= in_word;
                        in_word_ready <= 1'b0;
                        state         <= S_CS_FIN_KICK;
                    end
                end

                S_CS_FIN_KICK: begin
                    perm_state_in <= {cxof_state[319:64],
                                      cxof_state[63:0]
                                      ^ (cur_word & mask_n(cs_remaining[3:0]))
                                      ^ pad_val(cs_remaining[3:0])};
                    perm_rounds   <= 4'd12;
                    perm_start    <= 1'b1;
                    state         <= S_CS_FIN_WAIT;
                end

                S_CS_FIN_WAIT: begin
                    if (perm_done) begin
                        cxof_state <= perm_state_out;
                        if (msg_remaining >= 8'd8)
                            state <= S_REQ_MSG_FULL;
                        else if (msg_remaining[2:0] != 3'd0)
                            state <= S_REQ_MSG_FIN;
                        else begin
                            cur_word <= 64'd0;
                            state    <= S_MSG_FIN_KICK;
                        end
                    end
                end

                S_REQ_MSG_FULL: begin
                    if (msg_chain_source) begin
                        cur_word <= chain_word_at(chain_digest, msg_word_idx);
                        state    <= S_MSG_KICK;
                    end else begin
                        in_word_ready <= 1'b1;
                        in_word_kind  <= 1'b1;
                        in_word_bytes <= 4'd8;
                        if (in_word_valid) begin
                            cur_word      <= in_word;
                            in_word_ready <= 1'b0;
                            state         <= S_MSG_KICK;
                        end
                    end
                end

                S_MSG_KICK: begin
                    perm_state_in <= {cxof_state[319:64],
                                      cxof_state[63:0] ^ cur_word};
                    perm_rounds   <= 4'd12;
                    perm_start    <= 1'b1;
                    state         <= S_MSG_WAIT;
                end

                S_MSG_WAIT: begin
                    if (perm_done) begin
                        cxof_state    <= perm_state_out;
                        msg_word_idx  <= msg_word_idx + 3'd1;
                        msg_remaining <= msg_remaining - 8'd8;
                        if ((msg_remaining - 8'd8) >= 8'd8)
                            state <= S_REQ_MSG_FULL;
                        else if ((msg_remaining - 8'd8) != 8'd0)
                            state <= S_REQ_MSG_FIN;
                        else begin
                            cur_word <= 64'd0;
                            state    <= S_MSG_FIN_KICK;
                        end
                    end
                end

                S_REQ_MSG_FIN: begin
                    if (msg_chain_source) begin
                        cur_word <= chain_word_at(chain_digest, msg_word_idx);
                        state    <= S_MSG_FIN_KICK;
                    end else begin
                        in_word_ready <= 1'b1;
                        in_word_kind  <= 1'b1;
                        in_word_bytes <= {1'b0, msg_remaining[2:0]};
                        if (in_word_valid) begin
                            cur_word      <= in_word;
                            in_word_ready <= 1'b0;
                            state         <= S_MSG_FIN_KICK;
                        end
                    end
                end

                S_MSG_FIN_KICK: begin
                    perm_state_in <= {cxof_state[319:64],
                                      cxof_state[63:0]
                                      ^ (cur_word & mask_n(msg_remaining[3:0]))
                                      ^ pad_val(msg_remaining[3:0])};
                    perm_rounds   <= 4'd12;
                    perm_start    <= 1'b1;
                    state         <= S_MSG_FIN_WAIT;
                end

                S_MSG_FIN_WAIT: begin
                    if (perm_done) begin
                        cxof_state    <= perm_state_out;
                        out_remaining <= pass_out_length;
                        squeeze_idx   <= 5'd0;
                        state         <= S_SQ_PREP;
                    end
                end

                S_SQ_PREP: begin
                    squeeze_word <= cxof_state[63:0];
                    byte_idx     <= 4'd0;

                    if (out_remaining >= 16'd8)
                        bytes_this_word <= 4'd8;
                    else
                        bytes_this_word <= out_remaining[3:0];

                    if (!final_pass) begin
                        case (squeeze_idx)
                            5'd0:  chain_digest[63:0]    <= cxof_state[63:0];
                            5'd8:  chain_digest[127:64]  <= cxof_state[63:0];
                            5'd16: chain_digest[191:128] <= cxof_state[63:0];
                            5'd24: chain_digest[255:192] <= cxof_state[63:0];
                            default: ;
                        endcase

                        if (out_remaining > 16'd8)
                            state <= S_SQ_PERM_KICK;
                        else
                            state <= S_PASS_FINISH;
                    end else begin
                        state <= S_OUT_LOAD;
                    end
                end

                S_OUT_LOAD: begin
                    out_valid <= 1'b1;
                    out_byte  <= squeeze_word[7:0];
                    out_last  <= (out_remaining <= {12'd0, bytes_this_word}) &&
                                 (byte_idx == (bytes_this_word - 4'd1));
                    state     <= S_OUT_SEND;
                end

                S_OUT_SEND: begin
                    if (out_valid && out_ready) begin
                        out_valid    <= 1'b0;
                        out_last     <= 1'b0;
                        squeeze_word <= {8'd0, squeeze_word[63:8]};

                        if (byte_idx == (bytes_this_word - 4'd1)) begin
                            out_remaining <= out_remaining - {12'd0, bytes_this_word};

                            if (out_remaining > {12'd0, bytes_this_word})
                                state <= S_SQ_PERM_KICK;
                            else
                                state <= S_PASS_FINISH;
                        end else begin
                            byte_idx <= byte_idx + 4'd1;
                            state    <= S_OUT_LOAD;
                        end
                    end
                end

                S_SQ_PERM_KICK: begin
                    perm_state_in <= cxof_state;
                    perm_rounds   <= 4'd12;
                    perm_start    <= 1'b1;
                    squeeze_idx   <= squeeze_idx + 5'd8;
                    if (!final_pass)
                        out_remaining <= out_remaining - 16'd8;
                    state         <= S_SQ_PERM_WAIT;
                end

                S_SQ_PERM_WAIT: begin
                    if (perm_done) begin
                        cxof_state <= perm_state_out;
                        state      <= S_SQ_PREP;
                    end
                end

                S_PASS_FINISH: begin
                    if (passes_left > 16'd1) begin
                        passes_left      <= passes_left - 16'd1;
                        cs_remaining     <= cs_length;
                        msg_remaining    <= 8'd32;
                        msg_word_idx     <= 3'd0;
                        msg_chain_source <= 1'b1;
                        out_remaining    <= 16'd32;
                        squeeze_idx      <= 5'd0;
                        state            <= S_INIT_KICK;
                    end else begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
