`timescale 1ns / 1ps

// everything between the core and the pins. synchronizers, loopback, break,
// a flop on every output

module uart_io (
    input  logic       clk,
    input  logic       rstn,

    // pins in, asynchronous to clk
    input  logic       sin,
    input  logic       cts_n,
    input  logic       dsr_n,
    input  logic       ri_n,
    input  logic       dcd_n,

    // from the core
    input  logic       tx_ser,       // transmitter output
    input  logic       brk,          // LCR bit 6
    input  logic [4:0] mcr,          // MCR bits 4:0 {LOOP, OUT2, OUT1, RTS, DTR}

    // pins out
    output logic        sout,
    output logic        dtr_n,
    output logic        rts_n,
    output logic        out1_n,
    output logic        out2_n,

    // to the core
    output logic        rxd,          // what the receiver samples
    output logic  [3:0] msr_now       // MSR bits 7:4 as {DCD, RI, DSR, CTS}
);

    logic sin_s1_q, sin_s1_d;
    logic sin_s2_q, sin_s2_d;
    logic [3:0] mdm_s1_q, mdm_s1_d;   // {dcd_n, ri_n, dsr_n, cts_n}
    logic [3:0] mdm_s2_q, mdm_s2_d;
    logic rxd_q,    rxd_d;
    logic [3:0] msr_q,    msr_d;
    logic sout_q,   sout_d;
    logic [3:0] mctl_q,   mctl_d;     // {out2_n, out1_n, rts_n, dtr_n}

    // named "now" helpers
    logic loop = mcr[4];
    logic line = tx_ser & ~brk;      // the transmitted line level, with break

    //  ------------------------------------------------------------------------- Block
    always_ff @(posedge clk or negedge rstn) begin
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
    always_comb begin
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
    always_comb begin
        sout    = sout_q;
        dtr_n   = mctl_q[0];
        rts_n   = mctl_q[1];
        out1_n  = mctl_q[2];
        out2_n  = mctl_q[3];
        rxd     = rxd_q;
        msr_now = msr_q;
    end

endmodule
