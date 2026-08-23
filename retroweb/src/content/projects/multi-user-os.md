---
title: "Multi-User OS"
description: "Preemptive multitasking, multiple terminals, isolated user accounts. Same microkernel as the single-user OS, plus the services and policy a 'real' Unix-alike needs. 16/32-bit hosts only."
image: ./multi-user-os-card.svg
components:
  - "Built on the Retro-Active microkernel (same as single-user OS)"
  - "Process service (fork, exec, wait)"
  - "Multi-terminal multiplexer (vt100 emulation)"
  - "Per-user filesystem permissions"
  - "Optional: BSD-style network stack (later)"
order: 12
links:
  - label: "Microkernel (the layer underneath)"
    url: "/learn-fpga/projects/microkernel/"
  - label: "Single-user OS (sibling project)"
    url: "/learn-fpga/projects/single-user-os/"
---

The **maximalist OS personality** for the bus. Preemptive multitasking, multiple terminals, isolated user accounts, the works. Same [microkernel](/learn-fpga/projects/microkernel/) underneath, just with different services on top.

Status: **planned**. This is the v2 OS variant — won't see real work until the [single-user OS](/learn-fpga/projects/single-user-os/) is mature and the microkernel has proven IPC primitives at speed.

## What it adds over single-user

Going from "DOS plus Unix shell" to "real multi-user system" means adding:

1. **Preemptive multitasking** — the scheduler interrupts running processes on a timer. The single-user OS lets one program run to completion; this one switches between processes on a tick.
2. **Process isolation** — each process gets its own address space. Requires either an MMU or, on hosts without one, software-level discipline plus the kernel doing extra bounds-checking on IPC.
3. **Multiple terminals** — terminal multiplexer service that gives each user a vt100-emulated console. Switch between them with chord keys, run different programs in each.
4. **User accounts** — `/etc/passwd`, login prompt, per-user home directories, file permissions (Unix-style rwx for owner/group/other).
5. **Daemons** — long-running services like a network stack, a print spooler, a system logger.

## Why a separate project from single-user

Same kernel, same [driver library](/learn-fpga/projects/driver-library/), same on-disk format, same shell language. What changes is the *services running above the kernel*:

- `process_svc` instead of "shell forks a child and waits"
- `tty_svc` (terminal multiplexer) instead of "console is the UART"
- `auth_svc` for login / passwords
- `init_svc` that brings the system up to a multi-user state

A builder who chooses the multi-user variant gets a different `init` image and a different set of services in the boot config. Same hardware. Same drivers.

## The CPU constraint

This OS variant is **16/32-bit only.**

- A 6502 with no MMU can't enforce process isolation. You can run multiple processes cooperatively (the single-user OS does this for command pipelines), but a malicious or buggy program can corrupt anything in the 64 KB address space. That's not "multi-user" in any meaningful sense.
- A 68000 has supervisor/user mode separation. With an external MMU (the era had a few options; Motorola's MC68451 was the contemporary part) you get real isolation. Without an MMU, you get supervisor-mode protection but processes share the user-mode address space — better than the 6502 but still soft isolation.
- A 386 or later has a proper MMU and is comfortable.

A 68k system *with* an MMU is the canonical target for v1 of the multi-user OS. Without an MMU it runs but the user-isolation story is "we trust you."

## Network stack — later

The natural next thing to want is networking. The plan is:

- **Phase 1**: serial-over-UART terminal access (multiple users dialing in via modem, or via SSH-over-serial through a USB-serial adapter on a host machine)
- **Phase 2**: SLIP / PPP over UART for IP connectivity
- **Phase 3**: Ethernet via a network card (a separate project, requires designing the card)

Ethernet on a vintage CPU is realistic — see CSNet's CP/M era networking, NCSA Telnet on a Mac SE. It's just work.

## Process model

A traditional Unix `fork() + exec()` model fits the microkernel naturally:

```c
pid_t child = fork();         // microkernel duplicates the calling thread + maps
if (child == 0) {
    exec("/bin/ls", argv);    // child replaces its address space
} else {
    int status;
    wait(&status);            // parent waits
}
```

Implementation: `fork` is a syscall the `process_svc` handles. It allocates a fresh page table, copies (or marks copy-on-write) the parent's pages, and creates a new thread in the kernel. `exec` reads the binary off disk via the FS service, replaces the process's pages with the new image, jumps to the entry point.

## Dependencies

- A working **microkernel** with mature IPC
- A working **single-user OS** (this is incremental on top of it)
- A 16-bit-or-wider CPU; ideally with an MMU
- An **[I/O card](/learn-fpga/projects/io-card/)** for the console
- The **[driver library](/learn-fpga/projects/driver-library/)** populated with FS, console, and the relevant peripherals

## Next steps

1. Wait for the single-user OS to settle.
2. Spec the syscall set additions: `fork`, `exec`, `wait`, `kill`, `getpid`, `setuid`, etc.
3. Spec the on-disk passwd format and the auth service.
4. Spec the terminal-multiplexer protocol.
5. First-light on a 68k system with an MMU prototype.

Contributions wanted: anyone with experience writing small Unix-alikes (Minix, xv6 contributors), MMU specialists for the 68k, network stack implementers (when we get there).
