`timescale 1ns / 1ps

// the 16550 programming model. twelve registers, dlab, fifos, interrupts
// every collision rule is a row in docs/uart16550_decisions.md

module uart_regs #(
    parameter int ADDR_W = 12
) (
    input  logic              clk,
    input  logic              rstn,

    // register bus
    input  logic              reg_wr,
    input  logic [ADDR_W-1:0] reg_waddr,
    input  logic [7:0]        reg_wdata,
    input  logic              reg_wstrb0,
    output logic               reg_werr,
    input  logic              reg_rd,
    input  logic [ADDR_W-1:0] reg_raddr,
    output logic  [7:0]        reg_rdata,
    output logic               reg_rerr,

    // receiver
    input  logic              rx_valid,
    input  logic [7:0]        rx_data,
    input  logic              rx_pe,
    input  logic              rx_fe,
    input  logic              rx_bi,

    // receive FIFO, entries are {bi, fe, pe, data}
    output logic               rxf_push,
    output logic  [10:0]       rxf_din,
    output logic               rxf_pop,
    output logic               rxf_clear,
    input  logic [10:0]       rxf_dout,
    input  logic [4:0]        rxf_count,

    // transmit FIFO and transmitter
    output logic               txf_push,
    output logic  [7:0]        txf_din,
    output logic               txf_pop,
    output logic               txf_clear,
    input  logic [4:0]        txf_count,
    input  logic              tx_pop,          // the transmitter takes a character
    input  logic              tx_busy,

    // baud generator
    input  logic              tick,
    output logic  [15:0]       divisor,
    output logic               div_load,
    output logic  [15:0]       div_value,

    // line format, modem control and status
    output logic  [6:0]        lcr,             // LCR 6:0; DLAB stays inside
    output logic  [4:0]        mcr,
    input  logic [3:0]        msr_now,         // {DCD, RI, DSR, CTS}

    output logic               irq
);

    // offsets on the register bus (datasheet address x 4)
    localparam [ADDR_W-1:0] A_DATA = {{(ADDR_W-8){1'b0}}, 8'h00};  // RBR THR DLL
    localparam [ADDR_W-1:0] A_IER  = {{(ADDR_W-8){1'b0}}, 8'h04};  // IER DLM
    localparam [ADDR_W-1:0] A_IIR  = {{(ADDR_W-8){1'b0}}, 8'h08};  // IIR FCR
    localparam [ADDR_W-1:0] A_LCR  = {{(ADDR_W-8){1'b0}}, 8'h0C};
    localparam [ADDR_W-1:0] A_MCR  = {{(ADDR_W-8){1'b0}}, 8'h10};
    localparam [ADDR_W-1:0] A_LSR  = {{(ADDR_W-8){1'b0}}, 8'h14};
    localparam [ADDR_W-1:0] A_MSR  = {{(ADDR_W-8){1'b0}}, 8'h18};
    localparam [ADDR_W-1:0] A_SCR  = {{(ADDR_W-8){1'b0}}, 8'h1C};

    // interrupt identification, Table 5
    localparam [3:0] ID_NONE = 4'h1;
    localparam [3:0] ID_RLS  = 4'h6;   // receiver line status
    localparam [3:0] ID_RDA  = 4'h4;   // received data available
    localparam [3:0] ID_CTI  = 4'hC;   // character timeout
    localparam [3:0] ID_THRI = 4'h2;   // transmitter holding register empty
    localparam [3:0] ID_MSI  = 4'h0;   // modem status

    //  -------------------------------------------------------------------------
    logic [3:0] ier_q,       ier_d;
    logic [7:0] lcr_q,       lcr_d;
    logic [4:0] mcr_q,       mcr_d;
    logic [7:0] scr_q,       scr_d;
    logic [7:0] dll_q,       dll_d;
    logic [7:0] dlm_q,       dlm_d;
    logic fen_q,       fen_d;        // FCR0: FIFO mode
    logic [1:0] trig_q,      trig_d;       // FCR7:6

    logic oe_q,        oe_d;         // LSR1
    logic pe_q,        pe_d;         // LSR2
    logic fe_q,        fe_d;         // LSR3
    logic bi_q,        bi_d;         // LSR4
    logic lsr7_q,      lsr7_d;       // sticky part of LSR7
    logic [4:0] errs_q,      errs_d;       // characters with errors in the RX FIFO
    logic top_new_q,   top_new_d;    // a character became the RX head at the last edge

    logic thri_q,      thri_d;       // THRE interrupt pending
    logic thre_prev_q, thre_prev_d;  // THRE one cycle ago
    logic [3:0] delta_q,     delta_d;      // MSR3:0 {DDCD, TERI, DDSR, DCTS}
    logic [3:0] msr_prev_q,  msr_prev_d;   // msr_now one cycle ago
    logic [9:0] to_cnt_q,    to_cnt_d;     // character timeout counter, in ticks
    logic to_pend_q,   to_pend_d;    // character timeout pending
    logic irq_q,       irq_d;

    //  ------------------------------------------------------------------------- Named
    logic dlab       = lcr_q[7];

    // writes that select byte 0, decoded by address
    logic wr_ok      = reg_wr & reg_wstrb0;
    logic thr_write  = wr_ok & (reg_waddr == A_DATA) & ~dlab;
    logic dll_write  = wr_ok & (reg_waddr == A_DATA) &  dlab;
    logic ier_write  = wr_ok & (reg_waddr == A_IER)  & ~dlab;
    logic dlm_write  = wr_ok & (reg_waddr == A_IER)  &  dlab;
    logic fcr_write  = wr_ok & (reg_waddr == A_IIR);
    logic lcr_write  = wr_ok & (reg_waddr == A_LCR);
    logic mcr_write  = wr_ok & (reg_waddr == A_MCR);
    logic scr_write  = wr_ok & (reg_waddr == A_SCR);

    //  reads with side effects. reg_rd is only high for an accepted read, and these
    logic rbr_read   = reg_rd & (reg_raddr == A_DATA) & ~dlab;
    logic iir_read   = reg_rd & (reg_raddr == A_IIR);
    logic lsr_read   = reg_rd & (reg_raddr == A_LSR);
    logic msr_read   = reg_rd & (reg_raddr == A_MSR);

    // FIFO state
    logic rx_empty   = (rxf_count == 5'd0);
    logic tx_empty   = (txf_count == 5'd0);
    logic rx_full    = fen_q ? (rxf_count == 5'd16) : ~rx_empty;
    logic tx_full    = fen_q ? (txf_count == 5'd16) : ~tx_empty;
    logic cpu_pop    = rbr_read & ~rx_empty;
    logic rx_err     = rx_bi | rx_fe | rx_pe;
    logic head_err   = rxf_dout[10] | rxf_dout[9] | rxf_dout[8];

    // FIFO control writes
    logic fen_change = fcr_write & (reg_wdata[0] != fen_q);
    logic rx_reset   = fcr_write & (fen_change | (reg_wdata[0] & reg_wdata[1]));
    logic tx_reset   = fcr_write & (fen_change | (reg_wdata[0] & reg_wdata[2]));

    //  overrun: a character arrives, there is no room, and no read or reset makes room
    logic overrun    = rx_valid & rx_full & ~cpu_pop & ~rx_reset;

    // trigger level, FCR7:6
    logic [4:0] trig_level = (trig_q == 2'd0) ? 5'd1 :
                            (trig_q == 2'd1) ? 5'd4 :
                            (trig_q == 2'd2) ? 5'd8 : 5'd14;

    // interrupt sources and priority, Table 5
    logic src_rls = ier_q[2] & (oe_q | pe_q | fe_q | bi_q);
    logic src_rda = ier_q[0] & (fen_q ? (rxf_count >= trig_level) : ~rx_empty);
    logic src_cti = ier_q[0] & fen_q & to_pend_q;
    logic src_thr = ier_q[1] & thri_q;
    logic src_msi = ier_q[3] & (delta_q != 4'h0);

    logic [3:0] iir_id = src_rls ? ID_RLS  :
                        src_rda ? ID_RDA  :
                        src_cti ? ID_CTI  :
                        src_thr ? ID_THRI :
                        src_msi ? ID_MSI  : ID_NONE;

    // THRE interrupt set and clear conditions
    logic thre_rise  = tx_empty & ~thre_prev_q;
    logic etbei_rise = ier_write & reg_wdata[1] & ~ier_q[1] & tx_empty;
    logic thri_set   = thre_rise | etbei_rise | fen_change;
    logic thri_clr   = thr_write | (iir_read & (iir_id == ID_THRI));

    //  modem status changes {DDCD, TERI, DDSR, DCTS}: any change, except RI which only
    logic [3:0] msr_edge = {msr_now[3] ^ msr_prev_q[3],
                           msr_prev_q[2] & ~msr_now[2],
                           msr_now[1] ^ msr_prev_q[1],
                           msr_now[0] ^ msr_prev_q[0]};

    // character time for the timeout: 16 x (start + data + parity) + stop ticks
    logic [3:0] nbits      = 4'd6 + {2'b00, lcr_q[1:0]} + {3'b000, lcr_q[3]};
    logic [5:0] stop_ticks = !lcr_q[2]            ? 6'd16 :
                            (lcr_q[1:0] == 2'd0) ? 6'd24 : 6'd32;
    logic [7:0] char_ticks = {nbits, 4'b0000} + {2'b00, stop_ticks};   // at most 192
    logic [9:0] to_limit   = {char_ticks, 2'b00};                       // at most 768

    // register values as software sees them
    logic lsr7_vis = fen_q & (lsr7_q | (errs_q != 5'd0));
    logic [7:0] lsr_val  = {lsr7_vis, tx_empty & ~tx_busy, tx_empty,
                           bi_q, fe_q, pe_q, oe_q, ~rx_empty};
    logic [7:0] msr_val  = {msr_now, delta_q};
    logic [7:0] iir_val  = {fen_q, fen_q, 2'b00, iir_id};

    //  ------------------------------------------------------------------------- Block
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            ier_q       <= 4'h0;
            lcr_q       <= 8'h00;
            mcr_q       <= 5'h00;
            scr_q       <= 8'h00;
            dll_q       <= 8'h00;
            dlm_q       <= 8'h00;
            fen_q       <= 1'b0;
            trig_q      <= 2'd0;
            oe_q        <= 1'b0;
            pe_q        <= 1'b0;
            fe_q        <= 1'b0;
            bi_q        <= 1'b0;
            lsr7_q      <= 1'b0;
            errs_q      <= 5'd0;
            top_new_q   <= 1'b0;
            thri_q      <= 1'b0;
            thre_prev_q <= 1'b1;
            delta_q     <= 4'h0;
            msr_prev_q  <= 4'h0;
            to_cnt_q    <= 10'd0;
            to_pend_q   <= 1'b0;
            irq_q       <= 1'b0;
        end else begin
            ier_q       <= ier_d;
            lcr_q       <= lcr_d;
            mcr_q       <= mcr_d;
            scr_q       <= scr_d;
            dll_q       <= dll_d;
            dlm_q       <= dlm_d;
            fen_q       <= fen_d;
            trig_q      <= trig_d;
            oe_q        <= oe_d;
            pe_q        <= pe_d;
            fe_q        <= fe_d;
            bi_q        <= bi_d;
            lsr7_q      <= lsr7_d;
            errs_q      <= errs_d;
            top_new_q   <= top_new_d;
            thri_q      <= thri_d;
            thre_prev_q <= thre_prev_d;
            delta_q     <= delta_d;
            msr_prev_q  <= msr_prev_d;
            to_cnt_q    <= to_cnt_d;
            to_pend_q   <= to_pend_d;
            irq_q       <= irq_d;
        end
    end

    //  ------------------------------------------------------------------------- Block
    always_comb begin
        // ---- defaults: stored values hold, commands are off ------------------
        ier_d       = ier_q;
        lcr_d       = lcr_q;
        mcr_d       = mcr_q;
        scr_d       = scr_q;
        dll_d       = dll_q;
        dlm_d       = dlm_q;
        fen_d       = fen_q;
        trig_d      = trig_q;
        errs_d      = errs_q;
        to_cnt_d    = to_cnt_q;
        to_pend_d   = to_pend_q;
        thre_prev_d = tx_empty;
        msr_prev_d  = msr_now;

        rxf_push    = 1'b0;
        rxf_din     = {rx_bi, rx_fe, rx_pe, rx_data};
        rxf_pop     = 1'b0;
        rxf_clear   = rx_reset;
        txf_push    = 1'b0;
        txf_din     = reg_wdata;
        txf_pop     = tx_pop;
        txf_clear   = tx_reset;
        div_load    = 1'b0;
        div_value   = {dlm_q, dll_q};

        // ---- configuration writes --------------------------------------------
        if (ier_write) ier_d = reg_wdata[3:0];
        if (lcr_write) lcr_d = reg_wdata;
        if (mcr_write) mcr_d = reg_wdata[4:0];
        if (scr_write) scr_d = reg_wdata;

        if (dll_write) begin
            dll_d     = reg_wdata;
            div_load  = 1'b1;
            div_value = {dlm_q, reg_wdata};
        end
        if (dlm_write) begin
            dlm_d     = reg_wdata;
            div_load  = 1'b1;
            div_value = {reg_wdata, dll_q};
        end

        if (fcr_write) begin
            fen_d = reg_wdata[0];
            if (reg_wdata[0])
                trig_d = reg_wdata[7:6];
        end

        // ---- transmit FIFO -----------------------------------------------------
        if (thr_write) begin
            if (!tx_full || tx_pop) begin
                txf_push = 1'b1;                  // room, or room made this cycle
            end else if (!fen_q) begin
                txf_push = 1'b1;                  // 16450: replace the waiting byte
                txf_pop  = 1'b1;
            end
            // FIFO mode and 16 waiting: the byte is discarded
        end

        // ---- receive FIFO ------------------------------------------------------
        rxf_pop = cpu_pop;
        if (rx_valid) begin
            if (!rx_full || cpu_pop || rx_reset) begin
                rxf_push = 1'b1;
            end else if (!fen_q) begin
                rxf_push = 1'b1;                  // 16450: replace, OE is set below
                rxf_pop  = 1'b1;
            end
            // FIFO mode and full: the new character is discarded, OE is set below
        end

        // characters with errors in the FIFO
        if (rx_reset)
            errs_d = (rxf_push & rx_err) ? 5'd1 : 5'd0;
        else if ((rxf_push & rx_err) && !(rxf_pop & ~rx_empty & head_err))
            errs_d = errs_q + 5'd1;
        else if (!(rxf_push & rx_err) && (rxf_pop & ~rx_empty & head_err))
            errs_d = errs_q - 5'd1;

        // did a character become the head at this edge?
        if (rx_reset)
            top_new_d = rxf_push;
        else
            top_new_d = (rxf_push & (rx_empty | rxf_pop)) |
                        (rxf_pop  & (rxf_count >= 5'd2));

        // ---- line status: set wins over the LSR read that clears ---------------
        oe_d = overrun                              | (oe_q & ~lsr_read);
        pe_d = (top_new_q & ~rx_empty & rxf_dout[8])  | (pe_q & ~lsr_read);
        fe_d = (top_new_q & ~rx_empty & rxf_dout[9])  | (fe_q & ~lsr_read);
        bi_d = (top_new_q & ~rx_empty & rxf_dout[10]) | (bi_q & ~lsr_read);

        if (fen_change)
            lsr7_d = 1'b0;
        else
            lsr7_d = (lsr7_q | (fen_q & (errs_q != 5'd0))) & ~lsr_read;

        // ---- THRE interrupt: set wins -----------------------------------------
        thri_d = thri_set | (thri_q & ~thri_clr);

        // ---- modem status deltas: set wins ------------------------------------
        delta_d = msr_edge | (delta_q & ~{4{msr_read}});

        // ---- character timeout -------------------------------------------------
        if (rx_reset || fen_change || cpu_pop || !fen_q) begin
            to_cnt_d  = 10'd0;
            to_pend_d = 1'b0;
        end else if (to_pend_q) begin
            to_cnt_d  = 10'd0;                     // stays pending until a read
        end else if (rx_empty || rx_valid) begin
            to_cnt_d  = 10'd0;
        end else if (tick) begin
            if ((to_cnt_q + 10'd1) >= to_limit) begin
                to_cnt_d  = 10'd0;
                to_pend_d = 1'b1;
            end else begin
                to_cnt_d  = to_cnt_q + 10'd1;
            end
        end

        // ---- interrupt output, one cycle behind the pending state -------------
        irq_d = (iir_id != ID_NONE);

        // ---- answers to the bus -------------------------------------------------
        case (reg_waddr)
            A_DATA, A_IER, A_IIR, A_LCR, A_MCR, A_LSR, A_MSR, A_SCR: reg_werr = 1'b0;
            default:                                                 reg_werr = 1'b1;
        endcase

        reg_rerr  = 1'b0;
        reg_rdata = 8'h00;
        case (reg_raddr)
            A_DATA:  reg_rdata = dlab ? dll_q : (rx_empty ? 8'h00 : rxf_dout[7:0]);
            A_IER:   reg_rdata = dlab ? dlm_q : {4'h0, ier_q};
            A_IIR:   reg_rdata = iir_val;
            A_LCR:   reg_rdata = lcr_q;
            A_MCR:   reg_rdata = {3'b000, mcr_q};
            A_LSR:   reg_rdata = lsr_val;
            A_MSR:   reg_rdata = msr_val;
            A_SCR:   reg_rdata = scr_q;
            default: reg_rerr  = 1'b1;
        endcase
    end

    //  ------------------------------------------------------------------------- Block
    always_comb begin
        divisor = {dlm_q, dll_q};
        lcr     = lcr_q[6:0];
        mcr     = mcr_q;
        irq     = irq_q;
    end

endmodule
