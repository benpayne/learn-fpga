
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

%.bin: %.upload.elf
	$(RVOBJCOPY) -O binary $< $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

all: hello_gpu.bin gfx_test.bin

upload_hello: hello_gpu.bin
	python3 ../../TOOLS/xmodem_upload.py $< /dev/ttyACM0 4000

upload_gfx: gfx_test.bin
	python3 ../../TOOLS/xmodem_upload.py $< /dev/ttyACM0 4000

