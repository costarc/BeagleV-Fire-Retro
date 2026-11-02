"""ROM images for tb_z80sys.v, one byte per line (hex): rom0.hex (32 KB) and rom1.hex (16 KB).

  python3 gen_z80_roms.py <mach> <out dir> [rom file]
    0  the CP-300: a test program (fills $4000-$40FF with the low address byte, writes $A5 to $5000 and ($4010) to $5001)
    2  the MSX1: C-BIOS (rom0 = cbios_main_msx1.rom, rom1 = cbios_logo_msx1.rom; the rom file argument is the C-BIOS folder)
    3  the ZX Spectrum: the 48K ROM (rom0, 16 KB; the rom file is a 16 KB ROM, or a ROM set holding it: the 16 KB whose
       copyright message reads "1982 Sinclair Research" is taken)
    4  the MC-1000: its 16 KB ROM (rom0)
    7  the CP-400's floppy controller: a 6809 test program as Color BASIC (reads sector 3 of track 0 through the WD1793 at $FF48 with the HALT handshake)
    6  the MSX1's disk interface: a test program as the BIOS (reads sector 3 of track 0 through the WD1793 of slot 2)
ROMs are copyrighted (except C-BIOS and the test program): never commit them, nor the hex files.
"""
import os
import sys

mach, out = int(sys.argv[1]), sys.argv[2]
rom0, rom1 = bytes(), bytes()
if mach == 0:
    rom0 = bytes([0xF3, 0x21, 0x00, 0x40, 0x7D, 0x77, 0x2C, 0x20, 0xFB, 0x3E, 0xA5, 0x32, 0x00, 0x50,
                  0x3A, 0x10, 0x40, 0x32, 0x01, 0x50, 0x18, 0xFE])
elif mach == 2:
    d = sys.argv[3]
    rom0 = open(os.path.join(d, "cbios_main_msx1.rom"), "rb").read()
    rom1 = open(os.path.join(d, "cbios_logo_msx1.rom"), "rb").read()
elif mach == 3:
    d = open(sys.argv[3], "rb").read()
    if len(d) == 16384 and d[:8] == bytes.fromhex("f3af11ffffc3cb11"):
        rom0 = d                      # a plain 16 KB ROM that starts like the Spectrum's (the Brazilian TK90X: Portuguese messages)
    for i in range(0, len(d), 16384) if not rom0 else ():
        c = d[i:i + 16384]
        if c[:8] == bytes.fromhex("f3af11ffffc3cb11") and b"1982 Sinclair Research" in c:
            rom0 = c
            break
    if not rom0:
        raise SystemExit("no 48K ROM in " + sys.argv[3])
elif mach == 6:
    def jr(op, frm, to):
        return bytes([op, (to - (frm + 2)) & 255])
    prog = bytearray(32768)
    code = bytes([
        0xF3,                         # 0000 DI
        0x3E, 0xC0, 0xD3, 0xA8,       # 0001 page 3 = slot 3 (RAM)
        0x31, 0x00, 0xF0,             # 0005 LD SP,F000
        0x3E, 0xE8, 0xD3, 0xA8,       # 0008 pages 1 and 2 = slot 2 (the disk interface; the ROM's transfer loops use it in page 2: $BFBB)
        0x3A, 0x00, 0x40, 0x32, 0x00, 0xF1,   # 000C LD A,(4000) ; LD (F100),A   the disk ROM's first byte
        0x3E, 0x09, 0x32, 0xBC, 0x7F,         # 0012 drive 0 (one-hot 1), motor on
        0xAF, 0x32, 0xB8, 0x7F,               # 0017 RESTORE
        0xCD, 0x80, 0x00,                     # 001B CALL wait_intrq
        0x3A, 0xB8, 0x7F, 0x32, 0x01, 0xF1,   # 001E status -> F101
        0x3E, 0x03, 0x32, 0xBA, 0x7F,         # 0024 sector register = 3
        0xAF, 0x32, 0xB9, 0x7F,               # 0029 track register = 0
        0x3E, 0x80, 0x32, 0xB8, 0x7F,         # 002D READ SECTOR
        0x21, 0x00, 0xE0,                     # 0032 LD HL,E000
        0x01, 0x00, 0x02,                     # 0035 LD BC,0200
        0x3A, 0xBC, 0xBF, 0xCB, 0x77,         # 0038 loop: LD A,(BFBC) ; BIT 6,A  (/DRQ: low = a byte is ready)
        0x20, 0xF9,                           # 003D JR NZ,loop
        0x3A, 0xBB, 0xBF, 0x77, 0x23,         # 003F LD A,(BFBB) ; LD (HL),A ; INC HL
        0x0B, 0x78, 0xB1,                     # 0044 DEC BC ; LD A,B ; OR C
        0x20, 0xEF,                           # 0047 JR NZ,loop
        0xCD, 0x80, 0x00,                     # 0049 CALL wait_intrq
        0x3A, 0xB8, 0x7F, 0x32, 0x02, 0xF1,   # 004C status -> F102
        0x3E, 0x5A, 0x32, 0x03, 0xF1,         # 0052 done marker -> F103
        # the cassette input (PSG register 14, bit 7): count its changes in 2048 reads
        0x3E, 0x0E, 0xD3, 0xA0,               # 0057 PSG register 14
        0x06, 0x00,                           # 005B LD B,0
        0xDB, 0xA2, 0xE6, 0x80, 0x4F,         # 005D IN A,(A2) ; AND 80 ; LD C,A
        0x11, 0x00, 0x08,                     # 0062 LD DE,0800
        0xDB, 0xA2, 0xE6, 0x80, 0xB9,         # 0065 loop2: IN A,(A2) ; AND 80 ; CP C
        0x28, 0x02, 0x4F, 0x04,               # 006A JR Z,skip ; LD C,A ; INC B
        0x1B, 0x7A, 0xB3, 0x20, 0xF2,         # 006E DEC DE ; LD A,D ; OR E ; JR NZ,loop2
        0x78, 0x32, 0x10, 0xF1,               # 0073 LD A,B ; LD (F110),A
        0x18, 0xFE])                          # 0077 JR $
    assert len(code) == 0x79, hex(len(code))
    prog[0:len(code)] = code
    prog[0x80:0x88] = bytes([0x3A, 0xBC, 0x7F, 0xCB, 0x7F, 0x28, 0xF9, 0xC9])   # wait_intrq: LD A,(7FBC) ; BIT 7,A ; JR Z,wait ; RET
    rom0 = bytes(prog)
elif mach == 7:
    code = bytes([
        0x10, 0xCE, 0x7E, 0x00,               # A000 LDS #$7E00
        0x86, 0x09, 0xB7, 0xFF, 0x40,         # A004 LDA #$09 ; STA $FF40   drive 0, motor on
        0x86, 0x00, 0xB7, 0xFF, 0x48,         # A009 RESTORE
        0xB6, 0xFF, 0x48, 0x85, 0x01, 0x26, 0xF9,   # A00E wait: LDA $FF48 ; BITA #1 ; BNE wait
        0x86, 0x03, 0xB7, 0xFF, 0x4A,         # A015 sector register = 3
        0x4F, 0xB7, 0xFF, 0x49,               # A01A track register = 0
        0x86, 0x80, 0xB7, 0xFF, 0x48,         # A01E READ SECTOR (the command first: with the halt enable set the CPU would stop at once)
        0x86, 0x89, 0xB7, 0xFF, 0x40,         # A023 halt enable + motor + drive 0
        0x8E, 0x40, 0x00, 0xC6, 0x00,         # A028 LDX #$4000 ; LDB #0 (256 bytes)
        0xB6, 0xFF, 0x4B, 0xA7, 0x80, 0x5A, 0x26, 0xF8,   # A02D loop: LDA $FF4B ; STA ,X+ ; DECB ; BNE loop
        0xB6, 0xFF, 0x48, 0x85, 0x01, 0x26, 0xF9,         # A035 wait2: LDA $FF48 ; BITA #1 ; BNE wait2
        0xB7, 0x41, 0x00,                     # A03C STA $4100  (the status)
        0x86, 0x5A, 0xB7, 0x41, 0x01,         # A03F done marker
        # the SAM's page 1: with P1 set the CPU's $4200 is RAM $C200; with P1 clear it is $4200
        0x86, 0x55, 0xB7, 0xFF, 0xD5,         # A044 LDA #$55 ; STA $FFD5 (P1 = 1)
        0xB7, 0x42, 0x00,                     # A049 STA $4200
        0xB7, 0xFF, 0xD4,                     # A04C STA $FFD4 (P1 = 0)
        0x20, 0xFE])                          # A04F BRA *
    assert len(code) == 0x51, hex(len(code))
    img = bytearray(b"\xff" * 8192)
    img[0:len(code)] = code
    img[0x1FFE:0x2000] = bytes([0xA0, 0x00])  # the reset vector ($BFFE)
    rom0 = bytes(img)
elif mach == 4:
    rom0 = open(sys.argv[3], "rb").read()
    if len(rom0) != 16384:
        raise SystemExit("the MC-1000 ROM is 16384 bytes")
for name, data, size in (("rom0.hex", rom0, 32768), ("rom1.hex", rom1, 16384)):
    data = data + bytes([0xFF]) * (size - len(data))
    with open(os.path.join(out, name), "w") as f:
        f.write("\n".join("%02x" % b for b in data[:size]) + "\n")
