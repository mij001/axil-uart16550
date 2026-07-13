`timescale 1ns / 1ps

// baud gen, 8.5.1. tick is one cycle every divisor cycles, 16 ticks a bit
// no divided clock, tick is an enable. divisor 0 stops it

module uart_baud (
    input  logic        clk,
    input  logic        rstn,

    input  logic [15:0] divisor,      // DLM:DLL as stored now
    input  logic        load,         // DLL or DLM is written this cycle
    input  logic [15:0] load_value,   // the divisor after that write

    output logic         tick
);

    logic [15:0] cnt_q,  cnt_d;
    logic tick_q, tick_d;
    logic run;                  // the generator runs next cycle

    // b1
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            cnt_q  <= 16'd0;
            tick_q <= 1'b0;
        end else begin
            cnt_q  <= cnt_d;
            tick_q <= tick_d;
        end
    end

    // b2
    always_comb begin
        if (load) begin
            run   = (load_value != 16'd0);
            cnt_d = run ? load_value - 16'd1 : 16'd0;
        end else begin
            run = (divisor != 16'd0);
            if (!run)
                cnt_d = 16'd0;
            else if (cnt_q == 16'd0)
                cnt_d = divisor - 16'd1;
            else
                cnt_d = cnt_q - 16'd1;
        end

        tick_d = run & (cnt_d == 16'd0);
    end

    // b3
    always_comb begin
        tick = tick_q;
    end

endmodule
