YOSYS_COLORLIGHT_I5_OPT=-DCOLORLIGHT_I5 -DACTIVE_LOW_LEDS -q -p "read_verilog -Ilib/ps2-controller-lib -DCOLORLIGHT_I5 -DACTIVE_LOW_LEDS $(VERILOGS); synth_ecp5 -abc9 -top $(PROJECTNAME) -json $(PROJECTNAME).json"
NEXTPNR_COLORLIGHT_I5_OPT=--force --timing-allow-fail --json $(PROJECTNAME).json --lpf BOARDS/colorlight_i5.lpf \
                  --textcfg $(PROJECTNAME)_out.config --25k --freq 25 --package CABGA381


#######################################################################################################################


colorlight_i5: colorlight_i5.firmware_config colorlight_i5.synth colorlight_i5.prog

colorlight_i5.fast: colorlight_i5.firmware_config colorlight_i5.synth colorlight_i5.prog_fast

colorlight_i5.synth: FIRMWARE/firmware.hex
	yosys $(YOSYS_COLORLIGHT_I5_OPT)
	nextpnr-ecp5 $(NEXTPNR_COLORLIGHT_I5_OPT)
	ecppack --compress --svf-rowsize 100000 --svf $(PROJECTNAME).svf $(PROJECTNAME)_out.config $(PROJECTNAME).bit

colorlight_i5.show: FIRMWARE/firmware.hex 
	yosys $(YOSYS_ULX3S_OPT) $(VERILOGS)
	nextpnr-ecp5 $(NEXTPNR_ULX3S_OPT) --gui

colorlight_i5.prog_fast: FIRMWARE/firmware.hex # program once (lost if device restarted)
	#ujprog $(PROJECTNAME).bit           
	sudo openFPGALoader -c cmsisdap -v --file-type bin $(PROJECTNAME).bit

colorlight_i5.prog: # program permanently
	sudo openFPGALoader -c cmsisdap -v -f --unprotect-flash --file-type bin $(PROJECTNAME).bit

colorlight_i5.firmware_config:
	BOARD=colorlight_i5 TOOLS/make_config.sh -DCOLORLIGHT_I5
	(cd FIRMWARE && make libs)	
	(cd FIRMWARE/blinky && make clean blinky.hex)
	
colorlight_i5.lint:
	verilator -DCOLORLIGHT_I5 -DBENCH --lint-only --top-module $(PROJECTNAME) \
         -IRTL -IRTL/PROCESSOR -IRTL/DEVICES -IRTL/PLL $(VERILOGS)
