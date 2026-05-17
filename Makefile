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
TB  := $(DEP)/tb/common/axil_checker.v tb/axil_master_bfm.v tb/uart/serial_bfm.v \
       tb/uart/uart16550_model.v tb/uart/tb_axil_uart16550.v

SCENARIOS := tx_start tx_frame rx_frame rx_glitch fifo_overrun cti

all: lint run

check-dep:
	@test -d $(DEP)/rtl || \
	  (echo "deps/axil-timer is empty. run: git submodule update --init"; false)

$(SIMDIR):
	@mkdir -p $(SIMDIR)

$(SIMDIR)/tb_axil_uart16550.vvp: $(RTL) $(TB) | $(SIMDIR)
	iverilog -g2005 -o $@ $^

lint: check-dep
	verilator --lint-only -Wall --top-module axil_uart16550 $(RTL)

run: check-dep $(SIMDIR)/tb_axil_uart16550.vvp
	vvp $(SIMDIR)/tb_axil_uart16550.vvp +seed=$(SEED) +nrand=$(NRAND)

nomodel: check-dep $(SIMDIR)/tb_axil_uart16550.vvp
	vvp $(SIMDIR)/tb_axil_uart16550.vvp +seed=$(SEED) +nrand=$(NRAND) +no_model

regress: check-dep $(SIMDIR)/tb_axil_uart16550.vvp
	@for s in 1 2 3 4 5 6 7 8 9 10; do echo $$s; done | \
	  xargs -P 4 -I{} sh -c 'vvp $(SIMDIR)/tb_axil_uart16550.vvp +seed={} +nrand=$(NRAND) > $(SIMDIR)/uart_seed{}.log; \
	                         grep "^RESULT" $(SIMDIR)/uart_seed{}.log | sed "s/^/seed {}: /"'

waves: $(SIMDIR)/tb_axil_uart16550.vvp
	@for sc in $(SCENARIOS); do \
	  vvp $(SIMDIR)/tb_axil_uart16550.vvp +scenario=$$sc | grep WAVE_START | sed "s/^/$$sc /"; \
	done

clean:
	rm -rf $(SIMDIR)

.PHONY: all check-dep lint run nomodel regress waves clean
