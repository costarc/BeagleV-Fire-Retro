/* MC6803 (6800 + 6801/6803 additions) interpreter.
 *
 * Dependency free: no malloc, no libc (memcpy-free as well), no globals, no float.
 * Everything the CPU touches outside itself goes through the callbacks below, so the
 * same file runs on the PC (test harness) and bare-metal on a U54 hart.
 *
 * Timing: mc6803_step() executes one instruction (or one interrupt entry, or one wait
 * cycle in WAI) and returns the CPU cycles it took (the 6801 data sheet / MAME table).
 * The on-chip timer and the interrupt lines are advanced by that count at the end of
 * the instruction, so peripheral state changes inside one instruction (at most 12
 * cycles = 13 us at 0.9 MHz) become visible at the instruction boundary. Bus accesses
 * are done once per operand byte, in program order, without the dummy cycles.
 *
 * Not modelled: serial interface (TRCSR reads TDRE, nothing is sent), port 3 handshake,
 * port 4 as address lines, operating-mode pins (always an expanded mode with the
 * 128 byte on-chip RAM at $0080-$00FF, as in the MC-10 / Alice).
 * Written from the MC6801/MC6803 data sheet; cycle counts and timer details checked
 * against MAME's m6801.cpp (read only, nothing copied).
 */
#ifndef MC6803_H
#define MC6803_H

#include <stdint.h>

#define MC6803_CC_C 0x01
#define MC6803_CC_V 0x02
#define MC6803_CC_Z 0x04
#define MC6803_CC_N 0x08
#define MC6803_CC_I 0x10
#define MC6803_CC_H 0x20

/* on-chip register addresses */
#define MC6803_DDR1 0x00
#define MC6803_DDR2 0x01
#define MC6803_P1   0x02
#define MC6803_P2   0x03
#define MC6803_DDR3 0x04
#define MC6803_DDR4 0x05
#define MC6803_P3   0x06
#define MC6803_P4   0x07
#define MC6803_TCSR 0x08
#define MC6803_FRCH 0x09
#define MC6803_FRCL 0x0A
#define MC6803_OCRH 0x0B
#define MC6803_OCRL 0x0C
#define MC6803_ICRH 0x0D
#define MC6803_ICRL 0x0E
#define MC6803_P3CSR 0x0F
#define MC6803_RMCR 0x10
#define MC6803_TRCSR 0x11
#define MC6803_RDR  0x12
#define MC6803_TDR  0x13
#define MC6803_RCR  0x14

#define MC6803_TCSR_OLVL 0x01
#define MC6803_TCSR_IEDG 0x02
#define MC6803_TCSR_ETOI 0x04
#define MC6803_TCSR_EOCI 0x08
#define MC6803_TCSR_EICI 0x10
#define MC6803_TCSR_TOF  0x20
#define MC6803_TCSR_OCF  0x40
#define MC6803_TCSR_ICF  0x80

typedef struct mc6803 mc6803;

struct mc6803 {
    /* registers */
    uint16_t pc, sp, x;
    uint8_t  a, b, cc;
    /* on-chip peripherals */
    uint8_t  ddr[4];          /* DDR1..DDR4 */
    uint8_t  pout[4];         /* output latches P1..P4 */
    uint8_t  tcsr;
    uint8_t  pend;            /* flags set since TCSR was last read (TCSR-then-access clear rule) */
    uint8_t  frc_latch;       /* high byte written to FRC, waits for the low byte */
    uint16_t frc, ocr, icr;
    uint8_t  rcr;             /* RAM control: bit 6 = on-chip RAM enabled */
    uint8_t  ram[128];        /* on-chip RAM $0080-$00FF */
    /* state */
    uint8_t  wai;             /* 1 = executing WAI, frame already pushed */
    uint8_t  nmi_pending;
    uint8_t  irq1;            /* IRQ1 pin level, 1 = asserted (level sensitive) */
    uint8_t  illegal;         /* last illegal opcode seen (0 = none), pc in illegal_pc */
    uint16_t illegal_pc;
    uint32_t illegal_count;
    uint64_t cycles;          /* total CPU cycles since reset */
    /* bus */
    void    *ctx;
    uint8_t  (*rd)(void *ctx, uint16_t addr);             /* external memory read  */
    void     (*wr)(void *ctx, uint16_t addr, uint8_t v);  /* external memory write */
    uint8_t  (*port_in)(void *ctx, int port);             /* pin levels of P1..P4 (port 0..3); input bits only are used */
    void     (*port_out)(void *ctx, int port, uint8_t latch, uint8_t ddr); /* after every write to a port or DDR */
};

void     mc6803_init(mc6803 *c, void *ctx,
                     uint8_t (*rd)(void *, uint16_t), void (*wr)(void *, uint16_t, uint8_t),
                     uint8_t (*port_in)(void *, int), void (*port_out)(void *, int, uint8_t, uint8_t));
void     mc6803_reset(mc6803 *c);                 /* loads PC from $FFFE */
int      mc6803_step(mc6803 *c);                  /* returns cycles used (>=1) */
void     mc6803_set_irq(mc6803 *c, int level);    /* IRQ1 pin */
void     mc6803_nmi(mc6803 *c);                   /* NMI edge */
void     mc6803_input_capture(mc6803 *c);         /* active edge on P2.0 (TIN) seen by the harness */

#endif
