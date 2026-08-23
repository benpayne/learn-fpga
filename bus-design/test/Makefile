# Dispatches between the 6502 / 68k bridge test suites and their PAL/GAL
# variants.  The same Python tests run against either implementation, so
# all four targets verify identical bus-level behaviour.
#
# Usage:
#   make                       # runs the pure-74 6502 suite (default)
#   make TARGET=6502           # explicit
#   make TARGET=6502_pal       # PAL/GAL 6502 build (4-chip bridge)
#   make TARGET=68k            # pure-74 68000 build
#   make TARGET=68k_pal        # PAL/GAL 68k build (6-chip bridge)

TOPLEVEL_LANG = verilog
SIM          ?= icarus

TARGET ?= 6502

ifeq ($(TARGET),6502)
  TOPLEVEL        = bridge_6502_tb
  MODULE         ?= bridge_6502_tb
  SIM_BUILD       = sim_build_6502
  VERILOG_SOURCES = \
      ../rtl/chips_7400.v \
      ../rtl/bridge_6502.v \
      ../rtl/fake_bus_target.v \
      bridge_6502_tb.v
else ifeq ($(TARGET),6502_pal)
  TOPLEVEL        = bridge_6502_pal_tb
  MODULE         ?= bridge_6502_tb
  SIM_BUILD       = sim_build_6502_pal
  VERILOG_SOURCES = \
      ../rtl/chips_7400.v \
      ../rtl/bridge_6502_pal.v \
      ../rtl/fake_bus_target.v \
      bridge_6502_pal_tb.v
else ifeq ($(TARGET),68k)
  TOPLEVEL        = bridge_68k_tb
  MODULE         ?= bridge_68k_tb
  SIM_BUILD       = sim_build_68k
  VERILOG_SOURCES = \
      ../rtl/chips_7400.v \
      ../rtl/bridge_68k.v \
      ../rtl/fake_bus_target_16.v \
      bridge_68k_tb.v
else ifeq ($(TARGET),68k_pal)
  TOPLEVEL        = bridge_68k_pal_tb
  MODULE         ?= bridge_68k_pal_tests
  SIM_BUILD       = sim_build_68k_pal
  VERILOG_SOURCES = \
      ../rtl/chips_7400.v \
      ../rtl/bridge_68k_pal.v \
      ../rtl/fake_bus_target_16.v \
      bridge_68k_pal_tb.v
else ifeq ($(TARGET),68k_multislot)
  TOPLEVEL        = bridge_68k_multislot_tb
  MODULE         ?= bridge_68k_multislot_tb
  SIM_BUILD       = sim_build_68k_multislot
  VERILOG_SOURCES = \
      ../rtl/chips_7400.v \
      ../rtl/bridge_68k_pal.v \
      ../rtl/backplane_decoder.v \
      ../rtl/fake_bus_target_16.v \
      bridge_68k_multislot_tb.v
else ifeq ($(TARGET),6502_multislot)
  TOPLEVEL        = bridge_6502_multislot_tb
  MODULE         ?= bridge_6502_multislot_tb
  SIM_BUILD       = sim_build_6502_multislot
  VERILOG_SOURCES = \
      ../rtl/chips_7400.v \
      ../rtl/bridge_6502_pal.v \
      ../rtl/backplane_decoder.v \
      ../rtl/fake_bus_target.v \
      bridge_6502_multislot_tb.v
else
  $(error Unknown TARGET '$(TARGET)' — use 6502, 6502_pal, 68k, 68k_pal, 68k_multislot, or 6502_multislot)
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
