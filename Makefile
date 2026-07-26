# icarus and verilator. the bus front end, the checker and the assertions come
# from the axil-timer submodule:
# git submodule update --init
# targets are listed in the readme

DEP     := deps/axil-timer
SIMDIR  := sim
SEED    ?= 1
NRAND   ?= 4000

SVA := $(DEP)/sva/axil_sva.sv

RTL := $(DEP)/rtl/common/axil_reg_bus.sv rtl/sync_fifo.sv rtl/uart/uart_baud.sv \
       rtl/uart/uart_tx.sv rtl/uart/uart_rx.sv rtl/uart/uart_io.sv \
       rtl/uart/uart_regs.sv rtl/uart/axil_uart16550.sv
TB  := $(DEP)/tb/common/axil_checker.sv tb/axil_master_bfm.sv tb/uart/serial_bfm.sv \
       tb/uart/uart16550_model.sv tb/uart/tb_axil_uart16550.sv

SCENARIOS := tx_start tx_frame rx_frame rx_glitch fifo_overrun cti
VFLAGS    := --binary --timing --assert -Wno-fatal

all: check-dep lint run

check-dep:
	@test -f $(DEP)/rtl/common/axil_reg_bus.sv || \
	  (echo "deps/axil-timer is empty. run: git submodule update --init"; false)

$(SIMDIR):
	@mkdir -p $(SIMDIR)

$(SIMDIR)/tb_axil_uart16550.vvp: $(RTL) $(TB) | $(SIMDIR)
	iverilog -g2012 -o $@ $^

run: check-dep $(SIMDIR)/tb_axil_uart16550.vvp
	vvp $(SIMDIR)/tb_axil_uart16550.vvp +seed=$(SEED) +nrand=$(NRAND)

nomodel: check-dep $(SIMDIR)/tb_axil_uart16550.vvp
	vvp $(SIMDIR)/tb_axil_uart16550.vvp +seed=$(SEED) +nrand=$(NRAND) +no_model

regress: check-dep $(SIMDIR)/tb_axil_uart16550.vvp
	@for s in 1 2 3 4 5 6 7 8 9 10; do echo $$s; done | \
	  xargs -P 4 -I{} sh -c 'vvp $(SIMDIR)/tb_axil_uart16550.vvp +seed={} +nrand=$(NRAND) > $(SIMDIR)/uart_seed{}.log; \
	                         grep "^RESULT" $(SIMDIR)/uart_seed{}.log | sed "s/^/seed {}: /"'

$(SIMDIR)/uart_sva: $(RTL) $(SVA) $(TB) | $(SIMDIR)
	@echo "  verilating the bench with the assertions from $(DEP)"
	@verilator $(VFLAGS) --top-module tb_axil_uart16550 \
	  -Mdir $(SIMDIR)/obj_sva -o ../uart_sva $^ > $(SIMDIR)/build_sva.log 2>&1 \
	  || (cat $(SIMDIR)/build_sva.log; false)

sva: check-dep $(SIMDIR)/uart_sva
	$(SIMDIR)/uart_sva +seed=$(SEED) +nrand=$(NRAND)

lint: check-dep
	verilator --lint-only -Wall --top-module axil_uart16550 $(RTL)

waves: $(SIMDIR)/tb_axil_uart16550.vvp
	@for sc in $(SCENARIOS); do \
	  vvp $(SIMDIR)/tb_axil_uart16550.vvp +scenario=$$sc | grep WAVE_START | sed "s/^/$$sc /"; \
	done

clean:
	rm -rf $(SIMDIR)

.PHONY: all check-dep lint run nomodel regress sva waves clean
