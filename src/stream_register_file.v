/*
 * Stream-oriented register file.
 *
 * Host still writes/reads byte registers using the existing UART protocol.
 * The CXOF engine no longer receives 256-bit cs/msg/result buses.
 * Instead, this module supplies 64-bit input words and captures output bytes.
 */

`default_nettype none

module stream_register_file (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         we,
    input  wire         re,
    input  wire [7:0]   addr,
    input  wire [7:0]   wdata,
    output reg  [7:0]   rdata,

    output reg  [7:0]   cs_length,
    output reg  [7:0]   msg_length,
    output reg  [15:0]  out_length,
    output reg          chain_enable,
    output reg  [15:0]  chain_count,

    output wire [63:0]  in_word,
    output wire         in_word_valid,
    input  wire         in_word_ready,
    input  wire         in_word_kind,
    input  wire [2:0]   in_word_index,
    input  wire [3:0]   in_word_bytes,

    input  wire [7:0]   stream_out_byte,
    input  wire         stream_out_valid,
    output wire         stream_out_ready,
    input  wire         stream_out_last,

    input  wire         engine_busy,
    input  wire         engine_done,
    input  wire         engine_error
);

    reg [7:0] cs_mem     [0:31];
    reg [7:0] msg_mem    [0:31];
    reg [7:0] result_mem [0:31];

    reg       result_present;
    reg       engine_busy_d;
    reg [4:0] result_wr_idx;

    reg [63:0] word_mux;
    wire [4:0] word_base = {in_word_index[1:0], 3'b000};

    integer i;
    integer j;

    assign in_word        = word_mux;
    assign in_word_valid  = in_word_ready;
    assign stream_out_ready = 1'b1;

    wire _unused = &{in_word_bytes, 1'b0};

    always @* begin
        word_mux = 64'd0;
        for (j = 0; j < 8; j = j + 1) begin
            if (in_word_kind)
                word_mux[(8*j) +: 8] = msg_mem[word_base + j];
            else
                word_mux[(8*j) +: 8] = cs_mem[word_base + j];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_present <= 1'b0;
            engine_busy_d  <= 1'b0;
            result_wr_idx  <= 5'd0;
            for (i = 0; i < 32; i = i + 1) begin
                result_mem[i] <= 8'd0;
            end
        end else begin
            engine_busy_d <= engine_busy;

            if (engine_busy && !engine_busy_d) begin
                result_present <= 1'b0;
                result_wr_idx  <= 5'd0;
            end else if (stream_out_valid && stream_out_ready) begin
                result_mem[result_wr_idx] <= stream_out_byte;
                if (result_wr_idx != 5'd31)
                    result_wr_idx <= result_wr_idx + 5'd1;

                if (stream_out_last)
                    result_present <= 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs_length    <= 8'd0;
            msg_length   <= 8'd0;
            out_length   <= 16'd0;
            chain_enable <= 1'b0;
            chain_count  <= 16'd1;
            rdata        <= 8'd0;

            for (i = 0; i < 32; i = i + 1) begin
                cs_mem[i]  <= 8'd0;
                msg_mem[i] <= 8'd0;
            end
        end else begin
            if (we) begin
                case (addr)
                    8'h02: cs_length         <= wdata;
                    8'h03: msg_length        <= wdata;
                    8'h04: out_length[7:0]   <= wdata;
                    8'h05: out_length[15:8]  <= wdata;
                    8'h06: chain_enable      <= wdata[0];
                    8'h07: chain_count[7:0]  <= wdata;
                    8'h08: chain_count[15:8] <= wdata;
                    default: begin
                        if (addr >= 8'h10 && addr <= 8'h2F)
                            cs_mem[addr[4:0] - 5'h10] <= wdata;
                        else if (addr >= 8'h30 && addr <= 8'h4F)
                            msg_mem[addr[4:0] - 5'h10] <= wdata;
                    end
                endcase
            end

            if (re) begin
                case (addr)
                    8'h00: rdata <= {4'd0, result_present, engine_error, engine_busy, engine_done};
                    8'h02: rdata <= cs_length;
                    8'h03: rdata <= msg_length;
                    8'h04: rdata <= out_length[7:0];
                    8'h05: rdata <= out_length[15:8];
                    8'h06: rdata <= {7'd0, chain_enable};
                    8'h07: rdata <= chain_count[7:0];
                    8'h08: rdata <= chain_count[15:8];
                    8'h80: rdata <= 8'h01;
                    8'h81: rdata <= 8'hAC;
                    default: begin
                        if (addr >= 8'h10 && addr <= 8'h2F)
                            rdata <= cs_mem[addr[4:0] - 5'h10];
                        else if (addr >= 8'h30 && addr <= 8'h4F)
                            rdata <= msg_mem[addr[4:0] - 5'h10];
                        else if (addr >= 8'h50 && addr <= 8'h6F)
                            rdata <= result_mem[addr[4:0] - 5'h10];
                        else
                            rdata <= 8'd0;
                    end
                endcase
            end
        end
    end

endmodule
