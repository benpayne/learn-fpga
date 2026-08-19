#
# Makefile for the llama2.c port.
#
# Links llama2.c at 0x800000 (see llama2.ld) and produces a raw binary
# suitable for XMODEM upload via the BIOS monitor's 'L' command, then run
# with 'G 800000'.
#

include ../makefile.inc

FEMTORV32_LIBS_EX=$(FIRMWARE_DIR)/CRT/syscalls.o \
		   -L$(RVTOOLCHAIN_LIB_DIR)\
	           -L$(FIRMWARE_DIR)/CRT\
		       -L$(FIRMWARE_DIR)/LIBFEMTORV32\
		       -L$(FIRMWARE_DIR)/LIBFEMTOC\
	   	       -lfemtorv32 -lfemtoc -lm

LDFLAGS_LLAMA2=-T llama2.ld

# All three translation units must be linked: llama2.c (inference),
# model_load.c (SD card -> SDRAM loader) and profile.c (cycle accounting).
LLAMA2_OBJS=llama2.o model_load.o profile.o

llama2.elf: $(LLAMA2_OBJS) $(RV_BINARIES)
	$(RVLD) $(RVLDFLAGS) $(LDFLAGS_LLAMA2) $(LLAMA2_OBJS) -o $@ $(FEMTORV32_LIBS_EX) $(RVGCC_LIB)

llama2.o: llama2.c model_load.h profile.h
model_load.o: model_load.c model_load.h
profile.o: profile.c profile.h

llama2.bin: llama2.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

llama2.list: llama2.elf
	$(RVOBJDUMP) -Mnumeric -D $< > $@

all: llama2.bin

# Upload the program to the board via XMODEM (BIOS monitor 'L' command),
# then run it with 'G 800000' at the monitor prompt.
upload: llama2.bin
	python3 ../../TOOLS/xmodem_upload.py $< /dev/ttyACM0 800000

clean:
	rm -f *.o *.elf *.bin *.list
