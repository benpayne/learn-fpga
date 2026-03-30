PROJ = fm_synth_top
SOURCES = fm_synth_top.v fm_synth_tdm.v fm_sine_rom.v fm_algorithm.v i2s_tx.v

# Colorlight i5: ECP5-25K, CABGA381, speed grade 6
DEVICE  = --25k
PACKAGE = CABGA381
SPEED   = --speed 6
LPF     = colorlight_i5.lpf

.PHONY: all prog clean test

all: $(PROJ).bit

$(PROJ).json: $(SOURCES) sine_table.hex
	yosys -p "synth_ecp5 -abc9 -top $(PROJ) -json $@" $(SOURCES)

$(PROJ).config: $(PROJ).json
	nextpnr-ecp5 $(DEVICE) --package $(PACKAGE) $(SPEED) \
		--json $< --lpf $(LPF) --textcfg $@ --freq 25 --force

$(PROJ).bit: $(PROJ).config
	ecppack --compress $< --bit $@

prog: $(PROJ).bit
	openFPGALoader -c cmsisdap -v --file-type bin $<

prog_flash: $(PROJ).bit
	openFPGALoader -c cmsisdap -v -f --unprotect-flash --file-type bin $<

# ---- Tests (requires iverilog) ----

test: test_operator test_envelope test_synth
	@echo "All tests passed."

test_operator: tests/tb_fm_operator.v fm_operator.v
	iverilog -o tests/tb_fm_operator.out $^ && vvp tests/tb_fm_operator.out

test_envelope: tests/tb_fm_envelope.v fm_envelope.v
	iverilog -o tests/tb_fm_envelope.out $^ && vvp tests/tb_fm_envelope.out

test_synth: tests/tb_fm_synth.v fm_synth.v fm_operator.v fm_envelope.v
	iverilog -o tests/tb_fm_synth.out $^ && vvp tests/tb_fm_synth.out

clean:
	rm -f $(PROJ).json $(PROJ).config $(PROJ).bit $(PROJ).svf
	rm -f tests/*.out tests/*.vcd
