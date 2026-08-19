
include ../makefile.inc

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

%.upload_sdram.elf: %.o $(RV_BINARIES)
	$(RVLD) $(RVLDFLAGS) $(LDFLAGS_UPLOAD_SDRAM) $< -o $@ $(FEMTORV32_LIBS_EX) $(RVGCC_LIB)

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
	python3 ../../TOOLS/xmodem_upload.py $< /dev/ttyACM0 800000

# Upload a program to the board via XMODEM (to SDRAM for testing)
upload_%: %.bin
	python3 ../../TOOLS/xmodem_upload.py $< /dev/ttyACM0 810000

clean:
	rm -f *.o *.elf *.bin *.list
