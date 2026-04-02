
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

# ---- Kernel-loadable programs (load at 0x810000) ----

LDFLAGS_PROGRAM=-T program.ld

PROGRAMS=hello.bin nop.bin bounce.bin mario.bin hello_gpu.bin gfx_test.bin args.bin edit.bin play.bin sndtest.bin

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

# Upload a program to the board via XMODEM (to SDRAM for testing)
upload_%: %.bin
	python3 ../../TOOLS/xmodem_upload.py $< /dev/ttyACM0 810000

clean:
	rm -f *.o *.elf *.bin *.list
