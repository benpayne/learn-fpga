
include ../makefile.inc

# Serial port for XMODEM uploads; override with: make upload_x PORT=/dev/ttyUSB0
PORT ?= /dev/ttyACM0

FEMTORV32_LIBS_EX=$(FIRMWARE_DIR)/CRT/syscalls.o \
		   -L$(RVTOOLCHAIN_LIB_DIR)\
           -L$(FIRMWARE_DIR)/CRT\
	       -L$(FIRMWARE_DIR)/LIBFEMTORV32\
	       -L$(FIRMWARE_DIR)/LIBFEMTOC\
   	       -lfemtorv32 -lfemtoc -lm

# Build uploadable binaries (raw binary, not hex for BRAM init)
# These get loaded at 0x4000 by the monitor via XMODEM

# Link at load address 0x4000
LDFLAGS_UPLOAD=-T upload.ld

%.upload.elf: %.o $(RV_BINARIES)
	$(RVLD) $(RVLDFLAGS) $(LDFLAGS_UPLOAD) $< -o $@ $(FEMTORV32_LIBS_EX) $(RVGCC_LIB)

# Link at load address 0x800000 (SDRAM), for the monitor's default 'L'/'G'
# XMODEM load address. Used by standalone SDRAM test programs that run
# directly from SDRAM without the RetroKernel's progstart.o entry stub.
LDFLAGS_UPLOAD_SDRAM=-T upload_sdram.ld

# sdramstart.o zeroes .bss before calling main -- mandatory for SDRAM
# programs, see sdramstart.S. Must be listed before $< so it lands first.
%.upload_sdram.elf: %.o sdramstart.o $(RV_BINARIES)
	$(RVLD) $(RVLDFLAGS) $(LDFLAGS_UPLOAD_SDRAM) sdramstart.o $< -o $@ $(FEMTORV32_LIBS_EX) $(RVGCC_LIB)

# sdram_memtest.bin: explicit rule (overrides the %.bin: %.program.elf
# pattern rule below) so it links at 0x800000 via upload_sdram.ld instead
# of at 0x810000 via program.ld.
sdram_memtest.bin: sdram_memtest.upload_sdram.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

# ---- Kernel-loadable programs (load at 0x810000) ----

LDFLAGS_PROGRAM=-T program.ld

PROGRAMS=hello.bin nop.bin bounce.bin mario.bin hello_gpu.bin gfx_test.bin args.bin edit.bin play.bin sndtest.bin fbtest.bin showimg.bin bursttest.bin

# Build progstart.o (entry stub that saves/restores ra)
progstart.o: progstart.S
	$(RVAS) $(RVASFLAGS) $< -o $@

# Link a kernel-loadable program: progstart.o first, then the .o
%.program.elf: %.o progstart.o $(RV_BINARIES)
	$(RVLD) $(RVLDFLAGS) $(LDFLAGS_PROGRAM) progstart.o $< -o $@ $(FEMTORV32_LIBS_EX) $(RVGCC_LIB)

%.bin: %.program.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

%.list: %.program.elf
	$(RVOBJDUMP) -Mnumeric -D $< > $@

all: $(PROGRAMS)

# ---- SD card benchmark (T011, 003-llama2-minimal-soc) ----
# Explicit rule (overrides the %.bin: %.program.elf pattern rule above),
# same as sdram_memtest.bin: links via the %.upload_sdram.elf pattern rule
# at 0x800000 using the standard femtorv32.S _start -- no progstart.o /
# kernel argv needed. Upload via BIOS monitor 'L', run with 'G 800000'.
sd_bench.bin: sd_bench.upload_sdram.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

upload_sd_bench: sd_bench.bin
	python3 ../../TOOLS/xmodem_upload.py $< $(PORT) 800000 --follow

# ---- Serial-only demos for the minimal LLM profile ----
# hello_serial and sd_ls are the GPU-free, monitor-loadable siblings of
# hello.c and sd_dir.c. Those two are RetroKernel programs: they link at
# 0x810000 via program.ld and write to the GPU, neither of which exists in
# the colorlight_i5_llm profile. These link at 0x800000 through the
# %.upload_sdram.elf pattern rule instead, so the BIOS monitor's 'L'/'G'
# can run them directly. Explicit .bin rules, because the generic
# %.bin: %.program.elf pattern rule above would otherwise claim them and
# link them at the wrong address.

hello_serial.bin: hello_serial.upload_sdram.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

upload_hello_serial: hello_serial.bin
	python3 ../../TOOLS/xmodem_upload.py $< $(PORT) 800000 --follow

sd_ls.bin: sd_ls.upload_sdram.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

upload_sd_ls: sd_ls.bin
	python3 ../../TOOLS/xmodem_upload.py $< $(PORT) 800000 --follow

# Explicit upload target for the memory test. MUST be 800000 to match
# upload_sdram.ld -- the generic upload_% rule below uses 810000 (the
# RetroKernel program address) and would load this at the wrong address
# and jump into garbage.
upload_sdram_memtest: sdram_memtest.bin
	python3 ../../TOOLS/xmodem_upload.py $< $(PORT) 800000 --follow

# ---- Accelerator standalone test (T051/T052, feature 004) ----
# acc_test.c pulls in two sources that live under ../llama2/ (the
# accelerator driver, T057/T058, and the real quantize.c, T016) rather
# than duplicating them here -- explicit compile rules below, same
# cross-directory-source pattern this Makefile already uses for
# sdramstart.o (built from ../llama2/Makefile's perspective) and
# progstart.o.
#
# Links at 0x800000 like sd_bench.bin/sdram_memtest.bin above, via an
# EXPLICIT rule rather than the %.upload_sdram.elf pattern rule -- that
# pattern rule only links ONE object ($< sdramstart.o), and acc_test
# needs three (acc_test.o, acc_driver.o, quantize.o) plus sdramstart.o.
# Team-lead note: this project has already been bitten once by a target
# that linked only $< and reported success while silently omitting most
# of the program -- the recipe below names every object explicitly so
# that mistake cannot repeat here.
# attn_bench: decomposes attention's 170 cycles/MAC into arithmetic vs memory,
# so the KV-cache-vs-fp32-datapath decision is made from a measurement.
attn_bench.o: attn_bench.c

attn_bench.elf: sdramstart.o attn_bench.o $(RV_BINARIES)
	$(RVLD) $(RVLDFLAGS) $(LDFLAGS_UPLOAD_SDRAM) sdramstart.o attn_bench.o -o attn_bench.elf $(FEMTORV32_LIBS_EX) $(RVGCC_LIB)

attn_bench.bin: attn_bench.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

upload_attn_bench: attn_bench.bin
	python3 ../../TOOLS/xmodem_upload.py $< $(PORT) 800000 --follow

# sdput: writes a staged SDRAM buffer onto the SD card. Explicit multi-object
# link like acc_test below, not the %.upload_sdram.elf pattern rule.
sdput.o: sdput.c ../llama2/q8_format.h
	$(RVGCC) $(RVCFLAGS) $(RVUSERCFLAGS) -I../llama2 -c sdput.c -o sdput.o

sdput.elf: sdramstart.o sdput.o $(RV_BINARIES)
	$(RVLD) $(RVLDFLAGS) $(LDFLAGS_UPLOAD_SDRAM) sdramstart.o sdput.o -o sdput.elf $(FEMTORV32_LIBS_EX) $(RVGCC_LIB)

sdput.bin: sdput.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

upload_sdput: sdput.bin
	python3 ../../TOOLS/xmodem_upload.py $< $(PORT) 800000 --follow

acc_driver.o: ../llama2/acc_driver.c ../llama2/acc_driver.h
	$(RVGCC) $(RVCFLAGS) $(RVUSERCFLAGS) -I../llama2 -c ../llama2/acc_driver.c -o acc_driver.o

quantize.o: ../llama2/quantize.c ../llama2/quantize.h
	$(RVGCC) $(RVCFLAGS) $(RVUSERCFLAGS) -I../llama2 -c ../llama2/quantize.c -o quantize.o

# -ffp-contract=off is REQUIRED here, not a preference. The CPU reference in
# acc_test.c exists to be compared bit-for-bit against the accelerator, which
# rounds after every multiply and every add. GCC's default -ffp-contract=fast
# fuses `contrib = ival_f * w_s * x_s; val += contrib;` into a single fmadd.s
# once it inlines across the statement boundary, skipping the intermediate
# rounding -- so the reference computes something the hardware deliberately
# does not, and the comparison reports a difference that is nobody's bug
# (research R40). rv32imafc has hardware FMA, so this fires on real silicon.
acc_test.o: acc_test.c ../llama2/acc_driver.h ../llama2/quantize.h
	$(RVGCC) $(RVCFLAGS) $(RVUSERCFLAGS) -ffp-contract=off -I../llama2 -c acc_test.c -o acc_test.o

acc_test.elf: sdramstart.o acc_test.o acc_driver.o quantize.o $(RV_BINARIES)
	$(RVLD) $(RVLDFLAGS) $(LDFLAGS_UPLOAD_SDRAM) sdramstart.o acc_test.o acc_driver.o quantize.o -o acc_test.elf $(FEMTORV32_LIBS_EX) $(RVGCC_LIB)

acc_test.bin: acc_test.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

acc_test.list: acc_test.elf
	$(RVOBJDUMP) -Mnumeric -D $< > $@

# Explicit upload target, MUST be 800000 (upload_sdram.ld) -- same reason
# as upload_sdram_memtest above: the generic upload_% rule below uses
# 810000 (the RetroKernel program address) and would load this at the
# wrong address.
upload_acc_test: acc_test.bin
	python3 ../../TOOLS/xmodem_upload.py $< $(PORT) 800000 --follow

# Upload a program to the board via XMODEM (to SDRAM for testing).
# NOTE: 810000 is the RetroKernel program-load address. Programs linked
# with upload_sdram.ld live at 800000 and need an explicit target above.
upload_%: %.bin
	python3 ../../TOOLS/xmodem_upload.py $< $(PORT) 810000

clean:
	rm -f *.o *.elf *.bin *.list
