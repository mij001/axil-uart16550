# icarus and verilator. the bus front end and the checker are not here, they
# come from the axil-timer submodule under deps/. run:
# git submodule update --init
# targets are listed in the readme

DEP     := deps/axil-timer
SIMDIR  := sim
SEED    ?= 1
NRAND   ?= 4000

RTL := $(DEP)/rtl/common/axil_reg_bus.v rtl/sync_fifo.v rtl/uart/uart_baud.v \
       rtl/uart/uart_tx.v rtl/uart/uart_rx.v rtl/uart/uart_io.v \
       rtl/uart/uart_regs.v rtl/uart/axil_uart16550.v

check-dep:
	@test -d $(DEP)/rtl || \
	  (echo "deps/axil-timer is empty. run: git submodule update --init"; false)

$(SIMDIR):
	@mkdir -p $(SIMDIR)

lint: check-dep
	verilator --lint-only -Wall --top-module axil_uart16550 $(RTL)

clean:
	rm -rf $(SIMDIR)

.PHONY: check-dep lint clean
