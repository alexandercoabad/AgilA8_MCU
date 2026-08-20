<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->


## How it works

AgilA8 is a compact 8-bit microcontroller built around A8, a custom
16-instruction CPU (see `docs/ISA.md`), with memory-mapped GPIO, a 16-bit
timer, and PWM generation.

Instruction memory (all of it) and most of data memory live off-chip
on the Tiny Tapeout QSPI Pmod. Program code is fetched from external
SPI flash (CS0) using a standard `03h` Read Data command; the bulk of
data memory (0x80-0xEF) lives on one of the Pmod's two PSRAM chips
(RAM A / CS1) using standard `02h`/`03h` Write/Read commands. Only
plain, single-line SPI commands are used for flash/PSRAM - deliberately
not flash's continuous-read mode or PSRAM's QPI mode, both of which need
a mode-byte/setup sequence that's easy to get subtly wrong without
hardware to verify against.

The low 128 bytes of DMEM (0x00-0x7F) are on-chip instead, in `ram32`,
making the QSPI Pmod optional for software that stays within that
range - **flash is still required for IMEM regardless**, so the Pmod
as a whole is not optional, only the DMEM side of it. `ram32` is a
plain 128-byte flip-flop array (1,024 flip-flops), not a dense macro -
this project originally moved DMEM off-chip specifically because a 1x2
tile budget doesn't fit that (even Tiny Tapeout's own dense RAM32 hard
macro, the same 128 bytes laid out efficiently, needs 3x2 tiles on its
own; a plain flip-flop array is larger still). **This project now
targets 3x2 tiles** (see `info.yaml`'s `tiles` field) specifically to
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
