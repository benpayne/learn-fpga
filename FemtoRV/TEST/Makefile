SIM ?= icarus
WAVES = 1

SRC_DIR = ../RTL/DEVICES

#VERILOG_SOURCES = $(SRC_DIR)/timer.v
#TOPLEVEL := ClockTimer

#VERILOG_SOURCES = $(SRC_DIR)/InterruptController.v
#TOPLEVEL := InterruptController

#MODULE := ic_tb

VERILOG_SOURCES = $(SRC_DIR)/PS2Decoder.v \
	$(SRC_DIR)/ps2_controller/dual_fifo.v \
	$(SRC_DIR)/ps2_controller/debounce.v \
	$(SRC_DIR)/ps2_controller/ps2_decoder.v \
	$(SRC_DIR)/ps2_controller/ps2_top.v 
	
TOPLEVEL := ps2_decoder_device

MODULE := ps2dec_tb

include $(shell cocotb-config --makefiles)/Makefile.sim

synthesis:
	yosys -p 'synth_ice40 -top $(TOPLEVEL) -json $(TOPLEVEL).json' $(VERILOG_SOURCES)

simulation:
	$(MAKE) sim
