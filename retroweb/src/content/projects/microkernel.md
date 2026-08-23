---
title: "Microkernel"
description: "The OS core: a small kernel that handles only scheduling, IPC, and memory. File systems, drivers, and shells run as user-space services. The same source compiles for 6502, 68000, 8086, RISC-V."
image: ./microkernel-card.svg
components:
  - "Portable C kernel (~5–10 KB compiled per CPU)"
  - "Synchronous IPC primitives (send / receive / reply)"
  - "Round-robin or priority scheduler"
  - "Per-CPU bring-up code (vector table, context switch, IPI)"
  - "Service registration table (drivers, FS, network as user-space)"
order: 10
links:
  - label: "Single-user OS (uses this kernel)"
    url: "/learn-fpga/projects/single-user-os/"
  - label: "Multi-user OS (uses this kernel)"
    url: "/learn-fpga/projects/multi-user-os/"
  - label: "Roadmap blog post"
    url: "/learn-fpga/blog/the-retro-active-roadmap/"
---

A **small microkernel** that runs on every CPU the bus supports. The architectural bet of the project: keep the kernel responsible only for things the hardware genuinely demands — context switching, IPC, basic memory management — and push everything else (file systems, network stacks, drivers, shells) out to user-space services that talk to the kernel via IPC.

Status: **design phase**.

## What "microkernel" actually means here

In the L4 / QNX sense: the kernel's job list is short.

1. **Schedule** something to run.
2. **Switch** between threads when the schedule says so.
3. **Pass messages** between threads (IPC).
4. **Manage memory** at a low level — track which physical pages exist, hand them out, take them back.
5. **Receive interrupts** and turn them into IPC messages to the right service thread.

Everything else is a user-space service:

- The **file system** is a thread that talks to the SD driver thread.
- A **shell** is another thread that talks to the keyboard driver and the file system thread.
- A **video card driver** is a thread that talks to whatever needs to draw something.

When a process wants to read a file, it doesn't trap into the kernel for a `read()` syscall implementation. It sends a message to the FS service ("please read 1024 bytes of /etc/motd"), the FS service sends a message to the SD driver, the SD driver does its thing and replies, and the message replies come back up the chain.

This is more IPC than a monolithic kernel does. It's slower in the steady state. The win is *robustness* (a buggy driver doesn't crash the kernel — it crashes its own process and gets restarted) and *flexibility* (the same kernel powers a single-user shell-and-binaries machine and a multi-user time-sharing machine, just with different services on top).

## Why on a 6502?

Honestly: the 6502 stretches the definition. It has 64 KB of address space, no MMU, no privileged-mode CPU separation. You can do *cooperative* multitasking with IPC, and that's roughly what the kernel becomes there: a thread switcher with a message queue. Process isolation is by convention, not by hardware enforcement.

The 6502 build will be more like "small monitor with IPC primitives" than a textbook microkernel. We'll be honest about this on the page rather than overpromise.

The 68000 and any 32-bit hosts get the real thing: separate user/supervisor modes, optional MMU support, real process isolation, per-process address space.

## IPC design

Synchronous send/receive/reply, the L4 idiom. A thread does:

```c
msg_t request, reply;
request.type = MSG_FS_READ;
request.fs.path = "/etc/motd";
request.fs.length = 1024;

ipc_call(fs_service_tid, &request, &reply);
// blocks until fs_service replies
// reply.fs.bytes_read, reply.fs.data ready to use
```

The kernel never copies large message bodies — it remaps memory pages between the sender and receiver where possible, and falls back to per-byte copy on hosts without MMUs.

## CPU portability

Same C source for 6502, 68k, 8086, RISC-V. Each target has an `arch/<cpu>/` directory holding:

- The reset handler / vector table
- Context switch (save/restore the CPU's register set)
- IPI / cross-CPU interrupt handling (multi-CPU only — relevant for the 68k+6502 dual-host case)
- The IPC fast path (architecture-specific because save/restore is architecture-specific)

Everything else is pure portable C: scheduler, message queue, page allocator, service table.

Compiled size targets:

| CPU | Goal |
|---|---|
| 6502 | ≤ 6 KB (cc65) — fits in ROM with room left for the monitor |
| 68000 | ≤ 12 KB |
| 8086 | ≤ 10 KB |
| RISC-V | ≤ 10 KB |

These are tight but not absurd. Real microkernels (selL4 around 10 K SLOC and ~150 KB compiled, but with much more ambitious features) are bigger; we have less to do.

## Open design questions

- **Scheduler policy**: round-robin is the boring/safe choice. Priorities help interactive responsiveness. Pick one for v1?
- **Page-grain on the 6502**: probably 256 bytes (one page in 6502 terminology). Coarser pages waste memory; finer is impractical.
- **Service registration**: by ID (compile-time number) or by name (lookup at runtime)? Names are nicer; IDs are smaller.
- **Memory protection on hostswithout MMUs**: enforce by convention plus runtime bounds checks in the kernel's IPC path? Or don't try, and accept that 6502 / 8086-real-mode systems are best-effort?

## Dependencies

- **A bootloader** that can load the kernel image
- **A working main board** (any CPU)
- **At least one driver** in the [driver library](/learn-fpga/projects/driver-library/) so the kernel has something to demonstrate IPC against — typically the UART driver first

## Next steps

1. Decide the IPC primitive set (send, receive, reply, call, replywait, …) — borrowed from L4 with a minimal subset.
2. Write the 68k port first (most forgiving target).
3. Write a "hello world" service: a UART output thread that takes messages and prints them.
4. Add the scheduler.
5. Port to 6502; document where the 6502 falls short of the real microkernel definition.

Contributions wanted: anyone who's done a microkernel before, reviewers comfortable with IPC design, kernel implementers willing to write the per-CPU porting layer.
