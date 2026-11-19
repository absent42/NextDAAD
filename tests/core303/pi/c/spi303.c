/* spi303: spidev CLI for the core303 Pi tools. Rows go to stdout in the Pi log grammar.
   Never takes /run/nextspi.lock: the Python orchestrator holds it for the whole run.
   Every command is one SPI_IOC_MESSAGE(2): header at 2 MHz, payload at the test rate. */
#ifdef __linux__
#define _POSIX_C_SOURCE 200809L
#endif
#include <errno.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core303pi.h"

#ifdef __linux__
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <linux/spi/spidev.h>

/* link.py pack_spi_transfer: 32 bytes, len at 16, speed_hz at 20 */
typedef char chk_size[sizeof(struct spi_ioc_transfer) == 32 ? 1 : -1];
typedef char chk_len[offsetof(struct spi_ioc_transfer, len) == 16 ? 1 : -1];
typedef char chk_speed[offsetof(struct spi_ioc_transfer, speed_hz) == 20 ? 1 : -1];
#endif

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#endif

#define USAGE \
    "usage: spi303 [--dev PATH] [--sim [--sim-loss TX:OFF]] <subcommand> ...\n" \
    "  serve\n" \
    "  write <phys> <bytes> <hz> <chunk> <seed0> [--passes N] [--hb MBOX]\n" \
    "  read <phys> <bytes> <hz> <chunk> [--seed S] [--passes N] [--hb MBOX]\n" \
    "  bram <7> <hz> <passes> <seed0> [--hb MBOX]\n" \
    "  stream <phys|bram5:OFF|bram7[:OFF]> <len> <hz> <src_file> --hb MBOX\n" \
    "  selftest <phys>\n" \
    "  smoke\n"

static uint64_t host_now(void *ctx)
{
    (void)ctx;
#ifdef __linux__
    {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
    }
#elif defined(_WIN32)
    {
        LARGE_INTEGER c, f;
        QueryPerformanceCounter(&c);
        QueryPerformanceFrequency(&f);
        return (uint64_t)((double)c.QuadPart * 1e9 / (double)f.QuadPart);
    }
#else
    return 0;
#endif
}

#ifdef __linux__
static int spi_fd = -1;

/* Returns the raw ioctl result: total bytes on success, -1 on failure. */
static int spi_message(struct xfer_desc *d, int n)
{
    struct spi_ioc_transfer t[2];
    int i;
    if (xfer_guard(d, n)) {             /* speed 0 would mean the 12 MHz device max */
        errno = EINVAL;
        return -1;
    }
    memset(t, 0, sizeof t);
    for (i = 0; i < n; i++) {
        t[i].tx_buf = (uintptr_t)d[i].tx;
        t[i].rx_buf = (uintptr_t)d[i].rx;
        t[i].len = d[i].len;
        t[i].speed_hz = d[i].speed_hz;
        t[i].bits_per_word = d[i].bits_per_word;
        t[i].cs_change = d[i].cs_change;
    }
    return ioctl(spi_fd, n == 1 ? SPI_IOC_MESSAGE(1) : SPI_IOC_MESSAGE(2), t);
}

static int spi_xfer(void *ctx, struct xfer_desc *d, int n)
{
    uint32_t total = 0;
    int i;
    (void)ctx;
    for (i = 0; i < n; i++)
        total += d[i].len;
    return spi_message(d, n) == (int)total ? 0 : -1;
}

static int dev_rd(void *ctx, int what, uint32_t *v)
{
    uint8_t m;
    (void)ctx;
    if (what == DEV_HZ)
        return ioctl(spi_fd, SPI_IOC_RD_MAX_SPEED_HZ, v) < 0 ? -1 : 0;
    if (ioctl(spi_fd, SPI_IOC_RD_MODE, &m) < 0)
        return -1;
    *v = m;
    return 0;
}

static int dev_wr(void *ctx, int what, uint32_t v)
{
    uint8_t m = (uint8_t)v;
    (void)ctx;
    if (what == DEV_HZ)
        return ioctl(spi_fd, SPI_IOC_WR_MAX_SPEED_HZ, &v) < 0 ? -1 : 0;
    return ioctl(spi_fd, SPI_IOC_WR_MODE, &m) < 0 ? -1 : 0;
}

/* Device max to the ladder top (the SPI core clamps each transfer's speed_hz to it),
   mode 0; both saved first and restored at exit (devcfg). Bits go per transfer. */
static int spi_open(const char *dev, devcfg_t *c)
{
    spi_fd = open(dev, O_RDWR);
    if (spi_fd < 0)
        return -1;
    c->rd = dev_rd;
    c->wr = dev_wr;
    c->ctx = NULL;
    return devcfg_open(c);
}

static int err_fd = 1;

static void sig_emit(const char *s, size_t n)
{
    ssize_t k = write(err_fd, s, n);
    (void)k;
}

/* Restore-then-_exit on INT, TERM, HUP, PIPE; dispositions inherited as ignored stay. */
static void install_signals(void)
{
    static const int sigs[4] = {SIGINT, SIGTERM, SIGHUP, SIGPIPE};
    struct sigaction sa, old;
    int i;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = devcfg_on_signal;
    sigfillset(&sa.sa_mask);
    devcfg_emit = sig_emit;
    devcfg_exit = _exit;
    for (i = 0; i < 4; i++)
        if (sigaction(sigs[i], NULL, &old) == 0 && old.sa_handler != SIG_IGN)
            sigaction(sigs[i], &sa, NULL);
}

/* stream stops when the parent closes our stdin; stray input is discarded. */
static int stdin_closed(void *ctx)
{
    struct pollfd p;
    char buf[256];
    (void)ctx;
    for (;;) {
        p.fd = 0;
        p.events = POLLIN;
        p.revents = 0;
        if (poll(&p, 1, 0) <= 0)
            return 0;
        if (p.revents & POLLIN) {
            ssize_t k = read(0, buf, sizeof buf);
            if (k == 0 || (k < 0 && errno != EINTR))
                return 1;
            continue;
        }
        return (p.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0;
    }
}

/* No slave needed (SCLK runs regardless): a 4000-byte SRAM_R payload of address 0
   at 2 and 12 MHz, 5 runs each; a clamped speed shows as ns_hi close to ns_lo. */
static int do_smoke(void)
{
    static uint8_t rx[MAX_CHUNK];
    static const uint8_t z[MAX_CHUNK];
    uint64_t t[2][5], t0, nl, nh;
    uint32_t ratio;
    uint8_t h[8];
    struct xfer_desc d[2];
    size_t hl = build_cmd(CMD_SRAM_R, 0, MAX_CHUNK, h);
    int r, k, ok, failed = 0;
    memset(t, 0, sizeof t);
    for (r = 0; r < 2 && !failed; r++)
        for (k = 0; k < 5 && !failed; k++) {
            plan_xfers(h, hl, z, MAX_CHUNK, r ? MAX_HZ : HDR_HZ, d);
            d[1].rx = rx;
            t0 = host_now(NULL);
            failed = spi_message(d, 2) != (int)(hl + MAX_CHUNK);
            t[r][k] = host_now(NULL) - t0;
        }
    ok = smoke_eval(t[0], t[1], &nl, &nh, &ratio) && !failed;
    printf("P2SM ok=%d ns_lo=%" PRIu64 " ns_hi=%" PRIu64 " ratio_x100=%" PRIu32 "\n",
           ok, nl, nh, ratio);
    return ok ? 0 : 1;
}
#endif

static int std_read(void *ctx, uint8_t *b, size_t n)
{
    (void)ctx;
    return (int)fread(b, 1, n, stdin);
}

static int std_write(void *ctx, const uint8_t *b, size_t n)
{
    (void)ctx;
    return fwrite(b, 1, n, stdout) == n && fflush(stdout) == 0 ? 0 : -1;
}

static int parse_u32(const char *s, uint32_t *v)
{
    char *e;
    unsigned long x;
    if (!s || !*s || *s == '-')
        return 0;
    errno = 0;
    x = strtoul(s, &e, 0);
    if (*e || errno || x > 0xFFFFFFFFul)
        return 0;
    *v = (uint32_t)x;
    return 1;
}

/* <phys> or bram5:OFF / bram7[:OFF] into a command and slave address. */
static int parse_target(const char *s, uint8_t *wcmd, uint32_t *addr)
{
    uint32_t off = 0;
    if (strncmp(s, "bram5", 5) == 0 || strncmp(s, "bram7", 5) == 0) {
        if (s[5] == ':' ? !parse_u32(s + 6, &off) : s[5] != 0)
            return 0;
        if (off > 0x7FFF)
            return 0;
        *wcmd = CMD_BRAM_W;
        *addr = off | (s[4] == '7' ? BRAM7_FLAG : 0);
        return 1;
    }
    *wcmd = CMD_SRAM_W;
    return parse_u32(s, addr);
}

typedef struct {
    const char *pos[8];
    int npos;
    int sim;
    long loss_tx, loss_at;
    const char *dev;
    uint32_t hb, passes, seed;
    int has_hb, has_passes, has_seed;
} args_t;

static int parse_args(int argc, char **argv, args_t *a)
{
    int i;
    memset(a, 0, sizeof *a);
    a->dev = "/dev/spidev0.0";
    a->loss_tx = a->loss_at = -1;
    a->passes = 1;
    for (i = 1; i < argc; i++) {
        const char *s = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (strcmp(s, "--sim") == 0) {
            a->sim = 1;
        } else if (strcmp(s, "--dev") == 0 && v) {
            a->dev = v;
            i++;
        } else if (strcmp(s, "--sim-loss") == 0 && v) {
            uint32_t tx, at;
            char buf[32], *c;
            if (strlen(v) >= sizeof buf)
                return 0;
            strcpy(buf, v);
            c = strchr(buf, ':');
            if (!c)
                return 0;
            *c = 0;
            if (!parse_u32(buf, &tx) || !parse_u32(c + 1, &at))
                return 0;
            a->loss_tx = (long)tx;
            a->loss_at = (long)at;
            i++;
        } else if (strcmp(s, "--hb") == 0 && v) {
            if (!parse_u32(v, &a->hb))
                return 0;
            a->has_hb = 1;
            i++;
        } else if (strcmp(s, "--passes") == 0 && v) {
            if (!parse_u32(v, &a->passes) || a->passes == 0)
                return 0;
            a->has_passes = 1;
            i++;
        } else if (strcmp(s, "--seed") == 0 && v) {
            if (!parse_u32(v, &a->seed))
                return 0;
            a->has_seed = 1;
            i++;
        } else if (s[0] == '-' && s[1] == '-') {
            return 0;
        } else if (a->npos < 8) {
            a->pos[a->npos++] = s;
        } else {
            return 0;
        }
    }
    return a->npos >= 1;
}

static int want_pos(const args_t *a, int n)
{
    return a->npos == n + 1;
}

static FILE *err_out;                   /* stderr under serve: its stdout is the pipe */

static int fail(int code, int err, long arg)
{
    err_row(err_out, code, err, arg);
    fflush(err_out);
    return 2;
}

static devcfg_t cfg;                    /* spidev settings saved at open (static: atexit) */
static sim303_t sim;

static int body(int argc, char **argv)
{
    args_t a;
    link303_t l;
    const char *sub;
    uint32_t v[5] = {0, 0, 0, 0, 0};
    int rc = 0, i;
    if (!parse_args(argc, argv, &a)) {
        fputs(USAGE, stderr);
        return fail(E_ARG, 0, 0);
    }
    sub = a.pos[0];
    memset(&l, 0, sizeof l);
    l.now_ns = host_now;
    l.last_state = -1;
    memset(&sim, 0, sizeof sim);
    if (a.has_hb) {
        if (a.hb >= SRAM_SIZE || SRAM_SIZE - a.hb < MB_LEN || a.hb == 0)
            return fail(E_RANGE, 0, (long)a.hb);
        l.hb_mbox = a.hb;
    }
    if (strcmp(sub, "smoke") == 0) {
        if (a.sim || !want_pos(&a, 0))
            return fail(E_ARG, 0, 0);
#ifdef __linux__
        install_signals();
        if (spi_open(a.dev, &cfg) < 0)
            return fail(E_IO, errno, 0);
        return do_smoke();
#else
        return fail(E_IO, 0, 0);
#endif
    }
    if (a.sim) {
        if (sim_init(&sim))
            return fail(E_MEM, 0, 0);
        sim.loss_tx = a.loss_tx;
        sim.loss_at = a.loss_at;
        l.xfer = sim_xfer;
        l.ctx = &sim;
        cfg.rd = sim_dev_rd;            /* fake spidev settings exercise the exit paths */
        cfg.wr = sim_dev_wr;
        cfg.ctx = &sim;
        if (devcfg_open(&cfg))
            return fail(E_IO, 0, 0);
    } else {
#ifdef __linux__
        install_signals();
        if (spi_open(a.dev, &cfg) < 0)
            return fail(E_IO, errno, 0);
        l.xfer = spi_xfer;
#else
        return fail(E_IO, 0, 0);
#endif
    }
    if (strcmp(sub, "serve") == 0) {
        srv_io_t io;
        if (!want_pos(&a, 0) || a.has_hb)
            return fail(E_ARG, 0, 0);
        io.read = std_read;
        io.write = std_write;
        io.ctx = NULL;
        rc = serve_loop(&l, &io);
        if (rc)
            fputs("spi303 serve: request stream out of step\n", stderr);
        sim_free(&sim);
        return rc;
    }
    if ((a.has_seed && strcmp(sub, "read") != 0) ||
        (a.has_passes && strcmp(sub, "write") != 0 && strcmp(sub, "read") != 0))
        return fail(E_ARG, 0, 0);
    setvbuf(stdout, NULL, _IOLBF, 4096);
    for (i = 1; i < a.npos && i <= 5; i++)
        if (!parse_u32(a.pos[i], &v[i - 1]) &&
            !(strcmp(sub, "stream") == 0 && (i == 1 || i == 4)))
            return fail(E_ARG, 0, i);
    if (strcmp(sub, "write") == 0 && want_pos(&a, 5)) {
        rc = run_write(&l, stdout, "C3WP", CMD_SRAM_W, v[0], v[1], v[2], v[3], v[4], a.passes);
    } else if (strcmp(sub, "read") == 0 && want_pos(&a, 4)) {
        rc = run_read(&l, stdout, CMD_SRAM_R, v[0], v[1], v[2], v[3], a.has_seed, a.seed,
                      a.passes);
    } else if (strcmp(sub, "bram") == 0 && want_pos(&a, 4) && !a.has_passes) {
        /* bank 5 holds the screen and sysvars: only stream bram5:OFF (the R5 region) writes it */
        if (v[0] != 7)
            return fail(E_RANGE, 0, (long)v[0]);
        if (v[2] == 0)
            return fail(E_ARG, 0, 3);
        rc = run_write(&l, stdout, "C3BP", CMD_BRAM_W, BRAM7_FLAG, BRAM7_SIZE, v[1], MAX_CHUNK,
                       v[3], v[2]);
    } else if (strcmp(sub, "selftest") == 0 && want_pos(&a, 1)) {
        rc = run_selftest(&l, stdout, v[0]);
    } else if (strcmp(sub, "stream") == 0 && want_pos(&a, 4) && a.has_hb) {
#ifdef __linux__
        uint8_t wcmd, *buf;
        uint32_t addr;
        FILE *f;
        if (!parse_target(a.pos[1], &wcmd, &addr))
            return fail(E_ARG, 0, 1);
        buf = malloc(v[1] ? v[1] : 1);
        f = fopen(a.pos[4], "rb");
        if (!buf || !f || fread(buf, 1, v[1], f) != v[1])
            return fail(E_IO, errno, 4);
        fclose(f);
        rc = run_stream(&l, stdout, wcmd, addr, buf, v[1], v[2], stdin_closed, NULL);
        free(buf);
#else
        (void)parse_target;
        return fail(E_IO, 0, 0);
#endif
    } else {
        fputs(USAGE, stderr);
        return fail(E_ARG, 0, 0);
    }
    sim_free(&sim);
    if (rc < 0)
        return fail(rc, 0, 0);
    fflush(stdout);
    return rc;
}

/* Single exit: restore the spidev settings once, log C3MX on the row channel. */
static void finish(void)
{
    char row[160];
    if (!cfg.have || cfg.done)
        return;
#ifdef __linux__
    {
        sigset_t s;
        sigfillset(&s);
        sigprocmask(SIG_BLOCK, &s, NULL);
    }
#endif
    devcfg_restore(&cfg);
    devcfg_row(&cfg, row, sizeof row);
    fputs(row, err_out);
    fflush(err_out);
}

int main(int argc, char **argv)
{
    int rc, i;
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    err_out = stdout;
    for (i = 1; i < argc; i++)
        if (strcmp(argv[i], "serve") == 0)
            err_out = stderr;
#ifdef __linux__
    err_fd = err_out == stderr ? 2 : 1;
#endif
    devcfg_active = &cfg;
    atexit(finish);
    rc = body(argc, argv);
    finish();
    return rc;
}
