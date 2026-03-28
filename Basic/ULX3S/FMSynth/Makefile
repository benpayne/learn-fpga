PROJ = fm_synth_top
SOURCES = fm_synth_top.v fm_synth.v fm_operator.v fm_envelope.v

DEVICE  = --85k
PACKAGE = CABGA381
LPF     = ulx3s.lpf

.PHONY: all prog prog_flash clean

all: $(PROJ).bit

$(PROJ).json: $(SOURCES) sine_table.hex
	yosys -p "synth_ecp5 -abc9 -top $(PROJ) -json $@" $(SOURCES)

$(PROJ).config: $(PROJ).json
	nextpnr-ecp5 $(DEVICE) --package $(PACKAGE) --json $< --lpf $(LPF) \
		--textcfg $@ --freq 25 --timing-allow-fail --force

$(PROJ).bit: $(PROJ).config
	ecppack --compress $< --bit $@

prog: $(PROJ).bit
	ujprog $<

prog_flash: $(PROJ).bit
	ujprog -j FLASH $<

clean:
	rm -f $(PROJ).json $(PROJ).config $(PROJ).bit $(PROJ).svf
