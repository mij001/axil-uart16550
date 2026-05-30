`timescale 1ns / 1ps

// transmitter, 8.6.2 fig 7. a character only starts on a tick, bits are 16
// ticks, stop is 16 24 or 32

module uart_tx (
    input  logic       clk,
    input  logic       rstn,

    input  logic       tick,

    // LCR fields, as stored now
    input  logic [1:0] wls,
    input  logic       stb,
    input  logic       pen,
    input  logic       eps,
    input  logic       stick,

    // transmit FIFO
    input  logic [4:0] fifo_count,
    input  logic [7:0] fifo_data,
    output logic        pop,          // same cycle: take fifo_data now

    output logic        txd,          // serial output, idle high
    output logic        busy          // a character is being sent
);

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_START = 3'd1;
    localparam [2:0] ST_DATA  = 3'd2;
    localparam [2:0] ST_PAR   = 3'd3;
    localparam [2:0] ST_STOP  = 3'd4;

    // control
    logic [2:0] state_q,     state_d;
    // datapath
    logic [4:0] sub_q,       sub_d;        // 0 to 15, or to 23 or 31 in the stop bits
    logic [2:0] bitn_q,      bitn_d;
    logic [7:0] shreg_q,     shreg_d;
    logic par_q,       par_d;        // parity bit of this character
    logic [2:0] last_q,      last_d;       // index of the last data bit, 4 to 7
    logic pen_q,       pen_d;
    logic [4:0] stop_last_q, stop_last_d;  // 15, 23 or 31
    logic txd_q,       txd_d;

    // named "now" helpers, for taking a new character
    logic [7:0] mask      = (wls == 2'd0) ? 8'h1F :
                           (wls == 2'd1) ? 8'h3F :
                           (wls == 2'd2) ? 8'h7F : 8'hFF;
    logic [7:0] masked    = fifo_data & mask;
    logic par_calc  = stick ? ~eps : (eps ? ^masked : ~^masked);
    logic [4:0] stop_calc = !stb ? 5'd15 : (wls == 2'd0) ? 5'd23 : 5'd31;

    logic end_bit   = (sub_q == 5'd15);
    logic end_stop  = (sub_q == stop_last_q);
    logic have_char = (fifo_count != 5'd0);
    logic can_take  = tick & have_char &
                           ((state_q == ST_IDLE) | ((state_q == ST_STOP) & end_stop));

    //  ------------------------------------------------------------------------- Block
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_q     <= ST_IDLE;
            sub_q       <= 5'd0;
            bitn_q      <= 3'd0;
            shreg_q     <= 8'd0;
            par_q       <= 1'b0;
            last_q      <= 3'd7;
            pen_q       <= 1'b0;
            stop_last_q <= 5'd15;
            txd_q       <= 1'b1;
        end else begin
            state_q     <= state_d;
            sub_q       <= sub_d;
            bitn_q      <= bitn_d;
            shreg_q     <= shreg_d;
            par_q       <= par_d;
            last_q      <= last_d;
            pen_q       <= pen_d;
            stop_last_q <= stop_last_d;
            txd_q       <= txd_d;
        end
    end

    //  ------------------------------------------------------------------------- Block
    always_comb begin
        state_d     = state_q;
        sub_d       = sub_q;
        bitn_d      = bitn_q;
        shreg_d     = shreg_q;
        par_d       = par_q;
        last_d      = last_q;
        pen_d       = pen_q;
        stop_last_d = stop_last_q;
        pop         = 1'b0;

        if (can_take) begin
            pop         = 1'b1;
            state_d     = ST_START;
            sub_d       = 5'd0;
            bitn_d      = 3'd0;
            shreg_d     = masked;
            par_d       = par_calc;
            last_d      = {1'b1, wls};
            pen_d       = pen;
            stop_last_d = stop_calc;
        end else if (tick) begin
            case (state_q)
                ST_IDLE: begin
                    // nothing to send
                end

                ST_START: begin
                    if (end_bit) begin
                        state_d = ST_DATA;
                        sub_d   = 5'd0;
                    end else begin
                        sub_d   = sub_q + 5'd1;
                    end
                end

                ST_DATA: begin
                    if (end_bit) begin
                        sub_d   = 5'd0;
                        shreg_d = {1'b0, shreg_q[7:1]};
                        if (bitn_q == last_q)
                            state_d = pen_q ? ST_PAR : ST_STOP;
                        else
                            bitn_d  = bitn_q + 3'd1;
                    end else begin
                        sub_d   = sub_q + 5'd1;
                    end
                end

                ST_PAR: begin
                    if (end_bit) begin
                        state_d = ST_STOP;
                        sub_d   = 5'd0;
                    end else begin
                        sub_d   = sub_q + 5'd1;
                    end
                end

                ST_STOP: begin
                    if (end_stop) begin
                        state_d = ST_IDLE;
                        sub_d   = 5'd0;
                    end else begin
                        sub_d   = sub_q + 5'd1;
                    end
                end

                default: begin
                    state_d = ST_IDLE;
                    sub_d   = 5'd0;
                end
            endcase
        end

        // the line level for the next cycle, in step with the next state
        case (state_d)
            ST_START: txd_d = 1'b0;
            ST_DATA:  txd_d = shreg_d[0];
            ST_PAR:   txd_d = par_d;
            default:  txd_d = 1'b1;
        endcase
    end

    //  ------------------------------------------------------------------------- Block
    always_comb begin
        txd  = txd_q;
        busy = (state_q != ST_IDLE);
    end

endmodule
