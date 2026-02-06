# icarus and verilator. the bus front end and the checker are not here, they
# come from the axil-timer submodule under deps/. run:
# git submodule update --init
# targets are listed in the readme

DEP := deps/axil-timer
SIMDIR := sim

check-dep:
	@test -d $(DEP)/rtl || \
	  (echo "deps/axil-timer is empty. run: git submodule update --init"; false)

$(SIMDIR):
	@mkdir -p $(SIMDIR)

clean:
	rm -rf $(SIMDIR)

.PHONY: check-dep clean
