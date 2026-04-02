`timescale 1ns / 1ps

// everything between the core and the pins. synchronizers, loopback, break,
// a flop on every output

module uart_io (
    input  wire       clk,
    input  wire       rstn,

    // pins in, asynchronous to clk
    input  wire       sin,
    input  wire       cts_n,
    input  wire       dsr_n,
    input  wire       ri_n,
    input  wire       dcd_n,

    // from the core
    input  wire       tx_ser,       // transmitter output
    input  wire       brk,          // LCR bit 6
    input  wire [4:0] mcr,          // MCR bits 4:0 {LOOP, OUT2, OUT1, RTS, DTR}

    // pins out
    output reg        sout,
    output reg        dtr_n,
    output reg        rts_n,
    output reg        out1_n,
    output reg        out2_n,

    // to the core
    output reg        rxd,          // what the receiver samples
    output reg  [3:0] msr_now       // MSR bits 7:4 as {DCD, RI, DSR, CTS}
);

    reg       sin_s1_q, sin_s1_d;
    reg       sin_s2_q, sin_s2_d;
    reg [3:0] mdm_s1_q, mdm_s1_d;   // {dcd_n, ri_n, dsr_n, cts_n}
    reg [3:0] mdm_s2_q, mdm_s2_d;
    reg       rxd_q,    rxd_d;
    reg [3:0] msr_q,    msr_d;
    reg       sout_q,   sout_d;
    reg [3:0] mctl_q,   mctl_d;     // {out2_n, out1_n, rts_n, dtr_n}

    // named "now" helpers
    wire loop = mcr[4];
    wire line = tx_ser & ~brk;      // the transmitted line level, with break

    //  ------------------------------------------------------------------------- Block
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            sin_s1_q <= 1'b1;
            sin_s2_q <= 1'b1;
            mdm_s1_q <= 4'hF;
            mdm_s2_q <= 4'hF;
            rxd_q    <= 1'b1;
            msr_q    <= 4'h0;
            sout_q   <= 1'b1;
            mctl_q   <= 4'hF;
        end else begin
            sin_s1_q <= sin_s1_d;
            sin_s2_q <= sin_s2_d;
            mdm_s1_q <= mdm_s1_d;
            mdm_s2_q <= mdm_s2_d;
            rxd_q    <= rxd_d;
            msr_q    <= msr_d;
            sout_q   <= sout_d;
            mctl_q   <= mctl_d;
        end
    end

    //  ------------------------------------------------------------------------- Block
    always @(*) begin
        sin_s1_d = sin;
        sin_s2_d = sin_s1_q;
        mdm_s1_d = {dcd_n, ri_n, dsr_n, cts_n};
        mdm_s2_d = mdm_s1_q;

        rxd_d    = loop ? line : sin_s2_q;
        msr_d    = loop ? {mcr[3], mcr[2], mcr[0], mcr[1]} : ~mdm_s2_q;
        sout_d   = loop ? 1'b1 : line;
        mctl_d   = loop ? 4'hF : ~mcr[3:0];
    end

    //  ------------------------------------------------------------------------- Block
    always @(*) begin
        sout    = sout_q;
        dtr_n   = mctl_q[0];
        rts_n   = mctl_q[1];
        out1_n  = mctl_q[2];
        out2_n  = mctl_q[3];
        rxd     = rxd_q;
        msr_now = msr_q;
    end

endmodule
