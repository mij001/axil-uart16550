`timescale 1ns / 1ps

// bus bfm. aw and w in either order and with a gap

module axil_master_bfm #(
    parameter integer ADDR_W = 12
) (
    input  wire              aclk,

    output reg               awvalid,
    output reg  [ADDR_W-1:0] awaddr,
    output reg  [2:0]        awprot,
    input  wire              awready,

    output reg               wvalid,
    output reg  [31:0]       wdata,
    output reg  [3:0]        wstrb,
    input  wire              wready,

    input  wire              bvalid,
    input  wire [1:0]        bresp,
    output reg               bready,

    output reg               arvalid,
    output reg  [ADDR_W-1:0] araddr,
    output reg  [2:0]        arprot,
    input  wire              arready,

    input  wire              rvalid,
    input  wire [31:0]       rdata,
    input  wire [1:0]        rresp,
    output reg               rready
);

    integer seed;
    integer max_dly;
    integer force_aw, force_w, force_b, force_ar, force_r;
    integer usage_errors;

    // coverage of channel orderings, for the testbench report
    integer n_aw_first, n_w_first, n_aw_w_same;
    integer n_writes, n_reads;

    integer aw_at, w_at;          // cycle stamps of the two write handshakes
    integer cyc;

    initial begin
        awvalid = 1'b0; awaddr = 0; awprot = 3'd0;
        wvalid  = 1'b0; wdata  = 0; wstrb  = 4'd0;
        bready  = 1'b0;
        arvalid = 1'b0; araddr = 0; arprot = 3'd0;
        rready  = 1'b0;
        seed = 1; max_dly = 3;
        force_aw = -1; force_w = -1; force_b = -1; force_ar = -1; force_r = -1;
        usage_errors = 0;
        n_aw_first = 0; n_w_first = 0; n_aw_w_same = 0; n_writes = 0; n_reads = 0;
        aw_at = 0; w_at = 0; cyc = 0;
    end

    always @(posedge aclk) cyc = cyc + 1;

    function integer urand;
        input integer n;
        begin
            urand = (n <= 0) ? 0 : ({$random(seed)} % (n + 1));
        end
    endfunction

    function integer pick;
        input integer forced;
        begin
            pick = (forced >= 0) ? forced : urand(max_dly);
        end
    endfunction

    task no_delays;
        begin
            force_aw = 0; force_w = 0; force_b = 0; force_ar = 0; force_r = 0;
        end
    endtask

    task random_delays;
        begin
            force_aw = -1; force_w = -1; force_b = -1; force_ar = -1; force_r = -1;
        end
    endtask

    task write;
        input  [ADDR_W-1:0] a;
        input  [31:0]       d;
        input  [3:0]        s;
        output [1:0]        resp;
        integer dly_aw, dly_w, dly_b;
        begin
            if (aclk !== 1'b0) begin
                // report, then recover: driving now could put VALID up and down
                $display("[%0t] BFM USE ERROR: write must start at a falling edge", $time);
                usage_errors = usage_errors + 1;
                @(negedge aclk);
            end
            dly_aw = pick(force_aw);
            dly_w  = pick(force_w);
            dly_b  = pick(force_b);
            if (force_b < 0 && urand(3) == 0) bready = 1'b1;

            fork
                begin : aw_channel
                    repeat (dly_aw) @(negedge aclk);
                    awaddr = a; awprot = urand(7); awvalid = 1'b1;
                    while (awready !== 1'b1) @(negedge aclk);
                    aw_at = cyc;
                    @(negedge aclk);
                    awvalid = 1'b0; awaddr = $random(seed);
                end
                begin : w_channel
                    repeat (dly_w) @(negedge aclk);
                    wdata = d; wstrb = s; wvalid = 1'b1;
                    while (wready !== 1'b1) @(negedge aclk);
                    w_at = cyc;
                    @(negedge aclk);
                    wvalid = 1'b0; wdata = $random(seed); wstrb = $random(seed);
                end
            join

            if (aw_at < w_at)  n_aw_first  = n_aw_first + 1;
            if (aw_at > w_at)  n_w_first   = n_w_first + 1;
            if (aw_at == w_at) n_aw_w_same = n_aw_w_same + 1;

            if (!bready) begin
                repeat (dly_b) @(negedge aclk);
                bready = 1'b1;
            end
            while (bvalid !== 1'b1) @(negedge aclk);
            resp = bresp;
            @(negedge aclk);
            bready = 1'b0;
            n_writes = n_writes + 1;
        end
    endtask

    task read;
        input  [ADDR_W-1:0] a;
        output [31:0]       d;
        output [1:0]        resp;
        integer dly_ar, dly_r;
        begin
            if (aclk !== 1'b0) begin
                $display("[%0t] BFM USE ERROR: read must start at a falling edge", $time);
                usage_errors = usage_errors + 1;
                @(negedge aclk);
            end
            dly_ar = pick(force_ar);
            dly_r  = pick(force_r);
            if (force_r < 0 && urand(3) == 0) rready = 1'b1;

            repeat (dly_ar) @(negedge aclk);
            araddr = a; arprot = urand(7); arvalid = 1'b1;
            while (arready !== 1'b1) @(negedge aclk);
            @(negedge aclk);
            arvalid = 1'b0; araddr = $random(seed);

            if (!rready) begin
                repeat (dly_r) @(negedge aclk);
                rready = 1'b1;
            end
            while (rvalid !== 1'b1) @(negedge aclk);
            d    = rdata;
            resp = rresp;
            @(negedge aclk);
            rready = 1'b0;
            n_reads = n_reads + 1;
        end
    endtask

endmodule
