include ../../makefile.inc

RVUSERCFLAGS=-w -DRISCV -DTIME -DUSE_MYSTDLIB -fno-pic

FEMTORV32_LIBS_EX=$(FIRMWARE_DIR)/CRT/syscalls.o \
		   -L$(RVTOOLCHAIN_LIB_DIR)\
           -L$(FIRMWARE_DIR)/CRT\
	       -L$(FIRMWARE_DIR)/LIBFEMTORV32\
	       -L$(FIRMWARE_DIR)/LIBFEMTOC\
   	       -lfemtorv32 -lfemtoc -lm

OBJECTS=dhry_1.o dhry_2.o stubs.o

# Use progstart.S from parent dir for kernel-loadable program
PROGSTART=../progstart.o

$(PROGSTART): ../progstart.S
	$(RVAS) $(RVASFLAGS) $< -o $@

dhrystone.bin: $(PROGSTART) $(OBJECTS)
	$(RVLD) $(RVLDFLAGS) -T ../program.ld ./progstart.o $(OBJECTS) -o dhrystone.elf $(FEMTORV32_LIBS_EX) $(RVGCC_LIB)
	$(RVOBJCOPY) -O binary dhrystone.elf $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

all: dhrystone.bin

clean:
	rm -f *.o *.elf *.bin
