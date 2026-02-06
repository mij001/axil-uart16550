# axil_uart16550 scope

What i am promising to match and what i am not. Rev 0.2.

## What it is

`axil_uart16550` is a software compatible PC16550D UART for a synchronous SoC.

The datasheet is TI SNLS378C, <https://www.ti.com/lit/ds/symlink/pc16550d.pdf>.
Every section number below points into that.

The programming model stays exactly as the 16550 has it, so a driver written for
the real chip works with no change. What gets replaced is everything around it:
the parallel bus, the crystal oscillator and the receiver clock pin become an
AXI4-Lite slave port and one system clock.

So the question this document answers is which parts of a thirty year old
datasheet I am promising to match, and which parts I am not.

## What has to match

Software written for the PC16550D register interface must work without change.
That covers the register map, the reset values, every read and write side effect,
interrupt identification and priority, FIFO behaviour, line status reporting,
modem control and status, and loopback. The serial frame on `sout` and the frames
accepted on `sin` must match the datasheet's frame format.

Cycle-level timing inside the chip (the tSINT, tRINT and similar delays in section
7.5) is **not** a compatibility target. Register-visible behaviour is.

## In

- Registers RBR, THR, IER, IIR, FCR, LCR, MCR, LSR, MSR, SCR, DLL, DLM (8.6).
- 16450 mode (FCR0 = 0) and FIFO mode (FCR0 = 1) with 16-byte FIFOs (8.4, 8.6.4).
- All five interrupt sources and their priority (Table 5, 8.6.5, 8.6.6).
- Word length 5 to 8, parity none, odd, even, stick 0, stick 1, stop bits 1, 1.5
  And 2, set break (8.6.2).
- Overrun, parity, framing and break detection, LSR7 (8.6.3).
- Character timeout indication (8.4.1).
- Programmable baud generator, divisor 1 to 65535 (8.5.1).
- Modem control outputs, modem status inputs and delta bits (8.6.7, 8.6.8).
- Local loopback (8.6.7 bit 4).

## Out

| Datasheet feature | Why it is excluded |
|---|---|
| Parallel bus pins and timing (A0-A2, CS0-CS2, ADS, RD, WR, DDIS, D7-D0) | Replaced by AXI4-Lite |
| XIN, XOUT, RCLK, BAUDOUT | Single system clock, the 16x rate is a clock enable |
| RXRDY and TXRDY pins, FCR3 (DMA mode) | No DMA controller in the target system |
| Master reset pin MR | Replaced by `aresetn` |
| Transmitter FIFO empty indication delay (8.4.1, transmitter item 2) | Quirk of the original silicon, not needed by drivers |
| Writing LSR for factory test (8.6.3 note) | Factory test feature |

## Pins

| Signal | Direction | Description |
|---|---|---|
| `aclk`, `aresetn` | In | System clock and active-low reset, shared with the bus |
| AXI4-Lite slave | | 32-bit data, `ADDR_W` address bits, default 12 |
| `sin` | In | Serial input, asynchronous to `aclk` |
| `sout` | Out | Serial output, driven from a flip flop |
| `cts_n`, `dsr_n`, `ri_n`, `dcd_n` | In | Modem status inputs, active low, asynchronous |
| `dtr_n`, `rts_n`, `out1_n`, `out2_n` | Out | Modem control outputs, active low, driven from flip flops |
| `irq` | Out | Active-high level interrupt, high while any enabled interrupt is pending |

## Where the registers sit

Datasheet register address k (Table 2) is placed at AXI offset k x 4. The 8-bit
register value occupies bits 7:0 of RDATA and WDATA. Bits 31:8 read as zero and
are ignored on write. Only WSTRB[0] matters.

| Offset | DLAB = 0, read | DLAB = 0, write | DLAB = 1, read | DLAB = 1, write |
|---|---|---|---|---|
| 0x00 | RBR | THR | DLL | DLL |
| 0x04 | IER | IER | DLM | DLM |
| 0x08 | IIR | FCR | IIR | FCR |
| 0x0C | LCR | LCR | LCR | LCR |
| 0x10 | MCR | MCR | MCR | MCR |
| 0x14 | LSR | LSR | LSR | LSR |
| 0x18 | MSR | MSR | MSR | MSR |
| 0x1C | SCR | SCR | SCR | SCR |

## Clocking

The baud generator produces a one-cycle enable, `tick`, once every divisor clock
cycles. Everything in the block runs on `aclk`. The serial bit rate is therefore
aclk frequency / (16 x divisor).
