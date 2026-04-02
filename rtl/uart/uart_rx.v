`timescale 1ns / 1ps

// receiver, 8.6.2 8.6.3 fig 6. start is checked again 8 ticks in and dropped
// as a glitch if the line came back up. bits sampled every 16 ticks after

module uart_rx (
    input  wire       clk,
    input  wire       rstn,

    input  wire       tick,
    input  wire       rxd,

    // LCR fields, as stored now
    input  wire [1:0] wls,
    input  wire       pen,
    input  wire       eps,
    input  wire       stick,

    output reg        valid,
    output reg  [7:0] data,
    output reg        pe,
    output reg        fe,
    output reg        bi
);

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_START = 3'd1;
    localparam [2:0] ST_DATA  = 3'd2;
    localparam [2:0] ST_PAR   = 3'd3;
    localparam [2:0] ST_STOP  = 3'd4;
    localparam [2:0] ST_BRK   = 3'd5;

    // control
    reg [2:0] state_q, state_d;
    // datapath
    reg [3:0] sub_q,   sub_d;
    reg [2:0] bitn_q,  bitn_d;
    reg [7:0] shreg_q, shreg_d;
    reg       par_q,   par_d;
    reg       zero_q,  zero_d;
    reg [2:0] last_q,  last_d;
    reg       pen_q,   pen_d;
    reg       eps_q,   eps_d;
    reg       stick_q, stick_d;
    // output character
    reg       valid_q, valid_d;
    reg [7:0] data_q,  data_d;
    reg       pe_q,    pe_d;
    reg       fe_q,    fe_d;
    reg       bi_q,    bi_d;

    // named "now" helpers
    wire at_mid   = (sub_q == 4'd7);
    wire at_end   = (sub_q == 4'd15);
    wire par_exp  = stick_q ? ~eps_q : (eps_q ? ^shreg_q : ~^shreg_q);
    wire par_bad  = pen_q & (par_q != par_exp);

    //  ------------------------------------------------------------------------- Block
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_q <= ST_IDLE;
            sub_q   <= 4'd0;
            bitn_q  <= 3'd0;
            shreg_q <= 8'd0;
            par_q   <= 1'b0;
            zero_q  <= 1'b0;
            last_q  <= 3'd7;
            pen_q   <= 1'b0;
            eps_q   <= 1'b0;
            stick_q <= 1'b0;
            valid_q <= 1'b0;
            data_q  <= 8'd0;
            pe_q    <= 1'b0;
            fe_q    <= 1'b0;
            bi_q    <= 1'b0;
        end else begin
            state_q <= state_d;
            sub_q   <= sub_d;
            bitn_q  <= bitn_d;
            shreg_q <= shreg_d;
            par_q   <= par_d;
            zero_q  <= zero_d;
            last_q  <= last_d;
            pen_q   <= pen_d;
            eps_q   <= eps_d;
            stick_q <= stick_d;
            valid_q <= valid_d;
            data_q  <= data_d;
            pe_q    <= pe_d;
            fe_q    <= fe_d;
            bi_q    <= bi_d;
        end
    end

    //  ------------------------------------------------------------------------- Block
    always @(*) begin
        state_d = state_q;
        sub_d   = sub_q;
        bitn_d  = bitn_q;
        shreg_d = shreg_q;
        par_d   = par_q;
        zero_d  = zero_q;
        last_d  = last_q;
        pen_d   = pen_q;
        eps_d   = eps_q;
        stick_d = stick_q;
        valid_d = 1'b0;             // an event, so it defaults to low
        data_d  = data_q;
        pe_d    = pe_q;
        fe_d    = fe_q;
        bi_d    = bi_q;

        if (tick) begin
            case (state_q)
                ST_IDLE: begin
                    if (!rxd) begin
                        state_d = ST_START;
                        sub_d   = 4'd0;
                        last_d  = {1'b1, wls};
                        pen_d   = pen;
                        eps_d   = eps;
                        stick_d = stick;
                    end
                end

                ST_START: begin
                    if (at_mid) begin
                        if (rxd) begin
                            state_d = ST_IDLE;          // glitch, not a start bit
                            sub_d   = 4'd0;
                        end else begin
                            state_d = ST_DATA;
                            sub_d   = 4'd0;
                            bitn_d  = 3'd0;
                            shreg_d = 8'd0;
                            zero_d  = 1'b1;
                        end
                    end else begin
                        sub_d = sub_q + 4'd1;
                    end
                end

                ST_DATA: begin
                    if (at_end) begin
                        sub_d           = 4'd0;
                        shreg_d[bitn_q] = rxd;
                        zero_d          = zero_q & ~rxd;
                        if (bitn_q == last_q)
                            state_d = pen_q ? ST_PAR : ST_STOP;
                        else
                            bitn_d  = bitn_q + 3'd1;
                    end else begin
                        sub_d = sub_q + 4'd1;
                    end
                end

                ST_PAR: begin
                    if (at_end) begin
                        state_d = ST_STOP;
                        sub_d   = 4'd0;
                        par_d   = rxd;
                        zero_d  = zero_q & ~rxd;
                    end else begin
                        sub_d = sub_q + 4'd1;
                    end
                end

                ST_STOP: begin
                    if (at_end) begin
                        valid_d = 1'b1;
                        data_d  = shreg_q;
                        pe_d    = par_bad;
                        sub_d   = 4'd0;

                        if (rxd) begin
                            // good stop bit
                            fe_d    = 1'b0;
                            bi_d    = 1'b0;
                            state_d = ST_IDLE;
                        end else if (zero_q) begin
                            // everything was 0: a break
                            fe_d    = 1'b1;
                            bi_d    = 1'b1;
                            state_d = ST_BRK;
                        end else begin
                            //  framing error; this sample is the centre of the next
                            fe_d    = 1'b1;
                            bi_d    = 1'b0;
                            state_d = ST_DATA;
                            bitn_d  = 3'd0;
                            shreg_d = 8'd0;
                            zero_d  = 1'b1;
                            last_d  = {1'b1, wls};
                            pen_d   = pen;
                            eps_d   = eps;
                            stick_d = stick;
                        end
                    end else begin
                        sub_d = sub_q + 4'd1;
                    end
                end

                ST_BRK: begin
                    if (rxd) begin
                        state_d = ST_IDLE;
                        sub_d   = 4'd0;
                    end
                end

                default: begin
                    state_d = ST_IDLE;
                    sub_d   = 4'd0;
                end
            endcase
        end
    end

    //  ------------------------------------------------------------------------- Block
    always @(*) begin
        valid = valid_q;
        data  = data_q;
        pe    = pe_q;
        fe    = fe_q;
        bi    = bi_q;
    end

endmodule
