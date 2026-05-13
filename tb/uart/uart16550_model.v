`timescale 1ns / 1ps

// reference model, from the datasheet not from the rtl. +no_model turns it off

module uart16550_model #(
    parameter integer ADDR_W = 12
) (
    input wire              aclk,
    input wire              aresetn,

    input wire              reg_wr,
    input wire [ADDR_W-1:0] reg_waddr,
    input wire [7:0]        reg_wdata,
    input wire              reg_wstrb0,
    input wire              reg_rd,
    input wire [ADDR_W-1:0] reg_raddr,

    input wire              sin,
    input wire              cts_n,
    input wire              dsr_n,
    input wire              ri_n,
    input wire              dcd_n
);

    //  ------------------------------------------------------------- state pins
    reg        sin1, sin2, rxd;
    reg [3:0]  mdm1, mdm2;                   // {dcd_n, ri_n, dsr_n, cts_n}
    reg [3:0]  msr_hi;                       // MSR 7:4 {DCD, RI, DSR, CTS}
    reg        sout, dtr_n, rts_n, out1_n, out2_n;
    // baud generator
    reg [15:0] bcnt;
    reg        btick;
    // transmitter: state 0 idle, 1 start, 2 data, 3 parity, 4 stop
    integer    t_state, t_sub, t_bit, t_last, t_stop_last;
    reg [7:0]  t_sh;
    reg        t_par, t_pen, t_line;
    // receiver: state 0 idle, 1 start, 2 data, 3 parity, 4 stop, 5 break
    integer    r_state, r_sub, r_bit, r_last;
    reg [7:0]  r_sh;
    reg        r_par, r_zero, r_pen, r_eps, r_stick;
    reg        r_valid, r_pe, r_fe, r_bi;
    reg [7:0]  r_data;
    // FIFOs
    reg [10:0] rxq [0:15];                   // {bi, fe, pe, data}
    reg [7:0]  txq [0:15];
    integer    rxn, txn;
    // registers and status
    reg [3:0]  ier;
    reg [7:0]  lcr, scr, dll, dlm;
    reg [4:0]  mcr;
    reg        fen;
    reg [1:0]  trig;
    reg        oe, pe, fe, bi, lsr7s, head_new;
    integer    errs;
    reg        thri, thre_was;
    reg [3:0]  delta, msr_was;
    integer    to_cnt;
    reg        to_pend, irq;

    // events of the cycle that just ended, for coverage in the testbench
    reg        ev_overrun, ev_rx_glitch, ev_rx_break, ev_rx_fe, ev_rx_pe, ev_resync;
    reg        ev_cpu_pop_with_push, ev_lsr_clear_collision, ev_thri_collision;
    reg        ev_cti_set, ev_cti_kept_on_rx, ev_tx_replace, ev_tx_drop, ev_rx_replace;
    reg        ev_msr_collision, ev_back_to_back, ev_div_load_running;

    // ------------------------------------------------------------- views
    function integer trig_lvl;
        input dummy;
        begin
            case (trig)
                2'd0:    trig_lvl = 1;
                2'd1:    trig_lvl = 4;
                2'd2:    trig_lvl = 8;
                default: trig_lvl = 14;
            endcase
        end
    endfunction

    function [3:0] iir_id;
        input dummy;
        begin
            if      (ier[2] && (oe || pe || fe || bi))                     iir_id = 4'h6;
            else if (ier[0] && (fen ? (rxn >= trig_lvl(0)) : (rxn != 0))) iir_id = 4'h4;
            else if (ier[0] && fen && to_pend)                             iir_id = 4'hC;
            else if (ier[1] && thri)                                       iir_id = 4'h2;
            else if (ier[3] && delta != 4'h0)                              iir_id = 4'h0;
            else                                                           iir_id = 4'h1;
        end
    endfunction

    function [7:0] iir_view;
        input dummy;
        begin
            iir_view = {fen, fen, 2'b00, iir_id(0)};
        end
    endfunction

    function [7:0] lsr_view;
        input dummy;
        begin
            lsr_view = {fen && (lsr7s || errs != 0),
                        txn == 0 && t_state == 0,
                        txn == 0,
                        bi, fe, pe, oe,
                        rxn != 0};
        end
    endfunction

    function [7:0] msr_view;
        input dummy;
        begin
            msr_view = {msr_hi, delta};
        end
    endfunction

    // expected answer to a read at address a, from the state now: {error, data}
    function [8:0] read_value;
        input [ADDR_W-1:0] a;
        begin
            case (a)
                0:       read_value = {1'b0, lcr[7] ? dll : (rxn != 0 ? rxq[0][7:0] : 8'h00)};
                4:       read_value = {1'b0, lcr[7] ? dlm : {4'h0, ier}};
                8:       read_value = {1'b0, iir_view(0)};
                12:      read_value = {1'b0, lcr};
                16:      read_value = {1'b0, 3'b000, mcr};
                20:      read_value = {1'b0, lsr_view(0)};
                24:      read_value = {1'b0, msr_view(0)};
                28:      read_value = {1'b0, scr};
                default: read_value = {1'b1, 8'h00};
            endcase
        end
    endfunction

    function write_err;
        input [ADDR_W-1:0] a;
        begin
            write_err = !(a == 0 || a == 4 || a == 8 || a == 12 ||
                          a == 16 || a == 20 || a == 24 || a == 28);
        end
    endfunction

    // ------------------------------------------------------------- the process
    integer    i, w, lvl, char_t, limit;
    reg        tk, dl, wr_ok, is_thr, is_dll, is_ier, is_dlm, is_fcr, is_lcr, is_mcr, is_scr;
    reg        rd_rbr, rd_iir, rd_lsr, rd_msr;
    reg [3:0]  id_now;
    reg [7:0]  m;
    reg        exp_par;
    reg        t_pop, rx_full, tx_full, cpu_pop, fen_chg, rx_rst, tx_rst;
    reg        tx_push, tx_popc, rx_push, rx_popc, ovr, rin_err, head_err, take, thre_now;
    reg        run, dpop, dpush, div_load;
    reg [3:0]  ed;
    reg [10:0] rx_in;
    reg [15:0] div_new;

    integer    n_t_state, n_t_sub, n_t_bit, n_t_last, n_t_stop_last;
    reg [7:0]  n_t_sh;
    reg        n_t_par, n_t_pen, n_t_line;
    integer    n_r_state, n_r_sub, n_r_bit, n_r_last;
    reg [7:0]  n_r_sh, n_r_data;
    reg        n_r_par, n_r_zero, n_r_pen, n_r_eps, n_r_stick, n_r_valid, n_r_pe, n_r_fe, n_r_bi;
    reg [10:0] n_rxq [0:15];
    reg [7:0]  n_txq [0:15];
    integer    n_rxn, n_txn, n_errs, n_to_cnt;
    reg [3:0]  n_ier, n_delta;
    reg [7:0]  n_lcr, n_scr, n_dll, n_dlm;
    reg [4:0]  n_mcr;
    reg        n_fen, n_oe, n_pe, n_fe, n_bi, n_lsr7s, n_head_new, n_thri, n_to_pend, n_irq;
    reg [1:0]  n_trig;
    reg        n_sin1, n_sin2, n_rxd, n_sout;
    reg [3:0]  n_mdm1, n_mdm2, n_msr_hi, n_mctl;
    reg [15:0] n_bcnt;
    reg        n_btick;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            sin1 <= 1'b1; sin2 <= 1'b1; rxd <= 1'b1;
            mdm1 <= 4'hF; mdm2 <= 4'hF; msr_hi <= 4'h0;
            sout <= 1'b1; dtr_n <= 1'b1; rts_n <= 1'b1; out1_n <= 1'b1; out2_n <= 1'b1;
            bcnt <= 16'd0; btick <= 1'b0;
            t_state <= 0; t_sub <= 0; t_bit <= 0; t_last <= 7; t_stop_last <= 15;
            t_sh <= 8'd0; t_par <= 1'b0; t_pen <= 1'b0; t_line <= 1'b1;
            r_state <= 0; r_sub <= 0; r_bit <= 0; r_last <= 7;
            r_sh <= 8'd0; r_par <= 1'b0; r_zero <= 1'b0; r_pen <= 1'b0; r_eps <= 1'b0; r_stick <= 1'b0;
            r_valid <= 1'b0; r_pe <= 1'b0; r_fe <= 1'b0; r_bi <= 1'b0; r_data <= 8'd0;
            rxn <= 0; txn <= 0;
            ier <= 4'h0; lcr <= 8'h00; scr <= 8'h00; dll <= 8'h00; dlm <= 8'h00; mcr <= 5'h00;
            fen <= 1'b0; trig <= 2'd0;
            oe <= 1'b0; pe <= 1'b0; fe <= 1'b0; bi <= 1'b0; lsr7s <= 1'b0; head_new <= 1'b0;
            errs <= 0; thri <= 1'b0; thre_was <= 1'b1; delta <= 4'h0; msr_was <= 4'h0;
            to_cnt <= 0; to_pend <= 1'b0; irq <= 1'b0;
            ev_overrun <= 0; ev_rx_glitch <= 0; ev_rx_break <= 0; ev_rx_fe <= 0; ev_rx_pe <= 0;
            ev_resync <= 0; ev_cpu_pop_with_push <= 0; ev_lsr_clear_collision <= 0;
            ev_thri_collision <= 0; ev_cti_set <= 0; ev_cti_kept_on_rx <= 0; ev_tx_replace <= 0;
            ev_tx_drop <= 0; ev_rx_replace <= 0; ev_msr_collision <= 0; ev_back_to_back <= 0;
            ev_div_load_running <= 0;
        end else begin
            // =============================================== facts about this cycle
            tk     = btick;
            dl     = lcr[7];
            wr_ok  = reg_wr && reg_wstrb0;
            is_thr = wr_ok && reg_waddr == 0  && !dl;
            is_dll = wr_ok && reg_waddr == 0  &&  dl;
            is_ier = wr_ok && reg_waddr == 4  && !dl;
            is_dlm = wr_ok && reg_waddr == 4  &&  dl;
            is_fcr = wr_ok && reg_waddr == 8;
            is_lcr = wr_ok && reg_waddr == 12;
            is_mcr = wr_ok && reg_waddr == 16;
            is_scr = wr_ok && reg_waddr == 28;
            rd_rbr = reg_rd && reg_raddr == 0 && !dl;
            rd_iir = reg_rd && reg_raddr == 8;
            rd_lsr = reg_rd && reg_raddr == 20;
            rd_msr = reg_rd && reg_raddr == 24;
            id_now = iir_id(0);

            // =============================================== transmitter, 8.6.2
            n_t_state = t_state; n_t_sub = t_sub; n_t_bit = t_bit; n_t_last = t_last;
            n_t_stop_last = t_stop_last; n_t_sh = t_sh; n_t_par = t_par; n_t_pen = t_pen;
            t_pop = 1'b0;

            if (tk && txn != 0 && (t_state == 0 || (t_state == 4 && t_sub == t_stop_last))) begin
                t_pop         = 1'b1;
                w             = 5 + lcr[1:0];
                m             = txq[0] & ((8'd1 << w) - 8'd1);
                n_t_sh        = m;
                n_t_par       = lcr[5] ? !lcr[4] : (lcr[4] ? ^m : !(^m));
                n_t_last      = w - 1;
                n_t_pen       = lcr[3];
                n_t_stop_last = !lcr[2] ? 15 : (lcr[1:0] == 2'd0 ? 23 : 31);
                n_t_state     = 1;
                n_t_sub       = 0;
                n_t_bit       = 0;
            end else if (tk) begin
                case (t_state)
                    1: if (t_sub == 15) begin n_t_state = 2; n_t_sub = 0; end
                       else n_t_sub = t_sub + 1;
                    2: if (t_sub == 15) begin
                           n_t_sub = 0;
                           n_t_sh  = t_sh >> 1;
                           if (t_bit == t_last) n_t_state = t_pen ? 3 : 4;
                           else                 n_t_bit   = t_bit + 1;
                       end else n_t_sub = t_sub + 1;
                    3: if (t_sub == 15) begin n_t_state = 4; n_t_sub = 0; end
                       else n_t_sub = t_sub + 1;
                    4: if (t_sub == t_stop_last) begin n_t_state = 0; n_t_sub = 0; end
                       else n_t_sub = t_sub + 1;
                    default: ;
                endcase
            end

            case (n_t_state)
                1:       n_t_line = 1'b0;
                2:       n_t_line = n_t_sh[0];
                3:       n_t_line = n_t_par;
                default: n_t_line = 1'b1;
            endcase

            // =============================================== receiver, 8.6.2, 8.6.3
            n_r_state = r_state; n_r_sub = r_sub; n_r_bit = r_bit; n_r_last = r_last;
            n_r_sh = r_sh; n_r_par = r_par; n_r_zero = r_zero; n_r_pen = r_pen;
            n_r_eps = r_eps; n_r_stick = r_stick;
            n_r_valid = 1'b0; n_r_data = r_data; n_r_pe = r_pe; n_r_fe = r_fe; n_r_bi = r_bi;

            if (tk) begin
                case (r_state)
                    0: if (!rxd) begin
                           n_r_state = 1; n_r_sub = 0;
                           n_r_last = 4 + lcr[1:0]; n_r_pen = lcr[3]; n_r_eps = lcr[4]; n_r_stick = lcr[5];
                       end
                    1: if (r_sub == 7) begin
                           if (rxd) begin
                               n_r_state = 0; n_r_sub = 0;
                           end else begin
                               n_r_state = 2; n_r_sub = 0; n_r_bit = 0; n_r_sh = 8'd0; n_r_zero = 1'b1;
                           end
                       end else n_r_sub = r_sub + 1;
                    2: if (r_sub == 15) begin
                           n_r_sub        = 0;
                           n_r_sh[r_bit]  = rxd;
                           n_r_zero       = r_zero && !rxd;
                           if (r_bit == r_last) n_r_state = r_pen ? 3 : 4;
                           else                 n_r_bit   = r_bit + 1;
                       end else n_r_sub = r_sub + 1;
                    3: if (r_sub == 15) begin
                           n_r_state = 4; n_r_sub = 0; n_r_par = rxd; n_r_zero = r_zero && !rxd;
                       end else n_r_sub = r_sub + 1;
                    4: if (r_sub == 15) begin
                           exp_par   = r_stick ? !r_eps : (r_eps ? ^r_sh : !(^r_sh));
                           n_r_valid = 1'b1;
                           n_r_data  = r_sh;
                           n_r_pe    = r_pen && (r_par != exp_par);
                           n_r_sub   = 0;
                           if (rxd) begin
                               n_r_fe = 1'b0; n_r_bi = 1'b0; n_r_state = 0;
                           end else if (r_zero) begin
                               n_r_fe = 1'b1; n_r_bi = 1'b1; n_r_state = 5;
                           end else begin
                               n_r_fe = 1'b1; n_r_bi = 1'b0; n_r_state = 2;
                               n_r_bit = 0; n_r_sh = 8'd0; n_r_zero = 1'b1;
                               n_r_last = 4 + lcr[1:0]; n_r_pen = lcr[3]; n_r_eps = lcr[4]; n_r_stick = lcr[5];
                           end
                       end else n_r_sub = r_sub + 1;
                    5: if (rxd) begin n_r_state = 0; n_r_sub = 0; end
                    default: ;
                endcase
            end

            // =============================================== register block, 8.4, 8.6
            rx_full  = fen ? (rxn == 16) : (rxn != 0);
            tx_full  = fen ? (txn == 16) : (txn != 0);
            cpu_pop  = rd_rbr && rxn != 0;
            fen_chg  = is_fcr && (reg_wdata[0] != fen);
            rx_rst   = is_fcr && (fen_chg || (reg_wdata[0] && reg_wdata[1]));
            tx_rst   = is_fcr && (fen_chg || (reg_wdata[0] && reg_wdata[2]));
            rx_in    = {r_bi, r_fe, r_pe, r_data};
            rin_err  = r_bi || r_fe || r_pe;
            head_err = (rxn != 0) && (rxq[0][10:8] != 3'b000);

            // transmit FIFO: room, 16450 replace, or discard
            tx_push = 1'b0; tx_popc = t_pop;
            if (is_thr) begin
                if (!tx_full || t_pop) tx_push = 1'b1;
                else if (!fen) begin tx_push = 1'b1; tx_popc = 1'b1; end
            end

            // receive FIFO: room, 16450 replace, or discard; overrun in the last two
            rx_push = 1'b0; rx_popc = cpu_pop; ovr = 1'b0;
            if (r_valid) begin
                if (!rx_full || cpu_pop || rx_rst) rx_push = 1'b1;
                else begin
                    ovr = 1'b1;
                    if (!fen) begin rx_push = 1'b1; rx_popc = 1'b1; end
                end
            end

            // characters with errors in the receive FIFO
            if (rx_rst)
                n_errs = (rx_push && rin_err) ? 1 : 0;
            else
                n_errs = errs + ((rx_push && rin_err) ? 1 : 0)
                              - ((rx_popc && head_err) ? 1 : 0);

            // does a character become the head at this edge?
            if (rx_rst) n_head_new = rx_push;
            else        n_head_new = (rx_push && (rxn == 0 || rx_popc)) || (rx_popc && rxn >= 2);

            // line status: set wins over an LSR read
            take  = head_new && rxn != 0;
            n_oe  = ovr                   || (oe && !rd_lsr);
            n_pe  = (take && rxq[0][8])  || (pe && !rd_lsr);
            n_fe  = (take && rxq[0][9])  || (fe && !rd_lsr);
            n_bi  = (take && rxq[0][10]) || (bi && !rd_lsr);
            n_lsr7s = fen_chg ? 1'b0 : ((lsr7s || (fen && errs != 0)) && !rd_lsr);

            // THRE interrupt: set wins
            thre_now = (txn == 0);
            if ((thre_now && !thre_was) ||
                (is_ier && reg_wdata[1] && !ier[1] && thre_now) ||
                fen_chg)
                n_thri = 1'b1;
            else if (is_thr || (rd_iir && id_now == 4'h2))
                n_thri = 1'b0;
            else
                n_thri = thri;

            // modem status deltas: set wins
            ed      = {msr_hi[3] ^ msr_was[3], msr_was[2] && !msr_hi[2],
                       msr_hi[1] ^ msr_was[1], msr_hi[0] ^ msr_was[0]};
            n_delta = ed | (rd_msr ? 4'h0 : delta);

            // character timeout, 8.4.1
            char_t = 16 * (1 + 5 + lcr[1:0] + lcr[3]) + (!lcr[2] ? 16 : (lcr[1:0] == 2'd0 ? 24 : 32));
            limit  = 4 * char_t;
            n_to_cnt = to_cnt; n_to_pend = to_pend;
            if (rx_rst || fen_chg || cpu_pop || !fen) begin
                n_to_cnt = 0; n_to_pend = 1'b0;
            end else if (to_pend) begin
                n_to_cnt = 0;
            end else if (rxn == 0 || r_valid) begin
                n_to_cnt = 0;
            end else if (tk) begin
                if (to_cnt + 1 >= limit) begin n_to_cnt = 0; n_to_pend = 1'b1; end
                else n_to_cnt = to_cnt + 1;
            end

            n_irq = (id_now != 4'h1);

            // configuration registers
            n_ier  = is_ier ? reg_wdata[3:0] : ier;
            n_lcr  = is_lcr ? reg_wdata      : lcr;
            n_mcr  = is_mcr ? reg_wdata[4:0] : mcr;
            n_scr  = is_scr ? reg_wdata      : scr;
            n_dll  = is_dll ? reg_wdata      : dll;
            n_dlm  = is_dlm ? reg_wdata      : dlm;
            n_fen  = is_fcr ? reg_wdata[0]   : fen;
            n_trig = (is_fcr && reg_wdata[0]) ? reg_wdata[7:6] : trig;
            div_load = is_dll || is_dlm;
            div_new  = {n_dlm, n_dll};

            // =============================================== FIFOs
            for (i = 0; i < 16; i = i + 1) begin
                n_rxq[i] = rxq[i];
                n_txq[i] = txq[i];
            end

            if (rx_rst) begin
                n_rxn = 0;
                if (rx_push) begin n_rxq[0] = rx_in; n_rxn = 1; end
            end else begin
                n_rxn = rxn;
                dpop  = rx_popc && rxn > 0;
                dpush = rx_push && (rxn < 16 || dpop);
                if (dpop) begin
                    for (i = 0; i < 15; i = i + 1) n_rxq[i] = n_rxq[i+1];
                    n_rxn = n_rxn - 1;
                end
                if (dpush) begin
                    n_rxq[n_rxn] = rx_in;
                    n_rxn = n_rxn + 1;
                end
            end

            if (tx_rst) begin
                n_txn = 0;
                if (tx_push) begin n_txq[0] = reg_wdata; n_txn = 1; end
            end else begin
                n_txn = txn;
                dpop  = tx_popc && txn > 0;
                dpush = tx_push && (txn < 16 || dpop);
                if (dpop) begin
                    for (i = 0; i < 15; i = i + 1) n_txq[i] = n_txq[i+1];
                    n_txn = n_txn - 1;
                end
                if (dpush) begin
                    n_txq[n_txn] = reg_wdata;
                    n_txn = n_txn + 1;
                end
            end

            // =============================================== pins, 8.6.7
            n_sin1   = sin;
            n_sin2   = sin1;
            n_mdm1   = {dcd_n, ri_n, dsr_n, cts_n};
            n_mdm2   = mdm1;
            n_rxd    = mcr[4] ? (t_line && !lcr[6]) : sin2;
            n_msr_hi = mcr[4] ? {mcr[3], mcr[2], mcr[0], mcr[1]} : ~mdm2;
            n_sout   = mcr[4] ? 1'b1 : (t_line && !lcr[6]);
            n_mctl   = mcr[4] ? 4'hF : ~mcr[3:0];      // {out2_n, out1_n, rts_n, dtr_n}

            // =============================================== baud generator, 8.5.1
            if (div_load) begin
                run    = (div_new != 16'd0);
                n_bcnt = run ? div_new - 16'd1 : 16'd0;
            end else begin
                run    = ({dlm, dll} != 16'd0);
                n_bcnt = !run ? 16'd0 : (bcnt == 16'd0 ? {dlm, dll} - 16'd1 : bcnt - 16'd1);
            end
            n_btick = run && (n_bcnt == 16'd0);

            // =============================================== commit
            sin1 <= n_sin1; sin2 <= n_sin2; rxd <= n_rxd;
            mdm1 <= n_mdm1; mdm2 <= n_mdm2; msr_hi <= n_msr_hi;
            sout <= n_sout;
            {out2_n, out1_n, rts_n, dtr_n} <= n_mctl;
            bcnt <= n_bcnt; btick <= n_btick;

            t_state <= n_t_state; t_sub <= n_t_sub; t_bit <= n_t_bit; t_last <= n_t_last;
            t_stop_last <= n_t_stop_last; t_sh <= n_t_sh; t_par <= n_t_par; t_pen <= n_t_pen;
            t_line <= n_t_line;

            r_state <= n_r_state; r_sub <= n_r_sub; r_bit <= n_r_bit; r_last <= n_r_last;
            r_sh <= n_r_sh; r_par <= n_r_par; r_zero <= n_r_zero; r_pen <= n_r_pen;
            r_eps <= n_r_eps; r_stick <= n_r_stick;
            r_valid <= n_r_valid; r_data <= n_r_data; r_pe <= n_r_pe; r_fe <= n_r_fe; r_bi <= n_r_bi;

            for (i = 0; i < 16; i = i + 1) begin
                rxq[i] <= n_rxq[i];
                txq[i] <= n_txq[i];
            end
            rxn <= n_rxn; txn <= n_txn;

            ier <= n_ier; lcr <= n_lcr; mcr <= n_mcr; scr <= n_scr; dll <= n_dll; dlm <= n_dlm;
            fen <= n_fen; trig <= n_trig;
            oe <= n_oe; pe <= n_pe; fe <= n_fe; bi <= n_bi; lsr7s <= n_lsr7s; head_new <= n_head_new;
            errs <= n_errs; thri <= n_thri; thre_was <= thre_now;
            delta <= n_delta; msr_was <= msr_hi;
            to_cnt <= n_to_cnt; to_pend <= n_to_pend; irq <= n_irq;

            // events of this cycle, for coverage
            ev_overrun             <= ovr && fen;
            ev_rx_replace          <= ovr && !fen;
            ev_rx_glitch           <= tk && r_state == 1 && r_sub == 7 && rxd;
            ev_rx_break            <= tk && r_state == 4 && r_sub == 15 && !rxd && r_zero;
            ev_rx_fe               <= tk && r_state == 4 && r_sub == 15 && !rxd && !r_zero;
            ev_resync              <= tk && r_state == 4 && r_sub == 15 && !rxd && !r_zero;
            ev_rx_pe               <= n_r_valid && n_r_pe;
            ev_cpu_pop_with_push   <= cpu_pop && r_valid && rx_full;
            ev_lsr_clear_collision <= rd_lsr && (take && rxq[0][10:8] != 3'b000 || ovr);
            ev_thri_collision      <= (thre_now && !thre_was) && (is_thr || (rd_iir && id_now == 4'h2));
            ev_cti_set             <= !to_pend && n_to_pend;
            ev_cti_kept_on_rx      <= to_pend && r_valid && !(rx_rst || fen_chg || cpu_pop || !fen);
            ev_tx_replace          <= is_thr && tx_full && !t_pop && !fen;
            ev_tx_drop             <= is_thr && tx_full && !t_pop && fen;
            ev_msr_collision       <= rd_msr && (ed != 4'h0);
            ev_back_to_back        <= t_pop && t_state == 4;
            ev_div_load_running    <= div_load && t_state != 0;
        end
    end

endmodule
