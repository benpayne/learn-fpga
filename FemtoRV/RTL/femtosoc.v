// femtorv32, a minimalistic RISC-V RV32I core
//    (minus SYSTEM and FENCE that are not implemented)
//
//       Bruno Levy, May-June 2020
//
// This file: the "System on Chip" that goes with femtorv32.

/*************************************************************************************/


`default_nettype none // Makes it easier to detect typos !

`include "femtosoc_config.v"        // User configuration of processor and SOC.
`include "PLL/femtopll.v"           // The PLL (generates clock at NRV_FREQ)

`include "DEVICES/uart.v"           // The UART (serial port over USB)
`include "DEVICES/SSD1351_1331.v"   // The OLED display
`include "DEVICES/MappedSPIFlash.v" // Idem, but mapped in memory
`include "DEVICES/MAX7219.v"        // 8x8 led matrix driven by a MAX7219 chip
`include "DEVICES/LEDs.v"           // Driver for 4 leds
`include "DEVICES/SDCard.v"         // Driver for SDCard (just for bitbanging for now)
`include "DEVICES/Buttons.v"        // Driver for the buttons
`include "DEVICES/FGA.v"            // Femto Graphic Adapter
`include "DEVICES/HardwareConfig.v" // Constant registers to query hardware config.
`include "DEVICES/segment.v"        // 7-segment display
`include "DEVICES/timer.v"          // Timer
`include "DEVICES/InterruptController.v" // Interrupt controller
`include "DEVICES/Interrupt_bits.v" // Interrupt controller
`include "DEVICES/PS2Decoder.v" // PS2 keyboard decoder

`ifdef NRV_IO_SDRAM
`include "SDRAM/muchtoremember_colorlight.v"
`include "SDRAM/muchtoremember_burst.v"
`include "SDRAM/sdram_arbiter.v"
`include "SDRAM/video_fetch_engine.v"
`include "SDRAM/video_line_fifo.v"
`include "DEVICES/cache.v"
`endif

`ifdef NRV_IO_SYNTH
`include "DEVICES/synth/fm_synth_soc.v"
`include "DEVICES/synth/fm_synth_registers.v"
`include "DEVICES/synth/fm_synth_tdm.v"
`include "DEVICES/synth/audio_ringbuf.v"
`include "DEVICES/synth/fm_sine_rom.v"
`include "DEVICES/synth/fm_algorithm.v"
`include "DEVICES/synth/i2s_tx.v"
`endif

`ifdef NRV_IO_GPU
// HDMI Display GPU library - character and graphics modes
`include "lib/hdmi-display-lib/rtl/core/tmds_encoder.v"
`include "lib/hdmi-display-lib/rtl/core/dvi_transmitter.v"
`include "lib/hdmi-display-lib/rtl/core/vga_timing_generator.v"
`include "lib/hdmi-display-lib/rtl/core/gpu_mux.v"
`include "lib/hdmi-display-lib/rtl/character/font_rom.v"
`include "lib/hdmi-display-lib/rtl/character/character_buffer.v"
`include "lib/hdmi-display-lib/rtl/character/character_renderer.v"
`include "lib/hdmi-display-lib/rtl/character/gpu_core.v"
`include "lib/hdmi-display-lib/rtl/character/gpu_registers.v"
`include "lib/hdmi-display-lib/rtl/graphics/gpu_graphics_core.v"
`include "lib/hdmi-display-lib/rtl/graphics/gpu_graphics_registers.v"
`include "lib/hdmi-display-lib/rtl/graphics/gpu_graphics_vram.v"
`include "lib/hdmi-display-lib/rtl/graphics/gpu_graphics_palette.v"
`include "lib/hdmi-display-lib/rtl/graphics/gpu_pixel_renderer.v"
`include "lib/hdmi-display-lib/rtl/graphics/gpu_scanline_renderer.v"
`include "lib/hdmi-display-lib/rtl/gpu_top.v"
`include "lib/hdmi-display-lib/wrappers/fpga/gpu_femtorv_wrapper.v"
`include "lib/hdmi-display-lib/clock/gpu_pll.v"
`endif

// The Ice40UP5K has ample quantities (128 KB) of single-ported RAM that can be
// used as system RAM (but cannot be inferred, uses a special block).
`ifdef ICE40UP5K_SPRAM
`include "DEVICES/ice40up5k_spram.v"
`endif

/*************************************************************************************/

`ifndef NRV_RESET_ADDR
 `define NRV_RESET_ADDR 0
`endif

`ifndef NRV_ADDR_WIDTH
 `define NRV_ADDR_WIDTH 24
`endif

/*************************************************************************************/

module femtosoc(
`ifdef NRV_IO_LEDS
 `ifdef FOMU
   output rgb0,rgb1,rgb2,
 `else
  `ifdef ACTIVE_LOW_LEDS
   output D1_pin,D2_pin,D3_pin,D4_pin,D5_pin,D6_pin,D7_pin,D8_pin,
  `else
   output D1,D2,D3,D4,D5,D6,D7,D8,
  `endif
 `endif
`endif	      
`ifdef NRV_IO_SSD1351_1331	      
   output oled_DIN, oled_CLK, oled_CS, oled_DC, oled_RST,
`endif
`ifdef NRV_IO_UART
   input  RXD,
   output TXD,
`endif	      
`ifdef NRV_IO_MAX7219	   
   output ledmtx_DIN, ledmtx_CS, ledmtx_CLK,
`endif
`ifdef NRV_SPI_FLASH
   inout spi_mosi, inout spi_miso, output spi_cs_n,
 `ifndef ULX3S	
   output spi_clk, // ULX3S has spi clk shared with ESP32, using USRMCLK (below)	
 `endif
`endif
`ifdef NRV_IO_SDCARD
   output sd_mosi, input sd_miso, output sd_cs_n, output sd_clk,
`endif
`ifdef NRV_IO_BUTTONS
   `ifdef ICE_FEATHER
      input [3:0] buttons, 
   `else
      input [5:0] buttons,
   `endif		
`endif
`ifdef ULX3S
   output wifi_en,		
`endif		
   input  RESET,
`ifdef FOMU
   output usb_dp, usb_dn, usb_dp_pu, 
`endif
`ifdef NRV_IO_FGA
   output [3:0] gpdi_dp,
`elsif NRV_IO_GPU
   output [3:0] gpdi_dp,
`endif
`ifdef NRV_IO_SDRAM
   output        sdram_clk,
   inout  [31:0] sd_d,
   output [10:0] sd_addr,
   output  [1:0] sd_ba,
   output        sd_we,
   output        sd_ras,
   output        sd_cas,
`endif
`ifdef NRV_IO_SYNTH
   output audio_pwm,
   output i2s_bclk,
   output i2s_lrck,
   output i2s_din,
   output i2s_sd,
`endif
`ifdef NRV_IO_IRDA
   output irda_TXD,
   input  irda_RXD,
   output irda_SD,		
`endif   		
`ifdef NRV_IO_SEGMENT
   output [6:0] segments,
   output seg_select,
`endif
`ifdef NRV_IO_PS2
   input ps2_clk,
   input ps2_data,
`endif
   input pclk
);

/********************* Technicalities **************************************/
   
// On the ULX3S, deactivate the ESP32 so that it does not interfere with 
// the other devices (especially the SDCard).
`ifdef ULX3S
   assign wifi_en = 1'b0;
`endif		

// On the ULX3S, the CLK pin of the SPI is multiplexed with the ESP32.
// It can be accessed using the USRMCLK primitive of the ECP5
// as follows.
`ifdef NRV_SPI_FLASH
 `ifdef ULX3S
   wire   spi_clk;
   wire   tristate = 1'b0;
   `ifndef BENCH   
      USRMCLK u1 (.USRMCLKI(spi_clk), .USRMCLKTS(tristate));
   `endif
  `endif
`endif

`ifdef FOMU
   // Internal wires for the LEDs,
   // need to convert to signal for RGB led
   wire D1,D2,D3,D4,D5;
   // On the FOMU, USB pins should be statically driven if not used
   assign usb_dp    = 1'b0;
   assign usb_dn    = 1'b0;
   assign usb_dp_pu = 1'b0;
`endif

`ifdef ACTIVE_LOW_LEDS
   // Internal wires for active-low LED boards (e.g. Colorlight i5)
   // All LED logic drives these active-high, inverted at pin output
   wire D1,D2,D3,D4,D5,D6,D7,D8;
   assign D1_pin = ~D1;
   assign D2_pin = ~D2;
   assign D3_pin = ~D3;
   assign D4_pin = ~D4;
   assign D5_pin = ~D5;
   assign D6_pin = ~D6;
   assign D7_pin = ~D7;
   assign D8_pin = ~D8;
`endif

  wire  clk;
   
  femtoPLL #(
    .freq(`NRV_FREQ)	     
  ) pll(
    .pclk(pclk), 
    .clk(clk)
  );

  // A little delay for sending the reset signal after startup.
  // Explanation here: (ice40 BRAM reads incorrect values during
  // first cycles).
  // http://svn.clifford.at/handicraft/2017/ice40bramdelay/README
  // On the ICE40-UP5K, 4096 cycles do not suffice (-> 65536 cycles)
`ifdef ICE_STICK
  reg [11:0] reset_cnt = 0;   
`else   
  reg [15:0] reset_cnt = 0;
`endif   
  wire       reset = &reset_cnt;

/* verilator lint_off WIDTH */   
`ifdef NRV_NEGATIVE_RESET
   always @(posedge clk,negedge RESET) begin
      if(!RESET) begin
	 reset_cnt <= 0;
      end else begin
	 reset_cnt <= reset_cnt + !reset;
      end
   end
`else
   always @(posedge clk,posedge RESET) begin
      if(RESET) begin
	 reset_cnt <= 0;
      end else begin
	 reset_cnt <= reset_cnt + !reset;
      end
   end
`endif
/* verilator lint_on WIDTH */   
   
/***************************************************************************************************
/*
 * Memory and memory interface
 * memory map:
 *   address[21:2] RAM word address (4 Mb max).
 *   address[23:22]   00: RAM
 *                    01: IO page (1-hot)  (starts at 0x400000)
 *                    10: SPI Flash page   (starts at 0x800000)
 */ 

   // The memory bus.
   wire [31:0] mem_address; // 24 bits are used internally. The two LSBs are ignored (using word addresses)
   wire  [3:0] mem_wmask;   // mem write mask and strobe /write Legal values are 000,0001,0010,0100,1000,0011,1100,1111
   wire [31:0] mem_rdata;   // processor <- (mem and peripherals) 
   wire [31:0] mem_wdata;   // processor -> (mem and peripherals)
   wire        mem_rstrb;   // mem read strobe. Goes high to initiate memory write.
   wire        mem_rbusy;   // processor <- (mem and peripherals). Stays high until a read transfer is finished.
   wire        mem_wbusy;   // processor <- (mem and peripherals). Stays high until a write transfer is finished.

   wire        mem_wstrb = |mem_wmask; // mem write strobe, goes high to initiate memory write (deduced from wmask)

   // IO bus.
`ifdef NRV_MAPPED_SPI_FLASH
   wire mem_address_is_ram       = (mem_address[23:22] == 2'b00);   
   wire mem_address_is_io        = (mem_address[23:22] == 2'b01);
   wire mem_address_is_spi_flash = (mem_address[23:22] == 2'b10);
   wire mapped_spi_flash_rbusy;
   wire [31:0] mapped_spi_flash_rdata;
   
   MappedSPIFlash mapped_spi_flash(
      .clk(clk),
      .rstrb(mem_rstrb && mem_address_is_spi_flash),
      .word_address(mem_address[21:2]),
      .rdata(mapped_spi_flash_rdata),
      .rbusy(mapped_spi_flash_rbusy),
      .CLK(spi_clk),
      .CS_N(spi_cs_n),
`ifdef SPI_FLASH_FAST_READ_DUAL_IO				   
      .IO({spi_miso,spi_mosi})
`else	
      .MISO(spi_miso),
      .MOSI(spi_mosi)
`endif				   
   );
`else   
   wire mem_address_is_io  =  mem_address[22] && !mem_address[23];
   wire mem_address_is_ram = !mem_address[22] && !mem_address[23];
`ifdef NRV_IO_SDRAM
   wire mem_address_is_sdram = mem_address[23];  // 0x800000-0xFFFFFF
`endif
`endif
      
   reg  [31:0] io_rdata; 
   wire [31:0] io_wdata = mem_wdata;
   wire        io_rstrb = mem_rstrb && mem_address_is_io;
   wire        io_wstrb = mem_wstrb && mem_address_is_io;
   wire [19:0] io_word_address = mem_address[21:2]; // word offset in io page
   wire	       io_rbusy; 
   wire        io_wbusy;
   
   assign      mem_rbusy = io_rbusy
`ifdef NRV_MAPPED_SPI_FLASH
    | mapped_spi_flash_rbusy
`endif
`ifdef NRV_IO_SDRAM
    | (mem_address_is_sdram & sdram_busy)
`endif
    ;

   assign      mem_wbusy = io_wbusy
`ifdef NRV_IO_SDRAM
    | (mem_address_is_sdram & sdram_busy)
`endif
    ; 

`ifdef NRV_IO_FGA
   wire mem_address_is_vram = mem_address[21];
`else
   parameter mem_address_is_vram = 1'b0;
`endif

   wire [19:0] ram_word_address = mem_address[21:2];

// Using the 128 KBytes of SPRAM (single-ported RAM) embedded in the Ice40 UP5K   
`ifdef ICE40UP5K_SPRAM

   wire [31:0]  ram_rdata;
   wire 	spram_wr = mem_address_is_ram && !mem_address_is_vram;
   ice40up5k_spram RAM(
      .clk(clk),
      .wen({4{spram_wr}} & mem_wmask),
      .addr(ram_word_address[14:0]),
      .wdata(mem_wdata),
      .rdata(ram_rdata)		       
   );

`else // Synthethizing BRAM

   (* no_rw_check *)
   reg [31:0] RAM[0:(`NRV_RAM/4)-1];
   reg [31:0] ram_rdata;

   // Initialize the RAM with the generated firmware hex file.
   // The hex file is generated by the bundled elf-2-verilog converter (see TOOLS/FIRMWARE_WORDS_SRC)
`ifndef NRV_RUN_FROM_SPI_FLASH  
   initial begin
      $readmemh("FIRMWARE/firmware.hex",RAM); 
   end
`endif

   // The power of YOSYS: it infers BRAM primitives automatically ! (and recognizes
   // masked writes, amazing ...)
   /* verilator lint_off WIDTH */
   always @(posedge clk) begin
      if(mem_address_is_ram && !mem_address_is_vram) begin
	 if(mem_wmask[0]) RAM[ram_word_address][ 7:0 ] <= mem_wdata[ 7:0 ];
	 if(mem_wmask[1]) RAM[ram_word_address][15:8 ] <= mem_wdata[15:8 ];
	 if(mem_wmask[2]) RAM[ram_word_address][23:16] <= mem_wdata[23:16];
	 if(mem_wmask[3]) RAM[ram_word_address][31:24] <= mem_wdata[31:24];	 
      end 
      ram_rdata <= RAM[ram_word_address];
   end
   /* verilator lint_on WIDTH */
`endif
   
`ifdef NRV_IO_FGA
   wire [31:0] FGA_rdata;
   FGA graphic_adapter(
      .pclk(pclk), // board clock		       
      .clk(clk),   // femtorv32 clock
		       
      .sel(mem_address_is_ram && mem_address_is_vram), 
      .mem_wmask(mem_wmask),
      .mem_address(mem_address[16:0]),
      .mem_wdata(mem_wdata),
		       
      .gpdi_dp(gpdi_dp), 

      .io_rstrb(io_rstrb),		  
      .io_wstrb(io_wstrb),			
      .sel_cntl(io_word_address[IO_FGA_CNTL_bit]),
      .sel_dat(io_word_address[IO_FGA_DAT_bit]),
      .rdata(FGA_rdata)		       
   );
`endif   
   
`ifdef NRV_IO_SDRAM
   // SDRAM controller (muchtoremember by Matthias Koch)
   // Directly connected to FemtoRV memory bus when address bit 23 is set
   wire [31:0] sdram_rdata;
   wire        sdram_busy;

   // SDRAM with cache
   wire [12:0] sd_addr_full;
   wire        sd_cs_unused;
   wire [3:0]  sd_dqm_unused;
   assign sd_addr = sd_addr_full[10:0];

   // Cache <-> Arbiter <-> SDRAM controller wires
   wire [3:0]  cache_sdram_wmask;
   wire        cache_sdram_rd;
   wire [25:0] cache_sdram_addr;
   wire [31:0] cache_sdram_din;
   wire [31:0] cache_sdram_dout;
   wire        cache_sdram_busy;

   // Arbiter <-> SDRAM controller wires
   wire [3:0]  arb_ctrl_wmask;
   wire        arb_ctrl_rd;
   wire [25:0] arb_ctrl_addr;
   wire [31:0] arb_ctrl_din;
   wire [31:0] arb_ctrl_dout;
   wire        arb_ctrl_busy;
   wire        arb_ctrl_burst_rd;
   wire [25:0] arb_ctrl_burst_addr;
   wire [8:0]  arb_ctrl_burst_len;
   wire [31:0] arb_ctrl_burst_dout;
   wire        arb_ctrl_burst_valid;
   wire        arb_ctrl_burst_done;
   wire        arb_ctrl_burst_busy;

   // Video fetch <-> Arbiter wires
   wire        vid_burst_rd;
   wire [25:0] vid_burst_addr;
   wire [8:0]  vid_burst_len;
   wire [31:0] vid_burst_dout;
   wire        vid_burst_valid;
   wire        vid_burst_busy;

   // Video FIFO wires
   wire [31:0] fifo_wdata;
   wire        fifo_wen;
   wire        fifo_full;
   wire [31:0] fifo_rd_data;
   wire        fifo_rd_en;
   wire        fifo_empty;

   // GPU timing pulses (from GPU wrapper, pixel clock domain)
   wire        gpu_hsync_start;
   wire        gpu_vsync_start;

   // Cache between CPU and arbiter
   sdram_cache cache (
      .clk(clk),
      .resetn(reset),
      .cpu_wmask(mem_address_is_sdram ? mem_wmask : 4'b0),
      .cpu_rd(mem_address_is_sdram & mem_rstrb),
      .cpu_addr(mem_address[22:0]),
      .cpu_din(mem_wdata),
      .cpu_dout(sdram_rdata),
      .cpu_busy(sdram_busy),
      .sdram_wmask(cache_sdram_wmask),
      .sdram_rd(cache_sdram_rd),
      .sdram_addr(cache_sdram_addr),
      .sdram_din(cache_sdram_din),
      .sdram_dout(cache_sdram_dout),
      .sdram_busy(cache_sdram_busy)
   );

   // SDRAM controller — original single-word controller
   // (Video fetch pipeline disabled until burst controller busy signal is fixed)
   muchtoremember sdram_ctrl (
      .clk(clk),
      .resetn(reset),
      .sd_clk(sdram_clk),
      .sd_d(sd_d),
      .sd_addr(sd_addr_full),
      .sd_ba(sd_ba),
      .sd_dqm(sd_dqm_unused),
      .sd_cs(sd_cs_unused),
      .sd_we(sd_we),
      .sd_ras(sd_ras),
      .sd_cas(sd_cas),
      .wmask(cache_sdram_wmask),
      .rd(cache_sdram_rd),
      .addr(cache_sdram_addr),
      .din(cache_sdram_din),
      .dout(cache_sdram_dout),
      .busy(cache_sdram_busy)
   );

   // Stub out video fetch signals (disabled for now)
   assign vid_burst_dout = 0;
   assign vid_burst_valid = 0;
   assign vid_burst_busy = 0;

   // Video fetch engine: DISABLED until burst controller is integrated
   // Stub: no fetching, FIFO stays empty, display_mode=2 shows black
   assign fifo_wdata = 0;
   assign fifo_wen = 0;

   /* Video fetch engine (disabled):
   video_fetch_engine #(
      .H_ACTIVE(640),
      .V_ACTIVE(400),
      .STRIDE_WORDS(320),
      .FB_BASE_PARAM(26'h810000)
   ) video_fetch (
      .clk(clk),
      .resetn(reset),
      .hsync_start(gpu_hsync_start),
      .vsync_start(gpu_vsync_start),
      .fb_base(26'h810000),    // TODO: make configurable via register
      .burst_rd(vid_burst_rd),
      .burst_addr(vid_burst_addr),
      .burst_len(vid_burst_len),
      .burst_dout(vid_burst_dout),
      .burst_valid(vid_burst_valid),
      .burst_busy(vid_burst_busy),
      .fifo_wdata(fifo_wdata),
      .fifo_wen(fifo_wen),
      .fifo_full(fifo_full),
      .line_num()
   );
   */

   // Video line FIFO: bridges SDRAM fetch (sys clock) to GPU (pixel clock)
   video_line_fifo fifo (
      .clk_w(clk),
      .rst_w(!reset),
      .wr_data(fifo_wdata),
      .wr_en(fifo_wen),
      .full(fifo_full),
      .almost_full(),
      .clk_r(clk_pixel),
      .rst_r(!reset),
      .rd_data(fifo_rd_data),
      .rd_en(fifo_rd_en),
      .empty(fifo_empty),
      .almost_empty(),
      .wr_fill()
   );
`endif

`ifdef NRV_MAPPED_SPI_FLASH
   assign mem_rdata = mem_address_is_io  ? io_rdata  :
		      mem_address_is_ram ? ram_rdata :
		      mapped_spi_flash_rdata;
`else
 `ifdef NRV_IO_SDRAM
   assign mem_rdata = mem_address_is_io    ? io_rdata :
                      mem_address_is_sdram ? sdram_rdata :
                      ram_rdata;
 `else
   assign mem_rdata = mem_address_is_io ? io_rdata : ram_rdata;
 `endif
`endif   
   
/***************************************************************************************************
/*
 * Memory-mapped IO
 * Mapped IO uses "one-hot" addressing, to make decoder
 * simpler (saves a lot of LUTs), as in J1/swapforth,
 * thanks to Matthias Koch(Mecrisp author) for the idea !
 * The included files contains the symbolic constants that
 * determine which device uses which bit.
 */  

`include "DEVICES/HardwareConfig_bits.v"   

/*
 * Devices are components plugged to the IO memory bus.
 * A few words follow in case you want to write your own devices:
 *
 * Each device has one or several register(s). Each register 
 * can be optionally read or/and written.
 * - Each register is selected by a .sel_xxx signal (where xxx
 *   is the name of the register). With the 1-hot encoding that 
 *   I'm using, .sel_xxx is systematically one of the bits of the 
 *   IO word address (it is also possible to write a real
 *   address decoder, at the expense of eating-up a larger 
 *   number of LUTs).
 * - If the device requires wait cycles for writing and/or reading, 
 *   it can have a .wbusy and/or .rbusy signal(s). All the .wbusy
 *   and .rbusy signals of all the devices are ORed at the end of
 *   this file to form the .io_rbusy and .io_wbusy signals.
 * - If the device has read access, then it has a 32-bits .xxx_rdata
 *   signal, that returns 32'b0 if the device is not selected, or the
 *   read data otherwise. All the .xxx_rdata signals of all the devices
 *   are ORed at the end of this file to form the 32-bits io_rdata signal.
 * - Finally, of course, each device is plugged to some pins of the FPGA,
 *   the corresponding signals are in capital letters. 
 */   


/*********************** Hardware configuration ************/
/*
 * Three memory-mapped constant registers that make it easy for
 * client code to query installed RAM and configured devices
 * (this one does not use any pin, of course).
 * Uses some LUTs, a bit stupid, but more comfortable, so that
 * I do not need to change the software on the SDCard each time 
 * I test a different hardware configuration.
 */
`ifdef NRV_IO_HARDWARE_CONFIG   
wire [31:0] hwconfig_rdata;
HardwareConfig hwconfig(
   .clk(clk),			
   .sel_memory(io_word_address[IO_HW_CONFIG_RAM_bit]),
   .sel_devices(io_word_address[IO_HW_CONFIG_DEVICES_bit]),
   .sel_cpuinfo(io_word_address[IO_HW_CONFIG_CPUINFO_bit]),			
   .rdata(hwconfig_rdata)			 
);
`endif
   
/********************* Interrupt Controller *****************************/
/*
 * Interrupt Controller to track what interrupts needs to be serviced
 */

`ifdef NRV_INTERRUPTS
   wire        interrupt_request;
`endif 

`ifdef NRV_IO_INT_CONTROLLER
   wire [31:0] interrupt_rdata;
   wire [31:0] interrupt_bits;
   InterruptController interrupt_controller(
      .rst(reset),
      .clk(clk),
      .wstrb(io_wstrb),			
      .rstrb(io_rstrb),			
      .sel(io_word_address[IO_INT_CONTROLLER_bit]),
      .wdata(io_wdata),		  
      .rdata(interrupt_rdata),
      .interrupts(interrupt_bits), 
      .interrupt_request(interrupt_request)
   );

`ifndef NRV_IO_TIMER
   assign interrupt_bits[INT_TIMER_bit]   = 1'b0;
`endif

`ifndef NRV_IO_PS2
   assign interrupt_bits[INT_PS2_bit]   = 1'b0;
`endif

   assign interrupt_bits[31:7]   = 25'b0;
`ifdef NRV_IO_SYNTH
   assign interrupt_bits[INT_SAMPLEBUF_bit] = samplebuf_irq;
`else
   assign interrupt_bits[INT_SAMPLEBUF_bit] = 1'b0;
`endif
`ifdef NRV_IO_GPU
   assign interrupt_bits[INT_SCANLINE_bit] = scanline_irq;
`else
   assign interrupt_bits[INT_SCANLINE_bit] = 1'b0;
`endif
`ifndef NRV_IO_GPU
   assign interrupt_bits[INT_GPU_bit]   = 1'b0;
`endif
   assign interrupt_bits[INT_UART_bit]    = 1'b0;
   assign interrupt_bits[INT_BUTTONS_bit] = 1'b0;
`endif

/*********************** Four LEDs ************************/
`ifdef NRV_IO_LEDS
   wire [31:0] leds_rdata;
   LEDDriver leds(
`ifdef NRV_IO_IRDA
      .irda_TXD(irda_TXD),
      .irda_RXD(irda_RXD),
      .irda_SD(irda_SD),		
`endif		  
      .clk(clk),
      .rstrb(io_rstrb),		  
      .wstrb(io_wstrb),			
      .sel(io_word_address[IO_LEDS_bit]),
      .wdata(io_wdata),		  
      .rdata(leds_rdata),
      .LED({D4,D3,D2,D1})
   );
`endif

/********************** SSD1351/SSD1331 oled display ******/
`ifdef NRV_IO_SSD1351_1331
   wire SSD1351_wbusy;
   SSD1351 oled_display(
      .clk(clk),
      .wstrb(io_wstrb),			
      .sel_cntl(io_word_address[IO_SSD1351_CNTL_bit]),
      .sel_cmd(io_word_address[IO_SSD1351_CMD_bit]),
      .sel_dat(io_word_address[IO_SSD1351_DAT_bit]),
      .sel_dat16(io_word_address[IO_SSD1351_DAT16_bit]),			
      .wdata(io_wdata),
      .wbusy(SSD1351_wbusy),
      .DIN(oled_DIN),
      .CLK(oled_CLK),
      .CS(oled_CS),
      .DC(oled_DC),
      .RST(oled_RST)
   );
`endif   

/********************** UART ****************************************/
`ifdef NRV_IO_UART

 // Internal wires to connect IO buffers to UART
 wire RXD_internal;
 wire TXD_internal;

 `ifdef COLORLIGHT_I5
 `define BUFFER_RX
 `elsif ULX3S
 `define BUFFER_RX
 `endif
 `ifdef BUFFER_RX
   `ifndef BENCH_OR_LINT
     // On the ULX3S, we need to latch RXD, using the latch
     // embedded in the input buffer. If we do not do that,
     // then we unpredictably get garbage on the UART.
     // The two primitives BB (bidirectional three-state buffer)
     // and IFS1P3BX (latch in IO pin) are interpreted by the
     // synthesis tool as an IO cell.
     wire RXD_btw;
     BB RXD_bb(
       .I(1'b0), 
       .O(RXD_btw), 
       .B(RXD), 
       .T(1'b1)
     );
     IFS1P3BX RXD_pin(
       .SCLK(clk),		    
       .D(RXD_btw),
       .Q(RXD_internal),
       .PD(1'b0)		    
     );
     assign TXD = TXD_internal; // For now, do not latch output (but we may need to)
     `define UART_IO_BUFFER
   `endif
 `endif
 
 // For other boards, we directly connect RXD and TXD to the UART (but we may need
 // to latch).
 `ifndef UART_IO_BUFFER
   assign RXD_internal = RXD;
   assign TXD = TXD_internal;
 `endif

   wire        uart_brk;
   wire [31:0] uart_rdata;
   UART uart(
      .clk(clk),
      .rstrb(io_rstrb),	     	     
      .wstrb(io_wstrb),
      .sel_dat(io_word_address[IO_UART_DAT_bit]),
      .sel_cntl(io_word_address[IO_UART_CNTL_bit]),	     
      .wdata(io_wdata),
      .rdata(uart_rdata),
      .RXD(RXD_internal),
      .TXD(TXD_internal),
      .brk(uart_brk)
   );
`else
   wire uart_brk = 1'b0;
`endif 

/********** MAX7219 led matrix driver *******************************/
`ifdef NRV_IO_MAX7219
   wire max7219_wbusy;
   MAX7219 max7219(
      .clk(clk),
      .wstrb(io_wstrb),
      .sel(io_word_address[IO_MAX7219_DAT_bit]),
      .wdata(io_wdata),
      .wbusy(max7219_wbusy),
      .DIN(ledmtx_DIN),
      .CS(ledmtx_CS),
      .CLK(ledmtx_CLK)		   
   );
`endif   
   
/********************* SPI SDCard  *********************************/
/*
 * This one has an output register directly wired to the CLK,MOSI,CS_N
 * and an input register directly wired to MISO. The software driver
 * implements the SPI protocol by bit-banging (see FIRMWARE/LIBFEMTORV32/spi_sd.c).
 * One day I'll replace it with a hardware driver... if I have time !
 * ... a generic SPI driver would be good to have also.
 */
`ifdef NRV_IO_SDCARD
   wire [31:0] sdcard_rdata;
   SDCard sdcard(
      .clk(clk),
      .rstrb(io_rstrb),
      .wstrb(io_wstrb), 
      .sel(io_word_address[IO_SDCARD_bit]),
      .wdata(io_wdata),
      .rdata(sdcard_rdata),
      .CLK(sd_clk),
      .MISO(sd_miso),		 
      .MOSI(sd_mosi),
      .CS_N(sd_cs_n)
   );
`endif

/********************* Buttons  *************************************/
/*
 * Directly wired to the buttons.
 */
`ifdef NRV_IO_BUTTONS
   wire [31:0] buttons_rdata;
   Buttons buttons_driver(
      .sel(io_word_address[IO_BUTTONS_bit]),
      .rdata(buttons_rdata),
      .BUTTONS(buttons)		   
   );
`endif
   
/********************* 7 Segment Display *************************************/
/*
 * 7 segment display device
 */
`ifdef NRV_IO_SEGMENT
   SevenSegment segment_driver(
      .clk(clk),
      .wstrb(io_wstrb),			
      .sel(io_word_address[IO_SEGMENT_bit]),
      .wdata(io_wdata),		  
      .segments(segments),
      .seg_select(seg_select)
   );
`endif


/********************* Timer Device with Interupts *****************************/
/*
 * Timer device with interrupts
 */
`ifdef NRV_IO_TIMER
   wire [31:0] timer_rdata;
   ClockTimer timer_driver(
      .clk(clk),
      .wstrb(io_wstrb),			
      .rstrb(io_rstrb),			
      .sel(io_word_address[IO_TIMER_bit]),
      .wdata(io_wdata),		  
      .rdata(timer_rdata),
`ifdef NRV_IO_INT_CONTROLLER
      .complete(interrupt_bits[INT_TIMER_bit]),
`else
      .complete(interrupt_request),
`endif
      .running(D7)
   );
`endif


/********************* PS2 Device with Interupts *****************************/
/*
 * PS2 device with interrupts
 */
`ifdef NRV_IO_PS2
   wire [31:0] ps2_rdata;
   wire [7:0] raw_value;
   ps2_decoder_device #(
      .CLK_FREQ_HZ(`NRV_FREQ * 1_000_000)
   ) PS2(
      .reset(reset),
      .clk(clk),
      .rstrb(io_rstrb),
      .rdata(ps2_rdata),
      .sel(io_word_address[IO_PS2_bit]),
`ifdef NRV_IO_INT_CONTROLLER
      .interrupt(interrupt_bits[INT_PS2_bit]),
`else
      .interrupt(interrupt_request),
`endif
      .data_ready(D8),
      .ps2_clk(ps2_clk),
      .ps2_data(ps2_data)
   );
`endif

/********************* HDMI Display GPU *************************************/
/*
 * HDMI Display GPU with character and graphics modes.
 * Uses ECP5 PLL for 25MHz pixel + 125MHz TMDS clocks.
 * ODDRX1F DDR primitives for TMDS serialization.
 */
`ifdef NRV_IO_GPU
   // GPU PLL: Generate pixel and TMDS clocks from system clock
   wire clk_pixel;
   wire clk_tmds;
   wire gpu_pll_locked;

   gpu_pll gpu_pll_inst(
      .clk_25mhz(pclk),      // Use raw board clock (25 MHz)
      .clk_pixel(clk_pixel),  // 25 MHz pixel clock
      .clk_tmds(clk_tmds),    // 125 MHz TMDS clock
      .locked(gpu_pll_locked)
   );

   // GPU wrapper instance
   wire [31:0] gpu_rdata;
   wire [1:0] tmds_clk_parallel;
   wire [1:0] tmds_red_parallel;
   wire [1:0] tmds_green_parallel;
   wire [1:0] tmds_blue_parallel;
   wire gpu_irq;
   wire scanline_irq;

   gpu_femtorv_wrapper gpu_inst(
      .clk(clk),
      .reset(reset & gpu_pll_locked),  // Hold GPU in reset until PLL locks
      .wdata(io_wdata),
      .rdata(gpu_rdata),
      .wstrb(io_wstrb),
      .rstrb(io_rstrb),
      .sel(io_word_address[IO_GPU_bit]),

      .clk_pixel(clk_pixel),
      .clk_tmds(clk_tmds),

      .tmds_clk_out(tmds_clk_parallel),
      .tmds_red_out(tmds_red_parallel),
      .tmds_green_out(tmds_green_parallel),
      .tmds_blue_out(tmds_blue_parallel),

      .gpu_irq(gpu_irq),
      .scanline_irq(scanline_irq),
      .hsync_start(gpu_hsync_start),
      .vsync_start(gpu_vsync_start),
      .fb_pixel_data(fifo_rd_data),
      .fb_pixel_valid(!fifo_empty),
      .fb_pixel_rd(fifo_rd_en)
   );

 `ifdef NRV_IO_INT_CONTROLLER
   assign interrupt_bits[INT_GPU_bit] = gpu_irq;
 `endif

 `ifndef BENCH
   // ECP5 DDR output primitives for TMDS serialization
   // Must be at top level, directly connected to output pins
   ODDRX1F ddr_clk(
      .D0(tmds_clk_parallel[0]),
      .D1(tmds_clk_parallel[1]),
      .Q(gpdi_dp[3]),
      .SCLK(clk_tmds),
      .RST(1'b0)
   );

   ODDRX1F ddr_red(
      .D0(tmds_red_parallel[0]),
      .D1(tmds_red_parallel[1]),
      .Q(gpdi_dp[2]),
      .SCLK(clk_tmds),
      .RST(1'b0)
   );

   ODDRX1F ddr_green(
      .D0(tmds_green_parallel[0]),
      .D1(tmds_green_parallel[1]),
      .Q(gpdi_dp[1]),
      .SCLK(clk_tmds),
      .RST(1'b0)
   );

   ODDRX1F ddr_blue(
      .D0(tmds_blue_parallel[0]),
      .D1(tmds_blue_parallel[1]),
      .Q(gpdi_dp[0]),
      .SCLK(clk_tmds),
      .RST(1'b0)
   );
 `endif

`endif

/********************* FM Synthesizer *************************************/
`ifdef NRV_IO_SYNTH
   wire [31:0] synth_rdata_raw;
   wire samplebuf_irq;
   wire synth_sel = io_word_address[IO_SYNTH_bit];
   wire [31:0] synth_rdata = synth_sel ? synth_rdata_raw : 32'b0;
   fm_synth_soc synth_inst(
      .clk(clk),
      .reset(reset),
      .wdata(io_wdata),
      .wstrb(io_wstrb),
      .rstrb(io_rstrb),
      .sel(io_word_address[IO_SYNTH_bit]),
      .rdata(synth_rdata_raw),
      .samplebuf_irq(samplebuf_irq),
      .audio_pwm(audio_pwm),
      .i2s_bclk(i2s_bclk),
      .i2s_lrck(i2s_lrck),
      .i2s_din(i2s_din)
   );
   assign i2s_sd = 1'b1;  // MAX98357A enable (active-high)
`endif

/************** io_rdata, io_rbusy and io_wbusy signals *************/

/*
 * io_rdata is latched. Not mandatory, but probably allow higher freq, to be tested.
 */
always @(posedge clk) begin
   io_rdata <= 0
`ifdef NRV_IO_HARDWARE_CONFIG	       
       | hwconfig_rdata
`endif	       
`ifdef NRV_IO_LEDS      
	    | leds_rdata
`endif
`ifdef NRV_IO_UART
	    | uart_rdata
`endif	    
`ifdef NRV_IO_SDCARD
	    | sdcard_rdata
`endif
`ifdef NRV_IO_BUTTONS
	    | buttons_rdata
`endif
`ifdef NRV_IO_FGA
	    | FGA_rdata
`endif
`ifdef NRV_IO_TIMER
	    | timer_rdata
`endif
`ifdef NRV_IO_INT_CONTROLLER
	    | interrupt_rdata
`endif
`ifdef NRV_IO_PS2
	    | ps2_rdata
`endif
`ifdef NRV_IO_GPU
	    | gpu_rdata
`endif
`ifdef NRV_IO_SYNTH
	    | synth_rdata
`endif
	    ;
end

   // For now, we got no device that has
   // blocking reads (SPI flash blocks on
   // write address and waits for read data).
   assign io_rbusy = 0 ; 

   assign io_wbusy = 0
`ifdef NRV_IO_SSD1351_1331
	| SSD1351_wbusy
`endif
`ifdef NRV_IO_MAX7219
	| max7219_wbusy
`endif		   
`ifdef NRV_IO_SPI_FLASH
        | spi_flash_wbusy
`endif		   
; 

/****************************************************************/
/* And last but not least, the processor                        */
   
  reg error=1'b0;

   
  FemtoRV32 #(
     .ADDR_WIDTH(`NRV_ADDR_WIDTH),
     .RESET_ADDR(`NRV_RESET_ADDR)	      
  ) processor(
    .clk(clk),			
    .mem_addr(mem_address),
    .mem_wdata(mem_wdata),
    .mem_wmask(mem_wmask),
    .mem_rdata(mem_rdata),
    .mem_rstrb(mem_rstrb),
    .mem_rbusy(mem_rbusy),
    .mem_wbusy(mem_wbusy),
`ifdef NRV_INTERRUPTS
`ifdef NRV_IO_INT_CONTROLLER
    .interrupt_request(interrupt_request),	      
`else
    .interrupt_request(interrupt_request),	      
`endif
`endif     
    .reset(reset)
  );

`ifdef NRV_IO_LEDS
   assign D5 = error;
`ifdef NRV_INTERRUPTS
   assign D6 = interrupt_request;
`endif
 `ifdef FOMU
    SB_RGBA_DRV #(
        .CURRENT_MODE("0b1"),       // half current
        .RGB0_CURRENT("0b000011"),  // 4 mA
        .RGB1_CURRENT("0b000011"),  // 4 mA
        .RGB2_CURRENT("0b000011")   // 4 mA
    ) RGBA_DRIVER (
        .CURREN(1'b1),
        .RGBLEDEN(1'b1),
        .RGB0PWM(D1), 
        .RGB1PWM(D2), 
        .RGB2PWM(D3), 
        .RGB0(rgb0),
        .RGB1(rgb1),
        .RGB2(rgb2)
    );
 `endif
`endif
   
endmodule
