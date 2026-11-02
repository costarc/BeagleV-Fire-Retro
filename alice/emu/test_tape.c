/* alice_tape.h: the play FIFO in cycles, the hold bit, the commands. */
#include <stdio.h>
#include "alice_tape.h"

static tape_t t;
static int bad;
static void check(int ok, const char *what) { if (!ok) { printf("FAIL: %s\n", what); bad++; } }

int main(void)
{
    uint32_t hz = 894886;
    uint64_t c100 = tape_us_to_cycles(100, hz), c1000 = tape_us_to_cycles(1000, hz);
    check(c100 == 89 && c1000 == 894, "microseconds to cycles");
    tape_word(&t, TAPE_CMD(3), 0);
    tape_word(&t, 100, 0);                   /* 100 us low, then high */
    tape_word(&t, 1000, 0);                  /* 1000 us high, then low */
    tape_word(&t, 0x80000000u | 500, 0);     /* 500 us low, held */
    tape_word(&t, 200, 0);                   /* 200 us low, then high */
    tape_run(&t, hz, 1000);
    check(t.level == 0 && t.n == 4, "nothing moves while play is off");
    tape_word(&t, TAPE_CMD(1), 0);
    tape_run(&t, hz, c100 - 1);
    check(t.level == 0, "low until the end of the first entry");
    tape_run(&t, hz, 1);
    check(t.level == 1, "high after 100 us");
    tape_run(&t, hz, c1000);
    check(t.level == 0, "low after 1100 us");
    tape_run(&t, hz, tape_us_to_cycles(500, hz));
    check(t.level == 0, "the hold entry does not toggle");
    tape_run(&t, hz, tape_us_to_cycles(200, hz));
    check(t.level == 1, "high after the last entry");
    tape_run(&t, hz, 100000);
    check(t.level == 1 && t.n == 0, "an empty FIFO holds the level");
    tape_word(&t, TAPE_CMD(2), 0);
    tape_word(&t, 50, 0);
    tape_run(&t, hz, 1000);
    check(t.n == 1, "play off stops the tape");
    tape_word(&t, TAPE_CMD(3), 0);
    check(t.n == 0 && t.level == 0, "flush");
    printf(bad ? "%d tape checks failed\n" : "tape: all checks passed\n", bad);
    return bad != 0;
}
