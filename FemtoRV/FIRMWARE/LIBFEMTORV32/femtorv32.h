#ifndef H__FEMTORV32__H
#define H__FEMTORV32__H

#include "HardwareConfig_bits.h"
#include <stdint.h>

/* 
 * On the IceStick, code is entirely executed from the (slow) SPI flash,
 * except for functions marked as fastcode that will be loaded in the
 * (much faster) RAM (but use it wisely, you only got 7kB).
 * Other devices are sufficient RAM to load all the code.
 */
#if defined(ICE_STICK) || defined(ICE_BREAKER)
#define RV32_FASTCODE __attribute((section(".fastcode")))
#else
#define RV32_FASTCODE
#endif

/* Standard library */
extern int  printf(const char *fmt,...); /* supports %s, %d, %x */
extern void exit(int);
extern void abort();
extern int  getchar();
extern int  putchar(int c);
extern int  puts(const char* s);

/* Timing */
extern uint64_t cycles();            /* gets the number of cycles since last reset       (needs NRV_COUNTERS_64) */
extern uint64_t milliseconds();      /* gets the number of milliseconds since last reset (needs NRV_COUNTERS_64) */
extern void wait_cycles(int cycles); /* waits for a number of cycles.       */
extern void milliwait(int ms);       /* waits for a number of milliseconds. */
extern void microwait(int us);       /* waits for a number of microseconds. */
#define delay(ms) milliwait(ms)

/* System */

extern int filesystem_init(); /* 
			       * needs to be called to access files on SDCard (fopen(),fread()...) 
			       * returns 0 on success, non-zero on error.
			       */

extern int exec(const char* filename, int argc, char** argv);
                                       /* 
					* Executes a program from the SDCard. 
					* Returns a non-zero number on error.
					* does not return on success !
					* Supports risc-v elves (.elf) and
					* flat binaries (.bin).
					*/
/* Virtual I/O */
typedef int (*putcharfunc_t)(int);
typedef int (*getcharfunc_t)(void);
void set_putcharfunc(putcharfunc_t fptr);
void set_getcharfunc(getcharfunc_t fptr);

/* Specialized print functions (but one can use printf() instead) */
extern void print_string(const char* s);
extern void print_dec(int val);
extern void print_hex_digits(unsigned int val, int digits);
extern void print_hex(unsigned int val);

/* SDCard */
int sd_init(); /* Return 0 on success, non-zero on failure */
int sd_readsector(uint32_t sector, uint8_t* buffer, uint32_t sector_count); /* 1:success, 0:failure*/
int sd_writesector(uint32_t sector, uint8_t* buffer, uint32_t sector_count); /* 1:success, 0:failure*/


/********************* Memory-mapped IO *******************************************************/

#define IO_BASE      0x400000 /* Base address of memory-mapped IO */

/* Converts a memory-mapped register bit into the corresponding offset to be added to IO_BASE */
#define IO_BIT_TO_OFFSET(io_bit) (1 << (2+(io_bit)))  

/* All the memory-mapped hardware registers */
#define IO_LEDS              IO_BIT_TO_OFFSET(IO_LEDS_bit)
#define IO_SSD1351_CNTL      IO_BIT_TO_OFFSET(IO_SSD1351_CNTL_bit)
#define IO_SSD1351_CMD       IO_BIT_TO_OFFSET(IO_SSD1351_CMD_bit)
#define IO_SSD1351_DAT       IO_BIT_TO_OFFSET(IO_SSD1351_DAT_bit)
#define IO_SSD1351_DAT16     IO_BIT_TO_OFFSET(IO_SSD1351_DAT16_bit)
#define IO_UART_CNTL         IO_BIT_TO_OFFSET(IO_UART_CNTL_bit)
#define IO_UART_DAT          IO_BIT_TO_OFFSET(IO_UART_DAT_bit)
#define IO_MAX7219           IO_BIT_TO_OFFSET(IO_MAX7219_DAT_bit)
#define IO_SPI_FLASH         IO_BIT_TO_OFFSET(IO_SPI_FLASH_bit)
#define IO_SDCARD            IO_BIT_TO_OFFSET(IO_SDCARD_bit)
#define IO_BUTTONS           IO_BIT_TO_OFFSET(IO_BUTTONS_bit)
#define IO_FGA_CNTL          IO_BIT_TO_OFFSET(IO_FGA_CNTL_bit)
#define IO_FGA_DAT           IO_BIT_TO_OFFSET(IO_FGA_DAT_bit)    
#define IO_SEGMENT			 IO_BIT_TO_OFFSET(IO_SEGMENT_bit)
#define IO_TIMER             IO_BIT_TO_OFFSET(IO_TIMER_bit)
#define IO_INT_CONTROLLER    IO_BIT_TO_OFFSET(IO_INT_CONTROLLER_bit)
#define IO_PS2               IO_BIT_TO_OFFSET(IO_PS2_bit)
#define IO_HW_CONFIG_RAM     IO_BIT_TO_OFFSET(IO_HW_CONFIG_RAM_bit)
#define IO_HW_CONFIG_DEVICES IO_BIT_TO_OFFSET(IO_HW_CONFIG_DEVICES_bit)
#define IO_HW_CONFIG_CPUINFO IO_BIT_TO_OFFSET(IO_HW_CONFIG_CPUINFO_bit)

/*
 * GPU (HDMI Character + Graphics display)
 *
 * Uses a single 1-hot IO address. The GPU register index is packed
 * into wdata[12:8] alongside the value in wdata[7:0]:
 *
 *   Write: IO_OUT(IO_GPU, (reg << 8) | value)
 *   Read:  IO_OUT(IO_GPU, reg << 8); val = IO_IN(IO_GPU) & 0xFF;
 */
#define IO_GPU               IO_BIT_TO_OFFSET(IO_GPU_bit)

/* GPU register addresses (packed into wdata[12:8]) */
#define GPU_REG_CHAR_DATA    0x10  /* WO: write char at cursor, auto-advance */
#define GPU_REG_CURSOR_ROW   0x11  /* RW: cursor row (0-29) */
#define GPU_REG_CURSOR_COL   0x12  /* RW: cursor column (0-39/79) */
#define GPU_REG_CONTROL      0x13  /* WO: bit0=clear, bit1=80col, bit2=cursor_en */
#define GPU_REG_FG_COLOR     0x14  /* RW: foreground (3-bit RGB) */
#define GPU_REG_BG_COLOR     0x15  /* RW: background (3-bit RGB) */
#define GPU_REG_STATUS       0x16  /* RO: bit0=ready, bit1=vsync */

/* GPU write helper: packs register + value into single IO write */
#define GPU_WRITE(reg, val)  IO_OUT(IO_GPU, ((reg) << 8) | ((val) & 0xFF))

/* GPU read helper: select register then read */
#define GPU_READ(reg) (IO_OUT(IO_GPU, (reg) << 8), IO_IN(IO_GPU) & 0xFF)

/* GPU control register bits */
#define GPU_CTRL_CLEAR       0x01
#define GPU_CTRL_80COL       0x02
#define GPU_CTRL_CURSOR_EN   0x04

/* GPU color values (4-bit IRGB, CGA 16-color palette) */
#define GPU_BLACK          0x00
#define GPU_BLUE           0x01
#define GPU_GREEN          0x02
#define GPU_CYAN           0x03
#define GPU_RED            0x04
#define GPU_MAGENTA        0x05
#define GPU_BROWN          0x06
#define GPU_LIGHT_GRAY     0x07
#define GPU_DARK_GRAY      0x08
#define GPU_BRIGHT_BLUE    0x09
#define GPU_BRIGHT_GREEN   0x0A
#define GPU_BRIGHT_CYAN    0x0B
#define GPU_BRIGHT_RED     0x0C
#define GPU_BRIGHT_MAGENTA 0x0D
#define GPU_YELLOW         0x0E
#define GPU_WHITE          0x0F

#define IO_IN(port)       *(volatile uint32_t*)(IO_BASE + port)
#define IO_OUT(port,val)  *(volatile uint32_t*)(IO_BASE + port)=(val)
#define LEDS(val)         IO_OUT(IO_LEDS,val)

#define CLEAR_INT(bit)		IO_OUT(IO_INT_CONTROLLER,1<<bit)

#define FEMTOSOC_HAS_DEVICE(bit)  (IO_IN(IO_HW_CONFIG_DEVICES) & (1 << bit))
#define FEMTORV32_FREQ           ((IO_IN(IO_HW_CONFIG_CPUINFO) >> 16) & 1023)
#define FEMTORV32_COUNTER_BITS    (IO_IN(IO_HW_CONFIG_CPUINFO) & 127)


/* SSD1331/SSD1351 Oled display on 4-wire SPI bus */

#if defined(SSD1351)
#define OLED_WIDTH  128
#define OLED_HEIGHT 128
#endif

#if defined(SSD1331)
#define OLED_WIDTH  96
#define OLED_HEIGHT 64
#endif

#ifndef OLED_WIDTH
#define OLED_WIDTH 0
#endif

#ifndef OLED_HEIGHT
#define OLED_HEIGHT 0
#endif

extern void oled_init();
extern void oled_write_window(uint32_t x1, uint32_t y1, uint32_t x2, uint32_t y2);
extern void oled0(uint32_t cmd);
extern void oled1(uint32_t cmd, uint32_t arg1);
extern void oled2(uint32_t cmd, uint32_t arg1, uint32_t arg2);
extern void oled3(uint32_t cmd, uint32_t arg1, uint32_t arg2, uint32_t arg3);

/* MAX7219 led matrix */
extern void MAX7219_init();
extern void MAX7219(uint32_t address, uint32_t value);

#define MIN(x,y) (((x) < (y)) ? (x) : (y))
#define MAX(x,y) (((x) > (y)) ? (x) : (y))
#define SGN(x)   (((x) > (0)) ? 1 : ((x) ? -1 : 0))

/* Mapped SPI FLASH */
#define SPI_FLASH_BASE ((void*)(1 << 23))

/* FAT_IO_LIB */
#define USE_FILELIB_STDIO_COMPAT_NAMES
#define FAT_INLINE inline
#include <fat_io_lib/fat_filelib.h>

#endif
