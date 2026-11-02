/* Matra & Hachette Alice (= Tandy MC-10) machine around mc6803.c, PC test harness.
 *
 * Memory map (from MAME's mc10.cpp, to be re-checked against the schematic / ROM):
 *   $0000-$001F  6803 on-chip registers        $0080-$00FF  6803 on-chip RAM
 *   $4000-...    RAM (4 KB; 8/20/32 KB with expansion), also the video RAM
 *   $BFFF        write: b7 DAC (1-bit sound), b6 CSS, b5 A/G, b4 GM0, b3 GM1, b2 GM2 and INT/EXT
 *                read : keyboard rows of the columns selected on P1 (active low)
 *   $E000-$FFFF  8 KB BASIC ROM (reset vector $FFFE)
 *   P1 (out)     keyboard column strobe, active low (PB0..PB7)
 *   P2.0 out     cassette out and RS-232 TX;  P2.1 in  keyboard row 6 (CONTROL, BREAK, SHIFT);
 *   P2.2 in      RS-232 RX;  P2.3 in  CTS;  P2.4 in  cassette in
 *   VDG          reads RAM from $4000; b6 of each byte = INV, b7 = A/S (semigraphics)
 * Clock 3.579545 MHz / 4 = 894886 Hz.
 *
 * Usage:  alice --selftest
 *         alice --bench [seconds_of_machine_time]
 *         alice rom.bin [-ram bytes] [-secs n] [-type "text\n"] [-alice] [-trace]
 *         (the ROM is supplied by the user and is never committed)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "mc6803.h"

#define CPU_HZ 894886u

typedef struct {
    mc6803   cpu;
    uint8_t  rom[0x4000];
    uint32_t rom_base, rom_size, ram_base;   /* MC-10/Alice: E000/8K, $4000; Alice 32: C000/16K, $3000 */
    int      a32;
    uint8_t  ef[16];                      /* Alice 32: EF9345 registers seen at $BF20-$BF29 (stub: never busy) */
    uint32_t ef_writes;
    FILE    *eflog;
    uint8_t  ram[0x8000];
    uint32_t ram_size;
    uint8_t  keys[8];          /* keys[col] bit n set = key at row n pressed */
    uint8_t  strobe;           /* P1 output latch (columns, active low) */
    uint8_t  p1ddr;
    uint8_t  bfff;             /* last value written to $BFFF */
    uint8_t  p2_latch;
    uint32_t dac_edges, cass_edges;
    uint8_t  dac, cass_out;
    uint32_t bfff_writes, vram_writes;
    uint8_t  tape_in;          /* P2.4: the cassette input (alice_tape.h) */
} machine;

/* ---- bus ---- */

static uint8_t kbd_rows(const machine *m)
{
    uint8_t r = 0;
    int c;
    for (c = 0; c < 8; c++) if (!(m->strobe & (1u << c))) r |= m->keys[c];
    return r;
}

static uint8_t bus_rd(void *ctx, uint16_t a)
{
    machine *m = (machine *)ctx;
    if (a >= m->rom_base) return m->rom[a - m->rom_base];
    if (a >= m->ram_base && a < m->ram_base + m->ram_size) return m->ram[a - m->ram_base];
    if (m->a32 && a >= 0xBF20 && a <= 0xBF29) return a == 0xBF20 ? 0x00 : m->ef[a - 0xBF20];
    if (a == 0xBFFF) return (uint8_t)(~kbd_rows(m) | 0xC0);
    return 0xFF;
}

static void bus_wr(void *ctx, uint16_t a, uint8_t v)
{
    machine *m = (machine *)ctx;
    if (a >= m->ram_base && a < m->ram_base + m->ram_size) {
        m->ram[a - m->ram_base] = v;
        if (a < m->ram_base + 0x1800) m->vram_writes++;
    } else if (m->a32 && a >= 0xBF20 && a <= 0xBF29) {
        m->ef[a - 0xBF20] = v; m->ef_writes++;
        if (m->eflog) fprintf(m->eflog, "%llu EF[%X]=%02X\n", (unsigned long long)m->cpu.cycles, a - 0xBF20, v);
    } else if (a == 0xBFFF) {
        m->bfff = v; m->bfff_writes++;
        if ((v >> 7) != m->dac) { m->dac = (uint8_t)(v >> 7); m->dac_edges++; }
    }
}

static uint8_t port_in(void *ctx, int p)
{
    machine *m = (machine *)ctx;
    if (p == 1) {
        uint8_t v = 0xFF;
        if (kbd_rows(m) & 0x40) v &= (uint8_t)~0x02;   /* row 6 -> P2.1, active low */
        if (!m->tape_in) v &= (uint8_t)~0x10;           /* P2.4 */
        return v;
    }
    return 0xFF;
}

static void port_out(void *ctx, int p, uint8_t latch, uint8_t ddr)
{
    machine *m = (machine *)ctx;
    uint8_t pins = (uint8_t)(latch | (uint8_t)~ddr);   /* undriven inputs float high */
    if (p == 0) { m->strobe = pins; m->p1ddr = ddr; }
    if (p == 1) {
        uint8_t o = pins & 1;
        if (o != m->cass_out) { m->cass_out = o; m->cass_edges++; }
    }
}

static void machine_init(machine *m, uint32_t ram_size)
{
    memset(m, 0, sizeof *m);
    memset(m->rom, 0xFF, sizeof m->rom);
    m->ram_size = ram_size;
    m->rom_base = 0xE000; m->rom_size = 0x2000; m->ram_base = 0x4000;
    m->strobe = 0xFF;
    m->tape_in = 1;
}

static void machine_start(machine *m)
{
    mc6803_init(&m->cpu, m, bus_rd, bus_wr, port_in, port_out);
}

static void run_cycles(machine *m, uint64_t n)
{
    uint64_t end = m->cpu.cycles + n;
    while (m->cpu.cycles < end) mc6803_step(&m->cpu);
}

/* ---- keyboard ---- */

/* MC-10 matrix (MAME): column PB0..PB7, row bit 0..6. 0 = no key. */
static char kb[8][8] = {
    /* PB0 */ { '@', 'H', 'P', 'X', '0', '8', 'C'/*CTRL*/, 0 },
    /* PB1 */ { 'A', 'I', 'Q', 'Y', '1', '9', 0, 0 },
    /* PB2 */ { 'B', 'J', 'R', 'Z', '2', ':', 'K'/*BREAK*/, 0 },
    /* PB3 */ { 'C', 'K', 'S', 0, '3', ';', 0, 0 },
    /* PB4 */ { 'D', 'L', 'T', 0, '4', ',', 0, 0 },
    /* PB5 */ { 'E', 'M', 'U', 0, '5', '-', 0, 0 },
    /* PB6 */ { 'F', 'N', 'V', '\n', '6', '.', 0, 0 },
    /* PB7 */ { 'G', 'O', 'W', ' ', '7', '/', 'S'/*SHIFT*/, 0 },
};

/* Alice differences (AZERTY), same source */
static void keyboard_alice(void)
{
    kb[1][0] = 'Q'; kb[1][2] = 'A';
    kb[2][3] = 'W';
    kb[3][5] = 'M';
    kb[5][1] = '/';
    kb[7][2] = 'Z';
    kb[7][5] = ';';
}

static int find_key(char ch, int *col, int *row)
{
    int c, r;
    for (c = 0; c < 8; c++) for (r = 0; r < 8; r++)
        if (kb[c][r] == ch && !(r == 6)) { *col = c; *row = r; return 1; }
    return 0;
}

static const char *shifted_from = "!\"#$%&'()*+<=>?";
static const char *shifted_to   = "123456789:;,-./";

/* press a character for 'hold' cycles, release for 'gap' cycles */
static void type_char(machine *m, char ch, uint64_t hold, uint64_t gap)
{
    int col, row, shift = 0;
    const char *s;
    if (ch >= 'a' && ch <= 'z') ch = (char)(ch - 32);
    if ((s = strchr(shifted_from, ch)) != NULL && ch) { ch = shifted_to[s - shifted_from]; shift = 1; }
    if (ch == '\r') ch = '\n';
    if (!find_key(ch, &col, &row)) return;
    if (shift) m->keys[7] |= 0x40;
    m->keys[col] |= (uint8_t)(1u << row);
    run_cycles(m, hold);
    m->keys[col] &= (uint8_t)~(1u << row);
    m->keys[7] &= (uint8_t)~0x40;
    run_cycles(m, gap);
}

/* ---- video: text mode dump (32 x 16), 6847 internal character set ---- */

static void dump_text(const machine *m, FILE *f)
{
    int r, c;
    fprintf(f, "+--------------------------------+   mode $BFFF=%02X (%s)\n", m->bfff, (m->bfff & 0x20) ? "graphics" : "text");
    for (r = 0; r < 16; r++) {
        fputc('|', f);
        for (c = 0; c < 32; c++) {
            uint8_t v = m->ram[r * 32 + c];
            char ch;
            if (v & 0x80) ch = '#';                       /* semigraphics 4: shown as a block */
            else { ch = (char)(v & 0x3F); ch = (char)(ch < 32 ? ch + 64 : ch); }
            fputc(ch, f);
        }
        fputs("|\n", f);
    }
    fputs("+--------------------------------+\n", f);
}

/* ---- self test: a hand-assembled ROM (6803 code) ---- */

static void build_selftest_rom(machine *m)
{
    static const uint8_t code[] = {
        0x8E, 0x4F, 0xFF,         /* E000 LDS #$4FFF */
        0xCC, 0x40, 0x00,         /* E003 LDD #$4000 */
        0xDD, 0x80,               /* E006 STD $80 (pointer in on-chip RAM) */
        0xCE, 0xE0, 0x40,         /* E008 LDX #msg */
        0xA6, 0x00,               /* E00B loop: LDAA 0,X */
        0x27, 0x0E,               /* E00D BEQ done */
        0xDF, 0x82,               /* E00F STX $82 */
        0xDE, 0x80,               /* E011 LDX $80 */
        0xA7, 0x00,               /* E013 STAA 0,X */
        0x08,                     /* E015 INX */
        0xDF, 0x80,               /* E016 STX $80 */
        0xDE, 0x82,               /* E018 LDX $82 */
        0x08,                     /* E01A INX */
        0x20, 0xEE,               /* E01B BRA loop */
        0x86, 0x00,               /* E01D done: LDAA #0 */
        0xB7, 0xBF, 0xFF,         /* E01F STAA $BFFF  (text mode) */
        0x86, 0xFF, 0x97, 0x00,   /* E022 DDR1 = FF */
        0x86, 0xFE, 0x97, 0x02,   /* E026 P1 = FE (column 0) */
        0xB6, 0xBF, 0xFF,         /* E02A LDAA $BFFF */
        0xB7, 0x41, 0x00,         /* E02D STAA $4100 */
        0x86, 0x80, 0xB7, 0xBF, 0xFF, /* E030 DAC high */
        0x86, 0x00, 0xB7, 0xBF, 0xFF, /* E035 DAC low */
        0x20, 0xFE                /* E03A BRA * */
    };
    static const uint8_t msg[] = { 8, 5, 12, 12, 15, 0x20, 1, 12, 9, 3, 5, 0 };  /* HELLO ALICE in 6847 codes */
    memcpy(m->rom, code, sizeof code);
    memcpy(m->rom + 0x40, msg, sizeof msg);
    m->rom[0x1FFE] = 0xE0; m->rom[0x1FFF] = 0x00;
}

static int selftest(void)
{
    static machine m;
    int bad = 0;
    machine_init(&m, 0x1000);
    build_selftest_rom(&m);
    m.keys[0] = 0x01;                       /* '@' pressed in column 0 */
    machine_start(&m);
    run_cycles(&m, 20000);
    {
        static const uint8_t want[11] = { 8, 5, 12, 12, 15, 0x20, 1, 12, 9, 3, 5 };
        if (memcmp(m.ram, want, 11) != 0 || m.ram[11] != 0) { puts("VRAM text mismatch"); bad++; }
        if (m.cpu.ram[0] != 0x40 || m.cpu.ram[1] != 0x0B) { printf("on-chip RAM pointer %02X%02X, expected 400B\n", m.cpu.ram[0], m.cpu.ram[1]); bad++; }
    }
    if (m.ram[0x100] != 0xFE) { printf("keyboard read $BFFF = %02X (expected FE)\n", m.ram[0x100]); bad++; }
    if (m.dac_edges != 2) { printf("DAC edges %u (expected 2)\n", (unsigned)m.dac_edges); bad++; }
    if (m.cpu.illegal_count) { printf("illegal opcode %02X\n", m.cpu.illegal); bad++; }
    if (m.ram_size && m.vram_writes < 11) { printf("vram_writes %u\n", (unsigned)m.vram_writes); bad++; }
    dump_text(&m, stdout);
    printf("alice selftest: %s (%llu cycles, pc=%04X)\n", bad ? "FAIL" : "ok", (unsigned long long)m.cpu.cycles, m.cpu.pc);
    return bad;
}

static int bench(double secs)
{
    static machine m;
    clock_t t0, t1;
    uint64_t n = (uint64_t)(secs * CPU_HZ), insns = 0;
    machine_init(&m, 0x1000);
    build_selftest_rom(&m);
    machine_start(&m);
    t0 = clock();
    while (m.cpu.cycles < n) { mc6803_step(&m.cpu); insns++; }
    t1 = clock();
    {
        double s = (double)(t1 - t0) / CLOCKS_PER_SEC;
        printf("bench: %.1f s of machine time = %llu cycles, %llu instructions in %.3f s host: %.1f Minsn/s, %.1f MHz equivalent (%.0fx real time)\n",
               secs, (unsigned long long)m.cpu.cycles, (unsigned long long)insns, s, insns / s / 1e6, m.cpu.cycles / s / 1e6, m.cpu.cycles / s / CPU_HZ);
    }
    return 0;
}

#ifndef ALICE_EMU_LIB                  /* alice_emu.c includes this file for the machine and has its own main */
int main(int argc, char **argv)
{
    static machine m;
    const char *romfile = NULL, *text = NULL, *eflog = NULL, *dumpf = NULL;
    uint32_t ram = 0x1000;
    double secs = 5.0;
    int i, alice = 0;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--selftest")) return selftest() ? 1 : 0;
        else if (!strcmp(argv[i], "--bench")) return bench(i + 1 < argc ? atof(argv[i + 1]) : 60.0);
        else if (!strcmp(argv[i], "-ram") && i + 1 < argc) ram = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "-secs") && i + 1 < argc) secs = atof(argv[++i]);
        else if (!strcmp(argv[i], "-type") && i + 1 < argc) text = argv[++i];
        else if (!strcmp(argv[i], "-alice")) alice = 1;
        else if (!strcmp(argv[i], "-dump") && i + 1 < argc) dumpf = argv[++i];
        else if (!strcmp(argv[i], "-eflog") && i + 1 < argc) eflog = argv[++i];
        else romfile = argv[i];
    }
    if (!romfile) { fprintf(stderr, "usage: alice --selftest | --bench [s] | rom.bin [-ram n] [-secs s] [-type text] [-alice]\n"); return 2; }
    if (ram > sizeof m.ram) ram = sizeof m.ram;
    machine_init(&m, ram);
    if (alice) keyboard_alice();
    {
        FILE *f = fopen(romfile, "rb");
        size_t n;
        if (!f) { perror(romfile); return 2; }
        n = fread(m.rom, 1, sizeof m.rom, f);
        fclose(f);
        if (n == 0x4000) {              /* Alice 32 / 90 ROM */
            m.a32 = 1; m.rom_base = 0xC000; m.rom_size = 0x4000; m.ram_base = 0x3000;
            if (ram == 0x1000) m.ram_size = 0x2000;
            if (eflog) m.eflog = fopen(eflog, "w");
        } else if (n != 0x2000) fprintf(stderr, "warning: ROM is %u bytes, expected 8192 or 16384\n", (unsigned)n);
    }
    machine_start(&m);
    printf("reset vector -> pc=%04X\n", m.cpu.pc);
    run_cycles(&m, (uint64_t)(secs * CPU_HZ));
    dump_text(&m, stdout);
    if (text) {
        const char *p;
        for (p = text; *p; p++) type_char(&m, *p, CPU_HZ / 12, CPU_HZ / 12);
        run_cycles(&m, CPU_HZ * 2);
        dump_text(&m, stdout);
    }
    if (dumpf) {                         /* for the fabric bench (sim/tb_z80sys.v MACH=5): word 0 = $BFFF, then the 6 KB video RAM as 32 bit words (first byte in bits 7:0) */
        FILE *f = fopen(dumpf, "w");
        uint32_t n, b;
        if (!f) { perror(dumpf); return 2; }
        fprintf(f, "%08X\n", (unsigned)m.bfff);
        for (n = 0; n < 1536; n++) {
            uint32_t w = 0;
            for (b = 0; b < 4; b++) w |= (uint32_t)m.ram[4 * n + b] << (8 * b);
            fprintf(f, "%08X\n", (unsigned)w);
        }
        fclose(f);
    }
    if (m.a32) printf("EF9345 register writes: %u\n", (unsigned)m.ef_writes);
    printf("cycles=%llu pc=%04X illegal=%u (last %02X at %04X) vram_writes=%u dac_edges=%u cass_edges=%u\n",
           (unsigned long long)m.cpu.cycles, m.cpu.pc, (unsigned)m.cpu.illegal_count, m.cpu.illegal, m.cpu.illegal_pc,
           (unsigned)m.vram_writes, (unsigned)m.dac_edges, (unsigned)m.cass_edges);
    return 0;
}
#endif
