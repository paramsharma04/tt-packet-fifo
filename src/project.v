/*
 * Copyright (c) 2026 Param Sharma
 * SPDX-License-Identifier: Apache-2.0
 *
 * Packet FIFO with commit / rollback semantics.
 *
 * Words are written speculatively. A packet only becomes visible to the
 * reader when it ends cleanly (EOP with no error and no overflow).
 * A malformed or oversized packet is discarded whole by rolling the
 * write pointer back to the last committed position, so the reader can
 * never observe a partial packet.
 */

`default_nettype none

module tt_um_packet_fifo (
    input  wire [7:0] ui_in,    // write data
    output wire [7:0] uo_out,   // read data
    input  wire [7:0] uio_in,   // control inputs
    output wire [7:0] uio_out,  // status outputs
    output wire [7:0] uio_oe,   // IO direction: 1 = output
    input  wire       ena,      // always 1 when powered
    input  wire       clk,
    input  wire       rst_n     // active low reset
);

    localparam ADDR_W = 3;
    localparam DEPTH  = 8;      // 2 ** ADDR_W

    // ---------------- control inputs ----------------
    wire wr_en   = uio_in[0];   // write strobe
    wire rd_en   = uio_in[1];   // read strobe
    wire sop     = uio_in[2];   // start of packet
    wire eop     = uio_in[3];   // end of packet
    wire pkt_err = uio_in[4];   // upstream says this packet is bad

    // ---------------- storage ----------------
    reg [7:0] mem [0:DEPTH-1];

    // Pointers carry one extra MSB so full and empty are distinguishable.
    reg [ADDR_W:0] wr_spec;     // speculative: includes in-flight packet
    reg [ADDR_W:0] wr_commit;   // committed: what the reader may see
    reg [ADDR_W:0] rd_ptr;

    reg pkt_bad;                // sticky fault within current packet
    reg drop_flag;              // sticky: last packet was discarded

    // ---------------- occupancy ----------------
    wire [ADDR_W:0] used_commit = wr_commit - rd_ptr;
    wire [ADDR_W:0] used_spec   = wr_spec   - rd_ptr;

    wire empty = (used_commit == 0);
    wire full  = (used_spec == DEPTH);

    wire do_read = rd_en && !empty;

    // Combinational view of "is this packet already ruined?".
    // SOP clears the sticky bit in the same cycle, which matters for
    // single-word packets where SOP and EOP arrive together.
    wire bad_now = (sop ? 1'b0 : pkt_bad) | pkt_err | full;

    // ---------------- write side ----------------
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_spec   <= 0;
            wr_commit <= 0;
            pkt_bad   <= 1'b0;
            drop_flag <= 1'b0;
        end else if (wr_en) begin

            // track the fault state for the rest of this packet
            pkt_bad <= bad_now;

            // store the word unless there is no room
            if (!full) begin
                mem[wr_spec[ADDR_W-1:0]] <= ui_in;
                wr_spec <= wr_spec + 1'b1;
            end

            // packet boundary: commit it or throw it away
            if (eop) begin
                pkt_bad <= 1'b0;
                if (bad_now) begin
                    wr_spec   <= wr_commit;          // rollback
                    drop_flag <= 1'b1;
                end else begin
                    wr_commit <= wr_spec + 1'b1;     // include the EOP word
                    drop_flag <= 1'b0;
                end
            end
        end
    end

    // ---------------- read side ----------------
    always @(posedge clk) begin
        if (!rst_n)
            rd_ptr <= 0;
        else if (do_read)
            rd_ptr <= rd_ptr + 1'b1;
    end

    assign uo_out = mem[rd_ptr[ADDR_W-1:0]];

    // ---------------- status outputs ----------------
    assign uio_out = {drop_flag, empty, full, 5'b0};
    assign uio_oe  = 8'b1110_0000;   // bits 7:5 drive out, 4:0 are inputs

    // silence lint on unused signals
    wire _unused = &{ena, uio_in[7:5], 1'b0};

endmodule
