SIM ?= icarus
WAVES = 1

SRC_DIR = ../RTL/DEVICES
LIB_DIR = ../lib/ps2-controller-lib

# Default target: PS2 decoder
# Override with: make MODULE=ic_tb TOPLEVEL=InterruptController
# Or use convenience targets below

# PS2 decoder (default)
ifeq ($(MODULE),ic_tb)
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

include $(shell cocotb-config --makefiles)/Makefile.sim

# Convenience targets
.PHONY: test-ps2 test-ic test-timer test-all clean-sim

test-ps2:
	$(MAKE) MODULE=ps2dec_tb SIM=$(SIM)

test-ic:
	$(MAKE) MODULE=ic_tb SIM=$(SIM)

test-timer:
	$(MAKE) MODULE=timer_tb SIM=$(SIM)

test-all: clean-sim
	$(MAKE) test-ic
	$(MAKE) clean-sim
	$(MAKE) test-timer
	$(MAKE) clean-sim
	$(MAKE) test-ps2

clean-sim:
	rm -rf sim_build results.xml __pycache__
