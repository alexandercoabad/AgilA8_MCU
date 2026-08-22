OP = dict(NOP=0,ADD=1,ADDI=2,HALT=0xF)
def itype(op, rd, rs1, imm6):
    imm6 &= 0x3F
    return (OP[op] << 12) | (rd << 9) | (rs1 << 6) | imm6

words = [itype('ADDI', 4, 0, 31), itype('HALT', 0, 0, 0)]
mem = bytearray(512)
for i, w in enumerate(words):
    mem[i*2] = (w>>8)&0xFF
    mem[i*2+1] = w&0xFF
with open('imem.hex', 'w') as f:
    for b in mem:
        f.write(f"{b:02x}\n")
print("tiny flash image written")
