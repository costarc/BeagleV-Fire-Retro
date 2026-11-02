/* Instruction-level tests for mc6803.c. Expected values are worked out by hand from the
 * 6800 / 6801 programming model, not taken from the emulator's own output.
 * Build and run: see run_tests.sh */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "mc6803.h"

static uint8_t mem[65536];
static int ext_reads, ext_writes;
static uint8_t p2_pins, p2_last_latch, p2_last_ddr;
static int p2_out_calls;
static int fails, checks;

static uint8_t b_rd(void *x, uint16_t a) { (void)x; ext_reads++; return mem[a]; }
static void b_wr(void *x, uint16_t a, uint8_t v) { (void)x; ext_writes++; mem[a] = v; }
static uint8_t b_pin(void *x, int p) { (void)x; return p == 1 ? p2_pins : 0xFF; }
static void b_pout(void *x, int p, uint8_t l, uint8_t d) { (void)x; if (p == 1) { p2_last_latch = l; p2_last_ddr = d; p2_out_calls++; } }

#define CHECK(cond, ...) do { checks++; if (!(cond)) { fails++; printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static mc6803 cpu;

/* load code at $0200 and reset */
static void load(const uint8_t *code, int n)
{
    memset(mem, 0, sizeof mem);
    memcpy(mem + 0x200, code, (size_t)n);
    mem[0xFFFE] = 0x02; mem[0xFFFF] = 0x00;
    mem[0xFFFA] = 0x04; mem[0xFFFB] = 0x00;   /* SWI   -> $0400 */
    mem[0xFFF8] = 0x05; mem[0xFFF9] = 0x00;   /* IRQ1  -> $0500 */
    mem[0xFFF4] = 0x06; mem[0xFFF5] = 0x00;   /* OCI   -> $0600 */
    mem[0xFFF2] = 0x07; mem[0xFFF3] = 0x00;   /* TOI   -> $0700 */
    mem[0xFFFC] = 0x08; mem[0xFFFD] = 0x00;   /* NMI   -> $0800 */
    ext_reads = ext_writes = 0; p2_out_calls = 0; p2_pins = 0xFF;
    mc6803_init(&cpu, NULL, b_rd, b_wr, b_pin, b_pout);
    cpu.sp = 0x01FF;
}

/* run until PC reaches 'end' (or a cycle limit); returns cycles used */
static int run_to(uint16_t end)
{
    int tot = 0, guard = 0;
    while (cpu.pc != end && guard++ < 100000) tot += mc6803_step(&cpu);
    return tot;
}

#define PROG(...) do { (void)end_; static const uint8_t p_[] = { __VA_ARGS__ }; load(p_, (int)sizeof p_); end_ = (uint16_t)(0x200 + sizeof p_); } while (0)
#define FL(f) ((cpu.cc & MC6803_CC_##f) ? 1 : 0)
#define D() ((cpu.a << 8) | cpu.b)

static void test_alu8(void)
{
    uint16_t end_;
    PROG(0x86, 0x7F, 0x8B, 0x01);                  /* LDAA #$7F ; ADDA #1 */
    run_to(end_);
    CHECK(cpu.a == 0x80 && FL(N) && FL(V) && FL(H) && !FL(C) && !FL(Z), "ADDA 7F+1: a=%02X cc=%02X", cpu.a, cpu.cc);

    PROG(0x86, 0x80, 0x80, 0x01);                  /* SUBA #1 */
    run_to(end_);
    CHECK(cpu.a == 0x7F && FL(V) && !FL(N) && !FL(C), "SUBA 80-1: a=%02X cc=%02X", cpu.a, cpu.cc);

    PROG(0x86, 0x10, 0x81, 0x90);                  /* CMPA #$90 */
    run_to(end_);
    /* 0x10 - 0x90 = 0x80: N, borrow C, and signed overflow (16 - (-112) = 128) V */
    CHECK(cpu.a == 0x10 && FL(C) && !FL(Z) && FL(N) && FL(V), "CMPA 10-90: cc=%02X", cpu.cc);

    PROG(0x86, 0xFF, 0x8B, 0x01);                  /* ADDA #1 -> 00 C Z H */
    run_to(end_);
    CHECK(cpu.a == 0 && FL(C) && FL(Z) && FL(H) && !FL(V), "ADDA FF+1: cc=%02X", cpu.cc);

    PROG(0x0D, 0x86, 0x05, 0x89, 0x03);            /* SEC ; LDAA #5 ; ADCA #3 */
    run_to(end_);
    CHECK(cpu.a == 9, "ADCA with carry: a=%02X", cpu.a);

    PROG(0x0D, 0x86, 0x05, 0x82, 0x03);            /* SEC ; SBCA #3 -> 1 */
    run_to(end_);
    CHECK(cpu.a == 1, "SBCA with carry: a=%02X", cpu.a);

    PROG(0x86, 0xF0, 0x84, 0x3C);                  /* ANDA #$3C -> 30 */
    run_to(end_);
    CHECK(cpu.a == 0x30 && !FL(V), "ANDA");
    PROG(0x86, 0xF0, 0x8A, 0x0F);                  /* ORAA -> FF N */
    run_to(end_);
    CHECK(cpu.a == 0xFF && FL(N), "ORAA");
    PROG(0x86, 0xFF, 0x88, 0x0F);                  /* EORA -> F0 */
    run_to(end_);
    CHECK(cpu.a == 0xF0, "EORA");
    PROG(0x86, 0x80, 0x85, 0x80);                  /* BITA -> a unchanged, N */
    run_to(end_);
    CHECK(cpu.a == 0x80 && FL(N), "BITA");

    PROG(0xC6, 0x34, 0x86, 0x12, 0x1B);            /* ABA -> 46 */
    run_to(end_);
    CHECK(cpu.a == 0x46, "ABA");
    PROG(0xC6, 0x34, 0x86, 0x12, 0x10);            /* SBA -> DE, C */
    run_to(end_);
    CHECK(cpu.a == 0xDE && FL(C) && FL(N), "SBA");

    PROG(0x86, 0x19, 0x8B, 0x28, 0x19);            /* 19+28=41 H ; DAA -> 47 */
    run_to(end_);
    CHECK(cpu.a == 0x47 && !FL(C), "DAA 19+28: a=%02X", cpu.a);
    PROG(0x86, 0x99, 0x8B, 0x01, 0x19);            /* 99+01 = 9A ; DAA -> 00 C */
    run_to(end_);
    CHECK(cpu.a == 0x00 && FL(C) && FL(Z), "DAA 99+1: a=%02X cc=%02X", cpu.a, cpu.cc);
    PROG(0x86, 0x45, 0x8B, 0x55, 0x19);            /* 45+55 = 9A ; DAA -> 00 C */
    run_to(end_);
    CHECK(cpu.a == 0x00 && FL(C), "DAA 45+55");

    PROG(0x86, 0x80, 0x40);                        /* NEGA 80 -> 80 V C N */
    run_to(end_);
    CHECK(cpu.a == 0x80 && FL(V) && FL(C) && FL(N), "NEGA 80");
    PROG(0x86, 0x00, 0x40);                        /* NEGA 00 -> 00 Z, C clear */
    run_to(end_);
    CHECK(cpu.a == 0 && FL(Z) && !FL(C), "NEGA 00");
    PROG(0x86, 0x55, 0x43);                        /* COMA -> AA C N */
    run_to(end_);
    CHECK(cpu.a == 0xAA && FL(C) && FL(N) && !FL(V), "COMA");
    PROG(0x86, 0x81, 0x44);                        /* LSRA -> 40 C V(=N^C=1) */
    run_to(end_);
    CHECK(cpu.a == 0x40 && FL(C) && FL(V) && !FL(N), "LSRA");
    PROG(0x86, 0x81, 0x47);                        /* ASRA -> C0 C */
    run_to(end_);
    CHECK(cpu.a == 0xC0 && FL(C) && FL(N) && !FL(V), "ASRA");
    PROG(0x86, 0x81, 0x48);                        /* ASLA -> 02 C V */
    run_to(end_);
    CHECK(cpu.a == 0x02 && FL(C) && FL(V) && !FL(N), "ASLA");
    PROG(0x0D, 0x86, 0x01, 0x46);                  /* SEC; RORA -> 80 C N */
    run_to(end_);
    CHECK(cpu.a == 0x80 && FL(C) && FL(N), "RORA");
    PROG(0x0D, 0x86, 0x80, 0x49);                  /* SEC; ROLA -> 01 C */
    run_to(end_);
    CHECK(cpu.a == 0x01 && FL(C) && !FL(N) && FL(V), "ROLA");
    PROG(0x86, 0x80, 0x4A);                        /* DECA 80 -> 7F V */
    run_to(end_);
    CHECK(cpu.a == 0x7F && FL(V), "DECA");
    PROG(0x86, 0x7F, 0x4C);                        /* INCA 7F -> 80 V N */
    run_to(end_);
    CHECK(cpu.a == 0x80 && FL(V) && FL(N), "INCA");
    PROG(0x0D, 0x86, 0x00, 0x4D);                  /* TSTA clears C, sets Z */
    run_to(end_);
    CHECK(FL(Z) && !FL(C), "TSTA");
    PROG(0x86, 0x33, 0x4F);                        /* CLRA */
    run_to(end_);
    CHECK(cpu.a == 0 && FL(Z) && !FL(N) && !FL(V) && !FL(C), "CLRA");
    PROG(0xC6, 0x42, 0x16);                        /* TAB */
    run_to(end_);
    CHECK(cpu.a == 0 && cpu.b == 0, "TAB from a=0");
    PROG(0x86, 0x42, 0x16, 0x4F, 0x17);            /* TAB; CLRA; TBA */
    run_to(end_);
    CHECK(cpu.a == 0x42 && cpu.b == 0x42, "TAB/TBA");
    PROG(0x86, 0xA5, 0x06, 0x07);                  /* TAP ; TPA : bits 7,6 read as 1 */
    run_to(end_);
    CHECK(cpu.a == (0xA5 | 0xC0), "TAP/TPA a=%02X", cpu.a);
}

static void test_16bit(void)
{
    uint16_t end_;
    PROG(0xCC, 0xFF, 0xFF, 0xC3, 0x00, 0x01);      /* LDD #FFFF ; ADDD #1 */
    run_to(end_);
    CHECK(D() == 0 && FL(Z) && FL(C) && !FL(V) && !FL(N), "ADDD");
    PROG(0xCC, 0x7F, 0xFF, 0xC3, 0x00, 0x01);      /* 7FFF+1 -> 8000 V N */
    run_to(end_);
    CHECK(D() == 0x8000 && FL(V) && FL(N) && !FL(C), "ADDD ovf");
    PROG(0xCC, 0x80, 0x00, 0x83, 0x00, 0x01);      /* SUBD #1 -> 7FFF V */
    run_to(end_);
    CHECK(D() == 0x7FFF && FL(V) && !FL(N) && !FL(C), "SUBD");
    PROG(0xCC, 0x00, 0x00, 0x83, 0x00, 0x01);      /* 0-1 -> FFFF C N */
    run_to(end_);
    CHECK(D() == 0xFFFF && FL(C) && FL(N), "SUBD borrow");
    PROG(0xCC, 0x80, 0x01, 0x05);                  /* ASLD -> 0002 C V */
    run_to(end_);
    CHECK(D() == 0x0002 && FL(C) && FL(V) && !FL(N), "ASLD: D=%04X cc=%02X", D(), cpu.cc);
    PROG(0xCC, 0x00, 0x03, 0x04);                  /* LSRD -> 0001 C V */
    run_to(end_);
    CHECK(D() == 0x0001 && FL(C) && FL(V) && !FL(N) && !FL(Z), "LSRD");
    PROG(0xCC, 0x12, 0x34, 0x4F, 0x5F, 0xC6, 0x00); /* LDD ; CLRA ; CLRB (partial) */
    run_to(end_);
    CHECK(cpu.a == 0 && cpu.b == 0, "CLRA CLRB");
    PROG(0x86, 0x12, 0xC6, 0x34, 0x3D);            /* MUL: 12*34 = 03A8, C = bit7 of B */
    run_to(end_);
    CHECK(D() == 0x03A8 && FL(C), "MUL: D=%04X cc=%02X", D(), cpu.cc);
    PROG(0x86, 0x10, 0xC6, 0x10, 0x3D);            /* 10*10 = 0100, C=0 */
    run_to(end_);
    CHECK(D() == 0x0100 && !FL(C), "MUL 2");
    PROG(0xCE, 0x00, 0xFF, 0xC6, 0x80, 0x3A);      /* ABX: 00FF + 80 */
    run_to(end_);
    CHECK(cpu.x == 0x017F, "ABX x=%04X", cpu.x);
    PROG(0xCE, 0xFF, 0xFF, 0x08);                  /* INX wraps, Z */
    run_to(end_);
    CHECK(cpu.x == 0 && FL(Z), "INX");
    PROG(0xCE, 0x00, 0x01, 0x09);                  /* DEX -> 0 Z */
    run_to(end_);
    CHECK(cpu.x == 0 && FL(Z), "DEX");
    PROG(0xCE, 0x12, 0x34, 0x8C, 0x12, 0x34);      /* CPX equal: Z */
    run_to(end_);
    CHECK(FL(Z) && !FL(N), "CPX equal");
    PROG(0x0D, 0xCE, 0x00, 0x01, 0x8C, 0x00, 0x02);/* SEC; CPX: C must stay set, N set */
    run_to(end_);
    CHECK(FL(C) && FL(N), "CPX keeps C");
    PROG(0xCE, 0x12, 0x34, 0x3C, 0xCE, 0x00, 0x00, 0x38); /* PSHX ; LDX #0 ; PULX */
    run_to(end_);
    CHECK(cpu.x == 0x1234 && cpu.sp == 0x01FF, "PSHX/PULX x=%04X sp=%04X", cpu.x, cpu.sp);
    CHECK(mem[0x1FF] == 0x34 && mem[0x1FE] == 0x12, "PSHX layout: low byte at the higher address");
    PROG(0xCE, 0x03, 0x00, 0x35, 0x30);            /* LDX #$0300; TXS -> SP=02FF ; TSX -> X=0300 */
    run_to(end_);
    CHECK(cpu.sp == 0x02FF && cpu.x == 0x0300, "TXS/TSX sp=%04X x=%04X", cpu.sp, cpu.x);
    PROG(0x8E, 0x01, 0xFF, 0x34, 0x31);            /* DES then INS */
    run_to(end_);
    CHECK(cpu.sp == 0x01FF, "DES/INS");
    /* STD / LDD direct and extended, STX / STS, LDS */
    PROG(0xCC, 0xAB, 0xCD, 0xDD, 0x40, 0xFD, 0x03, 0x00, 0xCE, 0x11, 0x22, 0xFF, 0x03, 0x10, 0xDF, 0x42);
    run_to(end_);
    CHECK(mem[0x40] == 0xAB && mem[0x41] == 0xCD && mem[0x300] == 0xAB && mem[0x301] == 0xCD, "STD");
    CHECK(mem[0x310] == 0x11 && mem[0x311] == 0x22 && mem[0x42] == 0x11 && mem[0x43] == 0x22, "STX");
    PROG(0xCE, 0x01, 0x00, 0xEC, 0x04, 0xED, 0x08); /* LDX #$100 ; LDD 4,X (mem 104/105) ; STD 8,X */
    mem[0x104] = 0x5A; mem[0x105] = 0xA5;
    run_to(end_);
    CHECK(D() == 0x5AA5 && mem[0x108] == 0x5A && mem[0x109] == 0xA5, "LDD/STD indexed");
}

static void test_mem(void)
{
    uint16_t end_;
    /* on-chip RAM $80-$FF never reaches the external bus */
    PROG(0x86, 0x5A, 0x97, 0x80, 0xB7, 0x00, 0xFF, 0x96, 0x80);   /* STAA $80 ; STAA $00FF ; LDAA $80 */
    run_to(end_);
    CHECK(cpu.a == 0x5A && cpu.ram[0] == 0x5A && cpu.ram[0x7F] == 0x5A && ext_writes == 0 && mem[0x80] == 0 && mem[0xFF] == 0,
          "internal RAM: a=%02X wr=%d", cpu.a, ext_writes);
    /* RMW memory ops, indexed and extended */
    PROG(0xCE, 0x03, 0x00, 0x7C, 0x03, 0x00, 0x6A, 0x10);        /* INC $0300 ; DEC 16,X */
    mem[0x300] = 0x01; mem[0x310] = 0xFF;
    run_to(end_);
    CHECK(mem[0x300] == 0x02 && mem[0x310] == 0xFE, "INC/DEC mem");
    PROG(0x7F, 0x03, 0x00);                                      /* CLR $0300 */
    mem[0x300] = 0xAA;
    run_to(end_);
    CHECK(mem[0x300] == 0 && FL(Z), "CLR mem");
    PROG(0x77, 0x03, 0x00);                                      /* ASR $0300 -> C0 */
    mem[0x300] = 0x81;
    run_to(end_);
    CHECK(mem[0x300] == 0xC0 && FL(C), "ASR mem");
    /* stack frame / JSR / RTS / BSR */
    PROG(0xBD, 0x02, 0x10, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
         0x86, 0x77, 0x39);                                      /* JSR $0210 ; at $0210: LDAA #$77 ; RTS */
    {
        int cy;
        mem[0x210] = 0x86; mem[0x211] = 0x77; mem[0x212] = 0x39;
        cy = run_to(0x203);
        CHECK(cpu.a == 0x77 && cpu.pc == 0x203 && cpu.sp == 0x01FF, "JSR/RTS a=%02X pc=%04X", cpu.a, cpu.pc);
        CHECK(cy == 6 + 2 + 5, "JSR+LDAA+RTS cycles = %d", cy);
        CHECK(mem[0x1FF] == 0x03 && mem[0x1FE] == 0x02, "return address on stack");
    }
    PROG(0x8D, 0x02, 0x01, 0x01, 0x86, 0x66, 0x39);              /* BSR +2 -> $0204: LDAA #$66 ; RTS */
    run_to(0x203);
    CHECK(cpu.a == 0x66, "BSR");
}

static void test_branches(void)
{
    uint16_t end_;
    int cy;
    PROG(0xC6, 0x05, 0x5A, 0x26, 0xFD);                          /* LDAB #5 ; DECB ; BNE -3 */
    cy = run_to(end_);
    CHECK(cpu.b == 0 && cy == 2 + 5 * (2 + 3), "DECB/BNE loop cycles=%d", cy);
    /* signed compares: 0x80 < 0x01 */
    PROG(0x86, 0x80, 0x81, 0x01, 0x2D, 0x02, 0xC6, 0x11, 0xC6, 0x22); /* BLT over LDAB #$11 */
    run_to(end_);
    CHECK(cpu.b == 0x22, "BLT taken b=%02X", cpu.b);
    PROG(0x86, 0x01, 0x81, 0x80, 0x2E, 0x02, 0xC6, 0x11, 0xC6, 0x22); /* 1 > -128 : BGT taken */
    run_to(end_);
    CHECK(cpu.b == 0x22, "BGT taken");
    PROG(0x86, 0x01, 0x81, 0x80, 0x22, 0x02, 0xC6, 0x11, 0xC6, 0x22); /* unsigned 1 < 0x80: BHI not taken */
    run_to(end_);
    CHECK(cpu.b == 0x22 && 1, "BHI path");
    PROG(0x86, 0x01, 0x81, 0x80, 0x22, 0x02, 0xC6, 0x11);
    run_to(end_);
    CHECK(cpu.b == 0x11, "BHI not taken b=%02X", cpu.b);
    PROG(0x20, 0x02, 0xC6, 0x11, 0xC6, 0x22);                    /* BRA */
    run_to(end_);
    CHECK(cpu.b == 0x22, "BRA");
    PROG(0x21, 0x02, 0xC6, 0x11);                                /* BRN never */
    run_to(end_);
    CHECK(cpu.b == 0x11, "BRN");
    PROG(0x7E, 0x02, 0x08, 0, 0, 0, 0, 0, 0xC6, 0x11);           /* JMP $0208 */
    run_to(0x20A);
    CHECK(cpu.b == 0x11, "JMP");
}

static void test_int(void)
{
    uint16_t end_ = 0;
    int cy;
    /* SWI: push frame, I set, vector $FFFA */
    PROG(0x86, 0x11, 0xC6, 0x22, 0xCE, 0x33, 0x44, 0x3F);
    mem[0x400] = 0x3B;                                           /* handler: RTI */
    cy = run_to(0x400);
    CHECK(cpu.pc == 0x400 && FL(I) && cpu.sp == 0x01FF - 7, "SWI entry sp=%04X", cpu.sp);
    CHECK(mem[0x1FF] == 0x08 && mem[0x1FE] == 0x02 && mem[0x1FD] == 0x44 && mem[0x1FC] == 0x33 &&
          mem[0x1FB] == 0x11 && mem[0x1FA] == 0x22, "SWI frame layout");
    CHECK(cy == 2 + 2 + 3 + 12, "SWI cycles %d", cy);
    cy = run_to(0x208);
    CHECK(cpu.pc == 0x208 && cpu.a == 0x11 && cpu.b == 0x22 && cpu.x == 0x3344 && cpu.sp == 0x01FF, "RTI restore");
    CHECK(cy == 10, "RTI cycles %d", cy);

    /* IRQ1 masked, then unmasked by CLI */
    PROG(0x0E, 0x01, 0x01, 0x01);
    mem[0x500] = 0x86; mem[0x501] = 0x99; mem[0x502] = 0xB7; mem[0x503] = 0x03; mem[0x504] = 0x00; mem[0x505] = 0x3B;
    cpu.cc &= (uint8_t)~MC6803_CC_I;
    mc6803_set_irq(&cpu, 1);
    mc6803_step(&cpu);
    CHECK(cpu.pc == 0x500, "IRQ1 taken pc=%04X", cpu.pc);
    mc6803_set_irq(&cpu, 0);
    run_to(0x201);
    CHECK(mem[0x300] == 0x99 && cpu.a == 0 && cpu.pc == 0x201, "IRQ1 handler ran, RTI restored A: mem=%02X a=%02X pc=%04X", mem[0x300], cpu.a, cpu.pc);
    PROG(0x01, 0x01);
    mc6803_set_irq(&cpu, 1);            /* I is set after reset */
    mc6803_step(&cpu);
    CHECK(cpu.pc == 0x201, "IRQ1 masked by I");

    /* NMI ignores I */
    PROG(0x01);
    mc6803_nmi(&cpu);
    mc6803_step(&cpu);
    CHECK(cpu.pc == 0x800, "NMI");

    /* WAI: halts until an interrupt, 4 cycle wake-up */
    PROG(0x0E, 0x3E, 0x01);
    mem[0x500] = 0x3B;
    run_to(0x202);                      /* CLI ; WAI */
    CHECK(cpu.wai && cpu.sp == 0x01FF - 7, "WAI pushed frame");
    mc6803_step(&cpu); mc6803_step(&cpu);
    CHECK(cpu.pc == 0x202, "WAI idles");
    mc6803_set_irq(&cpu, 1);
    cy = mc6803_step(&cpu);
    CHECK(cpu.pc == 0x500 && cy == 4, "WAI wake pc=%04X cy=%d", cpu.pc, cy);
    mc6803_set_irq(&cpu, 0);
    mc6803_step(&cpu);                  /* RTI */
    CHECK(cpu.pc == 0x202, "WAI RTI");
}

static void test_timer(void)
{
    uint16_t end_ = 0;
    int i;
    /* FRC counts CPU cycles; OCF at match; TCSR read then OCR write clears it */
    PROG(0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01);
    CHECK(cpu.frc == 0, "FRC reset");
    for (i = 0; i < 5; i++) mc6803_step(&cpu);                   /* 5 NOPs = 10 cycles */
    CHECK(cpu.frc == 10, "FRC after 5 NOPs = %u", cpu.frc);
    cpu.ocr = 14;
    mc6803_step(&cpu); mc6803_step(&cpu);                        /* 14 reached after the 2nd */
    CHECK(cpu.frc == 14 && (cpu.tcsr & MC6803_TCSR_OCF), "OCF at match");
    {   /* clear sequence: read TCSR, write OCRH */
        uint8_t p_[] = { 0x96, 0x08, 0xCC, 0x00, 0x00, 0xDD, 0x0B };
        load(p_, sizeof p_);
        cpu.tcsr = MC6803_TCSR_OCF; cpu.pend = MC6803_TCSR_OCF;
        run_to(0x207);
        CHECK(!(cpu.tcsr & MC6803_TCSR_OCF), "OCF cleared by TCSR read + OCR write: tcsr=%02X", cpu.tcsr);
        load(p_ + 3, 4);                                         /* no TCSR read: write must not clear */
        cpu.tcsr = MC6803_TCSR_OCF; cpu.pend = MC6803_TCSR_OCF;
        run_to(0x204);
        CHECK(cpu.tcsr & MC6803_TCSR_OCF, "OCF not cleared without TCSR read");
    }
    /* TOF: FRC wraps; clear by TCSR then FRC high read */
    {
        uint8_t p_[] = { 0x96, 0x08, 0x96, 0x09 };
        load(p_, sizeof p_);
        cpu.frc = 0xFFFE;
        mc6803_step(&cpu);                                       /* LDAA TCSR: 3 cycles, FFFE -> 0001 */
        /* the wrap passes FFFF, which is also the reset value of OCR, so OCF is set too */
        CHECK(cpu.frc == 0x0001 && cpu.tcsr == (MC6803_TCSR_TOF | MC6803_TCSR_OCF), "TOF set: frc=%04X tcsr=%02X", cpu.frc, cpu.tcsr);
    }
    {
        uint8_t p_[] = { 0x96, 0x08, 0x96, 0x09 };
        load(p_, sizeof p_);
        cpu.tcsr = MC6803_TCSR_TOF; cpu.pend = MC6803_TCSR_TOF;
        run_to(0x204);
        CHECK(!(cpu.tcsr & MC6803_TCSR_TOF), "TOF cleared by TCSR + FRC high");
    }
    /* OCI interrupt */
    {
        uint8_t p_[] = { 0x0E, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01 };
        load(p_, sizeof p_);
        mem[0x600] = 0x3B;
        cpu.tcsr = MC6803_TCSR_EOCI; cpu.ocr = 6;
        for (i = 0; i < 3 && cpu.pc != 0x600; i++) mc6803_step(&cpu);
        mc6803_step(&cpu);
        CHECK(cpu.pc == 0x600, "OCI vector pc=%04X", cpu.pc);
    }
    /* FRC write: high byte write presets FFF8, then the low byte write completes */
    {
        uint8_t p_[] = { 0xCC, 0x12, 0x34, 0xDD, 0x09 };         /* STD $09 */
        load(p_, sizeof p_);
        run_to(0x205);
        CHECK(cpu.frc == 0x1234 + 4, "FRC write: %04X (STD takes 4 cycles after the store)", cpu.frc);
    }
}

static void test_ports(void)
{
    uint8_t p_[] = { 0x86, 0x03, 0x97, 0x01, 0x86, 0x01, 0x97, 0x03, 0x96, 0x03 };
    uint16_t end_ = 0x20A;
    load(p_, sizeof p_);
    p2_pins = 0xFE;                                              /* external pin 0 low, pin 1 low, rest high */
    run_to(end_);
    CHECK(p2_last_ddr == 0x03 && p2_last_latch == 0x01, "P2 DDR/latch ddr=%02X latch=%02X", p2_last_ddr, p2_last_latch);
    /* bits 0,1 are outputs (latch=1,0); bits 2.. come from the pins */
    CHECK(cpu.a == ((0xFE & ~0x03) | 0x01), "P2 read a=%02X", cpu.a);
    CHECK(p2_out_calls == 2, "port_out calls %d", p2_out_calls);
}

static void test_illegal_and_lengths(void)
{
    unsigned op;
    int bad = 0;
    for (op = 0; op < 256; op++) {
        unsigned lo = op & 15, hi = op >> 4, len;
        int ctl = 0, illegal;
        /* instruction length from the programming model */
        if (hi < 2) len = 1;
        else if (hi == 2) len = 2;
        else if (hi < 8 && hi >= 6) len = hi == 6 ? 2 : 3;
        else if (hi < 6) len = 1;
        else {
            unsigned m = (hi - 8) & 3;                          /* 0 imm 1 dir 2 idx 3 ext */
            len = m == 3 ? 3 : 2;
            if (m == 0 && (lo == 3 || lo == 0xC || lo == 0xE || lo == 0xF)) len = 3;
            if (hi >= 0xC && m == 0 && lo == 0xF) len = 3;
        }
        if (hi == 2 || op == 0x8D || op == 0x9D || op == 0xAD || op == 0xBD || op == 0x6E || op == 0x7E ||
            op == 0x39 || op == 0x3B || op == 0x3E || op == 0x3F) ctl = 1;
        /* legal opcode set of the 6801/6803 */
        illegal = 0;
        if (hi == 0) illegal = !(lo == 1 || (lo >= 4 && lo <= 0xF));
        else if (hi == 1) illegal = !(lo <= 1 || lo == 6 || lo == 7 || lo == 9 || lo == 0xB);
        else if (hi == 3) illegal = 0;
        else if (hi == 4 || hi == 5) illegal = (lo == 1 || lo == 2 || lo == 5 || lo == 0xB || lo == 0xE);
        else if (hi == 6 || hi == 7) illegal = (lo == 1 || lo == 2 || lo == 5 || lo == 0xB);
        else if (hi >= 8) {
            unsigned m = (hi - 8) & 3;
            if (lo == 7 && m == 0) illegal = 1;
            if (lo == 0xF && m == 0) illegal = 1;
            if (hi >= 0xC && lo == 0xD && m == 0) illegal = 1;
        }
        if (ctl) continue;
        {
            uint8_t p_[4]; mc6803 *c = &cpu;
            p_[0] = (uint8_t)op; p_[1] = 0x90; p_[2] = 0x00; p_[3] = 0;
            load(p_, 4);
            c->x = 0x0300; c->sp = 0x01FF;
            mc6803_step(c);
            if (illegal) {
                if (c->illegal != op) { bad++; printf("opcode %02X should be flagged illegal\n", op); }
            } else {
                if (c->illegal == op) { bad++; printf("opcode %02X flagged illegal\n", op); }
                else if (c->pc != 0x200 + len && !(hi == 3 && (lo == 8 || lo == 9))) {
                    bad++; printf("opcode %02X length %u, pc advanced to %04X\n", op, len, c->pc);
                }
            }
        }
    }
    CHECK(bad == 0, "opcode map / length sweep: %d mismatches", bad);
}

int main(void)
{
    test_alu8();
    test_16bit();
    test_mem();
    test_branches();
    test_int();
    test_timer();
    test_ports();
    test_illegal_and_lengths();
    printf("%d checks, %d failures\n", checks, fails);
    return fails ? 1 : 0;
}
