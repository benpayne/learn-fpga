---
title: "Single-User OS"
description: "DOS sensibilities, Unix CLI. One program at a time, FAT32 filesystem, a Bourne-style shell with pipes and redirection. Targets the 6502 and other tight machines."
image: ./single-user-os-card.svg
components:
  - "Built on the Retro-Active microkernel"
  - "Bourne-style shell (sh) with pipes and redirection"
  - "Coreutils-style binaries (ls, cat, cp, rm, mkdir, …)"
  - "FAT32 filesystem service"
  - "Footprint goal: ≤ 32 KB on 6502"
order: 11
links:
  - label: "Microkernel (the layer underneath)"
    url: "/learn-fpga/projects/microkernel/"
  - label: "Reference RetroKernel (FemtoRV)"
    url: "/learn-fpga/projects/femtorv-coprocessor/"
---

The **default OS personality** for tight machines: a 6502 running 32 KB of RAM, a Z80 with a similar budget, anything that wants the simplicity of "one program runs at a time, you talk to it through a shell." DOS sensibilities — boot to a prompt, run things, type `dir` and look at files. Unix CLI — pipes, redirection, lowercase commands, slash-separated paths.

Status: **design phase**, building on the existing RetroKernel work in the [FemtoRV co-processor](/learn-fpga/projects/femtorv-coprocessor/).

## What it feels like

```text
boot v0.1
loaded /kernel.bin (28760 bytes)
loaded /init (1240 bytes)

retro-os 0.1 (6502)
$ ls /etc
passwd  motd  shells
$ cat /etc/motd
welcome to retro-os, this thing is small but it works
$ cat /etc/motd | wc -l
1
$ ./editor /tmp/notes.txt
... (editor runs)
$ help
builtins:  cd  exit  set  unset  alias  history
$
```

That's the target. Boot to a prompt in under a second on a 6502 at 1 MHz. Pipes work. Redirection works. The shell is small enough to live in RAM with the running program; the program returns and the shell comes back.

## What's *not* here

Deliberately omitted to keep the budget honest:

- **No multitasking.** The shell runs, then it forks-and-execs a child, the child runs to completion, the shell comes back. Standard DOS / CP/M idiom.
- **No multiple users.** Anyone at the console is the user.
- **No memory protection on machines that lack an MMU.** A buggy program can corrupt the kernel. Programs are trusted.
- **No networking** in v1. A network stack is a multi-user-OS concern.

Builders who want any of those things should look at the [multi-user OS](/learn-fpga/projects/multi-user-os/) variant.

## Architecture

The single-user OS is itself a small set of services running on the [microkernel](/learn-fpga/projects/microkernel/):

```text
                ┌──────────────────┐
                │  user program    │  (one at a time)
                └────────┬─────────┘
                         │ syscalls (over IPC)
                ┌────────┴─────────┐
                │  shell (sh)      │
                └────────┬─────────┘
                         │
   ┌─────────────────────┼──────────────────────┐
   │                     │                      │
┌──┴──┐              ┌───┴────┐            ┌────┴────┐
│ FS  │              │ Console│            │ Drivers │
│(FAT)│              │ (UART) │            │ (kernel)│
└──┬──┘              └────────┘            └─────────┘
   │
┌──┴──┐
│ SD  │
│ drv │
└─────┘

           ─── microkernel ───
```

Six or so services in total. Each is a thread in the kernel's view. Each is small (a few hundred lines of C).

## Footprint

Goal: **≤ 32 KB total** on a 6502 system, including the kernel.

| Component | Target |
|---|---|
| Kernel | ≤ 6 KB |
| FS service | ≤ 4 KB |
| Console service (UART) | ≤ 1 KB |
| Driver shims (SD, video, audio) | ≤ 4 KB |
| Shell | ≤ 8 KB |
| Coreutils binaries (avg) | ≤ 1 KB each, on demand |

Coreutils are loaded from disk on demand, not kept in RAM. That's the only way the budget closes — `ls` lives on the SD card, runs, terminates, and its memory is reclaimed.

The 68k version is much more comfortable: same OS personality, but with hundreds of KB to spare. That's where you'd run an editor, a compiler, or a port of `vim`-style tooling.

## Filesystem

FAT32 read+write. Same disk format as everything else in 2026: a card written on a Mac or Linux box plugs into the SD slot and shows up. No proprietary on-disk format, no migration headache.

Path conventions are Unix-style: `/`, lowercase, no drive letters. The boot device mounts at `/`. Any second SD card or virtual disk mounts under `/mnt/...` like a sensible system.

## Shell

Bourne-style. The shell parser is small but real:

- Pipes: `cmd1 | cmd2 | cmd3`
- Redirection: `cmd > file`, `cmd < file`, `cmd >> file`
- Background: `cmd &` (works only on machines that can multitask — pretends on the 6502)
- Variables: `set FOO=bar`, `$FOO` expansion
- History: arrow keys recall previous commands

Builtins are minimal: `cd`, `exit`, `set`, `unset`, `alias`, `history`. Everything else is a binary on disk.

## Dependencies

- The **[microkernel](/learn-fpga/projects/microkernel/)** must work
- An **[I/O card](/learn-fpga/projects/io-card/)** for SD storage and the console UART
- The **[driver library](/learn-fpga/projects/driver-library/)** populated with at least SD/FAT32, UART, and one of {keyboard, display}
- A **[bootloader](/learn-fpga/projects/bootloader/)** that can load the kernel + init image

## Next steps

1. Define the syscall set (`open`, `read`, `write`, `close`, `exec`, `exit`, `dup`, `pipe`).
2. Port the existing RetroKernel shell to the new microkernel's IPC.
3. Write the FS service as a separate thread (currently inlined in RetroKernel).
4. First-light on a 68k system; then squeeze it onto a 6502.

Contributions wanted: shell implementers, anyone who's run a small Unix-alike before, FAT32 specialists, anyone with strong opinions about the syscall surface.
