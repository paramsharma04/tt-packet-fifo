`timescale 1ns/1ps
`default_nettype none

module tb;
    reg  [7:0] ui_in, uio_in;
    wire [7:0] uo_out, uio_out, uio_oe;
    reg clk = 0, rst_n = 0, ena = 1;
    integer errors = 0;

    tt_um_packet_fifo dut (
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in),
        .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(ena), .clk(clk), .rst_n(rst_n)
    );

    always #5 clk = ~clk;

    wire full  = uio_out[5];
    wire empty = uio_out[6];
    wire drop  = uio_out[7];

    task wr(input [7:0] d, input s, input e, input err);
        begin
            @(negedge clk);
            ui_in  = d;
            uio_in = {3'b0, err, e, s, 1'b0, 1'b1};
            @(negedge clk);
            uio_in = 8'b0;
        end
    endtask

    task rd(output [7:0] d);
        begin
            @(negedge clk);
            uio_in = 8'b0000_0010;
            d = uo_out;
            @(negedge clk);
            uio_in = 8'b0;
        end
    endtask

    task check(input [8*40:1] name, input cond);
        begin
            if (cond) $display("  PASS: %0s", name);
            else begin $display("  FAIL: %0s", name); errors = errors + 1; end
        end
    endtask

    reg [7:0] d;

    initial begin
        ui_in = 0; uio_in = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        $display("\n-- 1. empty after reset --");
        check("empty asserted", empty === 1'b1);

        $display("\n-- 2. good 3-word packet commits --");
        wr(8'hA1, 1, 0, 0);
        wr(8'hA2, 0, 0, 0);
        check("not visible mid-packet", empty === 1'b1);
        wr(8'hA3, 0, 1, 0);
        check("visible after EOP", empty === 1'b0);
        rd(d); check("word 1 = A1", d === 8'hA1);
        rd(d); check("word 2 = A2", d === 8'hA2);
        rd(d); check("word 3 = A3", d === 8'hA3);
        check("empty again", empty === 1'b1);

        $display("\n-- 3. bad packet is dropped whole --");
        wr(8'hB1, 1, 0, 0);
        wr(8'hB2, 0, 0, 0);
        wr(8'hB3, 0, 1, 1);          // EOP flagged bad
        check("nothing committed", empty === 1'b1);
        check("drop flag set", drop === 1'b1);

        $display("\n-- 4. good packet after a dropped one --");
        wr(8'hC1, 1, 0, 0);
        wr(8'hC2, 0, 1, 0);
        check("committed", empty === 1'b0);
        check("drop flag cleared", drop === 1'b0);
        rd(d); check("word 1 = C1", d === 8'hC1);
        rd(d); check("word 2 = C2", d === 8'hC2);

        $display("\n-- 5. single-word packet (SOP+EOP together) --");
        wr(8'hD1, 1, 1, 0);
        check("committed", empty === 1'b0);
        rd(d); check("word = D1", d === 8'hD1);

        $display("\n-- 6. oversized packet is dropped --");
        wr(8'hE0, 1, 0, 0);
        wr(8'hE1, 0, 0, 0);
        wr(8'hE2, 0, 0, 0);
        wr(8'hE3, 0, 0, 0);
        wr(8'hE4, 0, 0, 0);
        wr(8'hE5, 0, 0, 0);
        wr(8'hE6, 0, 0, 0);
        wr(8'hE7, 0, 0, 0);
        wr(8'hE8, 0, 0, 0);          // overflows depth 8
        wr(8'hE9, 0, 1, 0);
        check("oversized dropped", empty === 1'b1);
        check("drop flag set", drop === 1'b1);

        $display("\n-- 7. recovers after overflow --");
        wr(8'hF1, 1, 1, 0);
        check("committed", empty === 1'b0);
        rd(d); check("word = F1", d === 8'hF1);

        $display("\n========================================");
        if (errors == 0) $display("ALL TESTS PASSED");
        else $display("%0d FAILURE(S)", errors);
        $display("========================================\n");
        $finish;
    end
endmodule
