# MatMul Accelerator — Architecture and Integration Design

**Status**: design proposal, nothing built yet
**Date**: 2026-08-19
**Basis**: measurements from `specs/003-llama2-minimal-soc/` on a Colorlight i5 (ECP5
LFE5U-25F) at 25 MHz. Every number below is either measured on that hardware, taken from a
cocotb simulation, or derived arithmetically from one of those — and says which.

---

## 1. What we are building and why

llama2.c currently runs on the FemtoRV core at **1.38 tok/s**. The measured per-token
breakdown is:

| Category | Share |
|---|---|
| matmul | 61.3% |
| attention | 27.4% |
| sample | 4.0% |
| other | 6.6% |
| rmsnorm | 0.4% |
| rope | 0.2% |

**matmul + attention = 88.7%, and both are matrix-multiply shaped.** The accelerator's job is
to take over both. Covering only the weight matmuls caps the payoff at ~2.5x end-to-end;
covering attention as well gives ~7.6x. That is the single most important design constraint
and it comes straight from the profile.

### Target

| | Now | With accelerator |
|---|---|---|
| Accelerated work | 643 ms/token | **13.0 ms/token** |
| Scalar remainder | 82 ms/token | 82 ms/token |
| Token time | 725 ms | **95 ms** |
| Rate | 1.38 tok/s | **~10.5 tok/s** |

Per-token work for stories260K (dim=64, hidden=172, 5 layers, 8 heads / 4 kv-heads,
vocab=512), computed exactly:

```
weight MACs      259,328   (Q,K,V,wo,w1,w2,w3 per layer x5, plus the classifier)
attention MACs    64,640   (at position 100; scales linearly with context)
total            323,968   -> 13.0 ms at 1 MAC/cycle, 25 MHz
```

**Note what this implies**: after acceleration the scalar 82 ms becomes 86% of token time.
The bottleneck moves to the CPU. Do not expect a second accelerator generation to help much
until that scalar work is addressed — clock rate is the obvious lever, and there is now
timing room for it (section 4.3).

---

## 2. The controlling constraint: bandwidth, not compute

This is the part most likely to be got wrong, so it comes before any RTL.

At batch 1, **every weight is read exactly once per token and never reused.** There is no
temporal locality to exploit. The accelerator is therefore purely memory-bound, and its
throughput is set by how fast weights arrive, not by how many multipliers it has.

| Path | Rate | Source |
|---|---|---|
| SDRAM burst read | ~98 MB/s | cocotb: 0.98 words/cycle x 4 B x 25 MHz |
| SDRAM via CPU + cache | 5.1 MB/s | measured, hardware memory test |
| CPU float matmul | ~1.9 MB/s | derived from 952 KFLOPS at 2 FLOP/weight |

The arithmetic that settles the design:

```
32-bit SDRAM port, 1 word/cycle, 25 MHz  =  100 MB/s
1 fp32 weight per word                   =  1 MAC/cycle
323,968 MACs/token / 25 MHz              =  13.0 ms/token
323,968 weights x 4 B / 13.0 ms          =  100 MB/s   <-- exactly the roofline
```

**One fp32 MAC lane saturates SDRAM at 25 MHz.** A second lane would sit idle half the time.
The board has 20 spare multipliers; this design uses one or two of them.

> **The engineering effort belongs in the streaming/DMA orchestrator, not in a MAC array.**
> A 16-wide systolic array is the wrong answer to this problem. Anyone reviewing this design
> should push back if MAC count grows without a matching bandwidth increase.

---

## 3. Stage-1 accelerator: one MAC lane

### 3.1 The primitive

llama2's matmul is `out[i] = sum_j W[i*n + j] * x[j]` for `i` in `0..d`.

- `x` — the input vector. Small: `n` floats, 256 B (dim=64) to 688 B (hidden=172). **Fits in
  BRAM and is reused `d` times.**
- `W` — the weight matrix. Large: `d*n` floats, streamed from SDRAM, **used once**.
- `out` — `d` floats. Small, lands in BRAM.

So the shape is: hold `x` on-chip, stream `W`, produce `out` on-chip. That is a DMA engine
with a MAC on the end.

### 3.2 Block diagram

```
                   +------------------------------------------+
   CPU (IO bus) -->| CSR / descriptor FIFO                    |
                   |   base_w, base_x, base_out, n, d, mode   |
                   +---------------------+--------------------+
                                         |
                                    +----v-----+
                                    | control  |  row/col counters,
                                    |   FSM    |  issues burst requests
                                    +----+-----+
                                         |
      SDRAM burst port <-----------------+
      (shared, see section 6)            |
                                         v
                              +----------------------+
                              |  weight FIFO (BRAM)  |  decouples burst
                              |  ~256 x 32b          |  bursts from the
                              +----------+-----------+  1-word/cycle MAC
                                         |
        +------------------+             v
        |  x BRAM          |------> +---------+
        |  (n x 32b)       |        |   MAC   | fp32 multiply-accumulate
        +------------------+        | a*b + c |  (2-3 stage pipeline)
                                    +----+----+
                                         |
                              +----------v-----------+
                              |  accumulator + out   |
                              |  BRAM (d x 32b)      |
                              +----------------------+
```

### 3.3 Why a FIFO between burst and MAC

SDRAM delivers in bursts with gaps (setup, refresh, CPU preemption); the MAC wants one word
every cycle. A ~256-word FIFO absorbs that jitter. The control FSM keeps it topped up by
issuing the next burst whenever occupancy drops below a threshold. This is the same
structure as `RTL/SDRAM/video_fetch_engine.v`, which already does exactly this for scanlines
and is proven in hardware.

### 3.4 Numeric format

Stage 1 uses **fp32**, because that is what the model file contains and what the current
software does — so results can be compared bit-for-bit against the CPU implementation, which
makes verification trivial. The MAC needs one `MULT18X18D`-based fp32 multiplier plus an
adder; petitbateau already instantiates fp32 arithmetic that can be referenced.

Do not start with int8. Quantization changes the numerics, and debugging a new datapath and
new numerics simultaneously is how weeks disappear.

---

## 4. Scaling beyond one unit

### 4.1 Replication does not help on its own

Adding a second MAC lane doubles compute and does nothing, because the 32-bit SDRAM port
still delivers one fp32 weight per cycle. Lanes must be fed, and there is only one feed.

### 4.2 What actually adds lanes: narrower data

**int8 (Q8_0) is the real scaling path.** One 32-bit word carries four int8 weights, so the
same bandwidth supports **4 MACs/cycle**:

| Format | Weights/word | MACs/cycle | Model capacity in 8 MB |
|---|---|---|---|
| fp32 | 1 | 1 | ~1.8M params |
| int8 | 4 | 4 | ~7M params |

int8 buys 4x throughput *and* 4x model size from unchanged hardware bandwidth. This is the
right second generation. It is a Stage 5 item because it changes numerics.

### 4.3 What else adds throughput: clock

Bandwidth scales linearly with clock. The minimal SoC profile measured **40.76 MHz max
frequency** (up from 32.6 MHz with the GPU present, which freed the 125 MHz TMDS paths), so
there is real headroom. At 50 MHz the roofline roughly doubles to ~200 MB/s and one lane
still matches it.

**Do the clock increase before adding lanes.** It is cheaper, it benefits the scalar 86% that
will dominate after Stage 3, and it changes the target the accelerator is designed against.

### 4.4 Multiple independent units

Several concurrent matmuls (e.g. Q, K, V projections in parallel) do not help either — they
contend for the same port and the total weight traffic is unchanged. The only reason to build
more than one unit is if a future workload has **weight reuse**: batched decoding, beam
search, or speculative decoding, where one weight stream feeds several activation vectors.
That changes the arithmetic completely and would justify revisiting this section.

**Rule of thumb to carry forward: lanes = (bytes delivered per cycle) / (bytes per weight).**
Everything else is idle silicon.

---

## 5. CPU interface

### 5.1 Design intent

The CPU issues work and stays out of the way. Two properties matter:

1. **Low issue overhead.** A single Q projection is 4,096 MACs = 164 us. Writing six CSRs at
   ~10 cycles each is negligible, but per-op *polling* overhead is not if the CPU spins on a
   register through the IO bus. Prefer a descriptor queue plus one completion check.
2. **The CPU must be able to do useful work while the accelerator runs.** After Stage 3 the
   scalar remainder dominates, so overlap matters. See section 6.

### 5.2 Register map

One-hot IO address in the existing IO space (following the `HardwareConfig_bits.v`
convention), register index packed into the write data as the GPU does:

| Reg | Access | Meaning |
|---|---|---|
| `ACC_W_BASE` | W | Weight matrix base address in SDRAM |
| `ACC_X_BASE` | W | Input vector source (SDRAM) or BRAM slot |
| `ACC_OUT_BASE` | W | Result destination |
| `ACC_N` | W | Inner dimension (dot-product length) |
| `ACC_D` | W | Number of output rows |
| `ACC_MODE` | W | 0 = weight matmul, 1 = attention scores, 2 = attention weighted-sum |
| `ACC_CTRL` | W | bit0 START, bit1 ABORT, bit2 IRQ_EN |
| `ACC_STATUS` | R | bit0 BUSY, bit1 DONE, bit2 ERR, bits 15:8 queue depth |
| `ACC_PERF` | R | cycles busy / cycles stalled on SDRAM — for tuning, see section 8 |

`ACC_PERF` is not optional. Without it there is no way to tell a bandwidth problem from a
control-logic problem on hardware, and the whole project depends on knowing which.

### 5.3 Descriptor queue

A small FIFO (8-16 entries) of descriptors in BRAM lets the CPU enqueue an entire layer's
projections in one go and then do something else. The FSM walks the queue without further CPU
involvement. This is what makes overlap practical rather than theoretical.

### 5.4 Driver sketch

```c
/* Blocking form -- correct, simple, and fine for bring-up. */
static void acc_matmul(float *out, const float *x, const float *w, int n, int d) {
    ACC_WRITE(ACC_W_BASE,  (uint32_t)w);
    ACC_WRITE(ACC_X_BASE,  (uint32_t)x);
    ACC_WRITE(ACC_OUT_BASE,(uint32_t)out);
    ACC_WRITE(ACC_N, n);
    ACC_WRITE(ACC_D, d);
    ACC_WRITE(ACC_MODE, ACC_MODE_MATMUL);
    ACC_WRITE(ACC_CTRL, ACC_START);
    while (ACC_READ(ACC_STATUS) & ACC_BUSY) { /* spin */ }
}
```

The spin loop must live in the CPU's instruction cache or it will generate SDRAM traffic and
contend with the very transfer it is waiting for. It is small enough to fit the 64-entry
cache easily, but this is worth checking in the disassembly rather than assuming.

Drop-in replacement: llama2.c's `matmul()` becomes a call to the above. That single
substitution is Stage 3's integration test, and it lets the CPU and accelerator results be
compared directly.

---

## 6. SDRAM sharing

This is the part the design most needs to get right: the CPU must not starve, and the
accelerator must not be limited to half the cycles.

### 6.1 What the workload actually demands

The naive fear is that CPU and accelerator fight continuously. The measured profile says
otherwise:

- **During a matmul, the CPU has almost no SDRAM demand.** It is either spinning on a cached
  status loop or running scalar code whose working set is small. Instruction fetches hit the
  64-entry cache.
- **After Stage 3, the accelerator is idle 86% of the time** (13 ms of 95 ms). Contention is
  a transient during short bursts, not a steady state.

So the problem is not dividing a continuously contended resource. It is: **give the
accelerator essentially all of the bandwidth while it runs, without ever making a CPU cache
miss wait an unreasonable time.**

### 6.2 Scheme: burst-granular arbitration, CPU priority, accelerator credits

```
priority:  refresh  >  CPU single-word  >  accelerator burst
                        (preempts only at burst boundaries)
```

Three rules:

1. **Accelerator bursts are atomic.** Once started, a burst runs to completion. This keeps
   SDRAM efficiency high — the setup cost is amortised over the burst.
2. **The CPU wins at every burst boundary.** A pending CPU single-word request is served
   before the next accelerator burst is issued. CPU worst-case added latency is therefore one
   burst, bounded and known.
3. **Accelerator anti-starvation credits.** If the accelerator has been denied for more than
   `W` consecutive arbitration rounds, it takes priority for one burst regardless. This
   guards against a pathological CPU-heavy phase; it should essentially never fire, and a
   counter on it is worth exposing in `ACC_PERF`.

Note this **inverts the current controller's priority**, which today gives the burst port
precedence over single-word (`muchtoremember_burst.v`: refresh > burst > single-word). That
ordering was right for video, where a starved scanline fetch means visible corruption. It is
wrong here, where a starved CPU means a stalled pipeline and nothing to show for it.

### 6.3 Burst length: the actual tradeoff

Longer bursts are more efficient but make a CPU miss wait longer. From the cocotb burst
measurements (~6 cycles setup, then one word/cycle):

| Burst | Efficiency | CPU worst-case stall |
|---|---|---|
| 16 words | 72.7% | 22 cyc (0.9 us) |
| 32 words | 84.2% | 38 cyc (1.5 us) |
| **64 words** | **91.4%** | **70 cyc (2.8 us)** |
| 128 words | 95.5% | 134 cyc (5.4 us) |
| 256 words | 97.7% | 262 cyc (10.5 us) |

**Recommend 64 words.** A normal CPU cache miss is ~10-15 cycles; 64-word bursts raise the
worst case to ~70, which is noticeable but not pathological, and 91% efficiency keeps the
accelerator near its roofline. 256-word bursts would make a single cache miss cost 262
cycles — at 5.3 CPI that is ~50 instructions of stall for one miss, which is the kind of
thing that quietly destroys the scalar performance that dominates after Stage 3.

Make the burst length a parameter and sweep it in Stage 4 with `ACC_PERF`. This table is
derived from simulation; the real answer depends on refresh interaction and should be
measured.

### 6.4 The accelerator must bypass the CPU cache

Weights are read once and never reused. Routing them through the 64-entry direct-mapped cache
would evict the CPU's entire working set on every matmul, converting the CPU's cached spin
loop into a stream of misses — the exact contention this section exists to avoid. The
accelerator uses the SDRAM controller's burst port directly, as the video fetch engine did.

### 6.5 Expected outcome

With the above: accelerator sustains ~90 MB/s of the ~98 MB/s roofline while running; CPU
sees added miss latency bounded at ~70 cycles, only during the 14% of the time the
accelerator is active. Neither side is halved.

---

## 7. Attention mode

Attention is 27.4% and must be covered, but it is not a different datapath — only a different
address pattern.

| | Weight matmul | Attention |
|---|---|---|
| Streamed operand | weight matrix | KV cache |
| Resident operand | input vector `x` | query vector `q` |
| Output | `d` values | `pos+1` scores, then `head_size` values |
| Reuse | none | none |

Two sub-modes:

- **Mode 1, scores**: `score[p] = q · k[p]` for `p` in `0..pos`. Streams the key cache.
- **Mode 2, weighted sum**: `out += att[p] * v[p]`. Streams the value cache, with the softmaxed
  weights resident.

Softmax between them stays on the CPU — it is inside the measured 27.4% but is a small part
of it, and moving it to hardware would add transcendental logic for little gain.

The KV cache is laid out `[layer][pos][kv_dim]`, so a head's keys are strided rather than
contiguous. The stride is `kv_dim * 4 = 128 B` — smaller than a 64-word (256 B) burst, which
means naive bursting would fetch data for other heads too. **Either accept the waste (simple,
costs some bandwidth) or add a strided-burst mode (better, more control logic).** Decide this
with a measurement in Stage 4, not upfront.

---

## 8. Staged delivery

Each stage has an exit criterion that can fail. A stage is not done because the code is
written; it is done when its criterion is met.

### Stage 0 — MAC datapath in simulation
Build the fp32 MAC and accumulator alone. Cocotb testbench in `FemtoRV/TEST/`.
**Exit**: MAC results are bit-identical to the host's fp32 for a few thousand random vectors,
including denormals, zero, and sign cases. Bit-identical matters — it is what makes every
later comparison against the CPU trivially conclusive.

### Stage 1 — full accelerator against a simulated SDRAM
Add the FIFO, control FSM, x/out BRAMs, and CSRs. Drive it with the existing SDRAM model.
**Exit**: a `64x64` and a `172x64` matmul produce bit-identical results to the host, and the
FIFO never underruns at full burst rate. Report achieved words/cycle.

### Stage 2 — arbiter in simulation
Add the two-port arbiter (section 6) with a synthetic CPU traffic generator.
**Exit**: with the CPU generator idle, the accelerator sustains >=0.9 words/cycle. With the
generator issuing a miss every 100 cycles, CPU worst-case latency stays under one burst and
accelerator throughput degrades gracefully — not off a cliff. Sweep burst length; produce the
real version of the table in 6.3.

### Stage 3 — hardware in isolation
Synthesize into the minimal profile. **No llama2 yet.** A small test program writes a known
weight matrix and vector to SDRAM, runs one matmul, and compares against a CPU-computed
reference.
**Exit**: bit-identical result on hardware; `ACC_PERF` shows the expected words/cycle; the
build still meets timing at 25 MHz and the resource cost is recorded. Confirm the full
profile still builds (the SC-011 habit from feature 003).

### Stage 4 — hardware integrated, weight matmul only
Replace `matmul()` in llama2.c with the accelerator call. Attention stays on the CPU.
**Exit**: generated text is **byte-identical to the current CPU-only output for the same
prompt and seed** — this is why Stage 0 insisted on bit-identical arithmetic. Expect roughly
2.5x end-to-end (61.3% accelerated). Re-run the profiler; matmul should collapse and
attention should become the largest category. If the speedup is far off 2.5x, `ACC_PERF`
tells you whether it is bandwidth or control.

### Stage 5 — attention modes
Add modes 1 and 2, move attention off the CPU.
**Exit**: still byte-identical output; end-to-end approaching 7.6x; profile shows the scalar
remainder dominating. Decide the strided-burst question from 7 with measured numbers.

### Stage 6 — optional: clock increase, then int8
Raise the system clock (there is room to ~40 MHz measured, and the design should be re-timed
for it), re-measure, then consider int8/Q8_0 for 4 lanes and 4x model capacity.
**Exit**: for int8, output is no longer bit-identical, so the criterion changes to a
perplexity or output-similarity check against the fp32 reference. Define that before starting.

### Why this order

Stages 0-2 are free to iterate — no board, no upload, fast turnaround. Stage 3 puts hardware
in the loop with *one* variable changed. Stage 4 changes one more. By the time anything can
go wrong on the board, the arithmetic has already been proven in simulation and the only new
variable is integration. Feature 003 demonstrated the value of this: the llama2 port was
validated on the host before it ever ran on the FPGA, so when the board misbehaved the cause
was known to be loading or memory, not the maths.

---

## 9. Risks and open questions

| Risk | Mitigation |
|---|---|
| Arbiter starves CPU in practice despite the design | Stage 2 measures it in simulation before any RTL is committed to hardware; `ACC_PERF` measures it again on the board |
| fp32 MAC does not close timing at 25 MHz | Pipeline the MAC (2-3 stages); the FIFO already tolerates latency. 66% LUT and 20 multipliers are free |
| KV-cache stride wastes bandwidth in attention mode | Quantify in Stage 4; add strided burst only if the measurement justifies it |
| Scalar work dominates after Stage 5 and the payoff disappoints | Already known and quantified — 82 ms of 95 ms. Clock increase is the lever; consider it before Stage 5 rather than after |
| The 7.6x estimate assumes 50x on the accelerated portion | It is actually ~59x by the arithmetic in section 1, so there is margin. But if sustained bandwidth comes in at 60% of roofline the end-to-end figure drops to ~6x — still worth it |

**Open question worth settling early**: whether to raise the clock before or after Stage 4.
Raising it first changes the bandwidth target the whole design is sized against; raising it
later means re-timing a design that was closed at 25 MHz. The measured 40.76 MHz ceiling
suggests doing it first is safe, but it should be a deliberate decision rather than a drift.

---

## 9a. Reusing the existing video/SDRAM path — what is already there

The GPU framebuffer path was built to stream pixels out of SDRAM, and it turns out to be
almost exactly the infrastructure this accelerator needs. Findings from reading the RTL:

### The burst port is generic, not video-specific

`muchtoremember_burst.v` exposes a second port alongside the CPU's single-word port:

```verilog
input         burst_rd,        // pulse to start
input  [25:0] burst_addr,      // arbitrary start address
input  [8:0]  burst_len,       // 1-256 words, per request
output [31:0] burst_dout,
output        burst_valid, burst_done, burst_busy
```

Nothing here is about video. Arbitrary address, per-request length, streaming handshake — this
is the accelerator's weight-fetch interface as specified in section 3. **Use it unchanged.**
All the video-specific behaviour (scanline stride, hsync/vsync timing, framebuffer base) lives
one level up in `video_fetch_engine.v`, not in the controller.

The port is also already proven: 6/6 cocotb tests pass including 256-word bursts and
row-crossing, and it measured 0.98 words/cycle.

### The burst path is already wired up and currently idle

`video_fetch_engine` is instantiated under `` `ifdef NRV_IO_SDRAM ``, **not** under
`` `ifdef NRV_IO_GPU ``. So in the minimal LLM profile it is still instantiated — but its
inputs (`gpu_hsync_start`, `gpu_vsync_start`, `gpu_v_count`) are undriven wires, so it never
issues a burst and yosys prunes it. Confirmed by the resource report: the minimal profile uses
16 DP16KD, exactly the 32 KB boot ROM (16 x 2 KB), so the fetch engine's FIFO and line buffer
were optimised away entirely.

**Practical consequence**: there is no GPU to "replace" — it is already gone from this profile.
What remains is a live, tested burst port with nothing attached to it. The weight fetch engine
drops into precisely the instantiation site `video_fetch_engine` occupies today.

### What must change: the priority order

This is the one real modification, and it is small. Today, in the controller's IDLE state:

```verilog
if (refresh_pending)                      ... // refresh
else if (burst_busy)                      ... // burst wins over CPU
else if ((|wmask_sticky) | rd_sticky)     ... // CPU single-word last
```

Reorder to put the CPU ahead of the burst:

```verilog
if (refresh_pending)                      ...
else if ((|wmask_sticky) | rd_sticky)     ... // CPU first
else if (burst_busy)                      ... // burst second
```

**Bursts are already atomic** — once the FSM enters `s_burst_act` it stays there until the
burst completes and only then returns to `s_idle`. So swapping these two branches yields
exactly the "CPU priority, preemption only at burst boundaries" semantics of section 6.2, for
free. The burst-length bound in 6.3 then caps CPU worst-case latency.

Add the anti-starvation credit from 6.2 as a guard on the CPU branch:

```verilog
else if (((|wmask_sticky) | rd_sticky) && !accel_starved) ...
```

where `accel_starved` asserts after the burst port has been denied for N consecutive idle
cycles. Per the workload analysis in 6.1 it should essentially never fire; a counter on it
belongs in `ACC_PERF` so that assumption is checked rather than trusted.

**Do not change this ordering while the GPU profile still exists** without re-testing it. The
existing order was correct for video — a starved scanline fetch is visible corruption — and
`colorlight_i5` still builds the GPU. Either make the priority a parameter or gate the swap on
the profile. The SC-011 no-regression check from feature 003 covers this.

### What is NOT there: a write path

**The burst port is read-only.** There is no burst write; the video path never needed one. The
accelerator's results therefore need another route. Options, in order of preference:

1. **Keep results in accelerator BRAM and map it into the address space.** Outputs are small —
   `d` floats, 256 B typically and 2 KB for the classifier (`d`=512). One BRAM, normal CPU
   loads, no write path at all. Recommended.
2. Write back through the CPU's single-word port. Works, but `d` single-word writes at ~10
   cycles each is ~15% overhead on a `64x64` matmul — measurable and avoidable.
3. Add a burst write port to the controller. Most work, least benefit; the volume does not
   justify it.

Option 1 also removes any coherency question: results never enter SDRAM, so the CPU cache
cannot hold a stale copy.

### Also reusable, with care

- `video_line_buffer.v` — ping-pong double buffering. Useful if weight streaming later wants to
  overlap fetch and compute across tiles; not needed for the single-lane design, where one FIFO
  suffices.
- The `fetch_enabled` gating and VSync FIFO flush in `femtosoc.v` are video-specific lifecycle
  management. The accelerator's equivalent is "flush the FIFO on ABORT or at descriptor start",
  which is simpler.

### Revised effort estimate

| Component | Status |
|---|---|
| SDRAM burst port | **exists, unchanged** |
| Burst arbitration | **3-line reorder** + credit counter |
| Weight fetch engine | new, but `video_fetch_engine.v` is the template |
| FIFO | new, or adapt the video FIFO |
| MAC + accumulator | new |
| CSR block + descriptor queue | new |
| Result BRAM + address decode | new, small |

Roughly half the memory-side work is already done and proven in hardware. The genuinely new
RTL is the MAC datapath, the control FSM, and the CPU-facing registers.

---

## 10. What to reuse

- `RTL/SDRAM/muchtoremember_burst.v` — burst reads at 0.98 words/cycle, row-crossing handled
  internally. The second burst port the GPU used is now free.
- `RTL/SDRAM/video_fetch_engine.v` — **the closest thing to the orchestrator already written.**
  It issues bursts, tracks position, and feeds a consumer through a FIFO. Start by copying it.
- `RTL/SDRAM/video_line_buffer.v` — ping-pong BRAM buffering, the pattern for double-buffering
  weight streams if that proves useful.
- `FIRMWARE/llama2/profile.c` — per-category cycle accounting, so before/after comparisons use
  the same instrument.
- `FemtoRV/TEST/*.py` — established cocotb harness pattern for stages 0-2.
