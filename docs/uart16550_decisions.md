# axil_uart16550 decisions log

Every question I hit while reading the PC16550D datasheet (TI SNLS378C) and
`uart16550_scope.md`. Where it came from, what I decided, why. The rtl, the
reference model and the tests all do exactly what is in these tables.

This one is longer than the timer's because the datasheet is thirty years old and
it does not agree with itself everywhere. The first table below is the
contradictions.

## Principles

**Compatibility first.** When the datasheet is clear, follow it. Even where a
modern design would do it differently. This part is not mine to improve. When the
datasheet is silent, choose what existing 16550 software relies on.

**Events are never lost.** A flag set by hardware in the same cycle software
clears it stays set.

**Conditions are not events.** Some of the datasheet behaviour is a condition that
has to hold, not a thing that happens. The character timeout is "no read and no
new character for 4 character times". If something in that same cycle makes the
condition false, nothing fires. This is the opposite rule to the one above and
the difference matters, so each row says which one it is using.

**Software's newest intent wins** for configuration and stored data.

## Errors and contradictions in the datasheet

| Question | Where | Decision | Reason |
|---|---|---|---|
| Table 2 puts MODEM Control at A2 A1 A0 = 000 | Table 2 | MCR is at address 4 | Table 1 puts MCR at 4; the row order in Table 2 puts it between 3 and 5; 000 is already RBR/THR |
| Divisor range 1 or 2 to 65535? | Section 5 and 7.5 say 1, section 8.5.1 says 2 | 1 to 65535 supported | Two statements say 1, and divisor 1 is well defined with a clock enable |
| What does divisor 0 do? | 8.5.1 "not recommended" | The baud generator stops: no ticks, the transmitter, receiver and timeout freeze | Safe, and it is the reset state |
| Does reset clear DLL, DLM and SCR? | MR pin says it does not clear DLL/DLM; Table 3 omits SCR | `aresetn` clears every register, DLL, DLM and SCR included | No unknown values in simulation or silicon; 8.5.1 says software must load the divisor anyway |
| TERI: "low to high" or "high to low"? | RI pin note vs MSR bit 2 text | Set when the RI pin goes low to high, which is MSR bit 6 going 1 to 0 | Both texts describe the same edge; MSR bit 6 is the complement of the pin |

## Bus mapping and access

| Question | Where | Decision | Reason |
|---|---|---|---|
| Where does each register live on AXI? | Scope 6 | Offset = datasheet address x 4, value in bits 7:0 | Common practice for 8-bit peripherals on a 32-bit bus |
| Which strobes matter? | IHI 0022E B1.1.3 | Only WSTRB[0]. WSTRB[0] = 0 means no effect, response OKAY | The register is one byte wide |
| Offsets above 0x1C or not a multiple of 4? | Scope 6 | SLVERR, no effect, read data 0 | No register there |
| Writes to LSR and MSR? | 8.6.3 note, 8.6.8 | Accepted with OKAY and ignored | The original chip does not fault on them, and a bus error would crash software written for it. Compare the timer, where a read-only write gave SLVERR because no compatibility target existed |
| When do read side effects happen? | Scope, IHI 0022E | In the cycle of the AR handshake, exactly once, only when the read succeeds | Matches `reg_rd` in the shared bus bridge |
| Read and write of related state in one cycle | Not stated | The read sees the values from before the write | A write takes effect at the end of its cycle |
| Reserved bits | Table 1 | IER 7:4, MCR 7:5 and IIR 5:4 read 0 and are not stored | Table 1 marks them 0; PC drivers test IER 7:4 |

## Receive path

| Question | Where | Decision | Reason |
|---|---|---|---|
| RBR read with no data | Not stated | Returns 0x00, nothing popped | Drivers read RBR during initialisation to discard data |
| Data bits above the word length | Not stated | Read as 0 | Only received bits are stored |
| 16450 mode overrun | 8.6.3 bit 1 | New character replaces the one in RBR, OE set | "thereby destroying the previous character" |
| FIFO mode overrun | 8.6.3 bit 1 | FIFO keeps its 16 characters, new character discarded, OE set | "overwritten, but it is not transferred to the FIFO" |
| Character arrives in the same cycle the CPU reads RBR | Not stated | The read happens first, so a full buffer has room and there is no overrun | The old character was delivered before the new one needed its place |
| FIFO reset in the same cycle a character arrives | Not stated | Old contents cleared, the new character kept | Events are never lost |
| When do PE, FE and BI appear in LSR? | 8.6.3 bits 2 to 4 | When the character carrying the error becomes the top of the RX FIFO (in 16450 mode, when it arrives), visible one cycle later | "revealed to the CPU when its associated character is at the top of the FIFO" |
| LSR read in the same cycle an error flag is set | Not stated | Flag survives | Events are never lost |
| When is OE visible? | 8.6.3 bit 1 "as soon as it happens" | One cycle after the overrun | Earliest registered point |
| LSR7 | 8.6.3 bit 7 | FIFO mode only. 1 while any character with PE, FE or BI is in the FIFO, and stays 1 after they leave until the next LSR read | "cleared when the CPU reads the LSR, if there are no subsequent errors in the FIFO" |
| LSR7 across a mode change | Not stated | The sticky part is cleared when FCR0 changes, and only accumulates in FIFO mode | Avoids reporting 16450-mode errors after entering FIFO mode |
| Start bit detection | Figure 6 shows 8 RCLKs to the sample | On a tick, a low SIN while idle begins a start bit. It is checked again 8 ticks later. If SIN is high then, it was a glitch and is ignored | Mid-bit validation rejects short glitches |
| Where are bits sampled? | Figure 6 | Every 16 ticks after the start check, which is the centre of each bit | Maximum tolerance to baud rate mismatch |
| Stop bits checked | 8.6.2 bit 2 | Only the first | "The Receiver checks the first Stop-bit only" |
| LCR changed during a received character | Not stated | Word length and parity are captured when the start bit is detected; a change affects the next character | A character is decoded with one format |
| Break detection point | 8.6.3 bit 4 "longer than a full word" | If start, data, parity (if enabled) and the first stop bit all sample 0, it is a break, decided at the stop-bit sample | The receiver must decide at that sample; this is half a bit before the word time ends |
| What is loaded for a break? | 8.6.3 bit 4 | One 0x00 character with BI = 1 and FE = 1, PE as computed. The receiver then waits for SIN to be sampled high before looking for a start bit | "only one zero character is loaded"; the stop bit was 0, so FE applies literally |
| Framing error recovery | 8.6.3 bit 3 "samples this start bit twice" | The stop-bit sample is treated as the centre of the next start bit; the next data bit is sampled 16 ticks later | The datasheet wording is not precise enough to reproduce; this keeps every sample at a bit centre, which is the purpose of resynchronising |
| Parity checking | 8.6.2 bits 3 to 5 | Checked only when PEN = 1, including stick parity | Direct from the datasheet |
| Synchronisation of SIN | Not stated (asynchronous input) | Two synchronizer flip flops, then one register for the loopback multiplexer | Metastability protection |

## Transmit path

| Question | Where | Decision | Reason |
|---|---|---|---|
| When does a character start? | Figure 7 | Only on a tick; every bit then lasts exactly 16 ticks | Equal bit widths |
| Stop bit length | 8.6.2 bit 2 | 16 ticks; 24 for 5-bit words with STB = 1; 32 otherwise with STB = 1 | One, one and a half, two stop bits |
| Back-to-back characters | Not stated | If another character is waiting at the last stop tick, its start bit follows at once | No idle gap between characters |
| LCR changed during a transmitted character | Not stated | Format captured when the character is taken; a change affects the next character | A character is sent with one format |
| THR write in 16450 mode while THR is full | Not stated | The new character replaces the waiting one | In the 16450 the THR is a register |
| THR write in FIFO mode with 16 characters waiting | Not stated | The new character is discarded; no flag exists to report it | There is no transmit overrun bit in the 16550 |
| THR write in the same cycle the transmitter takes a character | Not stated | Both happen; the write is never dropped for lack of space | A slot frees at the same edge |
| THRE and TEMT | 8.6.3 bits 5, 6 | THRE = TX FIFO empty. TEMT = TX FIFO empty and shift register idle | Direct from the datasheet, FIFO mode wording used for both modes |
| Break and loopback | 8.6.2 bit 6, 8.6.7 bit 4 | Break forces the serial output low, and also the internal loopback path. The transmitter keeps running | Lets loopback tests exercise break detection; "no effect on the transmitter logic" |
| Output pins | Not stated | `sout` and the modem control outputs come from flip flops | Glitch-free pins |

## Interrupts

| Question | Where | Decision | Reason |
|---|---|---|---|
| When is the THRE interrupt set? | Table 5, 8.4.1 | When THRE rises; when IER bit 1 is written from 0 to 1 while THRE = 1; when FCR0 changes | Drivers expect the interrupt when they enable it on an idle transmitter; 8.4.1 says the first interrupt after changing FCR0 is immediate |
| When is it cleared? | Table 5 | By a THR write, or by an IIR read that reports THRI | "Reading the IIR (if source of interrupt)" |
| Set and clear together | Not stated | Set wins | Events are never lost |
| Priority | Table 5 | Line status, then received data, then character timeout, then THRE, then modem status | Table 5; received data is listed before timeout at the same level |
| Received data available | 8.4.1, Table 5 | 16450 mode: DR = 1. FIFO mode: count at or above the trigger level (1, 4, 8, 14) | Direct |
| IIR bits 7:6 | 8.6.5 | Equal to FCR0 | "set when FCR0 = 1" |
| Interrupt output | INTR pin | `irq` is high while any enabled interrupt is pending; OUT2 does not gate it | The datasheet's INTR has no OUT2 gating; PC boards gate it externally using `out2_n` |
| Interrupt output timing | Not a compatibility target (scope 2) | `irq` is a flip flop: it follows the IIR pending state one cycle later | Clean output pin; one cycle is shorter than any bus transaction |
| IIR freeze during a read | 8.6.5 | Inherent: the value is captured in one cycle | One-cycle AXI read |

## Character timeout

| Question | Where | Decision | Reason |
|---|---|---|---|
| What is a character time? | 8.4.1 item 2 | 16 x (1 + word length + PEN) ticks, plus 16, 24 or 32 ticks of stop bits | Counted with the 16x clock as the datasheet says; both stop bits included |
| When does the timer run? | 8.4.1 | FIFO mode, RX FIFO not empty, no timeout pending | Conditions of item 1 |
| What restarts the timer? | 8.4.1 items 3, 4 | An RBR read, a received character (while no timeout is pending), a FIFO reset, an empty FIFO, leaving FIFO mode | Direct |
| What clears a pending timeout? | 8.4.1 item 3 | An RBR read, a FIFO reset or a mode change. A new character does not | "cleared ... When the CPU reads one character" |
| Expiry in the same cycle as an RBR read or a new character | Not stated | No timeout | Conditions are not events: the read or the new character makes the condition false |

## FIFO control

| Question | Where | Decision | Reason |
|---|---|---|---|
| FCR0 changes | 8.6.4 bit 0 | Both FIFOs cleared, THRE interrupt set, timeout cleared, LSR7 sticky cleared | Direct, plus 8.4.1 |
| FCR written with bit 0 = 0 | 8.6.4 bit 0 | Bits 1, 2, 6, 7 ignored | "must be a 1 when other FCR bits are written to" |
| FCR3 | 8.6.4 bit 3 | Ignored | DMA out of scope |

## Modem control and status

| Question | Where | Decision | Reason |
|---|---|---|---|
| MSR bits 7:4 | 8.6.8 | Normal: complement of the synchronized DCD, RI, DSR, CTS pins. Loopback: DCD = OUT2, RI = OUT1, DSR = DTR, CTS = RTS | Direct |
| Delta bits | 8.6.8 | Set when the bit changes (TERI: MSR bit 6 goes 1 to 0), cleared by an MSR read, set wins | Direct, plus events are never lost |
| Delta after reset | Not stated | If a modem input is already active at reset, a delta is reported once it passes the synchronizer | The previous value resets to inactive; drivers read MSR during initialisation |
| Loopback pins | 8.6.7 bit 4 | `sout` = 1, modem control outputs inactive (1), SIN ignored, transmitter output drives the receiver | Direct |

## Baud generator

| Question | Where | Decision | Reason |
|---|---|---|---|
| Effect of writing DLL or DLM | 8.5.1 | The counter is reloaded at once from the new divisor; the first tick comes divisor cycles later | "a 16-bit Baud counter is immediately loaded" |
