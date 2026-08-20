![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# AgilA8 - an 8-bit Microcontroller
Agila is Tagalog for "eagle" - specifically evoking the Philippine Eagle (Haribon), the country's national bird. AgilA8 pairs that with A8, the name of the CPU core at the center of the design: Agil + A8 = AgilA8, the two overlapping on a shared capital A.

## Layout 
![Uploading image.png…]()


3D Viewer: https://gds-viewer.tinytapeout.com/?model=https://alexandercoabad.github.io/AgilA8_mcu/tinytapeout.oas&pdk=sky130A


## How it works

AgilA8 is a compact 8-bit microcontroller built around A8, a custom
16-instruction CPU (see `docs/ISA.md`), with memory-mapped GPIO, a 16-bit
timer, and PWM generation.

 `ram32` is a
plain 128-byte flip-flop array (1,024 flip-flops), not a dense macro -
this project originally moved DMEM off-chip specifically because a 1x2
tile budget doesn't fit that (even Tiny Tapeout's own dense RAM32 hard
macro, the same 128 bytes laid out efficiently, needs 3x2 tiles on its
own; a plain flip-flop array is larger still). **This project now
targets 6x2 tiles** (see `info.yaml`'s `tiles` field) specifically to
accommodate `ram32` at this size - that's a deliberate area/cost
tradeoff made in exchange for on-chip DMEM and an optional-for-data
Pmod, not an oversight. Still worth confirming against the actual
post-place-and-route cell/utilization numbers once this goes through
`harden` again, the same way the 1x2 numbers were confirmed against the
real GDS run before this change.

A third front-end, a general-purpose SPI master intended for driving an
external device (an LCD, an ADC, another MCU), shares the same physical
lines using CS2. **This requires one board modification first**: on the
stock QSPI Pmod, CS2 ("RAM B") is wired directly to a second, populated
PSRAM chip, not out to any external connector pin. Per the Pmod's own
documentation ([mole99/qspi-pmod](https://github.com/mole99/qspi-pmod)),
each of its three chip-select traces can be cut on the back of the
board - doing so for CS2 disables that second PSRAM chip (a 1k pull-up
holds its `/CS` disabled) and makes the pad available via a through-hole
header pin as a plain input or output. That's a documented, intended
modification on the board as sold, not a custom respin - and it leaves
flash (CS0) and RAM A (CS1) untouched, so IMEM/DMEM are unaffected.
Until that trace is cut, this peripheral is functionally inert: CS2
still selects the live RAM B chip, so its transfers just talk to that
PSRAM with the wrong command protocol rather than reaching any external
device. See `spi_ctrl.v`'s header for the full explanation.

All three front-ends (flash, PSRAM, and the general-purpose SPI
controller) are driven by one shared SPI shift engine rather than three
separate FSMs, since they're never active at the same time (see below)
and consolidating saves real area - roughly 85 flip-flops for the
shared engine plus three thin front-ends, versus about 196 flip-flops
for three independent controllers.

Because `imem_valid` and `dmem_valid` are never asserted in the same
cycle (fetch and memory-access are separate, sequential states in the
core's FSM), and the DMEM-side peripherals are mutually exclusive by
address decode, the shared engine can grant flash/PSRAM/SPI with a
simple fixed-priority mux rather than needing real bus arbitration -
by construction, at most one of the three is ever requesting at once.

### Address map

| Address range | Device                                  |
| -------------- | --------------------------------------- |
| 0x00 - 0x7F    | RAM (on-chip `ram32` - see area caveat above) |
| 0x80 - 0xEF, 0xF5 - 0xF7 | RAM (external PSRAM, RAM A) |
| 0xF0 - 0xF2    | GPIO                                    |
| 0xF3 - 0xF4    | SPI (general-purpose - requires a board mod, see below) |
| 0xF8 - 0xFB    | Timer                                   |
| 0xFC - 0xFD    | PWM                                     |

> **Note:** `0xF3`/`0xF4` used to be plain RAM in earlier revisions of
> this design. They now belong to the general-purpose SPI controller
> (see below) - any program that stored ordinary data at those two
> addresses will now silently hit the SPI controller instead of RAM.
> That controller only reaches an external device once the QSPI Pmod's
> RAM B chip-select trace has been cut (see "How it works" below) - on
> an unmodified board, writes there are functional but only reach the
> still-populated internal PSRAM chip, not anything external.

Instructions are fetched separately, as two consecutive bytes from
external flash (big-endian: high byte at PC, low byte at PC+1) - flash
isn't part of the 8-bit DMEM address space above.

### IO

| # | Input       | Output       | Bidirectional                    |
| - | ----------- | ------------ | --------------------------------- |
| 0 | GPIO in 0   | GPIO out 0   | Flash CS (CS0)                    |
| 1 | GPIO in 1   | GPIO out 1   | SD0 - MOSI (shared flash/PSRAM)   |
| 2 | GPIO in 2   | GPIO out 2   | SD1 - MISO (shared flash/PSRAM)   |
| 3 | GPIO in 3   | GPIO out 3   | SCK (shared flash/PSRAM)          |
| 4 | GPIO in 4   | GPIO out 4   | SD2 (held high, unused)           |
| 5 | GPIO in 5   | GPIO out 5   | SD3 (held high, unused)           |
| 6 | GPIO in 6   | GPIO out 6   | RAM A CS (CS1)                    |
| 7 | GPIO in 7   | PWM output   | SPI CS (CS2, general-purpose SPI - requires cutting the RAM B trace first, see below) |


#### GPIO

| Register | Address     | Description                                                      |
| -------- | ----------- | ------------------------------------------------------------------ |
| GPIO_OUT | 0xF0 (R/W)  | Write sets `uo_out[6:0]`; read returns the last value written    |
| GPIO_IN  | 0xF1 (R)    | Reads the current state of `ui_in[7:0]`                          |
| GPIO_DIR | 0xF2 (R/W)  | Read/write register; not wired to anything (`ui_in`/`uo_out` are fixed-direction TT pins, so there's no direction to control) |

`uo_out[7]` is dedicated to the PWM output, not GPIO - a write of
`0xAA` to GPIO_OUT reads back as `0xAA` internally, but only
`uo_out[6:0]` (`0x2A` in that example) reaches a physical pin.

#### SPI (general-purpose) - requires a board modification first

This peripheral's register interface (`SPI_DATA`/`SPI_CTRL` below) is
correct SPI-master logic, but **it needs one physical modification to
the QSPI Pmod before it can reach anything external**. On the stock
board, CS2 ("RAM B") is wired directly to a second, populated PSRAM
chip - using this peripheral as-is just sends SPI traffic to that real
PSRAM using the wrong command set, and reaches no external device.

Per the Pmod's own documentation
([mole99/qspi-pmod](https://github.com/mole99/qspi-pmod)): each of the
three chip-select traces on the board can be cut, on the back of the
PCB, to disable that chip - a 1k pull-up then holds its `/CS` disabled,
and the pad becomes available via a through-hole header pin as a plain
input or output. Cutting **CS2's** trace specifically disables RAM B
and frees exactly the pin this peripheral needs - flash (CS0) and RAM A
(CS1) are untouched, so IMEM/DMEM keep working normally. This is a
documented, intended modification on the board as sold, not a custom
PCB respin.

Until that cut is made, treat this peripheral as inert. If you don't
want to modify the board (or just want the simplest path for something
like an e-paper display, which is slow enough that bit-banging is a
non-issue), drive the external device over the GPIO pins in software
instead - `uo_out[6:0]` and `ui_in[7:0]` are on a separate header from
the QSPI Pmod's `uio` bus entirely, so they aren't affected by any of
the above either way.

| Register | Address     | Description                                                        |
| -------- | ----------- | -------------------------------------------------------------------- |
| SPI_DATA | 0xF3 (R/W)  | Write: shifts the byte out (CS auto-asserted for the transfer, **blocking** until the 8-bit transfer physically completes). Read: returns the byte simultaneously shifted in from MISO during the most recent transfer, without starting a new one - to read a byte from a slave, write a dummy `0x00` and then read DATA back (standard full-duplex SPI) |
| SPI_CTRL | 0xF4 (R/W)  | Bits[1:0] = SCK clock divider: `00` = fastest (~sys_clk/2, matches flash/PSRAM speed), `01` = ~sys_clk/8, `10` = ~sys_clk/32, `11` = ~sys_clk/128 (**reset default** - start slow, let software speed up once the attached device's timing is known to tolerate it) |

Each `SPI_DATA` write is deliberately blocking rather than
fire-and-forget: the core has no instruction cache, so the very next
instruction fetch also needs this same shared bus. Blocking keeps this
peripheral's transfers inside the same single-active-transaction
invariant the shared engine already depends on for flash/PSRAM, with no
separate arbitration hardware needed. CS is likewise auto-pulsed per
byte (asserted only during the active transfer) rather than held low
across a logical multi-byte burst - genuinely continuous bursts aren't
possible on this hardware anyway, since unrelated flash-fetch traffic
would otherwise appear on the shared lines mid-burst; auto-pulsing at
least keeps CS deasserted while that happens, so the attached device
correctly ignores it.

#### Timer

| Register    | Address     | Description                                                    |
| ----------- | ----------- | ---------------------------------------------------------------- |
| TIMER_LO    | 0xF8 (R)    | Bits 7:0 of the free-running 16-bit counter                    |
| TIMER_HI    | 0xF9 (R)    | Bits 15:8 of the counter                                       |
| TIMER_CTRL  | 0xFA (R/W)  | Bit 0 = enable (counts up once per clock while set). Writing bit 1 = 1 resets the counter to 0 |
| TIMER_FLAG  | 0xFB (R/W)  | Bit 0 = overflow (set when the counter wraps past 0xFFFF); any write clears it |

#### PWM

| Register  | Address     | Description                                                        |
| --------- | ----------- | ---------------------------------------------------------------------- |
| PWM_DUTY  | 0xFC (R/W)  | 8-bit duty cycle out of a free-running 256-cycle period. `0xFF` is a special-cased always-on |
| PWM_CTRL  | 0xFD (R/W)  | Bit 0 = enable. Output is forced low whenever disabled, regardless of PWM_DUTY |

## How to test

1. Program the test image onto the Pmod's flash chip (`test/imem.hex`,
   built by `test/build_prog.py` - exercises every opcode plus the GPIO,
   timer, and PWM registers) and leave the PSRAM chip's contents as-is;
   the program initializes any RAM it depends on.
2. Reset the design (`rst_n` low then high).
3. Run the clock. The CPU fetches from flash and reads/writes RAM over
   the shared SPI bus automatically - no host intervention needed once
   running.
4. Check final state against the golden reference model
   (`test/golden.py`) - `test/TESTING.md` and `test/TESTING_round2.md`
   document the expected register values, and the pipeline this was
   last verified against.

Before committing to a tapeout, the QSPI Pmod flash-read timing margin
(`read_delay_cfg`, now handled centrally in `qspi_shared_engine.v`) is
worth validating on real hardware first, since interconnect delay isn't
visible in behavioral simulation - see the FPGA bring-up guide for the
Tiny Tapeout FPGA Development Kit + QSPI Pmod path used for that.

## External hardware

- [Tiny Tapeout QSPI Pmod](https://store.tinytapeout.com/products/QSPI-Pmod-p716541602),
  plugged into the demoboard's bidirectional Pmod header. The flash chip
  (program memory) and one of the two PSRAM chips (RAM A, data memory)
  are used as designed. The second PSRAM chip (RAM B / CS2) needs its
  chip-select trace cut on the back of the Pmod PCB (documented,
  intended modification - see
  [mole99/qspi-pmod](https://github.com/mole99/qspi-pmod)) before the
  general-purpose SPI peripheral can drive an external device through
  it; on an unmodified board that peripheral just talks to the
  still-populated RAM B chip instead of anything external.
- Without that modification, drive an external SPI device (e.g. an
  e-paper display) over the separate `ui_in`/`uo_out` GPIO header
  instead, bit-banging the protocol in software - that header is
  independent of the QSPI Pmod's `uio` bus and works either way.
- Tiny Tapeout demoboard, or the
  [FPGA Development Kit](https://store.tinytapeout.com/products/FPGA-Development-Kit-p813805747)
  for pre-tapeout bring-up on real silicon-adjacent hardware.


# Acknowledgments & Attribution

This file documents the open-source tools, process design kit, and prior
art that AbadMCU depends on or was inspired by. It's split into two
categories that are easy to conflate but legally distinct:

1. **Tools and IP actually incorporated into this design** - their
   licenses (all Apache-2.0) place real obligations on redistribution.
2. **Architectural inspiration from prior projects** - no code was
   copied from these; crediting them is good academic/community
   practice, not a license requirement, since taking inspiration from
   a *design pattern* (as opposed to copying source text) isn't a
   Copyright event.

---

## 1. Tools & IP incorporated into this design (Apache-2.0)

The physical chip (GDS) produced from this repository directly embeds
standard-cell layouts from, and was built using, the following
Apache-2.0-licensed projects. Their copyright notices are reproduced
below per Apache-2.0 \u00a74; none of them ship a separate `NOTICE` file as
of this writing (checked: skywater-pdk's repository root contains only
`LICENSE` and `AUTHORS`, no `NOTICE` - worth re-checking the others
listed here yourself before a formal release, since this wasn't
exhaustively verified for every entry.

### SkyWater SKY130 PDK
The standard-cell library design was synthesized and hardened
against.

```
Copyright 2020 SkyWater PDK Authors
Licensed under the Apache License, Version 2.0 (the "License");
may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0
```
Source: https://github.com/google/skywater-pdk

### open_pdks
PDK build/installer tooling used to assemble the sky130 PDK for the
hardening flow.

Source: https://github.com/fossi-foundation/open-pdks (Apache-2.0)

### OpenLane / OpenROAD
The RTL-to-GDS tool flow (synthesis, place & route, STA, DRC/LVS) that
produced this design's GDS.

```
OpenLane is \u00a92020-2024 Efabless Corporation and is available under
the Apache License, version 2.0.
```
Source: https://github.com/The-OpenROAD-Project/OpenLane

If citing academically:
> M. Shalan and T. Edwards, "Building OpenLANE: A 130nm OpenROAD-based
> Tapeout-Proven Flow," 2020 IEEE/ACM International Conference on
> Computer-Aided Design (ICCAD), San Diego, CA, USA, 2020, pp. 1-6.

### Tiny Tapeout project templates / tt-support-tools
The `tt_um_*` port convention, `info.yaml` schema, and CI/build
scaffolding this repo's structure follows.

Source: https://github.com/TinyTapeout (templates are Apache-2.0 by
default per Tiny Tapeout's own FAQ)

---

## 2. Architectural inspiration (no code reused)

AgilA8's central design decision - CPU with no on-chip memory,
program fetched from external QSPI flash, working data in external
QSPI PSRAM, sharing physical SPI wires between them via a separate chip
selects - follows the same strategic pattern pioneered on Tiny Tapeout
by the following projects. **No RTL, ISA encoding, or source code from
either project was copied** - AgilA8's CPU core, instruction set, and
peripheral RTL were independently designed and implemented. What's
credited here is the *architectural pattern*, not any specific
implementation of it.

### TinyQV (Michael Bell)
First (and to date, most complete) demonstration of this
flash+PSRAM-over-shared-QSPI-Pmod pattern on Tiny Tapeout, including
the specific convention of a single active chip-select and
code-execution-restricted-to-flash.

Source: https://github.com/MichaelBell/tinyQV (Apache-2.0)

### KianV (Hirosh Dabui / splinedrive)
Independent, earlier demonstration of the same external-memory-over-QSPI
pattern (both the uLinux and bare-metal editions), predating this
project.

Source: https://github.com/splinedrive/kianRiscV,
https://github.com/TinyTapeout/KianV-RV32IMA-RISC-V-uLinux-SoC
(check the repository's own LICENSE file directly before citing a
specific license - it wasn't confirmed via an explicit license badge
at the time this was written)

### RISC-V (conceptual influence only)
A8's `r0`-hardwired-to-zero convention and load/store architectural
style are modeled on RISC-V's design philosophy. RISC-V is an open,
freely usable ISA specification; no code is reused here, so this
carries no license obligation. **TT8 is not RISC-V-compliant** - it's
a custom 16-bit-instruction, 8-bit-datapath ISA in the RISC-V style,
and should not be described as a RISC-V implementation or use the
RISC-V trademark/logo.

---

## 3. What's original to this project

- The A8 instruction encoding (16-bit fixed-width, R-type/I-type
  split, the specific opcode table) is a custom design, not derived
  from any existing ISA's bit layout.
- All RTL in this repository (`a8_core.v`, `a8_alu.v`,
  `a8_regfile.v`, `a8_peripherals.v`, `qspi_shared_engine.v`,
  `spi_ctrl.v`, `tt_um_agila8.v`) was independently written for
  this project. `qspi_shared_engine.v` consolidates what were
  previously three separate controllers (`qspi_flash_reader.v` for
  flash, `qspi_psram_ctrl.v` for PSRAM, and `spi_ctrl.v` for the
  general-purpose SPI peripheral) into one shared engine - see that
  file's header for why, and `spi_ctrl.v`'s own header/testbench for
  the general-purpose SPI register semantics it still documents even
  though it isn't the module instantiated in the final design.
- The verification suite, bug fixes, and STA signoff analysis
  documented in this repository's history are this project's own work.

---

## Unverified claims to double-check before formal publication

- A code comment (originally in `qspi_flash_reader.v`, which may or may
  not still be present in the repo as reference material - it isn't
  part of the module actually instantiated after the merge) attributes
  a ~20ns round-trip timing margin figure to "TinyQV's own QSPI
  controller comments." This has not been independently confirmed
  against TinyQV's actual source - verify both the exact figure/its
  origin, and which file it currently lives in, before citing it as a
  TinyQV-derived fact.
- The Apache-2.0 NOTICE-file check above was only performed for
  skywater-pdk; confirm the other three Apache-2.0 entries (open_pdks,
  OpenLane, Tiny Tapeout templates) don't ship their own NOTICE files
  before finalizing this document, since if any of them do, its
  contents would need to be reproduced here per \u00a74(d).

