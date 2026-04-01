
include ../makefile.inc

KERNEL_SRCS = os_main.c os_shell.c os_file.c os_loader.c os_syscall.c
KERNEL_OBJS = $(KERNEL_SRCS:.c=.o)

KERNEL_LIBS = $(FIRMWARE_DIR)/CRT/syscalls.o \
	-L$(RVTOOLCHAIN_LIB_DIR) \
	-L$(FIRMWARE_DIR)/CRT \
	-L$(FIRMWARE_DIR)/LIBFEMTORV32 \
	-L$(FIRMWARE_DIR)/LIBFEMTOC \
	-lfemtorv32 -lfemtoc -lm

CFLAGS_EXTRA = -I.

%.o: %.c
	$(RVGCC) $(RVCFLAGS) $(CFLAGS_EXTRA) -c $< -o $@

retrokernel.bin: $(KERNEL_OBJS)
	$(RVLD) $(RVLDFLAGS) --print-memory-usage -T retrokernel.ld \
		$(KERNEL_OBJS) -o retrokernel.elf $(KERNEL_LIBS) $(RVGCC_LIB)
	$(RVOBJCOPY) -O binary retrokernel.elf $@
	@echo "Built $@ ($$(stat -c%s $@) bytes)"

upload: retrokernel.bin
	python3 ../../TOOLS/xmodem_upload.py $< /dev/ttyACM0 800000

all: retrokernel.bin

clean:
	rm -f *.o *.elf *.bin

