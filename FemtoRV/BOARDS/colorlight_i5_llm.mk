# NOTE: -DCOLORLIGHT_I5 is required in addition to -DCOLORLIGHT_I5_LLM.
# FemtoRV/RTL/PLL/femtopll.v selects the board PLL via `elsif COLORLIGHT_I5`
# (checked after `ifdef COLORLIGHT_I5_LLM`); without -DCOLORLIGHT_I5,
# femtoPLL is left undefined and synthesis fails.
#
# NOTE: -Ilib/ps2-controller-lib is still required even though this profile
# has no PS2 keyboard: RTL/femtosoc.v unconditionally `includes
# DEVICES/PS2Decoder.v (it is not guarded by `ifdef NRV_IO_PS2`), and that
# file unconditionally includes the ps2-controller-lib wrapper, which in
# turn uses relative includes resolved against this -I path. Omitting it
# makes yosys read_verilog fail even though no PS2 pins exist in this
# profile's .lpf. The hdmi-display-lib path, by contrast, IS only needed
# under `ifdef NRV_IO_GPU` in femtosoc.v, so it is correctly dropped here.
YOSYS_COLORLIGHT_I5_LLM_OPT=-DCOLORLIGHT_I5 -DCOLORLIGHT_I5_LLM -DACTIVE_LOW_LEDS -q -p "read_verilog -Ilib/ps2-controller-lib -DCOLORLIGHT_I5 -DCOLORLIGHT_I5_LLM -DACTIVE_LOW_LEDS $(VERILOGS); synth_ecp5 -abc9 -top $(PROJECTNAME) -json $(PROJECTNAME).json"
NEXTPNR_COLORLIGHT_I5_LLM_OPT=--force --timing-allow-fail --json $(PROJECTNAME).json --lpf BOARDS/colorlight_i5_llm.lpf \
                  --textcfg $(PROJECTNAME)_out.config --25k --freq 25 --package CABGA381


#######################################################################################################################


colorlight_i5_llm: colorlight_i5_llm.firmware_config colorlight_i5_llm.synth colorlight_i5_llm.prog

colorlight_i5_llm.fast: colorlight_i5_llm.firmware_config colorlight_i5_llm.synth colorlight_i5_llm.prog_fast

colorlight_i5_llm.synth: FIRMWARE/firmware.hex
	yosys $(YOSYS_COLORLIGHT_I5_LLM_OPT)
	nextpnr-ecp5 $(NEXTPNR_COLORLIGHT_I5_LLM_OPT)
	ecppack --compress --svf-rowsize 100000 --svf $(PROJECTNAME).svf $(PROJECTNAME)_out.config $(PROJECTNAME).bit

colorlight_i5_llm.prog_fast: FIRMWARE/firmware.hex # program once (lost if device restarted)
	sudo openFPGALoader -c cmsisdap -v --file-type bin $(PROJECTNAME).bit

colorlight_i5_llm.prog: # program permanently
	sudo openFPGALoader -c cmsisdap -v -f --unprotect-flash --file-type bin $(PROJECTNAME).bit

colorlight_i5_llm.firmware_config:
	BOARD=colorlight_i5_llm TOOLS/make_config.sh -DCOLORLIGHT_I5 -DCOLORLIGHT_I5_LLM
	(cd FIRMWARE && make libs)

colorlight_i5_llm.lint:
	verilator -DCOLORLIGHT_I5 -DCOLORLIGHT_I5_LLM -DBENCH --lint-only --top-module $(PROJECTNAME) \
         -IRTL -IRTL/PROCESSOR -IRTL/DEVICES -IRTL/PLL -Ilib/ps2-controller-lib $(VERILOGS)
