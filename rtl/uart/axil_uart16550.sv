`timescale 1ns / 1ps

// pc16550d uart on axi4-lite. structure only
// scope docs/uart16550_scope.md, decisions docs/uart16550_decisions.md

module axil_uart16550 #(
    parameter int ADDR_W = 12
) (
    input  logic              aclk,
    input  logic              aresetn,

    input  logic              s_axil_awvalid,
    output logic              s_axil_awready,
    input  logic [ADDR_W-1:0] s_axil_awaddr,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [2:0]        s_axil_awprot,   // not used: no privilege checks
    /* verilator lint_on UNUSEDSIGNAL */

    input  logic              s_axil_wvalid,
    output logic              s_axil_wready,
    input  logic [31:0]       s_axil_wdata,
    input  logic [3:0]        s_axil_wstrb,

    output logic              s_axil_bvalid,
    input  logic              s_axil_bready,
    output logic [1:0]        s_axil_bresp,

    input  logic              s_axil_arvalid,
    output logic              s_axil_arready,
    input  logic [ADDR_W-1:0] s_axil_araddr,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [2:0]        s_axil_arprot,   // not used: no privilege checks
    /* verilator lint_on UNUSEDSIGNAL */

    output logic              s_axil_rvalid,
    input  logic              s_axil_rready,
    output logic [31:0]       s_axil_rdata,
    output logic [1:0]        s_axil_rresp,

    input  logic              sin,
    output logic              sout,
    input  logic              cts_n,
    input  logic              dsr_n,
    input  logic              ri_n,
    input  logic              dcd_n,
    output logic              dtr_n,
    output logic              rts_n,
    output logic              out1_n,
    output logic              out2_n,

    output logic              irq
);

    // register bus
    logic reg_wr;
    logic [ADDR_W-1:0] reg_waddr;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0]       reg_wdata;      // registers are 8 bits, bits 31:8 ignored
    logic [3:0]        reg_wstrb;      // only byte 0 exists
    /* verilator lint_on UNUSEDSIGNAL */
    logic reg_werr;
    logic reg_rd;
    logic [ADDR_W-1:0] reg_raddr;
    logic [7:0]        reg_rdata8;
    logic reg_rerr;

    // FIFOs
    logic rxf_push, rxf_pop, rxf_clear;
    logic [10:0]       rxf_din, rxf_dout;
    logic [4:0]        rxf_count;
    logic txf_push, txf_pop, txf_clear;
    logic [7:0]        txf_din, txf_dout;
    logic [4:0]        txf_count;

    // core
    logic tick;
    logic [15:0]       divisor, div_value;
    logic div_load;
    logic [6:0]        lcr;            // LCR 6:0 (format and break)
    logic [4:0]        mcr;
    logic [3:0]        msr_now;
    logic tx_pop, tx_busy, tx_ser;
    logic rxd;
    logic rx_valid, rx_pe, rx_fe, rx_bi;
    logic [7:0]        rx_data;

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
