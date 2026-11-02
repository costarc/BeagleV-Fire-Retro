/* The Alice's cassette recorder, in the emulator process (the other machines have it in the gateware: rtl/bvf_tape.v, same entries).
 *
 * Play: the daemon sends 32 bit little endian words on stdin: an entry is hold << 31 | duration in microseconds (< 2^20): the tape input
 * (P2.4) starts low and toggles at the end of every entry, except after an entry with the hold bit. A word with bits 30:28 set is a
 * command: 0x7000000n, n = 1 play on, 2 play off, 3 flush the play FIFO and the level, 4 record on, 5 record off, 6 flush the record list.
 * Time runs in 6803 cycles (894 886 per second) and only while play is on; an empty FIFO holds the level.
 * Record: every change of P2.0 (cassette out) while record is on goes to stdout as  "R <level> <microseconds since the previous change>".
 * "F <free entries> <active>" on stdout, every 20 ms, tells the daemon how much it may send.
 */
#ifndef ALICE_TAPE_H
#define ALICE_TAPE_H
#include <stdint.h>

#define TAPE_CAP 8192
#define TAPE_CMD(n) (0x70000000u | (n))

typedef struct {
    uint32_t q[TAPE_CAP];
    uint32_t head, n;
    int      play, active, hold, rec;
    uint64_t left;                 /* cycles left in the entry that is playing */
    uint8_t  level;                /* the tape input */
    uint64_t rec_last;             /* the cycle of the previous recorded change */
} tape_t;

static uint64_t tape_us_to_cycles(uint32_t us, uint32_t hz)
{
    uint64_t c = (uint64_t)us * hz / 1000000u;
    return c ? c : 1;
}

static void tape_word(tape_t *t, uint32_t w, uint64_t now)
{
    if (w & 0x70000000u) {
        switch (w & 15) {
        case 1: t->play = 1; break;
        case 2: t->play = 0; break;
        case 3: t->head = t->n = 0; t->active = 0; t->level = 0; break;
        case 4: t->rec = 1; t->rec_last = now; break;
        case 5: t->rec = 0; break;
        default: break;
        }
    } else if (t->n < TAPE_CAP) {
        t->q[(t->head + t->n) % TAPE_CAP] = w;
        t->n++;
    }
}

/* dc cycles passed */
static void tape_run(tape_t *t, uint32_t hz, uint64_t dc)
{
    if (!t->play) return;
    while (dc) {
        if (!t->active) {
            uint32_t w;
            if (!t->n) return;
            w = t->q[t->head];
            t->head = (t->head + 1) % TAPE_CAP;
            t->n--;
            t->hold = (int)(w >> 31);
            t->left = tape_us_to_cycles(w & 0xFFFFF, hz);
            t->active = 1;
        }
        if (dc >= t->left) {
            dc -= t->left;
            t->active = 0;
            if (!t->hold) t->level ^= 1;
        } else {
            t->left -= dc;
            dc = 0;
        }
    }
}

#endif
