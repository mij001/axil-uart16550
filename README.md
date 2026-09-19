# axil-uart16550

A PC16550D compatible UART with an AXI4-Lite slave port, in SystemVerilog.

The 16550 is a part from 1995 and the point here is software compatibility. A
driver written for the real chip has to work against this with no change, so the
datasheet decides and I do not get a vote. What gets replaced is everything around
the programming model: the parallel bus, the crystal and the receiver clock pin
become one AXI4-Lite port and one system clock.

The numbers in here all came off a real run, nothing made up.

## It needs the timer repo

The bus front end, the protocol checker and the assertions are not in here. They
belong to [axil-timer](https://github.com/mij001/axil-timer), which is where they
were written, and this repo carries that one as a submodule.

```
git clone https://github.com/mij001/axil-uart16550
cd axil-uart16550
git submodule update --init
```

Copying those three files in would have been one command and it would have been
wrong. Two copies drift and nothing would ever tell me. This way a fix reaches
here when the submodule pointer is bumped, which is a commit in this repo.

It costs something. A fresh clone does not build until the submodule is checked
out, so every target depends on a `check-dep` rule that says so in plain words.

`axil_reg_bus.sv` was reused unchanged except for one addition: the UART needs
read side effects, since reading RBR pops the FIFO, so `reg_rd` was added.

## The datasheet

TI PC16550D, doc SNLS378C. Get it from TI, I am not going to redistribute it:
<https://www.ti.com/lit/ds/symlink/pc16550d.pdf>

Every section number in the decisions log points into that one.

It contradicts itself in four places, and all four had to be settled before any
rtl could be written.

| What | The problem | What I did |
|---|---|---|
| MCR address | Table 2 puts MODEM Control at A2A1A0 = 000, which is already RBR/THR | Put MCR at 4, which is what Table 1 says |
| Divisor range | Sections 5 and 7.5 say 1 to 65535, section 8.5.1 says 2 | Supported 1 to 65535, two statements say 1 |
| TERI edge | The RI pin note and the MSR bit 2 text look like they disagree | Same edge. Set when RI goes low to high |
| Framing error recovery | 8.6.3 says the receiver "samples this start bit twice", not precise enough to reproduce | Treat the stop bit sample as the centre of the next start bit |

The last one is the honest one. The wording does not pin the behaviour down, so I
picked a reading and `docs/uart16550_decisions.md` says that I picked it.
`docs/uart16550_scope.md` says what is deliberately left out and why.

## The blocks

`axil_uart16550` is structure only. Under it the register file, two FIFOs, the
baud generator, a transmitter, a receiver, and the pin logic. The bus front end
and the checker come from the submodule.

| Module | Lines | What |
|---|---|---|
| `rtl/uart/uart_regs.sv` | 431 | The programming model, twelve registers, DLAB, interrupts |
| `rtl/uart/uart_rx.sv` | 258 | Start detect, mid bit glitch check, sampling, break, framing recovery |
| `rtl/uart/uart_tx.sv` | 204 | Frame assembly, 1 / 1.5 / 2 stop bits, stick parity, back to back |
| `rtl/uart/uart_io.sv` | 124 | Synchronizers, loopback, break, output flip flops |
| `rtl/uart/uart_baud.sv` | 77 | 16x tick, divisor 1 to 65535, divisor 0 stops it |
| `rtl/sync_fifo.sv` | 130 | 16 entries. The RX one is 11 bits so BI, FE and PE ride with the byte |

No divided clock anywhere. The baud generator makes a one cycle enable and every
flip flop runs on `aclk`.

The receiver samples a start bit again 8 ticks in and throws it away if the line
has gone back high. That is what rejects glitches, and `make waves` will dump
that scenario to `sim/uart_rx_glitch.vcd` if you want to watch it happen.

## How it is checked

20 named tests then a random phase, with a reference model beside the design and
every register compared every cycle.

```
CHECKER uart: AW 2694, W 2694, B 2694, AR 2362, R 2362 handshakes, 0 rule violations
SCOREBOARD: 2694 writes, 2362 reads, 0 errors, 0 mismatches in 113442 compared cycles
COVER received formats seen             : 40 of 40
RESULT: PASS
```

40 of 40 is every combination of word length 5 to 8, parity none / odd / even /
stick, and 1 / 1.5 / 2 stop bits the receiver can be asked to decode.

`make nomodel` reruns the same tests with the model off, so only the protocol
checker and the independent assertions are left. That separates "the model
noticed" from "the tests noticed". `make sva` binds the assertions from the
submodule onto the bus front end.

## Running it

Needs icarus verilog and verilator.

```
git submodule update --init

make lint       verilator -Wall on the rtl
make run        directed bench with the reference model
make nomodel    the same, model off
make regress    ten seeds, four at a time
make sva        assertions from the submodule, bound
make waves      scenarios to sim/uart_*.vcd, for gtkwave
```

## Not there yet

Nothing here has touched real silicon. No synthesis run, so no area number and
no timing closed, and it has never sat on an fpga.

No uvm bench here. The timer has one with constrained random stimulus and a
covergroup. This repo has the directed bench and the reference model instead, and
since the register map is far bigger a constrained random layer would pay more
here than it did there.

DMA mode, the parallel bus pins and the transmitter FIFO empty indication delay
are out of scope. Cycle level timing inside the original silicon is not a target
either, only register visible behaviour, so this would not pass as a drop in
replacement on a scope.
