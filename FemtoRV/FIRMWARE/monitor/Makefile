
include ../makefile.inc

FEMTORV32_LIBS_MON=$(FIRMWARE_DIR)/CRT/syscalls.o \
		   -L$(RVTOOLCHAIN_LIB_DIR)\
           -L$(FIRMWARE_DIR)/CRT\
	       -L$(FIRMWARE_DIR)/LIBFEMTORV32\
	       -L$(FIRMWARE_DIR)/LIBFEMTOC\
   	       -lfemtorv32 -lfemtoc -lm

%.baremetal.elf: %.o $(RV_BINARIES)
	$(RVLD) $(RVLDFLAGS) -T$(FIRMWARE_DIR)/CRT/baremetal.ld $< -o $@ $(FEMTORV32_LIBS_MON) $(RVGCC_LIB)

all: monitor.hex

