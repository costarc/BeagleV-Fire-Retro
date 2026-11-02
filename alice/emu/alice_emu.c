/* The Matra Alice on the BeagleV-Fire: the MC6803 runs here, in real time, the FPGA keeps the video (the MC6847 and the video RAM).
 *
 *   alice_emu <rom.bin> [--uio /dev/uio0 | --mem 0xADDR] [--ram bytes] [--sim file]
 *
 * It maps the gateware's register window (the same 32 bit accesses as cp300d.py's regs32.c) and
 *   - runs the 6803 paced against CLOCK_MONOTONIC (894 886 cycles per second), in slices of about 1 ms;
 *   - writes every changed 32 bit word of the video RAM ($4000-$57FF, 6 KB) into the window at 0x60000 after each slice;
 *   - writes the $BFFF latch (mode, CSS and the 1-bit sound on b7) to the ALICE register (0xA0) right after the instruction that
 *     stored it, so a sound edge is late by about one register write (a few us);
 *   - reads the key matrix (KEYS_LO / KEYS_HI, bit = 8 * column + row) at every slice;
 *   - SIGUSR1 = reset (RAM kept), SIGTERM / SIGINT = leave.
 * --sim file: no hardware, the register window is a plain array and the video RAM and mode are written to `file` (alice_vram.hex
 * format of sim/tb_z80sys.v) when the process is stopped: a test of the pacing and flush logic on the PC.
 * The ROM (8 KB, $E000-$FFFF) is supplied by the user and never committed.
 */
#define ALICE_EMU_LIB
#include "alice.c"
#include "alice_tape.h"

#include <signal.h>
#ifndef _WIN32
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif

#define R_KEYS_LO 0x0C
#define R_KEYS_HI 0x10
#define R_ALICE   0xA0
#define W_ALICE   0x60000u
#define WIN_SIZE  0x100000u
#define VRAM_WORDS 1536

static volatile uint32_t *regs;          /* the register window (word index = byte offset / 4) */
static volatile sig_atomic_t want_reset, want_stop;

static void wr32(uint32_t off, uint32_t v) { regs[off >> 2] = v; }
static uint32_t rd32(uint32_t off) { return regs[off >> 2]; }

#ifdef SIGUSR1
static void on_usr1(int s) { (void)s; want_reset = 1; }
#endif
static void on_term(int s) { (void)s; want_stop = 1; }

static uint64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static tape_t tp;
static uint8_t  tape_rest[4];
static int      tape_rest_n;
static char     outbuf[4096];
static size_t   outn;

#ifndef _WIN32
/* the daemon's words on stdin (non blocking); a word can arrive in two pieces */
static void tape_input(uint64_t now)
{
    uint8_t buf[4096 + 4];
    ssize_t r;
    while ((r = read(0, buf + tape_rest_n, 4096)) > 0) {
        size_t have = (size_t)r + (size_t)tape_rest_n, i;
        memcpy(buf, tape_rest, (size_t)tape_rest_n);
        for (i = 0; i + 4 <= have; i += 4)
            tape_word(&tp, (uint32_t)buf[i] | ((uint32_t)buf[i + 1] << 8) | ((uint32_t)buf[i + 2] << 16) | ((uint32_t)buf[i + 3] << 24), now);
        tape_rest_n = (int)(have - i);
        memcpy(tape_rest, buf + i, (size_t)tape_rest_n);
    }
}
#endif

static void out_flush(void)
{
    if (outn) { fwrite(outbuf, 1, outn, stdout); fflush(stdout); outn = 0; }
}

static void out_line(const char *fmt, unsigned a, unsigned long long b)
{
    int k;
    if (outn + 64 > sizeof outbuf) out_flush();
    k = snprintf(outbuf + outn, 64, fmt, a, b);
    if (k > 0) outn += (size_t)k;
}

static uint32_t vram_word(const machine *m, uint32_t n)
{
    return (uint32_t)m->ram[4 * n] | ((uint32_t)m->ram[4 * n + 1] << 8) | ((uint32_t)m->ram[4 * n + 2] << 16) | ((uint32_t)m->ram[4 * n + 3] << 24);
}

int main(int argc, char **argv)
{
    static machine m;
    static uint32_t shadow[VRAM_WORDS];
    static uint32_t simregs[WIN_SIZE / 4];
    const char *romfile = NULL, *uio = NULL, *simfile = NULL;
    uint64_t mem = 0;
    uint32_t ram = 0x5000;               /* 20 KB: the 4 KB MC-10 with the 16 KB expansion (the video RAM is the first 6 KB) */
    int i;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--uio") && i + 1 < argc) uio = argv[++i];
        else if (!strcmp(argv[i], "--mem") && i + 1 < argc) mem = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--ram") && i + 1 < argc) ram = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--sim") && i + 1 < argc) simfile = argv[++i];
        else romfile = argv[i];
    }
    if (!romfile || (!uio && !mem && !simfile)) {
        fprintf(stderr, "usage: alice_emu rom.bin (--uio /dev/uioN | --mem 0xADDR | --sim out.hex) [--ram bytes]\n");
        return 2;
    }
    if (ram < 0x1800) ram = 0x1800;
    if (ram > sizeof m.ram) ram = sizeof m.ram;

    machine_init(&m, ram);
    keyboard_alice();
    {
        FILE *f = fopen(romfile, "rb");
        size_t n;
        if (!f) { perror(romfile); return 2; }
        n = fread(m.rom, 1, sizeof m.rom, f);
        fclose(f);
        if (n != 0x2000) { fprintf(stderr, "%s: %u bytes, the Alice's ROM has 8192\n", romfile, (unsigned)n); return 2; }
    }

    if (simfile) regs = simregs;
    else {
#ifdef _WIN32
        fprintf(stderr, "no hardware access on Windows: use --sim\n");
        return 2;
#else
        int fd = open(uio ? uio : "/dev/mem", O_RDWR | O_SYNC);
        void *p;
        if (fd < 0) { perror(uio ? uio : "/dev/mem"); return 2; }
        p = mmap(NULL, WIN_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, uio ? 0 : (off_t)mem);
        if (p == MAP_FAILED) { perror("mmap"); return 2; }
        regs = (volatile uint32_t *)p;
#endif
    }

    #ifdef SIGUSR1
    signal(SIGUSR1, on_usr1);
#endif
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);

    machine_start(&m);
    memset(shadow, 0, sizeof shadow);
#ifndef _WIN32
    if (!simfile) fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);
#endif
    {
        uint64_t t0 = now_ns(), cyc0 = m.cpu.cycles;
        uint32_t last_bfff_writes = 0, last_cass_edges = 0;
        uint64_t last_f = 0;
        uint8_t shown_mode = 0xFF;
        uint32_t n;

        wr32(R_ALICE, m.bfff);
        shown_mode = m.bfff;
        while (!want_stop) {
            uint64_t target = cyc0 + (now_ns() - t0) * CPU_HZ / 1000000000ull + CPU_HZ / 2000;   /* up to 0.5 ms ahead */
            uint64_t k;
            uint32_t keys_lo, keys_hi;

            if (want_reset) { want_reset = 0; mc6803_reset(&m.cpu); }
            #ifndef _WIN32
            tape_input(m.cpu.cycles);
            #endif
            while (m.cpu.cycles < target) {
                uint64_t c0 = m.cpu.cycles;
                mc6803_step(&m.cpu);
                tape_run(&tp, CPU_HZ, m.cpu.cycles - c0);
                m.tape_in = tp.level;
                if (m.cass_edges != last_cass_edges) {            /* P2.0 changed: a recorded edge */
                    last_cass_edges = m.cass_edges;
                    if (tp.rec) out_line("R %u %llu\n", m.cass_out, (m.cpu.cycles - tp.rec_last) * 1000000ull / CPU_HZ);
                    tp.rec_last = m.cpu.cycles;
                }
                if (m.bfff_writes != last_bfff_writes) {          /* the 6803 stored $BFFF: the sound edge goes out now */
                    last_bfff_writes = m.bfff_writes;
                    if (m.bfff != shown_mode) { shown_mode = m.bfff; wr32(R_ALICE, shown_mode); }
                }
            }
            if (!simfile && m.cpu.cycles - last_f > CPU_HZ / 50) {            /* every 20 ms: what the daemon may send */
                last_f = m.cpu.cycles;
                out_line("F %u %llu\n", (unsigned)(TAPE_CAP - tp.n), (unsigned long long)(tp.active || tp.n));
            }
            out_flush();
            keys_lo = rd32(R_KEYS_LO); keys_hi = rd32(R_KEYS_HI);
            for (k = 0; k < 8; k++) m.keys[k] = (uint8_t)(((k < 4 ? keys_lo : keys_hi) >> (8 * (k & 3))) & 0x7F);
            for (n = 0; n < VRAM_WORDS; n++) {                    /* the changed words of the video RAM */
                uint32_t w = vram_word(&m, n);
                if (w != shadow[n]) { wr32(W_ALICE + 4 * n, w); shadow[n] = w; }
            }
            if (!simfile) {                                        /* sleep until the machine is about 0.25 ms ahead of real time */
                struct timespec ts = { 0, 250000 };
                nanosleep(&ts, NULL);
            } else if (m.cpu.cycles > (uint64_t)3 * CPU_HZ) break;
        }
    }
    if (simfile) {
        FILE *f = fopen(simfile, "w");
        uint32_t n;
        if (!f) { perror(simfile); return 2; }
        fprintf(f, "%08X\n", (unsigned)(simregs[R_ALICE >> 2] & 0xFF));
        for (n = 0; n < VRAM_WORDS; n++) fprintf(f, "%08X\n", (unsigned)simregs[(W_ALICE >> 2) + n]);
        fclose(f);
    }
    return 0;
}
