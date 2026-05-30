# axil-uart16550

PC16550D compatible UART on an AXI4-Lite port. Software compatible, so a driver
written for the real chip works unchanged.

Datasheet is TI SNLS378C, <https://www.ti.com/lit/ds/symlink/pc16550d.pdf>.

`docs/uart16550_scope.md` says what is in and what is out.
`docs/uart16550_decisions.md` is every question the datasheet did not answer, or
answered twice, and what I decided.

The bus front end and the checker come from
[axil-timer](https://github.com/mij001/axil-timer) as a submodule:

```
git submodule update --init
```

Needs icarus verilog and verilator.

```
make lint
make run
make nomodel
make regress
make waves
```
