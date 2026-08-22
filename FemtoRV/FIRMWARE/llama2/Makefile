#
# Makefile for the llama2.c port and its int8 (Q8_0) quantized sibling,
# runq.c (feature 004).
#
# Links llama2.c / runq.c at 0x800000 (see llama2.ld / runq.ld) and
# produces a raw binary suitable for XMODEM upload via the BIOS monitor's
# 'L' command, then run with 'G 800000'.
#

include ../makefile.inc

# Serial port for XMODEM uploads; override with: make upload PORT=/dev/ttyUSB0
PORT ?= /dev/ttyACM0

FEMTORV32_LIBS_EX=$(FIRMWARE_DIR)/CRT/syscalls.o \
		   -L$(RVTOOLCHAIN_LIB_DIR)\
	           -L$(FIRMWARE_DIR)/CRT\
		       -L$(FIRMWARE_DIR)/LIBFEMTORV32\
		       -L$(FIRMWARE_DIR)/LIBFEMTOC\
	   	       -lfemtorv32 -lfemtoc -lm

LDFLAGS_LLAMA2=-T llama2.ld
LDFLAGS_RUNQ=-T runq.ld

# All three translation units must be linked: llama2.c (inference),
# model_load.c (SD card -> SDRAM loader) and profile.c (cycle accounting).
# sdramstart.o zeroes .bss before main() -- mandatory for SDRAM programs.
# Single source of truth lives in ../examples/sdramstart.S.
LLAMA2_OBJS=sdramstart.o llama2.o model_load.o profile.o

# runq.c (int8 Q8_0 inference, feature 004) additionally links quantize.o
# (activation quantization, T016). model_load.o and profile.o are shared
# with llama2.c above -- same object, both formats' loaders/categories
# live in the one source file each.
RUNQ_OBJS=sdramstart.o runq.o model_load.o profile.o quantize.o

# runq_accel.c does not exist -- runq_accel.o is runq.c recompiled with
# -DUSE_ACC_MATMUL (T059's compile-time switch, see runq.c's do_matmul_q8()
# comment), via the EXPLICIT rule below rather than the implicit .c.o
# suffix rule, specifically so it cannot collide with plain runq.o's
# object file under `make all` (same source, two different flag sets,
# same stem would otherwise make one of the two builds silently reuse the
# other's stale .o). acc_driver.o is the accelerator register/BRAM driver
# (T057/T058) -- linked ONLY into this target, since the default runq.bin
# must stay exactly the already-verified software-only build.
RUNQ_ACCEL_OBJS=sdramstart.o runq_accel.o model_load.o profile.o quantize.o acc_driver.o

sdramstart.o: ../examples/sdramstart.S
	$(RVAS) $(RVASFLAGS) $(RVUSERASFLAGS) $< -o $@

llama2.elf: $(LLAMA2_OBJS) $(RV_BINARIES)
	$(RVLD) $(RVLDFLAGS) $(LDFLAGS_LLAMA2) $(LLAMA2_OBJS) -o $@ $(FEMTORV32_LIBS_EX) $(RVGCC_LIB)

runq.elf: $(RUNQ_OBJS) $(RV_BINARIES)
	$(RVLD) $(RVLDFLAGS) $(LDFLAGS_RUNQ) $(RUNQ_OBJS) -o $@ $(FEMTORV32_LIBS_EX) $(RVGCC_LIB)

runq_accel.elf: $(RUNQ_ACCEL_OBJS) $(RV_BINARIES)
	$(RVLD) $(RVLDFLAGS) $(LDFLAGS_RUNQ) $(RUNQ_ACCEL_OBJS) -o $@ $(FEMTORV32_LIBS_EX) $(RVGCC_LIB)

llama2.o: llama2.c model_load.h profile.h
# -ffp-contract=off on BOTH runq objects, and on quantize.o.
#
# The accelerator rounds after every multiply and every add. GCC's default
# -ffp-contract=fast fuses `a*b + c` into a single fmadd.s once it inlines
# across a statement boundary, skipping that intermediate rounding -- and
# rv32imafc has hardware FMA to fuse into. Built that way, runq.bin's software
# matmul and runq_accel.bin's hardware matmul compute genuinely different
# things, and the A/B comparison that is supposed to PROVE the accelerator
# instead reports a difference that is nobody's bug (research R40/R43).
#
# It goes on runq.o as well as runq_accel.o because the comparison is between
# those two binaries: they must round identically everywhere except in the
# matmul the accelerator replaces.
runq.o: runq.c model_load.h profile.h quantize.h q8_format.h
	$(RVGCC) $(RVCFLAGS) $(RVUSERCFLAGS) -ffp-contract=off -c runq.c -o runq.o
model_load.o: model_load.c model_load.h q8_format.h
profile.o: profile.c profile.h
quantize.o: quantize.c quantize.h
	$(RVGCC) $(RVCFLAGS) $(RVUSERCFLAGS) -ffp-contract=off -c quantize.c -o quantize.o
acc_driver.o: acc_driver.c acc_driver.h

# Explicit compile rule (bypasses the implicit .c.o suffix rule on purpose
# -- see RUNQ_ACCEL_OBJS comment above).
runq_accel.o: runq.c model_load.h profile.h quantize.h q8_format.h acc_driver.h
	$(RVGCC) $(RVCFLAGS) $(RVUSERCFLAGS) -ffp-contract=off -DUSE_ACC_MATMUL -c runq.c -o runq_accel.o

llama2.bin: llama2.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

runq.bin: runq.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

runq_accel.bin: runq_accel.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

llama2.list: llama2.elf
	$(RVOBJDUMP) -Mnumeric -D $< > $@

runq.list: runq.elf
	$(RVOBJDUMP) -Mnumeric -D $< > $@

runq_accel.list: runq_accel.elf
	$(RVOBJDUMP) -Mnumeric -D $< > $@

all: llama2.bin runq.bin runq_accel.bin

# Upload the program to the board via XMODEM (BIOS monitor 'L' command),
# then run it with 'G 800000' at the monitor prompt.
upload: llama2.bin
	python3 ../../TOOLS/xmodem_upload.py $< $(PORT) 800000 --follow

upload-runq: runq.bin
	python3 ../../TOOLS/xmodem_upload.py $< $(PORT) 800000 --follow

upload-runq-accel: runq_accel.bin
	python3 ../../TOOLS/xmodem_upload.py $< $(PORT) 800000 --follow

# ---- Host-side math verification (NOT cross-compiled) ----
# Confirms quantize.c's quantize_activations() and a hand-copy of runq.c's
# matmul_q8()/RoPE (runq.c itself is not host-buildable -- it needs
# femtorv32.h) are bit-identical to tools/runq_host.c, the golden
# reference, across this project's actual tensor shapes. Runs on the
# DEVELOPER'S machine with plain gcc, deliberately NOT $(RVGCC) -- this
# has nothing to do with the RISC-V target, see verify_fw_math.c's header.
verify-fw-math: tools/verify_fw_math.c quantize.c quantize.h tools/runq_host.c q8_format.h
	gcc -O2 -I. -o tools/verify_fw_math tools/verify_fw_math.c quantize.c -lm
	./tools/verify_fw_math

clean:
	rm -f *.o *.elf *.bin *.list
	rm -f tools/verify_fw_math
