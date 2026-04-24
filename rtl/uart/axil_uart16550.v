`timescale 1ns / 1ps

// pc16550d uart on axi4-lite. structure only
// scope docs/uart16550_scope.md, decisions docs/uart16550_decisions.md

module axil_uart16550 #(
    parameter integer ADDR_W = 12
) (
    input  wire              aclk,
    input  wire              aresetn,

    input  wire              s_axil_awvalid,
    output wire              s_axil_awready,
    input  wire [ADDR_W-1:0] s_axil_awaddr,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [2:0]        s_axil_awprot,   // not used: no privilege checks
    /* verilator lint_on UNUSEDSIGNAL */

    input  wire              s_axil_wvalid,
    output wire              s_axil_wready,
    input  wire [31:0]       s_axil_wdata,
    input  wire [3:0]        s_axil_wstrb,

    output wire              s_axil_bvalid,
    input  wire              s_axil_bready,
    output wire [1:0]        s_axil_bresp,

    input  wire              s_axil_arvalid,
    output wire              s_axil_arready,
    input  wire [ADDR_W-1:0] s_axil_araddr,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [2:0]        s_axil_arprot,   // not used: no privilege checks
    /* verilator lint_on UNUSEDSIGNAL */

    output wire              s_axil_rvalid,
    input  wire              s_axil_rready,
    output wire [31:0]       s_axil_rdata,
    output wire [1:0]        s_axil_rresp,

    input  wire              sin,
    output wire              sout,
    input  wire              cts_n,
    input  wire              dsr_n,
    input  wire              ri_n,
    input  wire              dcd_n,
    output wire              dtr_n,
    output wire              rts_n,
    output wire              out1_n,
    output wire              out2_n,

    output wire              irq
);

    // register bus
    wire              reg_wr;
    wire [ADDR_W-1:0] reg_waddr;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0]       reg_wdata;      // registers are 8 bits, bits 31:8 ignored
    wire [3:0]        reg_wstrb;      // only byte 0 exists
    /* verilator lint_on UNUSEDSIGNAL */
    wire              reg_werr;
    wire              reg_rd;
    wire [ADDR_W-1:0] reg_raddr;
    wire [7:0]        reg_rdata8;
    wire              reg_rerr;

    // FIFOs
    wire              rxf_push, rxf_pop, rxf_clear;
    wire [10:0]       rxf_din, rxf_dout;
    wire [4:0]        rxf_count;
    wire              txf_push, txf_pop, txf_clear;
    wire [7:0]        txf_din, txf_dout;
    wire [4:0]        txf_count;

    // core
    wire              tick;
    wire [15:0]       divisor, div_value;
    wire              div_load;
    wire [6:0]        lcr;            // LCR 6:0 (format and break)
    wire [4:0]        mcr;
    wire [3:0]        msr_now;
    wire              tx_pop, tx_busy, tx_ser;
    wire              rxd;
    wire              rx_valid, rx_pe, rx_fe, rx_bi;
    wire [7:0]        rx_data;

    axil_reg_bus #(.ADDR_W(ADDR_W)) u_bus (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .s_axil_awvalid (s_axil_awvalid),
        .s_axil_awready (s_axil_awready),
        .s_axil_awaddr  (s_axil_awaddr),
        .s_axil_wvalid  (s_axil_wvalid),
        .s_axil_wready  (s_axil_wready),
        .s_axil_wdata   (s_axil_wdata),
        .s_axil_wstrb   (s_axil_wstrb),
        .s_axil_bvalid  (s_axil_bvalid),
        .s_axil_bready  (s_axil_bready),
        .s_axil_bresp   (s_axil_bresp),
        .s_axil_arvalid (s_axil_arvalid),
        .s_axil_arready (s_axil_arready),
        .s_axil_araddr  (s_axil_araddr),
        .s_axil_rvalid  (s_axil_rvalid),
        .s_axil_rready  (s_axil_rready),
        .s_axil_rdata   (s_axil_rdata),
        .s_axil_rresp   (s_axil_rresp),
        .reg_wr         (reg_wr),
        .reg_waddr      (reg_waddr),
        .reg_wdata      (reg_wdata),
        .reg_wstrb      (reg_wstrb),
        .reg_werr       (reg_werr),
        .reg_rd         (reg_rd),
        .reg_raddr      (reg_raddr),
        .reg_rdata      ({24'd0, reg_rdata8}),
        .reg_rerr       (reg_rerr)
    );

    uart_regs #(.ADDR_W(ADDR_W)) u_regs (
        .clk        (aclk),
        .rstn       (aresetn),
        .reg_wr     (reg_wr),
        .reg_waddr  (reg_waddr),
        .reg_wdata  (reg_wdata[7:0]),
        .reg_wstrb0 (reg_wstrb[0]),
        .reg_werr   (reg_werr),
        .reg_rd     (reg_rd),
        .reg_raddr  (reg_raddr),
        .reg_rdata  (reg_rdata8),
        .reg_rerr   (reg_rerr),
        .rx_valid   (rx_valid),
        .rx_data    (rx_data),
        .rx_pe      (rx_pe),
        .rx_fe      (rx_fe),
        .rx_bi      (rx_bi),
        .rxf_push   (rxf_push),
        .rxf_din    (rxf_din),
        .rxf_pop    (rxf_pop),
        .rxf_clear  (rxf_clear),
        .rxf_dout   (rxf_dout),
        .rxf_count  (rxf_count),
        .txf_push   (txf_push),
        .txf_din    (txf_din),
        .txf_pop    (txf_pop),
        .txf_clear  (txf_clear),
        .txf_count  (txf_count),
        .tx_pop     (tx_pop),
        .tx_busy    (tx_busy),
        .tick       (tick),
        .divisor    (divisor),
        .div_load   (div_load),
        .div_value  (div_value),
        .lcr        (lcr),
        .mcr        (mcr),
        .msr_now    (msr_now),
        .irq        (irq)
    );

    sync_fifo #(.WIDTH(11), .ADDR_W(4)) u_rx_fifo (
        .clk   (aclk),
        .rstn  (aresetn),
        .clear (rxf_clear),
        .push  (rxf_push),
        .din   (rxf_din),
        .pop   (rxf_pop),
        .dout  (rxf_dout),
        .count (rxf_count)
    );

    sync_fifo #(.WIDTH(8), .ADDR_W(4)) u_tx_fifo (
        .clk   (aclk),
        .rstn  (aresetn),
        .clear (txf_clear),
        .push  (txf_push),
        .din   (txf_din),
        .pop   (txf_pop),
        .dout  (txf_dout),
        .count (txf_count)
    );

    uart_baud u_baud (
        .clk        (aclk),
        .rstn       (aresetn),
        .divisor    (divisor),
        .load       (div_load),
        .load_value (div_value),
        .tick       (tick)
    );

    uart_tx u_tx (
        .clk        (aclk),
        .rstn       (aresetn),
        .tick       (tick),
        .wls        (lcr[1:0]),
        .stb        (lcr[2]),
        .pen        (lcr[3]),
        .eps        (lcr[4]),
        .stick      (lcr[5]),
        .fifo_count (txf_count),
        .fifo_data  (txf_dout),
        .pop        (tx_pop),
        .txd        (tx_ser),
        .busy       (tx_busy)
    );

    uart_rx u_rx (
        .clk   (aclk),
        .rstn  (aresetn),
        .tick  (tick),
        .rxd   (rxd),
        .wls   (lcr[1:0]),
        .pen   (lcr[3]),
        .eps   (lcr[4]),
        .stick (lcr[5]),
        .valid (rx_valid),
        .data  (rx_data),
        .pe    (rx_pe),
        .fe    (rx_fe),
        .bi    (rx_bi)
    );

    uart_io u_io (
        .clk     (aclk),
        .rstn    (aresetn),
        .sin     (sin),
        .cts_n   (cts_n),
        .dsr_n   (dsr_n),
        .ri_n    (ri_n),
        .dcd_n   (dcd_n),
        .tx_ser  (tx_ser),
        .brk     (lcr[6]),
        .mcr     (mcr),
        .sout    (sout),
        .dtr_n   (dtr_n),
        .rts_n   (rts_n),
        .out1_n  (out1_n),
        .out2_n  (out2_n),
        .rxd     (rxd),
        .msr_now (msr_now)
    );

endmodule
