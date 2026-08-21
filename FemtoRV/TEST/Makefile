SIM ?= icarus
WAVES = 1

SRC_DIR = ../RTL/DEVICES
LIB_DIR = ../lib/ps2-controller-lib

# Default target: PS2 decoder
# Override with: make MODULE=ic_tb TOPLEVEL=InterruptController
# Or use convenience targets below

# PS2 decoder (default)
ifeq ($(MODULE),line_buffer_tb)
  VERILOG_SOURCES = ../RTL/SDRAM/video_line_buffer.v
  TOPLEVEL := video_line_buffer
else ifeq ($(MODULE),gpu_fb_tb)
  VERILOG_SOURCES = ../RTL/SDRAM/video_line_fifo.v
  TOPLEVEL := video_line_fifo
else ifeq ($(MODULE),video_fetch_tb)
  VERILOG_SOURCES = video_fetch_wrapper.v ../RTL/SDRAM/muchtoremember_burst.v ../RTL/SDRAM/sdram_arbiter.v ../RTL/SDRAM/video_fetch_engine.v ../RTL/SDRAM/video_line_fifo.v
  TOPLEVEL := video_fetch_wrapper
else ifeq ($(MODULE),acc_mac_tb)
  VERILOG_SOURCES = ../RTL/ACCEL/acc_mac.v
  TOPLEVEL := acc_mac
else ifeq ($(MODULE),acc_reject_tb)
  # T038: descriptor rejection paths, targeting acc_regs.v DIRECTLY (no
  # wrapper -- plain wire ports, same "raw module" style as acc_mac_tb
  # above) rather than acc_unit_tb.py's full acc_top stack. See
  # acc_reject_tb.py's file header for why (mac-unit owns acc_unit_tb.py
  # right now, and acc_regs.v is where accept-time validation lives).
  VERILOG_SOURCES = ../RTL/ACCEL/acc_regs.v
  # acc_regs.v `include "acc_bits.vh" -- same -I need as acc_unit_tb above.
  COMPILE_ARGS += -I../RTL/ACCEL
  TOPLEVEL := acc_regs
else ifeq ($(MODULE),acc_unit_tb)
  VERILOG_SOURCES = acc_unit_wrapper.v ../RTL/ACCEL/acc_top.v ../RTL/ACCEL/acc_mac.v ../RTL/ACCEL/acc_weight_fetch.v ../RTL/ACCEL/acc_regs.v ../RTL/SDRAM/muchtoremember_burst.v
  # acc_regs.v (and acc_top.v) `include "acc_bits.vh" -- icarus does not search
  # an including file's own directory by default, only cwd + -I, so this is
  # needed the same way the PS2 branch below needs -I$(LIB_DIR).
  COMPILE_ARGS += -I../RTL/ACCEL
  TOPLEVEL := acc_unit_wrapper
else ifeq ($(MODULE),acc_dump_replay_tb)
  # Same DUT stack as acc_unit_tb -- this module only differs in where its
  # test VECTOR comes from (a validated serial-capture dump, not real
  # weight-file/random synthetic data). Point ACC_DUMP_PATH at a real
  # board capture (see acc_dump_replay_tb.py's header); defaults to the
  # synthetic fixture in acc_dump_fixtures/ otherwise.
  VERILOG_SOURCES = acc_unit_wrapper.v ../RTL/ACCEL/acc_top.v ../RTL/ACCEL/acc_mac.v ../RTL/ACCEL/acc_weight_fetch.v ../RTL/ACCEL/acc_regs.v ../RTL/SDRAM/muchtoremember_burst.v
  COMPILE_ARGS += -I../RTL/ACCEL
  TOPLEVEL := acc_unit_wrapper
else ifeq ($(MODULE),acc_arb_tb)
  VERILOG_SOURCES = acc_arb_wrapper.v ../RTL/SDRAM/muchtoremember_burst.v
  TOPLEVEL := acc_arb_wrapper
else ifeq ($(MODULE),sdram_burst_tb)
  VERILOG_SOURCES = sdram_burst_wrapper.v ../RTL/SDRAM/muchtoremember_burst.v
  TOPLEVEL := sdram_burst_wrapper
else ifeq ($(MODULE),ic_tb)
  VERILOG_SOURCES = $(SRC_DIR)/InterruptController.v
  TOPLEVEL := InterruptController
else ifeq ($(MODULE),timer_tb)
  VERILOG_SOURCES = $(SRC_DIR)/timer.v
  TOPLEVEL := ClockTimer
else
  VERILOG_SOURCES = $(SRC_DIR)/PS2Decoder.v
  COMPILE_ARGS += -I$(LIB_DIR) -I..
  TOPLEVEL := ps2_decoder_device
  MODULE ?= ps2dec_tb
endif

# Each module gets its own scratch directory and results file. Without this,
# every testbench compiled into the same default sim_build/ (cocotb's own
# default, set in Makefile.inc) and wrote the same results.xml at the repo
# root -- two testbenches run at once silently overwrite each other's
# simulation binary and results, which looks like a passing (or failing)
# run of the WRONG design, not a build error. Must be set before Makefile.sim
# is included, since that is where cocotb's own `SIM_BUILD ?= sim_build`
# default (and the results.xml default) would otherwise win.
SIM_BUILD = sim_build/$(MODULE)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim

# Convenience targets
.PHONY: test-ps2 test-ic test-timer test-all clean-sim

test-ps2:
	$(MAKE) MODULE=ps2dec_tb SIM=$(SIM)

test-ic:
	$(MAKE) MODULE=ic_tb SIM=$(SIM)

test-timer:
	$(MAKE) MODULE=timer_tb SIM=$(SIM)

test-video-fetch:
	$(MAKE) MODULE=video_fetch_tb SIM=$(SIM)

test-sdram-burst:
	$(MAKE) MODULE=sdram_burst_tb SIM=$(SIM)

test-acc-reject:
	$(MAKE) MODULE=acc_reject_tb SIM=$(SIM)

test-all: clean-sim
	$(MAKE) test-ic
	$(MAKE) clean-sim
	$(MAKE) test-timer
	$(MAKE) clean-sim
	$(MAKE) test-ps2

clean-sim:
	rm -rf sim_build results.xml __pycache__

# Clean only the current $(MODULE)'s scratch dir, leaving other modules'
# build products (and any concurrently-running module) untouched.
clean-sim-module:
	rm -rf $(SIM_BUILD)

#######################################################################
# synth-check: does this module synthesize at all?
#
# research R21: acc_mac.v passes cocotb (7/7 tests, 1000/1000 bit-exact
# vectors) and was always functionally correct -- and could not be built.
# Its three large combinational fp32 rescale functions present yosys's
# `share` pass (SAT-based resource sharing) with an intractable instance;
# synth_ecp5 doesn't hang so much as grow without bound, and on the full
# SoC build that took the whole machine down via the kernel OOM-killer
# rather than failing loudly at the point of the actual problem. Cocotb
# proves logic is correct; it says NOTHING about whether yosys can turn
# that logic into gates. This target is the fast, standalone check that
# would have caught R21 before any full SoC synthesis ran.
#
# Each module is run out-of-context (its own -top, not the full SoC) so a
# broken module is identified directly rather than discovered as "the SoC
# build died" days later. `ulimit -v` bounds the run to a hard virtual-
# memory ceiling -- comfortably above what any of these modules need
# (the two that pass finish in ~2s), but low enough that a `share`-pass
# blowup like acc_mac's fails in under a minute with a clean abort
# (std::bad_alloc) instead of slowly consuming the machine's real RAM and
# swap the way the unbounded run did. `timeout` is a second, independent
# bound in case a future pathological module hangs without allocating
# enough virtual memory to trip the ulimit at all.
#
# This target uses the DEFAULT synth_ecp5 flow (share pass included), not
# the share-omitted workaround BOARDS/colorlight_i5_llm.mk now uses for
# the real SoC build -- deliberately: the point is to catch a module that
# needs a workaround to synthesize, not to launder it through a config
# that happens to avoid the failure. Right now acc_mac (and acc_top,
# which pulls acc_mac in transitively) are EXPECTED to fail this check;
# that is the check doing its job, not a bug in the check.
#######################################################################
ACC_DIR = ../RTL/ACCEL
SYNTH_CHECK_VMEM_KB = 4000000
SYNTH_CHECK_TIMEOUT = 90

.PHONY: synth-check synth-check-acc_regs synth-check-acc_weight_fetch synth-check-acc_mac synth-check-acc_top

synth-check: synth-check-acc_regs synth-check-acc_weight_fetch synth-check-acc_mac synth-check-acc_top
	@echo "synth-check: PASS -- all ACCEL modules synthesize standalone (default flow, share included)"

synth-check-acc_regs:
	@echo "=== synth-check: acc_regs ==="
	bash -c 'ulimit -v $(SYNTH_CHECK_VMEM_KB); timeout $(SYNTH_CHECK_TIMEOUT) yosys -q -p "read_verilog -I$(ACC_DIR) $(ACC_DIR)/acc_regs.v; synth_ecp5 -top acc_regs -json /tmp/synth_check_acc_regs.json"'

synth-check-acc_weight_fetch:
	@echo "=== synth-check: acc_weight_fetch ==="
	bash -c 'ulimit -v $(SYNTH_CHECK_VMEM_KB); timeout $(SYNTH_CHECK_TIMEOUT) yosys -q -p "read_verilog -I$(ACC_DIR) $(ACC_DIR)/acc_weight_fetch.v; synth_ecp5 -top acc_weight_fetch -json /tmp/synth_check_acc_weight_fetch.json"'

synth-check-acc_mac:
	@echo "=== synth-check: acc_mac (EXPECTED TO FAIL until R21 is resolved -- see header comment) ==="
	bash -c 'ulimit -v $(SYNTH_CHECK_VMEM_KB); timeout $(SYNTH_CHECK_TIMEOUT) yosys -q -p "read_verilog -I$(ACC_DIR) $(ACC_DIR)/acc_mac.v; synth_ecp5 -top acc_mac -json /tmp/synth_check_acc_mac.json"'

synth-check-acc_top:
	@echo "=== synth-check: acc_top (pulls in acc_regs/acc_weight_fetch/acc_mac -- EXPECTED TO FAIL, same root cause as acc_mac) ==="
	bash -c 'ulimit -v $(SYNTH_CHECK_VMEM_KB); timeout $(SYNTH_CHECK_TIMEOUT) yosys -q -p "read_verilog -I$(ACC_DIR) $(ACC_DIR)/acc_top.v $(ACC_DIR)/acc_regs.v $(ACC_DIR)/acc_weight_fetch.v $(ACC_DIR)/acc_mac.v; synth_ecp5 -top acc_top -json /tmp/synth_check_acc_top.json"'
