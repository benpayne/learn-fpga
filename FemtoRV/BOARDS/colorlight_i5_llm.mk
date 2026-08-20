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
# Artifact basename for this profile. The display profile uses $(PROJECTNAME)
# (= femtosoc) for its .json/.bit/_out.config/.svf; if this profile did the
# same, the two would overwrite each other -- concurrent runs corrupting each
# other's netlist, and sequential runs leaving a femtosoc.bit whose name does
# not say which profile is inside it. Flashing the wrong profile looks like a
# hardware fault, not a build accident (research R20). The Verilog top module
# is still $(PROJECTNAME); only the output files are renamed.
LLM_ARTIFACT=femtosoc_llm

# synth_ecp5's coarse stage, with the `share` pass omitted. `share` is a
# SAT-based resource-sharing optimisation; on RTL/ACCEL/acc_mac.v it does not
# terminate -- it grew to 21 GB RSS and was OOM-killed, and reproduces
# standalone in seconds (research R21). acc_mac's combinational fp32
# functions produce ~780 muxes for the SAT solver to reason over, and the
# problem is intractable rather than merely slow. Everything else in
# synth_ecp5 is unchanged, `share` is an optimisation and not required for
# correctness, and skipping it is measured at a few hundred LUTs.
#
# This is deliberately scoped to THIS profile. The display profile's flow is
# untouched, so its regression baseline stays comparable (constitution
# Principle V).
YOSYS_LLM_COARSE=proc; flatten; tribuf -logic; deminout; opt_expr; opt_clean; check; \
                 opt -nodffe -nosdff; fsm; opt; wreduce; peepopt; opt_clean; \
                 techmap -map +/cmp2lut.v -D LUT_WIDTH=4; opt_expr; opt_clean; \
                 techmap -map +/mul2dsp.v -map +/ecp5/dsp_map.v -D DSP_A_MAXWIDTH=18 \
                   -D DSP_B_MAXWIDTH=18 -D DSP_A_MINWIDTH=2 -D DSP_B_MINWIDTH=2 \
                   -D DSP_NAME=\$$__MUL18X18; \
                 chtype -set \$$mul t:\$$__soft_mul; \
                 alumacc; opt; memory -nomap; opt_clean

YOSYS_COLORLIGHT_I5_LLM_OPT=-DCOLORLIGHT_I5 -DCOLORLIGHT_I5_LLM -DACTIVE_LOW_LEDS -q -p "read_verilog -Ilib/ps2-controller-lib -IRTL/ACCEL -DCOLORLIGHT_I5 -DCOLORLIGHT_I5_LLM -DACTIVE_LOW_LEDS $(VERILOGS); synth_ecp5 -abc9 -top $(PROJECTNAME) -run begin:coarse; $(YOSYS_LLM_COARSE); synth_ecp5 -abc9 -top $(PROJECTNAME) -run map_ram:; write_json $(LLM_ARTIFACT).json; stat"
NEXTPNR_COLORLIGHT_I5_LLM_OPT=--force --timing-allow-fail --json $(LLM_ARTIFACT).json --lpf BOARDS/colorlight_i5_llm.lpf \
                  --textcfg $(LLM_ARTIFACT)_out.config --25k --freq 25 --package CABGA381


#######################################################################################################################


colorlight_i5_llm: colorlight_i5_llm.firmware_config colorlight_i5_llm.synth colorlight_i5_llm.prog

colorlight_i5_llm.fast: colorlight_i5_llm.firmware_config colorlight_i5_llm.synth colorlight_i5_llm.prog_fast

colorlight_i5_llm.synth: FIRMWARE/firmware.hex
	yosys $(YOSYS_COLORLIGHT_I5_LLM_OPT)
	nextpnr-ecp5 $(NEXTPNR_COLORLIGHT_I5_LLM_OPT)
	ecppack --compress --svf-rowsize 100000 --svf $(LLM_ARTIFACT).svf $(LLM_ARTIFACT)_out.config $(LLM_ARTIFACT).bit

colorlight_i5_llm.prog_fast: FIRMWARE/firmware.hex # program once (lost if device restarted)
	sudo openFPGALoader -c cmsisdap -v --file-type bin $(LLM_ARTIFACT).bit

colorlight_i5_llm.prog: # program permanently
	sudo openFPGALoader -c cmsisdap -v -f --unprotect-flash --file-type bin $(LLM_ARTIFACT).bit

colorlight_i5_llm.firmware_config:
	BOARD=colorlight_i5_llm TOOLS/make_config.sh -DCOLORLIGHT_I5 -DCOLORLIGHT_I5_LLM
	(cd FIRMWARE && make libs)

colorlight_i5_llm.lint:
	verilator -DCOLORLIGHT_I5 -DCOLORLIGHT_I5_LLM -DBENCH --lint-only --top-module $(PROJECTNAME) \
         -IRTL -IRTL/PROCESSOR -IRTL/DEVICES -IRTL/PLL -Ilib/ps2-controller-lib $(VERILOGS)
