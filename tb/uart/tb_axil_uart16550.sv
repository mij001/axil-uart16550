`timescale 1ns / 1ps

// directed bench, 20 tests then a random phase
// +seed= +nrand= +no_model +scenario=<name>

module tb_axil_uart16550;

    localparam integer ADDR_W = 12;
    localparam [ADDR_W-1:0] R_DATA = 12'h000, R_IER = 12'h004, R_IIR = 12'h008, R_LCR = 12'h00C,
                            R_MCR  = 12'h010, R_LSR = 12'h014, R_MSR = 12'h018, R_SCR = 12'h01C;
    localparam [1:0] OKAY = 2'b00, SLVERR = 2'b10;

    reg aclk    = 1'b0;
    always #5 aclk = ~aclk;

    // reset starts HIGH then goes low, on purpose it used to start low. an async
    reg aresetn = 1'b1;
    initial begin
        #1 aresetn = 1'b0;
    end

    // ------------------------------------------------------------ wires
    wire              awvalid, awready, wvalid, wready, bvalid, bready;
    wire              arvalid, arready, rvalid, rready;
    wire [ADDR_W-1:0] awaddr, araddr;
    wire [2:0]        awprot, arprot;
    wire [31:0]       wdata, rdata;
    wire [3:0]        wstrb;
    wire [1:0]        bresp, rresp;

    wire sin, sout, dtr_n, rts_n, out1_n, out2_n, irq;
    reg  cts_n = 1'b1, dsr_n = 1'b1, ri_n = 1'b1, dcd_n = 1'b1;

    // ------------------------------------------------------------ blocks
    axil_master_bfm #(.ADDR_W(ADDR_W)) u_bfm (
        .aclk(aclk),
        .awvalid(awvalid), .awaddr(awaddr), .awprot(awprot), .awready(awready),
        .wvalid(wvalid), .wdata(wdata), .wstrb(wstrb), .wready(wready),
        .bvalid(bvalid), .bresp(bresp), .bready(bready),
        .arvalid(arvalid), .araddr(araddr), .arprot(arprot), .arready(arready),
        .rvalid(rvalid), .rdata(rdata), .rresp(rresp), .rready(rready)
    );

    axil_uart16550 #(.ADDR_W(ADDR_W)) u_dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axil_awvalid(awvalid), .s_axil_awready(awready), .s_axil_awaddr(awaddr), .s_axil_awprot(awprot),
        .s_axil_wvalid(wvalid), .s_axil_wready(wready), .s_axil_wdata(wdata), .s_axil_wstrb(wstrb),
        .s_axil_bvalid(bvalid), .s_axil_bready(bready), .s_axil_bresp(bresp),
        .s_axil_arvalid(arvalid), .s_axil_arready(arready), .s_axil_araddr(araddr), .s_axil_arprot(arprot),
        .s_axil_rvalid(rvalid), .s_axil_rready(rready), .s_axil_rdata(rdata), .s_axil_rresp(rresp),
        .sin(sin), .sout(sout),
        .cts_n(cts_n), .dsr_n(dsr_n), .ri_n(ri_n), .dcd_n(dcd_n),
        .dtr_n(dtr_n), .rts_n(rts_n), .out1_n(out1_n), .out2_n(out2_n),
        .irq(irq)
    );

    axil_checker #(.ADDR_W(ADDR_W), .NAME("uart")) u_chk (
        .aclk(aclk), .aresetn(aresetn),
        .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awprot(awprot),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .araddr(araddr), .arprot(arprot),
        .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp)
    );

    serial_bfm u_ser (.aclk(aclk), .line_out(sin), .line_in(sout));

    uart16550_model #(.ADDR_W(ADDR_W)) u_model (
        .aclk(aclk), .aresetn(aresetn),
        .reg_wr(u_dut.reg_wr), .reg_waddr(u_dut.reg_waddr),
        .reg_wdata(u_dut.reg_wdata[7:0]), .reg_wstrb0(u_dut.reg_wstrb[0]),
        .reg_rd(u_dut.reg_rd), .reg_raddr(u_dut.reg_raddr),
        .sin(sin), .cts_n(cts_n), .dsr_n(dsr_n), .ri_n(ri_n), .dcd_n(dcd_n)
    );

    // ------------------------------------------------------------ bookkeeping
    integer seed, nrand, cyc, errors, mismatches, n_compared;
    integer use_model;          // 0 with +no_model: only the independent checks run
    reg [8*32-1:0] scenario, vcdname;
    reg [31:0] v;
    reg [1:0]  resp;
    reg        ok;
    integer    cur_div;          // divisor programmed by the tests
    integer    i, n;            // used by the main test sequence only
    integer    kc;              // used by the state compare process only
    integer    ks;              // used by the background serial process only
    integer    last_rx_cyc;     // cycle in which the model last delivered a character

    initial cyc = 0;
    always @(posedge aclk) if (aresetn) cyc = cyc + 1;

    function integer urand;
        input integer lim;
        begin
            urand = (lim <= 0) ? 0 : ({$random(seed)} % (lim + 1));
        end
    endfunction

    // ------------------------------------------------------------ bus scoreboard
    reg [8:0]  exp_r   [0:255];
    reg [1:0]  exp_b   [0:255];
    reg [ADDR_W-1:0] aw_q [0:255];
    reg [7:0]  w_q     [0:255];
    reg        ws_q    [0:255];
    integer    er_h, er_t, eb_h, eb_t, aw_h, aw_t, w_h, w_t;
    initial begin er_h = 0; er_t = 0; eb_h = 0; eb_t = 0; aw_h = 0; aw_t = 0; w_h = 0; w_t = 0; end

    always @(posedge aclk) begin
        if (aresetn) begin
            if (awvalid && awready) begin aw_q[aw_t] = awaddr; aw_t = (aw_t + 1) % 256; end
            if (wvalid && wready)   begin w_q[w_t] = wdata[7:0]; ws_q[w_t] = wstrb[0]; w_t = (w_t + 1) % 256; end

            if (u_dut.reg_wr) begin
                if (u_dut.reg_waddr !== aw_q[aw_h] || u_dut.reg_wdata[7:0] !== w_q[w_h] ||
                    u_dut.reg_wstrb[0] !== ws_q[w_h]) begin
                    $display("[%0t] MONITOR FAIL: applied %03h/%02h/%b but AXI sent %03h/%02h/%b", $time,
                             u_dut.reg_waddr, u_dut.reg_wdata[7:0], u_dut.reg_wstrb[0],
                             aw_q[aw_h], w_q[w_h], ws_q[w_h]);
                    errors = errors + 1;
                end
                aw_h = (aw_h + 1) % 256; w_h = (w_h + 1) % 256;
                exp_b[eb_t] = u_model.write_err(u_dut.reg_waddr) ? SLVERR : OKAY;
                eb_t = (eb_t + 1) % 256;
            end

            if (u_dut.reg_rd) begin
                exp_r[er_t] = u_model.read_value(u_dut.reg_raddr);
                er_t = (er_t + 1) % 256;
            end

            if (bvalid && bready) begin
                if (use_model != 0 && bresp !== exp_b[eb_h]) begin
                    $display("[%0t] MONITOR FAIL: BRESP %b expected %b", $time, bresp, exp_b[eb_h]);
                    errors = errors + 1;
                end
                eb_h = (eb_h + 1) % 256;
            end

            if (rvalid && rready) begin
                if (use_model != 0 &&
                    (rresp !== (exp_r[er_h][8] ? SLVERR : OKAY) || rdata !== {24'd0, exp_r[er_h][7:0]})) begin
                    $display("[%0t] MONITOR FAIL: read %b/%08h expected %b/%02h", $time, rresp, rdata,
                             exp_r[er_h][8] ? SLVERR : OKAY, exp_r[er_h][7:0]);
                    errors = errors + 1;
                end
                er_h = (er_h + 1) % 256;
            end
        end
    end

    // ------------------------------------------------------------ state compare
    task mismatch;
        input [8*40-1:0] what;
        input [31:0]     got;
        input [31:0]     want;
        begin
            if (mismatches < 8)
                $display("[%0t] MODEL MISMATCH cyc %0d: %0s dut %0h model %0h", $time, cyc, what, got, want);
            mismatches = mismatches + 1;
        end
    endtask

    always @(negedge aclk) begin
        if (aresetn && use_model != 0) begin
            n_compared = n_compared + 1;
            if (sout   !== u_model.sout)   mismatch("sout",   sout,   u_model.sout);
            if (dtr_n  !== u_model.dtr_n)  mismatch("dtr_n",  dtr_n,  u_model.dtr_n);
            if (rts_n  !== u_model.rts_n)  mismatch("rts_n",  rts_n,  u_model.rts_n);
            if (out1_n !== u_model.out1_n) mismatch("out1_n", out1_n, u_model.out1_n);
            if (out2_n !== u_model.out2_n) mismatch("out2_n", out2_n, u_model.out2_n);
            if (irq    !== u_model.irq)    mismatch("irq",    irq,    u_model.irq);

            if (u_dut.u_regs.ier_q   !== u_model.ier)   mismatch("IER",  u_dut.u_regs.ier_q,  u_model.ier);
            if (u_dut.u_regs.lcr_q   !== u_model.lcr)   mismatch("LCR",  u_dut.u_regs.lcr_q,  u_model.lcr);
            if (u_dut.u_regs.mcr_q   !== u_model.mcr)   mismatch("MCR",  u_dut.u_regs.mcr_q,  u_model.mcr);
            if (u_dut.u_regs.scr_q   !== u_model.scr)   mismatch("SCR",  u_dut.u_regs.scr_q,  u_model.scr);
            if (u_dut.u_regs.dll_q   !== u_model.dll)   mismatch("DLL",  u_dut.u_regs.dll_q,  u_model.dll);
            if (u_dut.u_regs.dlm_q   !== u_model.dlm)   mismatch("DLM",  u_dut.u_regs.dlm_q,  u_model.dlm);
            if (u_dut.u_regs.fen_q   !== u_model.fen)   mismatch("FCR0", u_dut.u_regs.fen_q,  u_model.fen);
            if (u_dut.u_regs.trig_q  !== u_model.trig)  mismatch("trig", u_dut.u_regs.trig_q, u_model.trig);
            if (u_dut.u_regs.lsr_val !== u_model.lsr_view(0)) mismatch("LSR", u_dut.u_regs.lsr_val, u_model.lsr_view(0));
            if (u_dut.u_regs.iir_val !== u_model.iir_view(0)) mismatch("IIR", u_dut.u_regs.iir_val, u_model.iir_view(0));
            if (u_dut.u_regs.msr_val !== u_model.msr_view(0)) mismatch("MSR", u_dut.u_regs.msr_val, u_model.msr_view(0));
            if (u_dut.u_regs.thri_q    !== u_model.thri)    mismatch("thri",    u_dut.u_regs.thri_q,    u_model.thri);
            if (u_dut.u_regs.to_pend_q !== u_model.to_pend) mismatch("to_pend", u_dut.u_regs.to_pend_q, u_model.to_pend);
            if (u_dut.u_regs.to_cnt_q  !== u_model.to_cnt)  mismatch("to_cnt",  u_dut.u_regs.to_cnt_q,  u_model.to_cnt);
            if (u_dut.u_regs.errs_q    !== u_model.errs)    mismatch("errs",    u_dut.u_regs.errs_q,    u_model.errs);

            if (u_dut.u_baud.cnt_q  !== u_model.bcnt)  mismatch("baud cnt", u_dut.u_baud.cnt_q,  u_model.bcnt);
            if (u_dut.u_baud.tick_q !== u_model.btick) mismatch("tick",     u_dut.u_baud.tick_q, u_model.btick);
            if (u_dut.u_tx.state_q  !== u_model.t_state) mismatch("tx state", u_dut.u_tx.state_q, u_model.t_state);
            if (u_dut.u_tx.txd_q    !== u_model.t_line)  mismatch("tx line",  u_dut.u_tx.txd_q,   u_model.t_line);
            if (u_dut.u_rx.state_q  !== u_model.r_state) mismatch("rx state", u_dut.u_rx.state_q, u_model.r_state);
            if (u_dut.u_rx.valid_q  !== u_model.r_valid) mismatch("rx valid", u_dut.u_rx.valid_q, u_model.r_valid);
            if (u_dut.u_rx.valid_q && {u_dut.u_rx.bi_q, u_dut.u_rx.fe_q, u_dut.u_rx.pe_q, u_dut.u_rx.data_q} !==
                                      {u_model.r_bi, u_model.r_fe, u_model.r_pe, u_model.r_data})
                mismatch("rx char", {u_dut.u_rx.bi_q, u_dut.u_rx.fe_q, u_dut.u_rx.pe_q, u_dut.u_rx.data_q},
                                    {u_model.r_bi, u_model.r_fe, u_model.r_pe, u_model.r_data});

            if (u_dut.u_rx_fifo.count_q !== u_model.rxn) mismatch("rx count", u_dut.u_rx_fifo.count_q, u_model.rxn);
            else for (kc = 0; kc < u_model.rxn; kc = kc + 1)
                if (u_dut.u_rx_fifo.mem[(u_dut.u_rx_fifo.rd_ptr_q + kc) % 16] !== u_model.rxq[kc])
                    mismatch("rx fifo entry", kc, u_model.rxq[kc]);
            if (u_dut.u_tx_fifo.count_q !== u_model.txn) mismatch("tx count", u_dut.u_tx_fifo.count_q, u_model.txn);
            else for (kc = 0; kc < u_model.txn; kc = kc + 1)
                if (u_dut.u_tx_fifo.mem[(u_dut.u_tx_fifo.rd_ptr_q + kc) % 16] !== u_model.txq[kc])
                    mismatch("tx fifo entry", kc, u_model.txq[kc]);
        end
    end

    // ------------------------------------------------------------ coverage
    integer cov_rx_break, cov_rx_fe, cov_resync, cov_rx_pe, cov_glitch, cov_overrun_fifo, cov_overrun_16450;
    integer cov_pop_with_push_full, cov_lsr_collision, cov_thri_collision, cov_cti_set, cov_cti_kept;
    integer cov_tx_replace, cov_tx_drop, cov_msr_collision, cov_back_to_back, cov_div_load_running;
    integer cov_iir [0:15];
    integer cov_fmt [0:63];      // {wbits-5 (2 bits), parity mode (3 bits), stb (1 bit)} seen on received frames
    integer cov_loop_rx, cov_fifo_full, cov_trig [0:3], cov_lsr7_sticky;
    reg     irq_prev;

    initial begin
        cov_rx_break = 0; cov_rx_fe = 0; cov_resync = 0; cov_rx_pe = 0; cov_glitch = 0;
        cov_overrun_fifo = 0; cov_overrun_16450 = 0; cov_pop_with_push_full = 0; cov_lsr_collision = 0;
        cov_thri_collision = 0; cov_cti_set = 0; cov_cti_kept = 0; cov_tx_replace = 0; cov_tx_drop = 0;
        cov_msr_collision = 0; cov_back_to_back = 0; cov_div_load_running = 0;
        cov_loop_rx = 0; cov_fifo_full = 0; cov_lsr7_sticky = 0; last_rx_cyc = 0;
        for (i = 0; i < 16; i = i + 1) cov_iir[i] = 0;
        for (i = 0; i < 64; i = i + 1) cov_fmt[i] = 0;
        for (i = 0; i < 4; i = i + 1) cov_trig[i] = 0;
        irq_prev = 1'b0;
    end

    always @(negedge aclk) begin
        if (aresetn) begin
            if (u_model.ev_rx_break)            cov_rx_break           = cov_rx_break + 1;
            if (u_model.ev_rx_fe)               cov_rx_fe              = cov_rx_fe + 1;
            if (u_model.ev_resync)              cov_resync             = cov_resync + 1;
            if (u_model.ev_rx_pe)               cov_rx_pe              = cov_rx_pe + 1;
            if (u_model.ev_rx_glitch)           cov_glitch             = cov_glitch + 1;
            if (u_model.ev_overrun)             cov_overrun_fifo       = cov_overrun_fifo + 1;
            if (u_model.ev_rx_replace)          cov_overrun_16450      = cov_overrun_16450 + 1;
            if (u_model.ev_cpu_pop_with_push)   cov_pop_with_push_full = cov_pop_with_push_full + 1;
            if (u_model.ev_lsr_clear_collision) cov_lsr_collision      = cov_lsr_collision + 1;
            if (u_model.ev_thri_collision)      cov_thri_collision     = cov_thri_collision + 1;
            if (u_model.ev_cti_set)             cov_cti_set            = cov_cti_set + 1;
            if (u_model.ev_cti_kept_on_rx)      cov_cti_kept           = cov_cti_kept + 1;
            if (u_model.ev_tx_replace)          cov_tx_replace         = cov_tx_replace + 1;
            if (u_model.ev_tx_drop)             cov_tx_drop            = cov_tx_drop + 1;
            if (u_model.ev_msr_collision)       cov_msr_collision      = cov_msr_collision + 1;
            if (u_model.ev_back_to_back)        cov_back_to_back       = cov_back_to_back + 1;
            if (u_model.ev_div_load_running)    cov_div_load_running   = cov_div_load_running + 1;
            if (u_model.rxn == 16)              cov_fifo_full          = cov_fifo_full + 1;
            if (u_model.fen && u_model.lsr7s && u_model.errs == 0) cov_lsr7_sticky = cov_lsr7_sticky + 1;
            if (u_model.fen && u_model.ier[0] && u_model.rxn >= u_model.trig_lvl(0) && u_model.rxn > 0)
                cov_trig[u_model.trig] = cov_trig[u_model.trig] + 1;
            if (u_model.r_valid && u_model.mcr[4]) cov_loop_rx = cov_loop_rx + 1;
            if (u_model.r_valid) last_rx_cyc = cyc;
            if (u_model.r_valid)
                cov_fmt[{u_model.r_last[1:0], u_model.r_pen ? (u_model.r_stick ? (u_model.r_eps ? 3'd4 : 3'd3)
                                                                                : (u_model.r_eps ? 3'd2 : 3'd1)) : 3'd0,
                         u_model.lcr[2]}] = cov_fmt[{u_model.r_last[1:0],
                         u_model.r_pen ? (u_model.r_stick ? (u_model.r_eps ? 3'd4 : 3'd3)
                                                          : (u_model.r_eps ? 3'd2 : 3'd1)) : 3'd0,
                         u_model.lcr[2]}] + 1;
            irq_prev = irq;
        end
    end

    // IIR values actually returned to software
    always @(posedge aclk) begin
        if (aresetn && u_dut.reg_rd && u_dut.reg_raddr == R_IIR)
            cov_iir[u_model.iir_id(0)] = cov_iir[u_model.iir_id(0)] + 1;
    end

    // ------------------------------------------------------------ helpers
    task check;
        input            cond;
        input [8*48-1:0] what;
        begin
            if (cond !== 1'b1) begin
                $display("[%0t] EXPECT FAIL: %0s", $time, what);
                errors = errors + 1;
            end
        end
    endtask

    task wr;
        input [ADDR_W-1:0] a;
        input [7:0]        d;
        begin
            u_bfm.write(a, {24'd0, d}, 4'b0001, resp);
        end
    endtask

    task rd;
        input  [ADDR_W-1:0] a;
        output [7:0]        d;
        begin
            u_bfm.read(a, v, resp);
            d = v[7:0];
        end
    endtask

    task rd_expect;
        input [ADDR_W-1:0] a;
        input [7:0]        want;
        input [8*48-1:0]   what;
        reg   [7:0]        got;
        begin
            rd(a, got);
            if (got !== want) begin
                $display("[%0t] EXPECT FAIL: %0s: read 0x%02h expected 0x%02h", $time, what, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // LCR value for a frame format. pmode: 0 none 1 odd 2 even 3 mark 4 space
    function [7:0] lcr_for;
        input integer wbits;
        input integer pmode;
        input integer stb;
        integer w;
        begin
            w = wbits - 5;
            lcr_for = {2'b00,
                       pmode >= 3,                      // stick parity
                       pmode == 2 || pmode == 4,        // even, or space
                       pmode != 0,                      // parity enable
                       stb != 0,
                       w[1:0]};
        end
    endfunction

    function integer halves_for;
        input integer wbits;
        input integer stb;
        begin
            halves_for = (stb == 0) ? 2 : (wbits == 5 ? 3 : 4);
        end
    endfunction

    task set_divisor;
        input integer d;
        reg   [7:0]   l;
        begin
            rd(R_LCR, l);
            wr(R_LCR, l | 8'h80);
            wr(R_DATA, d[7:0]);
            wr(R_IER, d[15:8]);
            wr(R_LCR, l & 8'h7F);
            cur_div = d;
        end
    endtask

    task set_format;
        input integer wbits;
        input integer pmode;
        input integer stb;
        begin
            wr(R_LCR, lcr_for(wbits, pmode, stb));
            u_ser.mon_wbits       = wbits;
            u_ser.mon_pmode       = pmode;
            u_ser.mon_stop_halves = halves_for(wbits, stb);
            u_ser.mon_bit_ns      = 160 * cur_div;
        end
    endtask

    // wait at falling edges until the transmitter is completely idle
    task wait_tx_idle;
        integer guard;
        begin
            guard = 0;
            @(negedge aclk);
            while (u_dut.u_regs.lsr_val[6] !== 1'b1 && guard < 200000) begin
                @(negedge aclk);
                guard = guard + 1;
            end
            repeat (4) @(negedge aclk);
        end
    endtask

    task wait_cycles;
        input integer c;
        begin
            repeat (c) @(negedge aclk);
        end
    endtask

    // send one frame on sin and return at a falling edge after the receiver has had
    task ser_send;
        input [7:0]   d;
        input integer wbits;
        input integer pmode;
        input integer stb;
        input integer flags;
        begin
            u_ser.send(d, wbits, pmode, halves_for(wbits, stb), 160 * cur_div, flags);
            wait_cycles(8);
        end
    endtask

    task init_uart;          // divisor 1, 8N1, FIFOs off, everything quiet
        begin
            wr(R_IER, 8'h00);
            wr(R_MCR, 8'h00);
            wr(R_IIR, 8'h00);
            set_divisor(1);
            set_format(8, 0, 0);
            rd(R_LSR, v[7:0]);
            rd(R_MSR, v[7:0]);
            rd(R_IIR, v[7:0]);
        end
    endtask

    // ================================================================ tests
    task test_reset;
        begin
            $display("[%0t] TEST test_reset", $time);
            rd_expect(R_IER,  8'h00, "reset IER");
            rd_expect(R_IIR,  8'h01, "reset IIR (Table 3)");
            rd_expect(R_LCR,  8'h00, "reset LCR");
            rd_expect(R_MCR,  8'h00, "reset MCR");
            rd_expect(R_LSR,  8'h60, "reset LSR (Table 3)");
            rd_expect(R_MSR,  8'h00, "reset MSR, modem pins inactive");
            rd_expect(R_SCR,  8'h00, "reset SCR");
            check(sout === 1'b1 && dtr_n === 1'b1 && rts_n === 1'b1 && out1_n === 1'b1 && out2_n === 1'b1,
                  "reset pins inactive (Table 3)");
            check(irq === 1'b0, "reset irq low");
            wr(R_LCR, 8'h80);
            rd_expect(R_DATA, 8'h00, "reset DLL");
            rd_expect(R_IER,  8'h00, "reset DLM");
            wr(R_LCR, 8'h00);
        end
    endtask

    // the register handshakes a PC serial driver performs to recognise a 16550A
    task test_driver_probe;
        reg [7:0] save;
        begin
            $display("[%0t] TEST test_driver_probe", $time);
            // interrupt enable register: only bits 3:0 exist
            wr(R_IER, 8'h00);   rd_expect(R_IER, 8'h00, "probe IER cleared");
            wr(R_IER, 8'h0F);   rd_expect(R_IER, 8'h0F, "probe IER all four enables");
            wr(R_IER, 8'hF0);   rd_expect(R_IER, 8'h00, "probe IER bits 7:4 read 0");
            wr(R_IER, 8'h00);
            // scratch register
            wr(R_SCR, 8'h55);   rd_expect(R_SCR, 8'h55, "probe scratch 55");
            wr(R_SCR, 8'hAA);   rd_expect(R_SCR, 8'hAA, "probe scratch AA");
            // loopback: LOOP | OUT2 | RTS must read back as DCD | CTS in MSR 7:4
            wr(R_MCR, 8'h1A);
            wait_cycles(3);
            rd(R_MSR, save);
            check((save & 8'hF0) == 8'h90, "probe loopback MSR 7:4 = 0x90");
            wr(R_MCR, 8'h00);
            wait_cycles(3);
            rd(R_MSR, save);
            // FIFO present: IIR 7:6 = 11 after enabling
            wr(R_IIR, 8'h01);
            rd(R_IIR, save);
            check(save[7:6] == 2'b11, "probe IIR 7:6 = 11 means 16550A");
            wr(R_IIR, 8'h00);
            rd(R_IIR, save);
            check(save[7:6] == 2'b00, "probe IIR 7:6 = 00 in 16450 mode");
            // THRE interrupt must appear when enabled on an idle transmitter
            wr(R_IER, 8'h02);
            rd(R_LSR, save);   check(save[6] == 1'b1, "probe TEMT on idle transmitter");
            rd(R_IIR, save);   check(save[3:0] == 4'h2, "probe THRE interrupt after enabling");
            rd(R_IIR, save);   check(save[3:0] == 4'h1, "probe IIR read cleared THRE interrupt");
            wr(R_IER, 8'h00);
            wr(R_IER, 8'h02);
            rd(R_IIR, save);   check(save[3:0] == 4'h2, "probe THRE interrupt reasserted");
            wr(R_IER, 8'h00);
        end
    endtask

    task test_dlab;
        begin
            $display("[%0t] TEST test_dlab", $time);
            wr(R_IER, 8'h05);
            wr(R_LCR, 8'h83);
            wr(R_DATA, 8'h34);
            wr(R_IER, 8'h12);
            rd_expect(R_DATA, 8'h34, "DLL through DLAB");
            rd_expect(R_IER,  8'h12, "DLM through DLAB");
            rd_expect(R_LCR,  8'h83, "LCR with DLAB");
            wr(R_LCR, 8'h03);
            rd_expect(R_IER,  8'h05, "IER untouched by DLM write");
            rd_expect(R_LSR,  8'h60, "DLL write sent nothing");
            wr(R_IER, 8'h00);
            set_divisor(1);
        end
    endtask

    task test_tx_formats;
        integer  wb, pm, sb, len2;
        reg [7:0] d;
        realtime t_first;
        begin
            $display("[%0t] TEST test_tx_formats", $time);
            u_ser.mon_en = 1;
            u_ser.mon_flush;
            for (wb = 5; wb <= 8; wb = wb + 1)
                for (pm = 0; pm <= 4; pm = pm + 1)
                    for (sb = 0; sb <= 1; sb = sb + 1) begin
                        set_format(wb, pm, sb);
                        d = $random(seed);
                        wr(R_DATA, d);
                        wr(R_DATA, ~d);
                        wait_tx_idle;
                        u_ser.expect_frame(d, ok);  check(ok, "tx frame 1");
                        t_first = u_ser.last_start;
                        u_ser.expect_frame(~d, ok); check(ok, "tx frame 2");
                        // the second byte was already waiting, so its start bit must
                        len2 = 2 * (1 + wb + (pm != 0)) + halves_for(wb, sb);
                        check(u_ser.last_start - t_first == len2 * 160 * cur_div / 2,
                              "back-to-back frames with no gap");
                    end
            set_format(8, 0, 0);
            u_ser.mon_en = 0;
        end
    endtask

    task test_rx_formats;
        integer wb, pm, sb;
        reg [7:0] d, got, mask;
        begin
            $display("[%0t] TEST test_rx_formats", $time);
            for (wb = 5; wb <= 8; wb = wb + 1)
                for (pm = 0; pm <= 4; pm = pm + 1)
                    for (sb = 0; sb <= 1; sb = sb + 1) begin
                        set_format(wb, pm, sb);
                        d    = $random(seed);
                        mask = (8'd1 << wb) - 8'd1;
                        ser_send(d, wb, pm, sb, 0);
                        rd_expect(R_LSR, 8'h61, "rx format: data ready, no errors");
                        rd_expect(R_DATA, d & mask, "rx format: data, upper bits 0");
                        rd_expect(R_LSR, 8'h60, "rx format: buffer empty after read");
                    end
            set_format(8, 0, 0);
        end
    endtask

    task test_rx_errors;
        begin
            $display("[%0t] TEST test_rx_errors", $time);
            wr(R_IIR, 8'h07);                                   // FIFO mode keeps every character
            // parity error
            set_format(8, 2, 0);
            ser_send(8'h5A, 8, 2, 0, 1);
            rd_expect(R_LSR, 8'hE5, "parity error: DR, PE, LSR7");
            rd_expect(R_DATA, 8'h5A, "parity error: data kept");
            rd_expect(R_LSR, 8'hE0, "LSR7 stays until the LSR read after the bad byte left");
            rd_expect(R_LSR, 8'h60, "all error state cleared");
            // a frame with no stop bit, followed at once by a good frame: the good
            set_format(8, 0, 0);
            u_ser.send(8'h0F, 8, 0, 2, 160, 8);
            u_ser.send(8'hA5, 8, 0, 2, 160, 4);
            wait_cycles(8);
            rd_expect(R_LSR, 8'hE9, "framing error: DR, FE, LSR7");
            rd_expect(R_DATA, 8'h0F, "framing error: data kept");
            rd_expect(R_LSR, 8'hE1, "resynchronised byte waiting, LSR7 sticky");
            rd_expect(R_DATA, 8'hA5, "resynchronised on the next start bit");
            rd_expect(R_LSR, 8'h60, "clean after resynchronisation");
            // break: exactly one zero character with BI and FE
            u_ser.send_break(30, 160);
            wait_cycles(8);
            rd_expect(R_LSR, 8'hF9, "break: DR, FE, BI, LSR7");
            rd_expect(R_DATA, 8'h00, "break: one zero character");
            rd_expect(R_LSR, 8'hE0, "break: LSR7 sticky");
            rd_expect(R_LSR, 8'h60, "break: only one character was loaded");
            ser_send(8'h3C, 8, 0, 0, 0);
            rd_expect(R_DATA, 8'h3C, "frame after break");
            wr(R_IIR, 8'h00);
        end
    endtask

    task test_glitch;
        begin
            $display("[%0t] TEST test_glitch", $time);
            set_format(8, 0, 0);
            u_ser.glitch(30);                            // under half a bit (80 ns)
            wait_cycles(400);
            rd_expect(R_LSR, 8'h60, "glitch ignored");
            u_ser.glitch(60);
            wait_cycles(400);
            rd_expect(R_LSR, 8'h60, "longer glitch ignored");
        end
    endtask

    task test_baud_tolerance;
        begin
            $display("[%0t] TEST test_baud_tolerance", $time);
            set_format(8, 0, 0);
            u_ser.send(8'hC3, 8, 0, 2, 155, 0);         // about 3 percent fast
            wait_cycles(8);
            rd_expect(R_DATA, 8'hC3, "3 percent fast frame");
            u_ser.send(8'h3C, 8, 0, 2, 165, 0);         // about 3 percent slow
            wait_cycles(8);
            rd_expect(R_DATA, 8'h3C, "3 percent slow frame");
            rd_expect(R_LSR, 8'h60, "no errors at 3 percent");
        end
    endtask

    task test_16450_mode;
        begin
            $display("[%0t] TEST test_16450_mode", $time);
            wr(R_IIR, 8'h00);
            set_format(8, 0, 0);
            // receive overrun replaces the character
            ser_send(8'h11, 8, 0, 0, 0);
            ser_send(8'h22, 8, 0, 0, 0);
            rd_expect(R_LSR, 8'h63, "16450 overrun: DR and OE");
            rd_expect(R_DATA, 8'h22, "16450 overrun: newest character kept");
            rd_expect(R_LSR, 8'h60, "16450 overrun cleared");
            // THR replace: baud generator off so nothing drains
            set_divisor(0);
            wr(R_DATA, 8'h41);
            wr(R_DATA, 8'h42);
            rd_expect(R_LSR, 8'h00, "16450 THR full, transmitter stopped");
            u_ser.mon_en = 1; u_ser.mon_flush;
            set_divisor(1);
            wait_tx_idle;
            u_ser.expect_frame(8'h42, ok); check(ok, "16450 THR replace sent newest byte");
            check(u_ser.mon_empty(0), "16450 THR replace sent only one byte");
            u_ser.mon_en = 0;
        end
    endtask

    task test_fifo_mode;
        integer t;
        begin
            $display("[%0t] TEST test_fifo_mode", $time);
            set_format(8, 0, 0);
            wr(R_IIR, 8'h07);                                   // FIFOs on and cleared, trigger 1
            for (i = 0; i < 18; i = i + 1)
                ser_send(8'h30 + i, 8, 0, 0, 0);
            rd_expect(R_LSR, 8'h63, "FIFO overrun: DR and OE");
            for (i = 0; i < 16; i = i + 1)
                rd_expect(R_DATA, 8'h30 + i, "FIFO keeps the first 16");
            rd_expect(R_LSR, 8'h60, "FIFO empty after 16 reads");
            // transmit FIFO: 16 accepted, the 17th discarded
            set_divisor(0);
            for (i = 0; i < 17; i = i + 1)
                wr(R_DATA, 8'h60 + i);
            u_ser.mon_en = 1; u_ser.mon_flush;
            set_divisor(1);
            wait_tx_idle;
            for (i = 0; i < 16; i = i + 1) begin
                u_ser.expect_frame(8'h60 + i, ok); check(ok, "TX FIFO order");
            end
            check(u_ser.mon_empty(0), "TX FIFO 17th byte discarded");
            u_ser.mon_en = 0;
            // trigger levels
            for (t = 0; t < 4; t = t + 1) begin
                wr(R_IIR, {t[1:0], 6'b000111});
                wr(R_IER, 8'h01);
                for (i = 0; i < 14; i = i + 1) begin
                    ser_send(8'h00 + i, 8, 0, 0, 0);
                    rd(R_IIR, v[7:0]);
                    if ((i + 1) >= ((t == 0) ? 1 : (t == 1) ? 4 : (t == 2) ? 8 : 14))
                        check(v[3:0] == 4'h4, "trigger level reached gives IIR 04");
                    else
                        check(v[3:0] != 4'h4, "below trigger level no IIR 04");
                end
                wr(R_IER, 8'h00);
            end
            wr(R_IIR, 8'h07);
        end
    endtask

    task test_timeout;
        integer t1;
        begin
            $display("[%0t] TEST test_timeout", $time);
            set_format(8, 0, 0);
            wr(R_IIR, 8'hC7);                                   // FIFOs, trigger 14
            wr(R_IER, 8'h01);
            ser_send(8'h99, 8, 0, 0, 0);
            while (u_model.to_pend !== 1'b1 && cyc < last_rx_cyc + 2000) @(negedge aclk);
            t1 = cyc;
            // 8N1 is 10 bits of 16 ticks; 4 character times is 640 ticks, one per
            check(t1 - last_rx_cyc == 641, "timeout exactly 4 character times after the character");
            rd_expect(R_IIR, 8'hCC, "character timeout indication");
            ser_send(8'h98, 8, 0, 0, 0);
            rd_expect(R_IIR, 8'hCC, "timeout kept after a new character");
            rd_expect(R_DATA, 8'h99, "timeout: first byte");
            rd_expect(R_IIR, 8'hC1, "RBR read cleared the timeout");
            wait_cycles(700);
            rd_expect(R_IIR, 8'hCC, "timeout again for the remaining byte");
            rd_expect(R_DATA, 8'h98, "timeout: second byte");
            wait_cycles(700);
            rd_expect(R_IIR, 8'hC1, "no timeout with an empty FIFO");
            // two stop bits and parity lengthen the character time: 12 bits
            set_format(8, 1, 1);
            ser_send(8'h97, 8, 1, 1, 0);
            while (u_model.to_pend !== 1'b1 && cyc < last_rx_cyc + 2000) @(negedge aclk);
            check(cyc - last_rx_cyc == 4 * (16 * 10 + 32) + 1, "timeout counts parity and both stop bits");
            rd(R_DATA, v[7:0]);
            wr(R_IER, 8'h00);
            set_format(8, 0, 0);
        end
    endtask

    task test_lsr_flags;
        begin
            $display("[%0t] TEST test_lsr_flags", $time);
            set_format(8, 2, 0);
            wr(R_IIR, 8'h07);
            ser_send(8'h01, 8, 2, 0, 0);            // good
            ser_send(8'h02, 8, 2, 0, 1);            // parity error
            ser_send(8'h03, 8, 2, 0, 0);            // good
            rd_expect(R_LSR, 8'hE1, "LSR7 set, PE not yet at head");
            rd_expect(R_DATA, 8'h01, "head 1");
            wait_cycles(2);
            rd_expect(R_LSR, 8'hE5, "PE revealed at head");
            rd_expect(R_DATA, 8'h02, "head 2");
            rd_expect(R_LSR, 8'hE1, "LSR7 still set after the bad byte left");
            rd_expect(R_LSR, 8'h61, "LSR7 cleared by the next LSR read");
            rd_expect(R_DATA, 8'h03, "head 3");
            set_format(8, 0, 0);
        end
    endtask

    task test_priority;
        begin
            $display("[%0t] TEST test_priority", $time);
            set_format(8, 2, 0);
            wr(R_IIR, 8'h07);
            wr(R_IER, 8'h0F);
            rd_expect(R_IIR, 8'hC2, "only THRE pending");
            // that read reported THRI, so it cleared it (decisions log); arm it again
            wr(R_IER, 8'h00);
            wr(R_IER, 8'h0F);
            cts_n = 1'b0;
            wait_cycles(6);
            ser_send(8'h55, 8, 2, 0, 1);            // parity error
            rd_expect(R_IIR, 8'hC6, "line status is highest");
            rd_expect(R_LSR, 8'hE5, "read LSR: DR, PE, LSR7");
            rd_expect(R_IIR, 8'hC4, "then received data");
            rd_expect(R_DATA, 8'h55, "read RBR");
            rd_expect(R_IIR, 8'hC2, "then THRE");
            rd_expect(R_IIR, 8'hC0, "IIR read cleared THRE, then modem status");
            rd_expect(R_MSR, 8'h11, "CTS active and DCTS");
            rd_expect(R_IIR, 8'hC1, "nothing left");
            check(irq === 1'b0, "irq low when nothing pending");
            cts_n = 1'b1;
            wait_cycles(6);
            rd(R_MSR, v[7:0]);
            rd(R_LSR, v[7:0]);
            wr(R_IER, 8'h00);
            set_format(8, 0, 0);
        end
    endtask

    task test_thri;
        begin
            $display("[%0t] TEST test_thri", $time);
            wr(R_IIR, 8'h07);
            wr(R_IER, 8'h02);
            rd_expect(R_IIR, 8'hC2, "THRI on enable");
            rd_expect(R_IIR, 8'hC1, "IIR read that reports THRI clears it");
            // hold the transmitter so the byte stays in the FIFO
            set_divisor(0);
            wr(R_DATA, 8'h77);
            rd_expect(R_IIR, 8'hC1, "no THRI while a byte waits");
            set_divisor(1);
            wait_tx_idle;
            rd_expect(R_IIR, 8'hC2, "THRI when the FIFO empties");
            // THRI pending, then a higher priority interrupt hides it
            wr(R_IER, 8'h00);
            wr(R_IER, 8'h07);
            set_format(8, 2, 0);
            ser_send(8'h00, 8, 2, 0, 1);
            rd_expect(R_IIR, 8'hC6, "line status hides THRI");
            rd_expect(R_IIR, 8'hC6, "reading it again changes nothing");
            rd(R_LSR, v[7:0]);
            rd(R_DATA, v[7:0]);
            rd_expect(R_IIR, 8'hC2, "hidden THRI was not cleared by those IIR reads");
            rd_expect(R_IIR, 8'hC1, "now it is");
            rd(R_LSR, v[7:0]);
            wr(R_IER, 8'h00);
            set_format(8, 0, 0);
        end
    endtask

    task test_modem;
        begin
            $display("[%0t] TEST test_modem", $time);
            wr(R_MCR, 8'h0F);
            wait_cycles(2);
            check({out2_n, out1_n, rts_n, dtr_n} == 4'h0, "MCR 1 drives pins low");
            wr(R_MCR, 8'h00);
            wait_cycles(2);
            check({out2_n, out1_n, rts_n, dtr_n} == 4'hF, "MCR 0 drives pins high");
            rd(R_MSR, v[7:0]);
            dsr_n = 1'b0; wait_cycles(6);
            rd_expect(R_MSR, 8'h22, "DSR active, DDSR");
            rd_expect(R_MSR, 8'h20, "DDSR cleared by read");
            dcd_n = 1'b0; wait_cycles(6);
            rd_expect(R_MSR, 8'hA8, "DCD active, DDCD");
            ri_n = 1'b0; wait_cycles(6);
            rd_expect(R_MSR, 8'hE0, "RI going active does not set TERI");
            ri_n = 1'b1; wait_cycles(6);
            rd_expect(R_MSR, 8'hA4, "RI going inactive sets TERI");
            dsr_n = 1'b1; dcd_n = 1'b1; wait_cycles(6);
            rd_expect(R_MSR, 8'h0A, "both inactive, DDSR and DDCD");
            // loopback mapping and pin behaviour
            wr(R_MCR, 8'h1F);
            wait_cycles(3);
            check({out2_n, out1_n, rts_n, dtr_n} == 4'hF && sout === 1'b1, "loopback pins inactive");
            rd(R_MSR, v[7:0]);
            check(v[7:4] == 4'hF, "loopback MSR follows MCR");
            wr(R_MCR, 8'h15);                           // DTR and OUT1
            wait_cycles(3);
            rd(R_MSR, v[7:0]);
            check(v[7:4] == 4'h6, "loopback DTR to DSR, OUT1 to RI");
            wr(R_MCR, 8'h00);
            wait_cycles(3);
            rd(R_MSR, v[7:0]);
        end
    endtask

    task test_loopback_data;
        begin
            $display("[%0t] TEST test_loopback_data", $time);
            wr(R_IIR, 8'h07);
            wr(R_MCR, 8'h10);
            set_format(7, 1, 1);
            for (i = 0; i < 5; i = i + 1) wr(R_DATA, 8'h50 + i);
            wait_tx_idle;
            wait_cycles(40);
            for (i = 0; i < 5; i = i + 1) rd_expect(R_DATA, (8'h50 + i) & 8'h7F, "loopback data");
            rd_expect(R_LSR, 8'h60, "loopback clean");
            // break in loopback is received as a break
            wr(R_LCR, lcr_for(7, 1, 1) | 8'h40);
            wait_cycles(16 * 12);
            wr(R_LCR, lcr_for(7, 1, 1));
            wait_cycles(40);
            rd_expect(R_LSR, 8'hFD, "loopback break: DR, PE (odd parity of zero), FE, BI, LSR7");
            rd_expect(R_DATA, 8'h00, "loopback break character");
            rd(R_LSR, v[7:0]);
            wr(R_MCR, 8'h00);
            set_format(8, 0, 0);
        end
    endtask

    task test_break_tx;
        begin
            $display("[%0t] TEST test_break_tx", $time);
            u_ser.mon_en = 1; u_ser.mon_width_check = 0;
            wr(R_LCR, 8'h43);
            wait_cycles(3);
            check(sout === 1'b0, "break drives sout low");
            wr(R_LCR, 8'h03);
            wait_cycles(3);
            check(sout === 1'b1, "break released");
            wait_cycles(200);
            u_ser.mon_flush;
            u_ser.mon_width_check = 1; u_ser.mon_en = 0;
        end
    endtask

    task test_fcr;
        begin
            $display("[%0t] TEST test_fcr", $time);
            set_format(8, 0, 0);
            wr(R_IIR, 8'h01);
            ser_send(8'h10, 8, 0, 0, 0);
            ser_send(8'h11, 8, 0, 0, 0);
            wr(R_IIR, 8'h03);                           // clear the receive FIFO only
            rd_expect(R_LSR, 8'h60, "FCR1 cleared the receive FIFO");
            set_divisor(0);
            wr(R_DATA, 8'hEE);
            wr(R_IIR, 8'h05);                           // clear the transmit FIFO only
            rd_expect(R_LSR, 8'h60, "FCR2 cleared the transmit FIFO");
            wr(R_DATA, 8'hEF);
            wr(R_IIR, 8'hC1);                           // trigger 14, FCR2 not set
            rd_expect(R_LSR, 8'h00, "byte still waiting: FCR 0xC1 does not clear the transmit FIFO");
            wr(R_IIR, 8'h40);                           // leave FIFO mode
            rd_expect(R_LSR, 8'h60, "FCR0 change cleared the FIFOs");
            // white-box: with FCR0 = 0 the trigger bits are not programmed
            check(u_dut.u_regs.trig_q == 2'd3, "FCR 7:6 ignored when FCR0 = 0");
            wr(R_IIR, 8'h01);
            wr(R_IER, 8'h01);
            set_divisor(1);
            ser_send(8'h12, 8, 0, 0, 0);
            rd_expect(R_IIR, 8'hC4, "trigger 1 programmed with FCR0 = 1");
            rd(R_DATA, v[7:0]);
            wr(R_IER, 8'h00);
        end
    endtask

    task test_bus_rules;
        begin
            $display("[%0t] TEST test_bus_rules", $time);
            u_bfm.write(12'h020, 32'h0, 4'hF, resp);  check(resp == SLVERR, "write past the map is SLVERR");
            u_bfm.write(12'h002, 32'h0, 4'hF, resp);  check(resp == SLVERR, "misaligned write is SLVERR");
            u_bfm.read(12'h024, v, resp);             check(resp == SLVERR && v == 0, "read past the map");
            u_bfm.read(12'h005, v, resp);             check(resp == SLVERR, "misaligned read");
            u_bfm.write(R_LSR, 32'hFF, 4'hF, resp);   check(resp == OKAY, "LSR write accepted");
            u_bfm.write(R_MSR, 32'hFF, 4'hF, resp);   check(resp == OKAY, "MSR write accepted");
            rd_expect(R_LSR, 8'h60, "LSR write ignored");
            u_bfm.write(R_SCR, 32'h000000A5, 4'hE, resp);
            rd_expect(R_SCR, 8'hAA, "WSTRB0 = 0 changes nothing");
            u_bfm.write(R_SCR, 32'hFFFFFF3C, 4'h1, resp);
            rd_expect(R_SCR, 8'h3C, "upper bytes ignored");
            // side effect exactly once while RREADY waits
            set_format(8, 0, 0);
            ser_send(8'h61, 8, 0, 0, 0);
            ser_send(8'h62, 8, 0, 0, 0);
            u_bfm.force_r = 6;
            rd_expect(R_DATA, 8'h61, "stalled RBR read");
            u_bfm.force_r = -1;
            rd_expect(R_DATA, 8'h62, "stalled read popped only once");
        end
    endtask

    task test_divisor;
        begin
            $display("[%0t] TEST test_divisor", $time);
            set_format(8, 0, 0);
            set_divisor(3);
            u_ser.mon_en = 1; u_ser.mon_flush;
            u_ser.mon_bit_ns = 480;
            wr(R_DATA, 8'h96);
            wait_tx_idle;
            u_ser.expect_frame(8'h96, ok); check(ok, "frame at divisor 3");
            u_ser.send(8'h69, 8, 0, 2, 480, 0);
            wait_cycles(8);
            rd_expect(R_DATA, 8'h69, "receive at divisor 3");
            u_ser.mon_en = 0;
            set_divisor(1);
            u_ser.mon_bit_ns = 160;
        end
    endtask


    // land two events in exactly the same cycle, using the model to see them coming
    task test_collisions;
        integer guard;
        begin
            $display("[%0t] TEST test_collisions", $time);
            u_bfm.no_delays;
            set_format(8, 0, 0);
            wr(R_IIR, 8'h07);
            // (1) RX FIFO full, a character arrives, CPU reads RBR that cycle
            for (i = 0; i < 16; i = i + 1) ser_send(8'h80 + i, 8, 0, 0, 0);
            fork
                u_ser.send(8'hC0, 8, 0, 2, 160, 0);
                begin
                    guard = 0;
                    while (!(u_model.r_state == 4 && u_model.r_sub == 13) && guard < 5000) begin
                        @(negedge aclk); guard = guard + 1;
                    end
                    wait_cycles(3);
                    rd(R_DATA, v[7:0]);
                end
            join
            wait_cycles(8);
            rd(R_LSR, v[7:0]);
            check(v[1] == 1'b0, "read in the arrival cycle prevents overrun");
            for (i = 0; i < 16; i = i + 1) rd(R_DATA, v[7:0]);
            check(v[7:0] == 8'hC0, "arriving byte stored after the read made room");
            // (2) RX FIFO full, a character arrives, CPU reads LSR that cycle
            for (i = 0; i < 16; i = i + 1) ser_send(8'h90 + i, 8, 0, 0, 0);
            fork
                u_ser.send(8'hC1, 8, 0, 2, 160, 0);
                begin
                    guard = 0;
                    while (!(u_model.r_state == 4 && u_model.r_sub == 13) && guard < 5000) begin
                        @(negedge aclk); guard = guard + 1;
                    end
                    wait_cycles(3);
                    rd(R_LSR, v[7:0]);
                    check(v[1] == 1'b0, "LSR read in the overrun cycle shows old value");
                end
            join
            wait_cycles(8);
            rd(R_LSR, v[7:0]);
            check(v[1] == 1'b1, "overrun survived the colliding LSR read");
            wr(R_IIR, 8'h07);
            // (3) modem input change reaches MSR in the same cycle as an MSR read
            dsr_n = 1'b0;
            wait_cycles(3);
            rd(R_MSR, v[7:0]);
            wait_cycles(2);
            rd(R_MSR, v[7:0]);
            check(v[1] == 1'b1, "DDSR survived the colliding MSR read");
            dsr_n = 1'b1;
            wait_cycles(6);
            rd(R_MSR, v[7:0]);
            // (4) THR written in the cycle THRE rises: THRI set wins, so IIR still
            set_divisor(4);
            wr(R_IER, 8'h00);
            wr(R_IER, 8'h02);
            wr(R_DATA, 8'h31);
            guard = 0;
            while (!(u_dut.u_tx_fifo.count_q == 1 && u_dut.u_baud.tick_q && u_dut.u_tx.state_q == 0) &&
                   guard < 5000) begin
                @(negedge aclk); guard = guard + 1;
            end
            wr(R_DATA, 8'h32);
            rd(R_IIR, v[7:0]);
            check(v[3:0] == 4'h2, "THRE rise survived the colliding THR write");
            wr(R_IER, 8'h00);
            wait_tx_idle;
            // (5) a parity error character reaches the head of the RX FIFO
            set_divisor(1);
            set_format(8, 2, 0);
            fork
                u_ser.send(8'h44, 8, 2, 2, 160, 1);
                begin
                    guard = 0;
                    while (u_dut.u_rx.valid_q !== 1'b1 && guard < 5000) begin
                        @(negedge aclk); guard = guard + 1;
                    end
                    @(negedge aclk);
                    rd(R_LSR, v[7:0]);
                    check(v[2] == 1'b0, "LSR read in the head cycle shows PE = 0");
                end
            join
            @(negedge aclk);                    // the serial branch ends between edges
            rd(R_LSR, v[7:0]);
            check(v[2] == 1'b1, "PE survived the colliding LSR read");
            rd(R_DATA, v[7:0]);
            rd(R_LSR, v[7:0]);
            set_format(8, 0, 0);
            set_divisor(4);
            // (6) divisor reloaded while a character is being sent
            wr(R_DATA, 8'h33);
            wait_cycles(30);
            set_divisor(4);
            wait_tx_idle;
            set_divisor(1);
            wr(R_IIR, 8'h00);
            rd(R_LSR, v[7:0]);
            u_bfm.random_delays;
        end
    endtask

    // ------------------------------------------------------------ random test
    reg rnd_running;
    initial rnd_running = 1'b0;

    // background serial traffic: random formats, errors, glitches and breaks
    always begin
        @(posedge aclk);
        if (rnd_running) begin
            ks = urand(99);
            if (ks < 70)
                u_ser.send($random(seed), 5 + urand(3), urand(4), 2 + urand(2), 160 * cur_div, urand(7) & 3);
            else if (ks < 76)
                u_ser.send($random(seed), 5 + urand(3), urand(4), 2, 160 * cur_div, 8);
            else if (ks < 82)
                u_ser.glitch(10 + 5 * urand(14));
            else if (ks < 86)
                u_ser.send_break(12 + urand(10), 160 * cur_div);
            else
                u_ser.idle(5 * urand(100));
        end
    end

    // background modem pin changes, away from both clock edges
    always begin
        @(negedge aclk);
        if (rnd_running && urand(299) == 0) begin
            #2;
            case (urand(3))
                0: cts_n = ~cts_n;
                1: dsr_n = ~dsr_n;
                2: ri_n  = ~ri_n;
                default: dcd_n = ~dcd_n;
            endcase
        end
    end

    task rnd_write;
        integer c, a, b;
        reg [7:0] x;
        begin
            c = urand(99);
            a = urand(3);
            b = urand(63);
            if      (c < 40) wr(R_DATA, $random(seed));
            else if (c < 50) wr(R_IER, $random(seed));
            else if (c < 58) begin
                x = {a[1:0], 3'b000, (urand(1) == 1) ? 3'b111 : {b[1:0], 1'b1}};
                wr(R_IIR, x);
            end
            else if (c < 62) wr(R_IIR, urand(1));
            else if (c < 68) begin
                x = {1'b0, urand(9) == 0, b[5:0]};
                wr(R_LCR, x);
            end
            else if (c < 74) begin
                x = {3'b000, urand(3) == 0, b[3:0]};
                wr(R_MCR, x);
            end
            else if (c < 78) wr(R_SCR, $random(seed));
            else if (c < 80) begin
                wr(R_LCR, 8'h80 | urand(127));
                wr(R_DATA, 1 + urand(1));
                wr(R_IER, 8'h00);
                wr(R_LCR, urand(63));
                cur_div = u_dut.u_regs.dll_q;
            end
            else if (c < 90) u_bfm.write(R_DATA + 4 * urand(7), $random(seed), $random(seed), resp);
            else             u_bfm.write(urand(4095), $random(seed), 4'hF, resp);
        end
    endtask

    task rnd_read;
        integer c;
        begin
            c = urand(99);
            if      (c < 35) rd(R_DATA, v[7:0]);
            else if (c < 55) rd(R_LSR, v[7:0]);
            else if (c < 75) rd(R_IIR, v[7:0]);
            else if (c < 85) rd(R_MSR, v[7:0]);
            else if (c < 95) rd(R_DATA + 4 * urand(7), v[7:0]);
            else             u_bfm.read(urand(4095), v, resp);
        end
    endtask

    task test_random;
        input integer count;
        integer it, c;
        begin
            $display("[%0t] TEST test_random", $time);
            wr(R_LCR, 8'h03);
            rnd_running = 1'b1;
            for (it = 0; it < count; it = it + 1) begin
                c = urand(99);
                if (c < 45)      rnd_write;
                else if (c < 85) rnd_read;
                else if (c < 95) fork rnd_write; rnd_read; join
                else             wait_cycles(urand(300));
            end
            rnd_running = 1'b0;
            wait_cycles(4000);
        end
    endtask

    // ---------------------------------------------------------- scenarios
    task run_scenario;
        begin
            $sformat(vcdname, "sim/uart_%0s.vcd", scenario);
            $dumpfile(vcdname);
            $dumpvars(0, tb_axil_uart16550);
            u_bfm.no_delays;
            init_uart;
            if (scenario == "tx_start") begin
                set_divisor(2);
                set_format(8, 0, 0);
                @(posedge aclk); $display("WAVE_START %0d", $time); @(negedge aclk);
                wr(R_DATA, 8'hA5);
                wait_tx_idle;
            end else if (scenario == "tx_frame") begin
                set_format(8, 2, 0);
                @(posedge aclk); $display("WAVE_START %0d", $time); @(negedge aclk);
                wr(R_DATA, 8'hA5);
                wait_tx_idle;
            end else if (scenario == "rx_frame") begin
                set_format(8, 0, 0);
                @(posedge aclk); $display("WAVE_START %0d", $time); @(negedge aclk);
                ser_send(8'h35, 8, 0, 0, 0);
                wait_cycles(20);
            end else if (scenario == "rx_glitch") begin
                set_format(8, 0, 0);
                @(posedge aclk); $display("WAVE_START %0d", $time); @(negedge aclk);
                u_ser.glitch(60);
                wait_cycles(30);
            end else if (scenario == "fifo_overrun") begin
                wr(R_IIR, 8'h07);
                for (i = 0; i < 16; i = i + 1) ser_send(8'h40 + i, 8, 0, 0, 0);
                @(posedge aclk); $display("WAVE_START %0d", $time); @(negedge aclk);
                ser_send(8'h7F, 8, 0, 0, 0);
                wait_cycles(10);
            end else if (scenario == "cti") begin
                wr(R_IIR, 8'hC7);
                wr(R_IER, 8'h01);
                ser_send(8'h99, 8, 0, 0, 0);
                @(posedge aclk); $display("WAVE_START %0d", $time); @(negedge aclk);
                wait_cycles(700);
                rd(R_DATA, v[7:0]);
                wait_cycles(10);
            end
        end
    endtask

    // ------------------------------------------------------------ report
    task report_and_finish;
        integer holes, f;
        begin
            wait_cycles(10);
            holes = 0;
            $display("");
            u_chk.report;
            $display("SERIAL: %0d frames driven, %0d frames decoded, %0d width errors",
                     u_ser.drv_frames, u_ser.mon_frames, u_ser.mon_width_errors);
            $display("SCOREBOARD: %0d writes, %0d reads, %0d errors, %0d mismatches in %0d compared cycles",
                     u_bfm.n_writes, u_bfm.n_reads, errors, mismatches, n_compared);
            $display("COVER AW first / W first / same cycle : %0d / %0d / %0d",
                     u_bfm.n_aw_first, u_bfm.n_w_first, u_bfm.n_aw_w_same);
            $display("COVER IIR 01 / 06 / 04 / 0C / 02 / 00 : %0d / %0d / %0d / %0d / %0d / %0d",
                     cov_iir[1], cov_iir[6], cov_iir[4], cov_iir[12], cov_iir[2], cov_iir[0]);
            $display("COVER break / framing / resync / parity: %0d / %0d / %0d / %0d",
                     cov_rx_break, cov_rx_fe, cov_resync, cov_rx_pe);
            $display("COVER glitch rejected                  : %0d", cov_glitch);
            $display("COVER overrun FIFO / 16450             : %0d / %0d", cov_overrun_fifo, cov_overrun_16450);
            $display("COVER RX FIFO full cycles              : %0d", cov_fifo_full);
            $display("COVER read frees full buffer same cycle: %0d", cov_pop_with_push_full);
            $display("COVER LSR read collides with new error : %0d", cov_lsr_collision);
            $display("COVER THRI set collides with clear     : %0d", cov_thri_collision);
            $display("COVER timeout set / kept on new char   : %0d / %0d", cov_cti_set, cov_cti_kept);
            $display("COVER THR replace / TX FIFO drop       : %0d / %0d", cov_tx_replace, cov_tx_drop);
            $display("COVER MSR read collides with change    : %0d", cov_msr_collision);
            $display("COVER back-to-back transmit            : %0d", cov_back_to_back);
            $display("COVER divisor reload while sending     : %0d", cov_div_load_running);
            $display("COVER LSR7 sticky with no errors left  : %0d", cov_lsr7_sticky);
            $display("COVER loopback characters              : %0d", cov_loop_rx);
            $display("COVER trigger 1 / 4 / 8 / 14 reached   : %0d / %0d / %0d / %0d",
                     cov_trig[0], cov_trig[1], cov_trig[2], cov_trig[3]);
            n = 0;
            for (f = 0; f < 64; f = f + 1) if (cov_fmt[f] != 0) n = n + 1;
            $display("COVER received formats seen            : %0d of 40", n);

            if (u_bfm.n_aw_first == 0 || u_bfm.n_w_first == 0 || u_bfm.n_aw_w_same == 0 ||
                cov_iir[1] == 0 || cov_iir[6] == 0 || cov_iir[4] == 0 || cov_iir[12] == 0 ||
                cov_iir[2] == 0 || cov_iir[0] == 0 || cov_rx_break == 0 || cov_rx_fe == 0 ||
                cov_resync == 0 || cov_rx_pe == 0 || cov_glitch == 0 || cov_overrun_fifo == 0 ||
                cov_overrun_16450 == 0 || cov_fifo_full == 0 || cov_pop_with_push_full == 0 ||
                cov_lsr_collision == 0 || cov_thri_collision == 0 || cov_cti_set == 0 ||
                cov_cti_kept == 0 || cov_tx_replace == 0 || cov_tx_drop == 0 ||
                cov_msr_collision == 0 || cov_back_to_back == 0 || cov_div_load_running == 0 ||
                cov_lsr7_sticky == 0 || cov_loop_rx == 0 || cov_trig[0] == 0 || cov_trig[1] == 0 ||
                cov_trig[2] == 0 || cov_trig[3] == 0 || n < 40)
                holes = 1;

            if (errors == 0 && mismatches == 0 && u_chk.errors == 0 && u_bfm.usage_errors == 0 &&
                u_ser.mon_width_errors == 0 && holes == 0)
                $display("RESULT: PASS");
            else
                $display("RESULT: FAIL%0s", holes ? " (coverage hole)" : "");
            $display("");
            $finish;
        end
    endtask

    // ------------------------------------------------------------ main
    initial begin
        if (!$value$plusargs("seed=%d", seed))       seed  = 1;
        if (!$value$plusargs("nrand=%d", nrand))     nrand = 4000;
        if (!$value$plusargs("scenario=%s", scenario)) scenario = "";
        u_bfm.seed = seed + 17;
        use_model  = $test$plusargs("no_model") ? 0 : 1;
        errors = 0; mismatches = 0; n_compared = 0; cur_div = 1;

        repeat (4) @(posedge aclk);
        @(negedge aclk) aresetn = 1'b1;
        @(negedge aclk);

        if (scenario != "") begin
            run_scenario;
            $finish;
        end

        test_reset;
        u_bfm.random_delays;
        test_driver_probe;
        init_uart;
        test_dlab;
        test_tx_formats;
        test_rx_formats;
        test_rx_errors;
        test_glitch;
        test_baud_tolerance;
        test_16450_mode;
        test_fifo_mode;
        test_timeout;
        test_lsr_flags;
        test_priority;
        test_thri;
        test_modem;
        test_loopback_data;
        test_break_tx;
        test_fcr;
        test_bus_rules;
        test_divisor;
        test_collisions;
        init_uart;
        test_random(nrand);
        report_and_finish;
    end

    initial begin
        #400_000_000;
        $display("TIMEOUT at cycle %0d", cyc);
        $display("RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
