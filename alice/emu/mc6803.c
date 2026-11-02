/* MC6803 interpreter, see mc6803.h. */
#include "mc6803.h"

#define XX 4 /* illegal opcode: 4 cycles, as in MAME's table */

static const uint8_t cyc[256] = {
/*0*/ XX, 2,XX,XX, 3, 3, 2, 2, 3, 3, 2, 2, 2, 2, 2, 2,
/*1*/  2, 2,XX,XX,XX,XX, 2, 2,XX, 2,XX, 2,XX,XX,XX,XX,
/*2*/  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
/*3*/  3, 3, 4, 4, 3, 3, 3, 3, 5, 5, 3,10, 4,10, 9,12,
/*4*/  2,XX,XX, 2, 2,XX, 2, 2, 2, 2, 2,XX, 2, 2,XX, 2,
/*5*/  2,XX,XX, 2, 2,XX, 2, 2, 2, 2, 2,XX, 2, 2,XX, 2,
/*6*/  6,XX,XX, 6, 6,XX, 6, 6, 6, 6, 6,XX, 6, 6, 3, 6,
/*7*/  6,XX,XX, 6, 6,XX, 6, 6, 6, 6, 6,XX, 6, 6, 3, 6,
/*8*/  2, 2, 2, 4, 2, 2, 2, 2, 2, 2, 2, 2, 4, 6, 3, 3,
/*9*/  3, 3, 3, 5, 3, 3, 3, 3, 3, 3, 3, 3, 5, 5, 4, 4,
/*A*/  4, 4, 4, 6, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 5, 5,
/*B*/  4, 4, 4, 6, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 5, 5,
/*C*/  2, 2, 2, 4, 2, 2, 2, 2, 2, 2, 2, 2, 3,XX, 3, 3,
/*D*/  3, 3, 3, 5, 3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4,
/*E*/  4, 4, 4, 6, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5,
/*F*/  4, 4, 4, 6, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5
};

/* ---- on-chip registers ---- */

static uint8_t port_read(mc6803 *c, int p)
{
    uint8_t pins = c->port_in ? c->port_in(c->ctx, p) : 0xFF;
    return (uint8_t)((pins & ~c->ddr[p]) | (c->pout[p] & c->ddr[p]));
}

static void port_write(mc6803 *c, int p)
{
    if (c->port_out) c->port_out(c->ctx, p, c->pout[p], c->ddr[p]);
}

static uint8_t io_r(mc6803 *c, uint16_t a)
{
    switch (a) {
    case MC6803_DDR1: case MC6803_DDR2: case MC6803_DDR3: case MC6803_DDR4: return 0xFF; /* write only */
    case MC6803_P1: return port_read(c, 0);
    case MC6803_P2: return port_read(c, 1);
    case MC6803_P3: return port_read(c, 2);
    case MC6803_P4: return port_read(c, 3);
    case MC6803_TCSR: c->pend = 0; return c->tcsr;
    case MC6803_FRCH:
        if (!(c->pend & MC6803_TCSR_TOF)) c->tcsr &= (uint8_t)~MC6803_TCSR_TOF;
        return (uint8_t)(c->frc >> 8);
    case MC6803_FRCL: return (uint8_t)c->frc;
    case MC6803_OCRH: return (uint8_t)(c->ocr >> 8);
    case MC6803_OCRL: return (uint8_t)c->ocr;
    case MC6803_ICRH:
        if (!(c->pend & MC6803_TCSR_ICF)) c->tcsr &= (uint8_t)~MC6803_TCSR_ICF;
        return (uint8_t)(c->icr >> 8);
    case MC6803_ICRL: return (uint8_t)c->icr;
    case MC6803_TRCSR: return 0x20;   /* TDRE only */
    case MC6803_RCR: return c->rcr;
    default: return 0xFF;
    }
}

static void io_w(mc6803 *c, uint16_t a, uint8_t v)
{
    switch (a) {
    case MC6803_DDR1: c->ddr[0] = v; port_write(c, 0); break;
    case MC6803_DDR2: c->ddr[1] = v & 0x1F; port_write(c, 1); break;
    case MC6803_P1: c->pout[0] = v; port_write(c, 0); break;
    case MC6803_P2: c->pout[1] = v & 0x1F; port_write(c, 1); break;
    case MC6803_DDR3: c->ddr[2] = v; port_write(c, 2); break;
    case MC6803_DDR4: c->ddr[3] = v; port_write(c, 3); break;
    case MC6803_P3: c->pout[2] = v; port_write(c, 2); break;
    case MC6803_P4: c->pout[3] = v; port_write(c, 3); break;
    case MC6803_TCSR: c->tcsr = (uint8_t)((v & 0x1F) | (c->tcsr & 0xE0)); break;
    case MC6803_FRCH: c->frc_latch = v; c->frc = 0xFFF8; break;     /* any write presets FFF8 */
    case MC6803_FRCL: c->frc = (uint16_t)((c->frc_latch << 8) | v); break;
    case MC6803_OCRH:
        if (!(c->pend & MC6803_TCSR_OCF)) c->tcsr &= (uint8_t)~MC6803_TCSR_OCF;
        c->ocr = (uint16_t)((c->ocr & 0x00FF) | (v << 8)); break;
    case MC6803_OCRL:
        if (!(c->pend & MC6803_TCSR_OCF)) c->tcsr &= (uint8_t)~MC6803_TCSR_OCF;
        c->ocr = (uint16_t)((c->ocr & 0xFF00) | v); break;
    case MC6803_RCR: c->rcr = (uint8_t)((v & 0xC0) | 0x00); break;
    default: break;
    }
}

static uint8_t rb(mc6803 *c, uint16_t a)
{
    if (a < 0x20) return io_r(c, a);
    if (a >= 0x80 && a < 0x100 && (c->rcr & 0x40)) return c->ram[a - 0x80];
    return c->rd(c->ctx, a);
}

static void wb(mc6803 *c, uint16_t a, uint8_t v)
{
    if (a < 0x20) { io_w(c, a, v); return; }
    if (a >= 0x80 && a < 0x100 && (c->rcr & 0x40)) { c->ram[a - 0x80] = v; return; }
    c->wr(c->ctx, a, v);
}

static uint16_t rw(mc6803 *c, uint16_t a)
{
    uint16_t h = rb(c, a);
    return (uint16_t)((h << 8) | rb(c, (uint16_t)(a + 1)));
}

static void ww(mc6803 *c, uint16_t a, uint16_t v)
{
    wb(c, a, (uint8_t)(v >> 8));
    wb(c, (uint16_t)(a + 1), (uint8_t)v);
}

/* ---- setup ---- */

void mc6803_init(mc6803 *c, void *ctx,
                 uint8_t (*rd)(void *, uint16_t), void (*wr)(void *, uint16_t, uint8_t),
                 uint8_t (*port_in)(void *, int), void (*port_out)(void *, int, uint8_t, uint8_t))
{
    unsigned i;
    uint8_t *p = (uint8_t *)c;
    for (i = 0; i < sizeof(*c); i++) p[i] = 0;
    c->ctx = ctx; c->rd = rd; c->wr = wr; c->port_in = port_in; c->port_out = port_out;
    mc6803_reset(c);
}

void mc6803_reset(mc6803 *c)
{
    int i;
    for (i = 0; i < 4; i++) { c->ddr[i] = 0; c->pout[i] = 0; }
    c->tcsr = 0; c->pend = 0; c->frc = 0; c->ocr = 0xFFFF; c->icr = 0;
    c->rcr = 0x40; c->wai = 0; c->nmi_pending = 0; c->irq1 = 0;
    c->cc = 0xD0;                      /* 11 H=0 I=1 N Z V C = 0 */
    c->pc = rw(c, 0xFFFE);
}

void mc6803_set_irq(mc6803 *c, int level) { c->irq1 = level ? 1 : 0; }
void mc6803_nmi(mc6803 *c) { c->nmi_pending = 1; }

void mc6803_input_capture(mc6803 *c)
{
    c->icr = c->frc;
    c->tcsr |= MC6803_TCSR_ICF;
    c->pend |= MC6803_TCSR_ICF;
}

/* ---- timer ---- */

static void tick(mc6803 *c, unsigned n)
{
    uint16_t old = c->frc;
    unsigned dist;
    c->frc = (uint16_t)(old + n);
    dist = (uint16_t)(c->ocr - old);
    if (dist >= 1 && dist <= n) { c->tcsr |= MC6803_TCSR_OCF; c->pend |= MC6803_TCSR_OCF; }
    dist = 0x10000u - old;
    if (dist <= n) { c->tcsr |= MC6803_TCSR_TOF; c->pend |= MC6803_TCSR_TOF; }
    c->cycles += n;
}

/* ---- ALU helpers ---- */

#define SETNZ8(c, r)  ((c)->cc = (uint8_t)(((c)->cc & ~(MC6803_CC_N | MC6803_CC_Z)) | ((r) & 0x80 ? MC6803_CC_N : 0) | (((r) & 0xFF) == 0 ? MC6803_CC_Z : 0)))
#define SETNZ16(c, r) ((c)->cc = (uint8_t)(((c)->cc & ~(MC6803_CC_N | MC6803_CC_Z)) | ((r) & 0x8000 ? MC6803_CC_N : 0) | (((r) & 0xFFFF) == 0 ? MC6803_CC_Z : 0)))
#define CLRV(c) ((c)->cc &= (uint8_t)~MC6803_CC_V)
#define SETCC(c, mask, cond) ((c)->cc = (uint8_t)((cond) ? ((c)->cc | (mask)) : ((c)->cc & ~(mask))))

static uint8_t add8(mc6803 *c, uint8_t a, uint8_t b, unsigned cin)
{
    unsigned r = (unsigned)a + b + cin;
    SETCC(c, MC6803_CC_H, ((a ^ b ^ r) & 0x10));
    SETCC(c, MC6803_CC_C, r & 0x100);
    SETCC(c, MC6803_CC_V, (~(a ^ b) & (a ^ r)) & 0x80);
    SETNZ8(c, r);
    return (uint8_t)r;
}

static uint8_t sub8(mc6803 *c, uint8_t a, uint8_t b, unsigned cin)  /* a - b - cin, no H */
{
    unsigned r = (unsigned)a - b - cin;
    SETCC(c, MC6803_CC_C, r & 0x100);
    SETCC(c, MC6803_CC_V, ((a ^ b) & (a ^ r)) & 0x80);
    SETNZ8(c, r);
    return (uint8_t)r;
}

static uint16_t add16(mc6803 *c, uint16_t a, uint16_t b)
{
    uint32_t r = (uint32_t)a + b;
    SETCC(c, MC6803_CC_C, r & 0x10000);
    SETCC(c, MC6803_CC_V, (~(a ^ b) & (a ^ r)) & 0x8000);
    SETNZ16(c, r);
    return (uint16_t)r;
}

static uint16_t sub16(mc6803 *c, uint16_t a, uint16_t b)
{
    uint32_t r = (uint32_t)a - b;
    SETCC(c, MC6803_CC_C, r & 0x10000);
    SETCC(c, MC6803_CC_V, ((a ^ b) & (a ^ r)) & 0x8000);
    SETNZ16(c, r);
    return (uint16_t)r;
}

static uint8_t logic_flags(mc6803 *c, uint8_t r) { SETNZ8(c, r); CLRV(c); return r; }

/* read-modify-write ops by low nibble: 0 NEG 3 COM 4 LSR 6 ROR 7 ASR 8 ASL 9 ROL A DEC C INC D TST F CLR */
static uint8_t rmw(mc6803 *c, unsigned op, uint8_t v)
{
    uint8_t r, cin = (uint8_t)(c->cc & MC6803_CC_C);
    switch (op) {
    case 0x0: r = (uint8_t)(0 - v); SETNZ8(c, r); SETCC(c, MC6803_CC_V, v == 0x80); SETCC(c, MC6803_CC_C, v != 0); return r;
    case 0x3: r = (uint8_t)~v; SETNZ8(c, r); CLRV(c); c->cc |= MC6803_CC_C; return r;
    case 0xA: r = (uint8_t)(v - 1); SETNZ8(c, r); SETCC(c, MC6803_CC_V, v == 0x80); return r;
    case 0xC: r = (uint8_t)(v + 1); SETNZ8(c, r); SETCC(c, MC6803_CC_V, v == 0x7F); return r;
    case 0xD: SETNZ8(c, v); CLRV(c); c->cc &= (uint8_t)~MC6803_CC_C; return v;
    case 0xF: c->cc = (uint8_t)((c->cc & ~(MC6803_CC_N | MC6803_CC_V | MC6803_CC_C)) | MC6803_CC_Z); return 0;
    case 0x4: r = (uint8_t)(v >> 1); SETCC(c, MC6803_CC_C, v & 1); break;
    case 0x6: r = (uint8_t)((v >> 1) | (cin << 7)); SETCC(c, MC6803_CC_C, v & 1); break;
    case 0x7: r = (uint8_t)((v >> 1) | (v & 0x80)); SETCC(c, MC6803_CC_C, v & 1); break;
    case 0x8: r = (uint8_t)(v << 1); SETCC(c, MC6803_CC_C, v & 0x80); break;
    default:  r = (uint8_t)((v << 1) | cin); SETCC(c, MC6803_CC_C, v & 0x80); break; /* 9 ROL */
    }
    SETNZ8(c, r);
    SETCC(c, MC6803_CC_V, ((c->cc & MC6803_CC_N) != 0) != ((c->cc & MC6803_CC_C) != 0));
    return r;
}

/* ---- stack ---- */

static void push8(mc6803 *c, uint8_t v) { wb(c, c->sp, v); c->sp--; }
static uint8_t pull8(mc6803 *c) { c->sp++; return rb(c, c->sp); }
static void push16(mc6803 *c, uint16_t v) { push8(c, (uint8_t)v); push8(c, (uint8_t)(v >> 8)); }
static uint16_t pull16(mc6803 *c) { uint16_t h = pull8(c); return (uint16_t)((h << 8) | pull8(c)); }

static void push_frame(mc6803 *c)
{
    push8(c, (uint8_t)c->pc); push8(c, (uint8_t)(c->pc >> 8));
    push8(c, (uint8_t)c->x);  push8(c, (uint8_t)(c->x >> 8));
    push8(c, c->a); push8(c, c->b); push8(c, c->cc);
}

static int enter_irq(mc6803 *c, uint16_t vec)
{
    int n = 12;
    if (c->wai) { n = 4; c->wai = 0; } else push_frame(c);
    c->cc |= MC6803_CC_I;
    c->pc = rw(c, vec);
    tick(c, (unsigned)n);
    return n;
}

static int cond(mc6803 *c, unsigned k)  /* branch condition by low nibble of the opcode */
{
    unsigned cc = c->cc;
    unsigned C = cc & 1, V = (cc >> 1) & 1, Z = (cc >> 2) & 1, N = (cc >> 3) & 1;
    switch (k) {
    case 0x0: return 1;
    case 0x1: return 0;
    case 0x2: return !(C | Z);
    case 0x3: return C | Z;
    case 0x4: return !C;
    case 0x5: return C;
    case 0x6: return !Z;
    case 0x7: return Z;
    case 0x8: return !V;
    case 0x9: return V;
    case 0xA: return !N;
    case 0xB: return N;
    case 0xC: return !(N ^ V);
    case 0xD: return N ^ V;
    case 0xE: return !(Z | (N ^ V));
    default:  return Z | (N ^ V);
    }
}

static uint16_t fetch16(mc6803 *c) { uint16_t v = rw(c, c->pc); c->pc += 2; return v; }
static uint8_t fetch8(mc6803 *c) { return rb(c, c->pc++); }

/* effective address: mode 0 immediate (address of the operand, pc advanced by size), 1 direct, 2 indexed, 3 extended */
static uint16_t ea(mc6803 *c, unsigned mode, unsigned size)
{
    uint16_t a;
    switch (mode) {
    case 0: a = c->pc; c->pc = (uint16_t)(c->pc + size); return a;
    case 1: return fetch8(c);
    case 2: return (uint16_t)(c->x + fetch8(c));
    default: return fetch16(c);
    }
}

int mc6803_step(mc6803 *c)
{
    unsigned op, n;
    uint16_t addr;
    uint8_t t8;
    uint16_t t16;
    uint32_t t32;

    /* interrupts: NMI, IRQ1, then timer (ICF, OCF, TOF) */
    if (c->nmi_pending) { c->nmi_pending = 0; return enter_irq(c, 0xFFFC); }
    if (!(c->cc & MC6803_CC_I)) {
        if (c->irq1) return enter_irq(c, 0xFFF8);
        if ((c->tcsr & (MC6803_TCSR_EICI | MC6803_TCSR_ICF)) == (MC6803_TCSR_EICI | MC6803_TCSR_ICF)) return enter_irq(c, 0xFFF6);
        if ((c->tcsr & (MC6803_TCSR_EOCI | MC6803_TCSR_OCF)) == (MC6803_TCSR_EOCI | MC6803_TCSR_OCF)) return enter_irq(c, 0xFFF4);
        if ((c->tcsr & (MC6803_TCSR_ETOI | MC6803_TCSR_TOF)) == (MC6803_TCSR_ETOI | MC6803_TCSR_TOF)) return enter_irq(c, 0xFFF2);
    }
    if (c->wai) { tick(c, 1); return 1; }

    op = fetch8(c);
    n = cyc[op];

    if (op >= 0x80) {
        unsigned mode = (op >> 4) & 3;         /* 8/C imm, 9/D dir, A/E idx, B/F ext */
        unsigned lo = op & 15;
        int accb = op >= 0xC0;
        uint8_t *acc = accb ? &c->b : &c->a;
        switch (lo) {
        case 0x0: addr = ea(c, mode, 1); *acc = sub8(c, *acc, rb(c, addr), 0); break;                        /* SUB */
        case 0x1: addr = ea(c, mode, 1); (void)sub8(c, *acc, rb(c, addr), 0); break;                         /* CMP */
        case 0x2: addr = ea(c, mode, 1); *acc = sub8(c, *acc, rb(c, addr), c->cc & MC6803_CC_C); break;      /* SBC */
        case 0x3: addr = ea(c, mode, 2);
            if (!accb) { t16 = sub16(c, (uint16_t)((c->a << 8) | c->b), rw(c, addr)); }                      /* SUBD */
            else       { t16 = add16(c, (uint16_t)((c->a << 8) | c->b), rw(c, addr)); }                      /* ADDD */
            c->a = (uint8_t)(t16 >> 8); c->b = (uint8_t)t16; break;
        case 0x4: addr = ea(c, mode, 1); *acc = logic_flags(c, (uint8_t)(*acc & rb(c, addr))); break;        /* AND */
        case 0x5: addr = ea(c, mode, 1); (void)logic_flags(c, (uint8_t)(*acc & rb(c, addr))); break;         /* BIT */
        case 0x6: addr = ea(c, mode, 1); *acc = logic_flags(c, rb(c, addr)); break;                          /* LDA */
        case 0x7:                                                                                            /* STA */
            if (mode == 0) goto illegal;
            addr = ea(c, mode, 1); (void)logic_flags(c, *acc); wb(c, addr, *acc); break;
        case 0x8: addr = ea(c, mode, 1); *acc = logic_flags(c, (uint8_t)(*acc ^ rb(c, addr))); break;        /* EOR */
        case 0x9: addr = ea(c, mode, 1); *acc = add8(c, *acc, rb(c, addr), c->cc & MC6803_CC_C); break;      /* ADC */
        case 0xA: addr = ea(c, mode, 1); *acc = logic_flags(c, (uint8_t)(*acc | rb(c, addr))); break;        /* ORA */
        case 0xB: addr = ea(c, mode, 1); *acc = add8(c, *acc, rb(c, addr), 0); break;                        /* ADD */
        case 0xC: addr = ea(c, mode, 2);
            if (!accb) { t8 = (uint8_t)(c->cc & MC6803_CC_C); (void)sub16(c, c->x, rw(c, addr));              /* CPX: N Z V, C unchanged */
                         c->cc = (uint8_t)((c->cc & ~MC6803_CC_C) | t8); }
            else { t16 = rw(c, addr); SETNZ16(c, t16); CLRV(c); c->a = (uint8_t)(t16 >> 8); c->b = (uint8_t)t16; } /* LDD */
            break;
        case 0xD:
            if (!accb) {                                                                                     /* BSR / JSR */
                if (mode == 0) { t8 = fetch8(c); push16(c, c->pc); c->pc = (uint16_t)(c->pc + (int8_t)t8); }
                else { addr = ea(c, mode, 0); push16(c, c->pc); c->pc = addr; }
            } else {                                                                                         /* STD */
                if (mode == 0) goto illegal;
                addr = ea(c, mode, 2); t16 = (uint16_t)((c->a << 8) | c->b); SETNZ16(c, t16); CLRV(c); ww(c, addr, t16);
            }
            break;
        case 0xE: addr = ea(c, mode, 2); t16 = rw(c, addr); SETNZ16(c, t16); CLRV(c);                        /* LDS / LDX */
            if (!accb) c->sp = t16; else c->x = t16;
            break;
        default:                                                                                             /* STS / STX */
            if (mode == 0) goto illegal;
            addr = ea(c, mode, 2); t16 = accb ? c->x : c->sp; SETNZ16(c, t16); CLRV(c); ww(c, addr, t16);
            break;
        }
        goto done;
    }

    if (op >= 0x40) {
        unsigned lo = op & 15;
        unsigned mode = op >> 4;               /* 4 A, 5 B, 6 idx, 7 ext */
        if (lo == 1 || lo == 2 || lo == 5 || lo == 0xB) goto illegal;
        if (mode < 6) {
            if (lo == 0xE) goto illegal;
            if (mode == 4) c->a = rmw(c, lo, c->a); else c->b = rmw(c, lo, c->b);
        } else if (lo == 0xE) {
            c->pc = ea(c, mode == 6 ? 2 : 3, 0);                                                              /* JMP */
        } else {
            addr = ea(c, mode == 6 ? 2 : 3, 0);
            if (lo == 0xF) (void)rmw(c, lo, 0), wb(c, addr, 0);                                                /* CLR: no read */
            else if (lo == 0xD) (void)rmw(c, lo, rb(c, addr));                                                 /* TST */
            else wb(c, addr, rmw(c, lo, rb(c, addr)));
        }
        goto done;
    }

    if (op >= 0x20 && op < 0x30) {
        t8 = fetch8(c);
        if (cond(c, op & 15)) c->pc = (uint16_t)(c->pc + (int8_t)t8);
        goto done;
    }

    switch (op) {
    case 0x01: break;                                                                                         /* NOP */
    case 0x04: t16 = (uint16_t)((c->a << 8) | c->b);                                                          /* LSRD */
        SETCC(c, MC6803_CC_C, t16 & 1); t16 >>= 1; c->a = (uint8_t)(t16 >> 8); c->b = (uint8_t)t16;
        SETNZ16(c, t16); c->cc &= (uint8_t)~MC6803_CC_N; SETCC(c, MC6803_CC_V, c->cc & MC6803_CC_C); break;
    case 0x05: t32 = (uint32_t)((c->a << 8) | c->b) << 1;                                                      /* ASLD */
        SETCC(c, MC6803_CC_C, t32 & 0x10000); t16 = (uint16_t)t32; c->a = (uint8_t)(t16 >> 8); c->b = (uint8_t)t16;
        SETNZ16(c, t16); SETCC(c, MC6803_CC_V, ((c->cc & MC6803_CC_N) != 0) != ((c->cc & MC6803_CC_C) != 0)); break;
    case 0x06: c->cc = (uint8_t)(c->a | 0xC0); break;                                                          /* TAP */
    case 0x07: c->a = c->cc; break;                                                                            /* TPA */
    case 0x08: c->x++; SETCC(c, MC6803_CC_Z, c->x == 0); break;                                                /* INX */
    case 0x09: c->x--; SETCC(c, MC6803_CC_Z, c->x == 0); break;                                                /* DEX */
    case 0x0A: c->cc &= (uint8_t)~MC6803_CC_V; break;
    case 0x0B: c->cc |= MC6803_CC_V; break;
    case 0x0C: c->cc &= (uint8_t)~MC6803_CC_C; break;
    case 0x0D: c->cc |= MC6803_CC_C; break;
    case 0x0E: c->cc &= (uint8_t)~MC6803_CC_I; break;
    case 0x0F: c->cc |= MC6803_CC_I; break;
    case 0x10: c->a = sub8(c, c->a, c->b, 0); break;                                                           /* SBA */
    case 0x11: (void)sub8(c, c->a, c->b, 0); break;                                                            /* CBA */
    case 0x16: c->b = logic_flags(c, c->a); break;                                                             /* TAB */
    case 0x17: c->a = logic_flags(c, c->b); break;                                                             /* TBA */
    case 0x19: {                                                                                               /* DAA */
        unsigned adj = 0, a = c->a;
        if ((c->cc & MC6803_CC_H) || (a & 0x0F) > 9) adj |= 0x06;
        if ((c->cc & MC6803_CC_C) || a > 0x99 || ((a & 0xF0) > 0x90 && (a & 0x0F) > 9)) adj |= 0x60;
        a += adj;
        SETCC(c, MC6803_CC_C, (c->cc & MC6803_CC_C) || (adj & 0x60));
        c->a = (uint8_t)a; SETNZ8(c, a);
        break; }
    case 0x1B: c->a = add8(c, c->a, c->b, 0); break;                                                           /* ABA */
    case 0x30: c->x = (uint16_t)(c->sp + 1); break;                                                            /* TSX */
    case 0x31: c->sp++; break;                                                                                 /* INS */
    case 0x32: c->a = pull8(c); break;                                                                         /* PULA */
    case 0x33: c->b = pull8(c); break;
    case 0x34: c->sp--; break;                                                                                 /* DES */
    case 0x35: c->sp = (uint16_t)(c->x - 1); break;                                                            /* TXS */
    case 0x36: push8(c, c->a); break;
    case 0x37: push8(c, c->b); break;
    case 0x38: c->x = pull16(c); break;                                                                        /* PULX */
    case 0x39: c->pc = pull16(c); break;                                                                       /* RTS */
    case 0x3A: c->x = (uint16_t)(c->x + c->b); break;                                                          /* ABX */
    case 0x3B: c->cc = (uint8_t)(pull8(c) | 0xC0); c->b = pull8(c); c->a = pull8(c); c->x = pull16(c); c->pc = pull16(c); break; /* RTI */
    case 0x3C: push16(c, c->x); break;                                                                         /* PSHX */
    case 0x3D: t16 = (uint16_t)(c->a * c->b); c->a = (uint8_t)(t16 >> 8); c->b = (uint8_t)t16;                /* MUL */
        SETCC(c, MC6803_CC_C, t16 & 0x80); break;
    case 0x3E: push_frame(c); c->wai = 1; break;                                                               /* WAI */
    case 0x3F: push_frame(c); c->cc |= MC6803_CC_I; c->pc = rw(c, 0xFFFA); break;                              /* SWI */
    default:
    illegal:
        c->illegal = (uint8_t)op; c->illegal_pc = (uint16_t)(c->pc - 1); c->illegal_count++;
        break;
    }
done:
    tick(c, n);
    return (int)n;
}
