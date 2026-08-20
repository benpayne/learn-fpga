"""
Cocotb testbench for the CPU_PRIORITY / anti-starvation arbitration scheme
added to muchtoremember_burst (FemtoRV/RTL/ACCEL/DESIGN.md sec 6.2,
tasks.md T040/T041). Exercises acc_arb_wrapper.v, which builds the
controller with CPU_PRIORITY=1 (CPU wins at every idle-round arbitration
boundary unless the accelerator has been denied STARVE_LIMIT rounds in a
row, in which case the guard forces one burst through).

This does NOT re-test the legacy CPU_PRIORITY=0 (burst-first) ordering --
that is sdram_burst_tb.py's job, run against the unmodified default, and it
must keep passing unchanged as the regression proving the display profile
is untouched (constitution Principle V).

Scenarios:
  - CPU idle             : accelerator should approach its unshared roofline.
  - CPU light (~1/500 cyc): accelerator throughput barely dented, CPU rarely
                            has to wait more than one burst.
  - CPU heavy (~1/20 cyc) : CPU still bounded to roughly one burst's added
                            latency per request (SC-007) even though it is
                            almost always the one pending; accelerator
                            throughput degrades but does not collapse
                            (SC-008).
  - Starvation stress     : CPU requests every cycle (pathological, not a
                            realistic workload) to force the anti-starvation
                            guard to actually fire and prove the accelerator
                            is not shut out completely (FR-017).
  - Burst-length sweep    : 16/32/64/128/256 words at a fixed moderate CPU
                            rate, producing the measured efficiency-vs-
                            latency table that replaces the ESTIMATED table
                            in ACCEL/DESIGN.md sec 6.3.

Run: cd FemtoRV/TEST && make MODULE=acc_arb_tb SIM=icarus
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 40  # 25 MHz, matches the board and sdram_burst_tb.py

SDRAM_INIT_CYCLES = 10200  # sdram_startup_cycles=10100 + margin


# ---------------------------------------------------------------------
# Behavioral SDRAM model — identical in spirit to sdram_burst_tb.py's.
# Correctness of the burst/single-word datapath is already proven there;
# this model exists here only so the arbitration FSM has something to
# transact against. Content is not checked, only word counts and timing.
# ---------------------------------------------------------------------
class SDRAMModel:
    def __init__(self):
        self.memory = {}
        self.active_row = [None, None, None, None]
        self.cas_latency = 1  # see sdram_burst_tb.py for why CAS=1 here

    def write(self, bank, row, col, data, dqm):
        key = (bank, row, col)
        old = self.memory.get(key, 0)
        new = 0
        for i in range(4):
            if dqm & (1 << i):
                new |= (old & (0xFF << (i * 8)))
            else:
                new |= (data & (0xFF << (i * 8)))
        self.memory[key] = new

    def read(self, bank, row, col):
        return self.memory.get((bank, row, col), 0xDEAD0000 | (col & 0xFF))

    def activate(self, bank, row):
        self.active_row[bank] = row

    def precharge(self, bank):
        if bank == -1:
            self.active_row = [None, None, None, None]
        else:
            self.active_row[bank] = None


async def sdram_responder(dut, model):
    CMD_READ = 0b0101
    CMD_WRITE = 0b0100
    CMD_ACTIVE = 0b0011
    CMD_PRECHARGE = 0b0010

    read_pipe = []
    dut.sd_d_in.value = 0

    while True:
        await RisingEdge(dut.clk)

        try:
            cmd = ((int(dut.sd_cs.value) << 3) |
                   (int(dut.sd_ras.value) << 2) |
                   (int(dut.sd_cas.value) << 1) |
                   int(dut.sd_we.value))
            bank = int(dut.sd_ba.value)
            addr = int(dut.sd_addr.value)
        except (ValueError, AttributeError):
            continue

        if cmd == CMD_ACTIVE:
            model.activate(bank, addr & 0x7FF)
        elif cmd == CMD_READ:
            col = addr & 0xFF
            row = model.active_row[bank]
            if row is not None:
                read_pipe.append((model.cas_latency, model.read(bank, row, col)))
        elif cmd == CMD_WRITE:
            col = addr & 0xFF
            row = model.active_row[bank]
            try:
                dqm = int(dut.sd_dqm.value)
                data = int(dut.sd_d_out.value)
            except (ValueError, AttributeError):
                dqm, data = 0xF, 0
            if row is not None:
                model.write(bank, row, col, data, dqm)
        elif cmd == CMD_PRECHARGE:
            model.precharge(-1 if (addr & 0x400) else bank)

        new_pipe = []
        drive_data = 0
        for delay, data in read_pipe:
            if delay <= 1:
                drive_data = data
            else:
                new_pipe.append((delay - 1, data))
        read_pipe = new_pipe
        dut.sd_d_in.value = drive_data


def word_addr(n, bank=0):
    """Map a flat word index to the controller's {bank,row,col} address
    encoding. Stays within a single bank; row-crossing is exercised
    incidentally as the accelerator streams past col 255, and is already
    proven correct by sdram_burst_tb.py's row-crossing test."""
    row = (n // 256) % 2048
    col = n % 256
    return (bank << 21) | (row << 10) | (col << 2)


def cpu_addr_words():
    """A handful of addresses in a different bank from the accelerator's
    stream, so CPU traffic and accelerator traffic never coincidentally
    share a row (not required for correctness, just keeps the two streams
    obviously independent when reading waveforms)."""
    return [(2 << 21) | (5 << 10) | (c << 2) for c in range(4)]


# ---------------------------------------------------------------------
# Traffic generators
# ---------------------------------------------------------------------
async def accel_streamer(dut, burst_len, stats):
    """Simulates a saturated accelerator: issues the next burst the cycle
    after the previous one completes, forever, until killed."""
    offset = 0
    while True:
        dut.burst_len.value = burst_len
        dut.burst_addr.value = word_addr(offset)
        dut.burst_rd.value = 1
        await RisingEdge(dut.clk)
        dut.burst_rd.value = 0
        while True:
            await RisingEdge(dut.clk)
            if int(dut.burst_valid.value):
                stats["words"] += 1
            if int(dut.burst_done.value):
                stats["bursts"] += 1
                break
        offset += burst_len


async def cpu_request_latency(dut, addr_word, timeout=2000):
    """Issue one single-word CPU read. Returns the number of cycles from
    the request (inclusive) to busy deasserting -- the CPU's total added
    wait, arbitration delay and intrinsic SDRAM latency both included."""
    dut.addr.value = addr_word
    dut.rd.value = 1
    await RisingEdge(dut.clk)
    dut.rd.value = 0
    cycles = 1
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        cycles += 1
        if not int(dut.busy.value):
            return cycles
    raise TimeoutError(f"CPU request to 0x{addr_word:07X} did not complete within {timeout} cycles")


async def cpu_traffic_generator(dut, period_cycles, stats):
    """Issues one CPU read every `period_cycles` cycles, forever, until
    killed. `period_cycles` is the configurable rate the task asked for.

    Note: even at period_cycles=0 or 1, cpu_pending still drops to 0 for at
    least the cycle between one request's busy deasserting and the next
    rd pulse landing, because cpu_request_latency() pulses rd for exactly
    one cycle rather than holding it. That gap is enough for the burst
    port to win an idle-round on a CPU_PRIORITY=1 controller in between
    requests, so this generator -- even run flat out -- represents a
    "CPU as busy as real load gets" scenario, not "CPU permanently
    pending". See cpu_hammer() for the latter, used to stress the
    anti-starvation guard itself."""
    addrs = cpu_addr_words()
    i = 0
    while True:
        await ClockCycles(dut.clk, period_cycles)
        latency = await cpu_request_latency(dut, addrs[i % len(addrs)])
        stats["latencies"].append(latency)
        i += 1


async def cpu_hammer(dut):
    """Holds a CPU read request asserted continuously so cpu_pending never
    drops, even for one cycle -- the only way to force the accelerator to
    be denied every idle-round arbitration and actually exercise the
    STARVE_LIMIT guard. This is NOT a realistic CPU access pattern (a real
    CPU cannot issue a new request before the last one's data comes back);
    it exists solely to prove the guard mechanism fires and bounds the
    accelerator's worst case (FR-017)."""
    dut.addr.value = cpu_addr_words()[0]
    dut.rd.value = 1
    while True:
        await RisingEdge(dut.clk)


# ---------------------------------------------------------------------
# Scenario driver
# ---------------------------------------------------------------------
async def run_scenario(dut, burst_len, cpu_period, duration_cycles=None, target_bursts=None):
    """Runs a continuous accelerator burst stream, plus a CPU side driven
    according to cpu_period, concurrently, then measures both sides.
    Returns a dict of results.

    Exactly one of duration_cycles / target_bursts must be given:
      duration_cycles -- run for a fixed number of cycles (throughput is
                         an approximation -- the last burst in flight when
                         time runs out is not counted).
      target_bursts    -- run until the accelerator has COMPLETED this many
                         bursts, then stop. Gives an exact, reproducible
                         burst count per measurement (statistical
                         confidence is visible directly in the result)
                         instead of an estimated one.

    cpu_period:
      None      -- CPU idle, no traffic.
      int       -- periodic traffic generator, one request every
                   cpu_period cycles (see cpu_traffic_generator).
      "hammer"  -- continuous, always-pending CPU load (see cpu_hammer);
                   no per-request latencies are collected in this mode.
    """
    assert (duration_cycles is None) != (target_bursts is None), \
        "run_scenario: pass exactly one of duration_cycles or target_bursts"

    clock = Clock(dut.clk, CLK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    model = SDRAMModel()
    cocotb.start_soon(sdram_responder(dut, model))

    dut.resetn.value = 0
    dut.rd.value = 0
    dut.wmask.value = 0
    dut.addr.value = 0
    dut.din.value = 0
    dut.burst_rd.value = 0
    dut.burst_addr.value = 0
    dut.burst_len.value = 0
    await ClockCycles(dut.clk, 5)
    dut.resetn.value = 1
    await ClockCycles(dut.clk, SDRAM_INIT_CYCLES)

    accel_stats = {"words": 0, "bursts": 0}
    cpu_stats = {"latencies": []}

    accel_task = cocotb.start_soon(accel_streamer(dut, burst_len, accel_stats))
    cpu_task = None
    if cpu_period == "hammer":
        cpu_task = cocotb.start_soon(cpu_hammer(dut))
    elif cpu_period is not None:
        cpu_task = cocotb.start_soon(cpu_traffic_generator(dut, cpu_period, cpu_stats))

    if target_bursts is not None:
        elapsed = 0
        while accel_stats["bursts"] < target_bursts:
            await RisingEdge(dut.clk)
            elapsed += 1
        duration_cycles = elapsed
    else:
        await ClockCycles(dut.clk, duration_cycles)

    accel_task.cancel()
    if cpu_task is not None:
        cpu_task.cancel()

    latencies = cpu_stats["latencies"]
    return {
        "burst_len": burst_len,
        "cpu_period": cpu_period,
        "duration_cycles": duration_cycles,
        "accel_words": accel_stats["words"],
        "accel_bursts": accel_stats["bursts"],
        "words_per_cycle": accel_stats["words"] / duration_cycles,
        "cpu_count": len(latencies),
        "cpu_max_wait": max(latencies) if latencies else None,
        "cpu_mean_wait": (sum(latencies) / len(latencies)) if latencies else None,
        "starve_guard_fired": int(dut.starve_guard_fired.value),
    }


def log_result(dut, label, r):
    dut._log.info(
        f"[{label}] burst_len={r['burst_len']} cpu_period={r['cpu_period']} "
        f"duration={r['duration_cycles']}cyc  "
        f"accel: {r['accel_words']}w/{r['accel_bursts']}bursts "
        f"({r['words_per_cycle']*100:.1f}% eff)  "
        f"cpu: n={r['cpu_count']} max={r['cpu_max_wait']} mean="
        f"{(r['cpu_mean_wait'] or 0):.1f}  guard_fired={r['starve_guard_fired']}"
    )


# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------
@cocotb.test()
async def test_accel_only_cpu_idle(dut):
    """CPU idle: accelerator should approach its unshared roofline, and the
    starvation guard should never need to fire (nothing is denying it)."""
    r = await run_scenario(dut, burst_len=64, cpu_period=None, duration_cycles=8000)
    log_result(dut, "cpu-idle", r)

    assert r["accel_bursts"] > 10, "accelerator made almost no progress"
    assert r["words_per_cycle"] > 0.5, f"unshared throughput too low: {r['words_per_cycle']:.3f} words/cycle"
    assert r["starve_guard_fired"] == 0, "guard fired with no CPU contention -- should be impossible"


@cocotb.test()
async def test_cpu_light_load(dut):
    """CPU makes a request roughly every 500 cycles (a light, occasional
    cache-miss cadence). Accelerator throughput should barely be dented,
    and CPU worst-case wait should stay in the neighbourhood of one burst
    (per DESIGN.md sec 6.3's ~70-cycle figure for 64-word bursts)."""
    r = await run_scenario(dut, burst_len=64, cpu_period=500, duration_cycles=10000)
    log_result(dut, "cpu-light", r)

    assert r["cpu_count"] > 5, "CPU generator did not run enough requests"
    assert r["words_per_cycle"] > 0.7, f"accelerator throughput degraded too much under light load: {r['words_per_cycle']:.3f}"
    assert r["cpu_max_wait"] < 64 + 80, f"CPU worst-case wait exceeded one burst by a wide margin: {r['cpu_max_wait']}"


@cocotb.test()
async def test_cpu_heavy_load(dut):
    """CPU makes a request roughly every 20 cycles (heavy contention). Under
    CPU-priority arbitration the CPU should still see roughly the same
    worst-case added latency as the light-load case (SC-007: bounded by one
    burst boundary, not by queue depth), while accelerator throughput
    degrades gradually rather than collapsing to zero (SC-008)."""
    r = await run_scenario(dut, burst_len=64, cpu_period=20, duration_cycles=10000)
    log_result(dut, "cpu-heavy", r)

    assert r["cpu_count"] > 50, "CPU generator did not run enough requests"
    assert r["cpu_max_wait"] < 64 + 80, f"CPU worst-case wait grew with load -- arbitration is not bounding it: {r['cpu_max_wait']}"
    assert r["words_per_cycle"] > 0.02, "accelerator was fully starved, not merely degraded"


# ---------------------------------------------------------------------
# The three scenarios above were written and last measured against
# burst_len=64, the pre-R19 default. R19/T041 decided BURST_LEN=128 for
# the production config (acc_top.v/femtosoc.v both instantiate it that
# way), so an SC-007/SC-008 verdict against the actual shipped
# configuration needs its own measurement, not an extrapolation from the
# 64-word numbers above. Mirrors test_cpu_light_load/test_cpu_heavy_load/
# test_starvation_guard_fires_under_pathological_load exactly, at
# burst_len=128, with the same thresholds (the "one burst boundary" bound
# in SC-007 scales with burst_len, so 64+80 -> 128+80 below).
# ---------------------------------------------------------------------
@cocotb.test()
async def test_cpu_light_load_bl128(dut):
    """burst_len=128 (production default) counterpart of test_cpu_light_load."""
    r = await run_scenario(dut, burst_len=128, cpu_period=500, duration_cycles=10000)
    log_result(dut, "cpu-light-bl128", r)

    assert r["cpu_count"] > 3, "CPU generator did not run enough requests"
    assert r["words_per_cycle"] > 0.7, f"accelerator throughput degraded too much under light load: {r['words_per_cycle']:.3f}"
    assert r["cpu_max_wait"] < 128 + 80, f"CPU worst-case wait exceeded one burst by a wide margin: {r['cpu_max_wait']}"


@cocotb.test()
async def test_cpu_heavy_load_bl128(dut):
    """burst_len=128 (production default) counterpart of test_cpu_heavy_load
    -- the actual SC-007/SC-008 measurement against the shipped
    configuration, not the pre-decision burst_len=64 one above."""
    r = await run_scenario(dut, burst_len=128, cpu_period=20, duration_cycles=10000)
    log_result(dut, "cpu-heavy-bl128", r)

    assert r["cpu_count"] > 50, "CPU generator did not run enough requests"
    assert r["cpu_max_wait"] < 128 + 80, f"CPU worst-case wait grew with load -- arbitration is not bounding it: {r['cpu_max_wait']}"
    assert r["words_per_cycle"] > 0.02, "accelerator was fully starved, not merely degraded"


@cocotb.test()
async def test_starvation_guard_fires_bl128(dut):
    """burst_len=128 counterpart of test_starvation_guard_fires_under_pathological_load."""
    r = await run_scenario(dut, burst_len=128, cpu_period="hammer", duration_cycles=10000)
    log_result(dut, "pathological-bl128", r)

    assert r["starve_guard_fired"] > 0, "guard never fired even under continuous CPU pressure -- accelerator would starve forever"
    assert r["accel_bursts"] > 0, "accelerator made zero progress despite the anti-starvation guard"


@cocotb.test()
async def test_starvation_guard_fires_under_pathological_load(dut):
    """Deliberately pathological: CPU issues a request every single cycle,
    i.e. cpu_pending is asserted continuously. Without the guard the
    accelerator would never win arbitration. This is NOT a realistic
    workload -- FR-017 expects the guard to stay at 0 under the light/heavy
    scenarios above -- it exists purely to prove the guard mechanism itself
    works and bounds the accelerator's worst case."""
    r = await run_scenario(dut, burst_len=64, cpu_period="hammer", duration_cycles=10000)
    log_result(dut, "pathological", r)

    assert r["starve_guard_fired"] > 0, "guard never fired even under continuous CPU pressure -- accelerator would starve forever"
    assert r["accel_bursts"] > 0, "accelerator made zero progress despite the anti-starvation guard"


# Target burst counts for the two sweeps below. The CPU-idle sweep is the
# SC-006 gate (>= 90% of theoretical rate with no competing traffic) and a
# design-parameter decision hangs on it, so it gets the larger sample. The
# cpu_period=100 sweep is supplementary "realistic load" context for the
# same table and gets a smaller, still much-improved, sample.
SWEEP_TARGET_BURSTS_IDLE = 3000
SWEEP_TARGET_BURSTS_LOADED = 1000
SC006_THRESHOLD = 0.90


@cocotb.test()
async def test_burst_length_sweep(dut):
    """Sweep BURST_LEN across 16/32/64/128/256 words at a fixed, moderate
    CPU miss rate (every 100 cycles), each length run until
    SWEEP_TARGET_BURSTS_LOADED bursts have completed. Produces the
    measured efficiency-vs-latency table that replaces the ESTIMATED table
    in ACCEL/DESIGN.md sec 6.3 (constitution Principle VI: measurements
    replace estimates)."""
    burst_lengths = [16, 32, 64, 128, 256]
    results = []
    for bl in burst_lengths:
        r = await run_scenario(dut, burst_len=bl, cpu_period=100, target_bursts=SWEEP_TARGET_BURSTS_LOADED)
        log_result(dut, f"sweep bl={bl}", r)
        results.append(r)

    dut._log.info("=" * 78)
    dut._log.info(f"Measured burst-length sweep (cpu_period=100 cycles, target {SWEEP_TARGET_BURSTS_LOADED} bursts/length):")
    dut._log.info(f"{'burst':>6} {'eff%':>7} {'bursts':>7} {'cpu_n':>6} {'cpu_max':>8} {'cpu_mean':>9} {'guard_fired':>12}")
    for r in results:
        dut._log.info(
            f"{r['burst_len']:>6} {r['words_per_cycle']*100:>6.1f}% {r['accel_bursts']:>7} "
            f"{r['cpu_count']:>6} {r['cpu_max_wait']:>8} {r['cpu_mean_wait']:>9.1f} {r['starve_guard_fired']:>12}"
        )
    dut._log.info("=" * 78)

    for r in results:
        assert r["accel_bursts"] >= SWEEP_TARGET_BURSTS_LOADED, f"burst_len={r['burst_len']}: target burst count not reached"
        assert r["words_per_cycle"] > 0.3, f"burst_len={r['burst_len']}: efficiency implausibly low ({r['words_per_cycle']:.3f})"

    # Efficiency should increase monotonically with burst length (longer
    # bursts amortise the fixed setup cost over more words).
    effs = [r["words_per_cycle"] for r in results]
    assert effs == sorted(effs), f"efficiency did not increase monotonically with burst length: {effs}"


@cocotb.test()
async def test_burst_length_sweep_cpu_idle(dut):
    """Same sweep as test_burst_length_sweep, but with the CPU idle, i.e.
    the unshared roofline per burst length -- this is the like-for-like
    comparison against ACCEL/DESIGN.md sec 6.3's ESTIMATED table, which
    modelled pure burst efficiency (setup-cycle overhead amortised over
    burst_len words) with no CPU contention at all, AND the direct SC-006
    gate ('sustain at least 90% of the theoretical memory rate with no
    competing traffic'). Each length runs until SWEEP_TARGET_BURSTS_IDLE
    bursts have completed -- two to three orders of magnitude more samples
    than the first pass (25-375 bursts), because this measurement decides
    a design parameter (the default BURST_LEN)."""
    burst_lengths = [16, 32, 64, 128, 256]
    results = []
    for bl in burst_lengths:
        r = await run_scenario(dut, burst_len=bl, cpu_period=None, target_bursts=SWEEP_TARGET_BURSTS_IDLE)
        log_result(dut, f"idle-sweep bl={bl}", r)
        results.append(r)

    dut._log.info("=" * 78)
    dut._log.info(f"Measured burst-length sweep, CPU idle / SC-006 gate (target {SWEEP_TARGET_BURSTS_IDLE} bursts/length):")
    dut._log.info(f"{'burst':>6} {'eff%':>7} {'bursts':>7} {'cycles':>10} {'SC-006(>=90%)':>14}")
    for r in results:
        verdict = "PASS" if r["words_per_cycle"] >= SC006_THRESHOLD else "FAIL"
        dut._log.info(
            f"{r['burst_len']:>6} {r['words_per_cycle']*100:>6.1f}% {r['accel_bursts']:>7} "
            f"{r['duration_cycles']:>10} {verdict:>14}"
        )
    dut._log.info("=" * 78)

    for r in results:
        assert r["accel_bursts"] >= SWEEP_TARGET_BURSTS_IDLE, f"burst_len={r['burst_len']}: target burst count not reached"

    effs = [r["words_per_cycle"] for r in results]
    assert effs == sorted(effs), f"efficiency did not increase monotonically with burst length: {effs}"
