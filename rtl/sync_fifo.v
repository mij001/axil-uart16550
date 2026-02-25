`timescale 1ns / 1ps

// sync fifo. count tells full apart from empty, both have wr_ptr == rd_ptr

module sync_fifo #(
    parameter integer WIDTH  = 8,
    parameter integer ADDR_W = 4
) (
    input  wire              clk,
    input  wire              rstn,

    input  wire              clear,
    input  wire              push,
    input  wire [WIDTH-1:0]  din,
    input  wire              pop,

    output wire [WIDTH-1:0]  dout,
    output reg  [ADDR_W:0]   count
);

    localparam integer    DEPTH_I = 1 << ADDR_W;
    localparam [ADDR_W:0] FULL    = DEPTH_I[ADDR_W:0];
    localparam [ADDR_W:0] ONE_C   = {{ADDR_W{1'b0}}, 1'b1};
    localparam [ADDR_W-1:0] ONE_P = {{(ADDR_W-1){1'b0}}, 1'b1};

    reg [ADDR_W-1:0] wr_ptr_q, wr_ptr_d;
    reg [ADDR_W-1:0] rd_ptr_q, rd_ptr_d;
    reg [ADDR_W:0]   count_q,  count_d;

    reg [WIDTH-1:0]  mem [0:DEPTH_I-1];
    reg              mem_we;
    reg [ADDR_W-1:0] mem_waddr;

    // named "now" helpers
    wire do_pop  = pop  & (count_q != {(ADDR_W+1){1'b0}});
    wire do_push = push & ((count_q != FULL) | do_pop);

    //  ------------------------------------------------------------------------- Block
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wr_ptr_q <= {ADDR_W{1'b0}};
            rd_ptr_q <= {ADDR_W{1'b0}};
            count_q  <= {(ADDR_W+1){1'b0}};
        end else begin
            wr_ptr_q <= wr_ptr_d;
            rd_ptr_q <= rd_ptr_d;
            count_q  <= count_d;

            if (mem_we)
                mem[mem_waddr] <= din;
        end
    end

    //  ------------------------------------------------------------------------- Block
    always @(*) begin
        wr_ptr_d  = wr_ptr_q;
        rd_ptr_d  = rd_ptr_q;
        count_d   = count_q;
        mem_we    = 1'b0;
        mem_waddr = wr_ptr_q;

        if (clear) begin
            rd_ptr_d = {ADDR_W{1'b0}};
            if (push) begin
                mem_we    = 1'b1;
                mem_waddr = {ADDR_W{1'b0}};
                wr_ptr_d  = ONE_P;
                count_d   = ONE_C;
            end else begin
                wr_ptr_d  = {ADDR_W{1'b0}};
                count_d   = {(ADDR_W+1){1'b0}};
            end
        end else begin
            if (do_push) begin
                mem_we   = 1'b1;
                wr_ptr_d = wr_ptr_q + ONE_P;
            end
            if (do_pop)
                rd_ptr_d = rd_ptr_q + ONE_P;

            if (do_push && !do_pop)
                count_d = count_q + ONE_C;
            else if (do_pop && !do_push)
                count_d = count_q - ONE_C;
        end
    end

    //  ------------------------------------------------------------------------- Block
    always @(*) begin
        count = count_q;
    end

    //  the head is a lookup into storage at a registered index. it is written as a
    assign dout = mem[rd_ptr_q];

endmodule
