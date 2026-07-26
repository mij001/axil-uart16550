# Debug log

What broke while building this, and while splitting it out of the combined repo
it started in. Numbers are from real runs.

The bus level bugs are not here. They belong to
[axil-timer](https://github.com/mij001/axil-timer), which owns the bus front end,
the checker and the assertions, and that repo has its own debug log. This one is
the UART and the split.

---

## 1. the datasheet contradicts itself, four times

Not a bug in my code, but it is the thing that took the longest and it is all in
`docs/uart16550_decisions.md`.

| What | The problem | What I did |
|---|---|---|
| MCR address | Table 2 puts MODEM Control at A2A1A0 = 000, which is already RBR/THR | Put MCR at 4, which is what Table 1 says and what the row order implies |
| Divisor range | Sections 5 and 7.5 say 1 to 65535, section 8.5.1 says 2 | Supported 1 to 65535. Two statements say 1, and divisor 1 is well defined with a clock enable |
| TERI edge | The RI pin note and the MSR bit 2 text look like they disagree | They are the same edge. Set when RI goes low to high, which is MSR bit 6 going 1 to 0 |
| Framing error recovery | 8.6.3 says the receiver "samples this start bit twice", which is not precise enough to reproduce | Treat the stop bit sample as the centre of the next start bit, so every later sample stays at a bit centre |

The last one is the honest one. The wording does not pin the behaviour down. I
picked a reading, and the row says that I picked it rather than pretending the
datasheet decided.

---

## 2. submodule, not a copy

The timer already had three things this needs: the AXI4-Lite bus front end, the
hand written protocol checker, and the assertions. So the first question here was
how to get at them.

Copying them in would have been one command and it would have been wrong. Two
copies drift. A fix to the bus front end would land in one repo and sit rotting in
the other, and nothing would ever tell me.

So the timer repo owns them and this one carries it as a submodule under `deps/`.
The makefile builds straight out of that path:

```make
DEP := deps/axil-timer
RTL := $(DEP)/rtl/common/axil_reg_bus.sv rtl/sync_fifo.sv ...
TB  := $(DEP)/tb/common/axil_checker.sv tb/axil_master_bfm.sv ...
```

The cost is real and worth naming. A fresh clone does not build until
`git submodule update --init`, so every target depends on a `check-dep` rule that
says exactly that instead of failing with a confusing missing file. And a fix in
the timer repo does not arrive here on its own, it arrives when the submodule
pointer is bumped, which is a commit in this repo. That is the point: the update
is visible and deliberate rather than silent.

---

## Where it stands

```
CHECKER uart: AW 2694, W 2694, B 2694, AR 2362, R 2362 handshakes, 0 rule violations
SERIAL: 391 frames driven, 99 frames decoded, 0 width errors
SCOREBOARD: 2694 writes, 2362 reads, 0 errors, 0 mismatches in 113442 compared cycles
COVER received formats seen            : 40 of 40
RESULT: PASS
```
