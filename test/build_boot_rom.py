#!/usr/bin/env python3
"""
Bootloader ROM assembler.

Protocol (all on GPIO, via GPIO_IN=0xF1):
  ui_in[0] = DATA (host drives)
  ui_in[1] = CLOCK (host drives, one pulse per bit, chip samples on the
             rising edge and waits for the falling edge before the next
             bit - a full handshake, not timed, so no baud/frequency
             matching needed on either side)
  ui_in[2] = START (host asserts high to request a bootload; sampled
             with a bounded timeout - if never seen, falls back to
             flash automatically)

Wire format once START is seen: 1 length byte (number of program bytes
to follow, MSB first per byte) then that many program bytes, each
MSB-first, each bit following the clock handshake above. Bytes are
written into on-chip instruction RAM via two peripheral registers:
IMEM_WADDR (0xF5, sets the write pointer) and IMEM_WDATA (0xF6, commits
a byte and auto-increments the pointer).

On completion, jumps to 0x0080 (IRAM base) to run the loaded program.
On timeout (no START seen), sets FLASH_MODE (0xF7) so address 0x0080
resolves to external flash instead of iram, then jumps there too -
boot_rom (0x00-0x7F) is always mapped regardless of flash_mode, so
both the successful-load and timeout paths JALR to the SAME address
(0x0080); flash_mode only changes what that address resolves to. JALR
cannot reach flash space directly if it were still based at 0x0100+,
since its target is always an 8-bit result zero-extended - see tt_um_agila8.v's header for the full
reasoning, and the timeout-path comment below for a bug this fixes.
"""

OP = dict(NOP=0,ADD=1,ADDI=2,SUB=3,AND=4,OR=5,XOR=6,SLL=7,SRL=8,
          LW=9,SW=0xA,BEQ=0xB,BLT=0xC,JAL=0xD,JALR=0xE,HALT=0xF)

def rtype(op, rd, rs1, rs2):
    return (OP[op] << 12) | (rd << 9) | (rs1 << 6) | (rs2 << 3)

def itype(op, rd, rs1, imm6):
    imm6 &= 0x3F
    return (OP[op] << 12) | (rd << 9) | (rs1 << 6) | imm6

class Asm:
    def __init__(self):
        self.instrs = []
        self.labels = {}
        self.fixups = []

    def addr(self):
        return len(self.instrs) * 2

    def label(self, name):
        self.labels[name] = self.addr()

    def emit(self, word):
        self.instrs.append(word)
        return self.addr() - 2

    def ADDI(self, rd, rs1, imm): self.emit(itype('ADDI', rd, rs1, imm))
    def ADD(self, rd, rs1, rs2):  self.emit(rtype('ADD', rd, rs1, rs2))
    def SUB(self, rd, rs1, rs2):  self.emit(rtype('SUB', rd, rs1, rs2))
    def AND(self, rd, rs1, rs2):  self.emit(rtype('AND', rd, rs1, rs2))
    def OR(self, rd, rs1, rs2):   self.emit(rtype('OR', rd, rs1, rs2))
    def XOR(self, rd, rs1, rs2):  self.emit(rtype('XOR', rd, rs1, rs2))
    def SLL(self, rd, rs1, imm):  self.emit(itype('SLL', rd, rs1, imm))
    def SRL(self, rd, rs1, imm):  self.emit(itype('SRL', rd, rs1, imm))
    def LW(self, rd, rs1, imm):   self.emit(itype('LW', rd, rs1, imm))
    def SW(self, rsrc, rs1, imm): self.emit(itype('SW', rsrc, rs1, imm))
    def NOP(self):                self.emit(itype('NOP', 0, 0, 0))
    def HALT(self):                self.emit(itype('HALT', 0, 0, 0))

    def BEQ(self, rs1, rs2_as_rd, target_label):
        idx = self.emit(itype('BEQ', rs2_as_rd, rs1, 0))
        self.fixups.append((idx, 'branch', target_label))

    def BLT(self, rs1, rs2_as_rd, target_label):
        idx = self.emit(itype('BLT', rs2_as_rd, rs1, 0))
        self.fixups.append((idx, 'branch', target_label))

    def JAL(self, rd, target_label):
        idx = self.emit(itype('JAL', rd, 0, 0))
        self.fixups.append((idx, 'jal', target_label))

    def JALR(self, rd, rs1, imm): self.emit(itype('JALR', rd, rs1, imm))

    def finalize(self):
        words = list(self.instrs)
        for idx, kind, target in self.fixups:
            target_addr = self.labels[target]
            src_addr = idx
            off = (target_addr - src_addr) // 2
            assert -32 <= off <= 31, f"{kind} offset {off} out of range (target={target}, {target_addr}, from {src_addr})"
            opcode_rd_rs1 = words[idx // 2] & 0xFFC0
            words[idx // 2] = opcode_rd_rs1 | (off & 0x3F)
        return words


a = Asm()

GPIO_IN  = -15   # 0xF1
IMEM_WADDR = -11 # 0xF5
IMEM_WDATA = -10 # 0xF6
FLASH_MODE = -9  # 0xF7 (write-any-value-to-set; see tt_um_agila8.v header)

# Registers:
# r1 = timeout counter        r2 = bit/byte counter
# r3 = received byte accum    r4 = GPIO_IN scratch
# r5 = length remaining       r6 = mask constants
# r7 = link / jump-target scratch

# --- Wait for START (ui_in[2], mask 0x04) with a bounded timeout ---
a.ADDI(1, 0, 0)              # r1 = 0 (timeout counter)
a.label("WAIT_START")
a.LW(4, 0, GPIO_IN)          # r4 = GPIO_IN
a.ADDI(6, 0, 4)               # r6 = 0x04 (START bit mask)
a.AND(4, 4, 6)
a.BEQ(4, 0, "NO_START_YET")  # if (r4==0) branch ahead (start not seen)
a.JAL(0, "START_SEEN")
a.label("NO_START_YET")
a.ADDI(1, 1, 1)
a.ADDI(6, 0, 31)              # timeout threshold (small for test purposes -
                               # real deployment would want this much
                               # larger; kept small here so simulation
                               # doesn't need an enormous cycle budget)
a.BLT(1, 6, "WAIT_START")
# timeout expired - jump to flash fallback via FLASH_MODE (0xF7).
#
# *** BUG FIX (see chat): two separate issues here.
#
# (1) JALR's target is ALWAYS {8'h00, ...} - an 8-bit result,
# zero-extended (confirmed in a8_core.v/a8_alu.v) - so no register
# value can make JALR reach 0x0100 or beyond, full stop. An earlier
# version tried `SLL r7, r7, 6` to compute 0x100 directly into r7,
# intending to JALR straight to flash space - but a8_alu.v's SLL
# result is declared [7:0], so 4<<6=256 silently truncates to 0. r7
# ended up 0x00, not 0x100.
#
# (2) The fix for (1) - writing FLASH_MODE then JALR to 0x0000 - was
# ITSELF wrong once tt_um_agila8.v's boot_rom_hit became unconditional
# (a separate, necessary fix: boot_rom has to stay mapped regardless
# of flash_mode, since the SW+JALR sequence setting the flag is itself
# stored there and needs to keep fetching correctly until the JALR
# completes). With boot_rom unconditional, JALR to 0x0000 just re-
# enters boot_rom's own reset vector forever, regardless of
# flash_mode - it never reaches flash. What flash_mode actually
# changes is what 0x0080-0x00FF resolves to (iram normally, flash once
# set) - so this needs to JALR to 0x0080, the exact same target
# LOAD_DONE already uses below, not 0x0000.
a.SW(0, 0, FLASH_MODE)      # DMEM[FLASH_MODE] = r0 (0) - write-any-value-to-set
a.ADDI(7, 0, 2)
a.SLL(7, 7, 6)                # r7 = 2 << 6 = 0x80
a.JALR(0, 7, 0)                # jump to imem 0x0080, now backed by flash

a.label("START_SEEN")
# --- Receive length byte into r5 ---
# *** BUG FIX (see chat): a8_core.v's JAL hardwires its link register to
# r7 - ALWAYS, regardless of what rd is encoded in the instruction. This
# was empirically confirmed by simulation: with the OLD code below
# encoding rd=6, JAL still wrote the return address into r7, while r6
# sat frozen at a stale value (4, left over from the WAIT_START loop
# above) the entire time. RECV_BYTE's return then read r6 instead of
# r7, jumping to address 0x0004 (garbage) instead of back to the
# caller - confirmed directly in a cycle-by-cycle trace: r3 correctly
# decoded to 8 (the sent length byte), then pc landed at 0x0004 instead
# of continuing here.
#
# Fix: encode rd=7 (matching what the hardware actually does, so this
# isn't misleading to read later) and have every RECV_BYTE return via
# r7, not r6. r7 is safe to use as the link register everywhere it's
# called from in this program - the two other places r7 is used (the
# timeout-fallback and LOAD_DONE address math, both below) happen on
# code paths that either never call RECV_BYTE at all, or only use r7
# AFTER every RECV_BYTE call is finished, and both reload r7 fresh via
# ADDI immediately before using it - no live value is ever clobbered.
a.JAL(7, "RECV_BYTE")          # r7 = link register (ALWAYS r7 - see above)
a.ADD(5, 3, 0)                  # r5 = r3 (length)

# --- IMEM write pointer starts at IRAM base (0x80, not 0x40 - the
#     routine itself is 90 bytes, past the old 64-byte/0x40 boundary;
#     see chat for why this moved rather than trying to shrink the
#     routine to fit the old budget) ---
a.ADDI(2, 0, 2)
a.SLL(2, 2, 6)                  # r2 = 2 << 6 = 0x80
a.SW(2, 0, IMEM_WADDR)          # IMEM_WADDR = 0x40

a.label("BYTE_LOOP")
a.BEQ(5, 0, "LOAD_DONE")        # while (r5 != 0)
a.JAL(7, "RECV_BYTE")           # r3 = received byte
a.SW(3, 0, IMEM_WDATA)           # IMEM_WDATA = r3 (auto-increments pointer)
a.ADDI(5, 5, -1)
a.JAL(0, "BYTE_LOOP")

a.label("LOAD_DONE")
a.ADDI(7, 0, 2)
a.SLL(7, 7, 6)                   # r7 = 2 << 6 = 0x80 (IRAM base)
a.JALR(0, 7, 0)                  # jump to the loaded program

# --- RECV_BYTE subroutine: receives 8 bits MSB-first into r3, returns
#     via JALR through the link register a8_core.v's JAL always uses:
#     r7 (hardwired, regardless of any rd field encoded in the calling
#     JAL instruction - see the bug-fix note above) ---
a.label("RECV_BYTE")
a.ADDI(3, 0, 0)                  # r3 = 0 (accumulator)
a.ADDI(2, 0, 0)                  # r2 = bit counter (reused - safe, caller
                                  # doesn't need r2 live across this call
                                  # except BYTE_LOOP, which reloads it
                                  # from IMEM_WADDR semantics, not r2 -
                                  # actually BYTE_LOOP doesn't use r2 at
                                  # all after the initial pointer setup,
                                  # so clobbering it here is safe)
a.label("BIT_LOOP")
a.label("BIT_WAIT_HIGH")
a.LW(4, 0, GPIO_IN)
a.ADDI(1, 0, 2)                   # r1 = 0x02 (CLOCK bit mask) - r1 safe to
                                   # reuse here, timeout counter no longer
                                   # needed post-START
a.AND(4, 4, 1)
a.BEQ(4, 0, "BIT_WAIT_HIGH")      # loop while clock==0

a.LW(4, 0, GPIO_IN)               # sample DATA on the high clock
a.ADDI(1, 0, 1)                    # r1 = 0x01 (DATA bit mask)
a.AND(4, 4, 1)
a.SLL(3, 3, 1)                      # r3 <<= 1
a.BEQ(4, 0, "SKIP_OR")             # if data bit == 0, skip the OR
a.OR(3, 3, 1)                       # NOTE: ORs in the mask value (0x01)
                                     # not a full "1" - safe here since
                                     # r3's LSB is guaranteed 0 right
                                     # after the shift above
a.label("SKIP_OR")

a.label("BIT_WAIT_LOW")
a.LW(4, 0, GPIO_IN)
a.ADDI(1, 0, 2)
a.AND(4, 4, 1)
a.BLT(0, 4, "BIT_WAIT_LOW")        # loop while clock still 1 (0 < r4)

a.ADDI(2, 2, 1)
a.ADDI(1, 0, 8)
a.BLT(2, 1, "BIT_WAIT_HIGH")        # while (bitcount < 8) do next bit

a.JALR(0, 7, 0)                      # return to caller via r7 (link reg -
                                       # see bug-fix note above)

words = a.finalize()
print(f"Boot ROM is {len(words)*2} bytes ({len(words)} instructions)")
assert len(words) * 2 <= 128, f"exceeds 128-byte boot ROM budget: {len(words)*2} bytes"

with open('boot_rom.hex', 'w') as f:
    for w in words:
        f.write(f"{(w>>8)&0xFF:02x}\n{w&0xFF:02x}\n")

# Also emit a Verilog case-statement ROM body
with open('boot_rom_body.vh', 'w') as f:
    for i, w in enumerate(words):
        addr = i * 2
        f.write(f"        7'h{addr:02x}: data = 8'h{(w>>8)&0xFF:02x};\n")
        f.write(f"        7'h{addr+1:02x}: data = 8'h{w&0xFF:02x};\n")

print("Wrote boot_rom.hex and boot_rom_body.vh")
for name, a_ in sorted(a.labels.items(), key=lambda kv: kv[1]):
    print(f"  {name:20s} 0x{a_:02x}")
