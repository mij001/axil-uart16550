# axil_uart16550 decisions log

every question I hit while reading the PC16550D datasheet (TI SNLS378C) and
`uart16550_scope.md`. where it came from, what I decided, why. the rtl, the
reference model and the tests all do exactly what is in these tables.

this one is longer than the timer's because the datasheet is thirty years old and
it does not agree with itself everywhere. the first table below is the
contradictions.

## principles

**compatibility first.** when the datasheet is clear, follow it. even where a
modern design would do it differently. this part is not mine to improve. when the
datasheet is silent, choose what existing 16550 software relies on.

**events are never lost.** a flag set by hardware in the same cycle software
clears it stays set.

**conditions are not events.** some of the datasheet behaviour is a condition that
has to hold, not a thing that happens. the character timeout is "no read and no
new character for 4 character times". if something in that same cycle makes the
condition false, nothing fires. this is the opposite rule to the one above and
the difference matters, so each row says which one it is using.

**software's newest intent wins** for configuration and stored data.

## errors and contradictions in the datasheet

| question | where | decision | reason |
|---|---|---|---|
| table 2 puts MODEM Control at A2 A1 A0 = 000 | table 2 | MCR is at address 4 | table 1 puts MCR at 4; the row order in Table 2 puts it between 3 and 5; 000 is already RBR/THR |
| divisor range 1 or 2 to 65535? | section 5 and 7.5 say 1, section 8.5.1 says 2 | 1 to 65535 supported | two statements say 1, and divisor 1 is well defined with a clock enable |
| what does divisor 0 do? | 8.5.1 "not recommended" | the baud generator stops: no ticks, the transmitter, receiver and timeout freeze | safe, and it is the reset state |
| does reset clear DLL, DLM and SCR? | MR pin says it does not clear DLL/DLM; Table 3 omits SCR | `aresetn` clears every register, DLL, DLM and SCR included | no unknown values in simulation or silicon; 8.5.1 says software must load the divisor anyway |
| TERI: "low to high" or "high to low"? | RI pin note vs MSR bit 2 text | set when the RI pin goes low to high, which is MSR bit 6 going 1 to 0 | both texts describe the same edge; MSR bit 6 is the complement of the pin |

## bus mapping and access

| question | where | decision | reason |
|---|---|---|---|
| where does each register live on AXI? | scope 6 | offset = datasheet address x 4, value in bits 7:0 | common practice for 8-bit peripherals on a 32-bit bus |
| which strobes matter? | IHI 0022E B1.1.3 | only WSTRB[0]. WSTRB[0] = 0 means no effect, response OKAY | the register is one byte wide |
| offsets above 0x1C or not a multiple of 4? | scope 6 | SLVERR, no effect, read data 0 | no register there |
| writes to LSR and MSR? | 8.6.3 note, 8.6.8 | accepted with OKAY and ignored | the original chip does not fault on them, and a bus error would crash software written for it. compare the timer, where a read-only write gave SLVERR because no compatibility target existed |
| when do read side effects happen? | scope, IHI 0022E | in the cycle of the AR handshake, exactly once, only when the read succeeds | matches `reg_rd` in the shared bus bridge |
| read and write of related state in one cycle | not stated | the read sees the values from before the write | a write takes effect at the end of its cycle |
| reserved bits | table 1 | IER 7:4, MCR 7:5 and IIR 5:4 read 0 and are not stored | table 1 marks them 0; PC drivers test IER 7:4 |
