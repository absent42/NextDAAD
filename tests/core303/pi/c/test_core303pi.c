/* Host unit tests for core303pi.c. --dump <seed> <n> prints pat_fill as hex;
   --hdr <cmd> <addr> <len> [...] prints build_cmd headers, one hex line each. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core303pi.h"

static int fails, checks;
#define CHECK(c) do { checks++; if (!(c)) { fails++; \
    printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); } } while (0)

#define MB 0x1F0000u
#define FAST 8000000u
#define ROWS_TMP "core303pi_test_rows.tmp"

/* Spy backend: records every message, then hands it to the sim. */
typedef struct {
    uint8_t cmd; uint32_t addr; uint32_t len; uint32_t hdr_hz, pay_hz;
    uint8_t cs0, cs1; int n; uint64_t t; uint8_t rx0;
} msg_t;

typedef struct { sim303_t *sim; msg_t log[4096]; int nlog; } spy_t;

static int spy_xfer(void *ctx, struct xfer_desc *d, int n)
{
    spy_t *s = ctx;
    msg_t m;
    int rc;
    memset(&m, 0, sizeof m);
    m.cmd = d[0].tx[0];
    m.n = n;
    m.hdr_hz = d[0].speed_hz;
    m.cs0 = d[0].cs_change;
    if (m.cmd == CMD_SRAM_R || m.cmd == CMD_SRAM_W)
        m.addr = ((uint32_t)d[0].tx[1] << 16) | ((uint32_t)d[0].tx[2] << 8) | d[0].tx[3];
    else if (m.cmd == CMD_BRAM_R || m.cmd == CMD_BRAM_W)
        m.addr = ((uint32_t)d[0].tx[1] << 8) | d[0].tx[2];
    if (n > 1) {
        m.len = d[1].len;
        m.pay_hz = d[1].speed_hz;
        m.cs1 = d[1].cs_change;
    }
    m.t = s->sim->t_ns;
    rc = sim_xfer(s->sim, d, n);
    if (n > 1 && d[1].rx)
        m.rx0 = d[1].rx[0];
    if (s->nlog < 4096)
        s->log[s->nlog++] = m;
    return rc;
}

static void link_sim(link303_t *l, sim303_t *s)
{
    memset(l, 0, sizeof *l);
    l->xfer = sim_xfer;
    l->now_ns = sim_now;
    l->ctx = s;
    l->last_state = -1;
}

static void link_spy(link303_t *l, spy_t *sp)
{
    link_sim(l, sp->sim);
    l->xfer = spy_xfer;
    l->ctx = sp;
}

static uint64_t spy_now(void *ctx)
{
    return ((spy_t *)ctx)->sim->t_ns;
}

static void prep_mailbox(sim303_t *s, uint8_t state)
{
    memset(s->sram + MB, 0, 32);
    memcpy(s->sram + MB, "M303", 4);
    s->sram[MB + MB_STATE] = state;
}

static FILE *rows_open(void)
{
    return fopen(ROWS_TMP, "w+b");
}

static char *rows_take(FILE *f)
{
    static char buf[65536];
    size_t n;
    fflush(f);
    rewind(f);
    n = fread(buf, 1, sizeof buf - 1, f);
    buf[n] = 0;
    fclose(f);
    remove(ROWS_TMP);
    return buf;
}

static void test_pattern(void)
{
    static const uint8_t want[8] = {231, 7, 67, 69, 255, 148, 186, 87};
    uint8_t a[64], b[64];
    pat_fill(7, a, 8);
    CHECK(memcmp(a, want, 8) == 0);
    pat_fill(0, a, 64);
    pat_fill(1, b, 64);
    CHECK(memcmp(a, b, 64) == 0);
    pat_fill(12345, a, 64);
    pat_fill(12345, b, 64);
    CHECK(memcmp(a, b, 64) == 0);
}

static void lose(const uint8_t *want, uint8_t *got, size_t n, size_t at, size_t k, uint8_t stale)
{
    size_t i;
    memcpy(got, want, at);
    for (i = at; i + k < n; i++)
        got[i] = want[i + k];
    for (; i < n; i++)
        got[i] = stale;
}

static void test_cmp(void)
{
    static uint8_t want[4000], got[4000];
    cmp_t c;
    pat_fill(3, want, 4000);
    memcpy(got, want, 4000);
    c = cmp_tx(want, got, 4000);
    CHECK(c.mismatches == 0 && c.first == -1 && c.shift == 0);

    got[500] ^= 0xFF;
    c = cmp_tx(want, got, 4000);
    CHECK(c.mismatches == 1 && c.first == 500 && c.shift == 0);

    lose(want, got, 4000, 100, 1, 0);
    c = cmp_tx(want, got, 4000);
    CHECK(c.first == 100 && c.shift == 1 && c.mismatches > 3000);

    lose(want, got, 4000, 100, 3, 0);
    c = cmp_tx(want, got, 4000);
    CHECK(c.first == 100 && c.shift == 3);

    lose(want, got, 4000, 100, 9, 0);   /* beyond 8: no shift claimed */
    c = cmp_tx(want, got, 4000);
    CHECK(c.first == 100 && c.shift == 0);

    memcpy(got, want, 4000);
    got[3999] ^= 1;                     /* nothing left to test a shift on */
    c = cmp_tx(want, got, 4000);
    CHECK(c.mismatches == 1 && c.first == 3999 && c.shift == 0);
}

static void test_shift_stops_k_short(void)
{
    static uint8_t want[4000], got[4000];
    size_t i;
    cmp_t c;
    pat_fill(11, want, 4000);
    lose(want, got, 4000, 100, 3, 0);
    for (i = 3997; i < 4000; i++)
        got[i] = (uint8_t)(want[i] ^ 0x5A);     /* the never-written tail */
    c = cmp_tx(want, got, 4000);
    CHECK(c.shift == 3 && c.first == 100);
    CHECK(got[3999] != want[3999]);
}

static void test_spans(void)
{
    uint8_t prev[64], cur[64];
    uint32_t st[16], ln[16];
    static const uint32_t es[6] = {2, 10, 30, 40, 45, 63};
    static const uint32_t el[6] = {3, 7, 1, 1, 1, 1};
    size_t n, i;
    memset(prev, 0, 64);
    memcpy(cur, prev, 64);
    CHECK(spans(prev, cur, 64, st, ln, 16) == 0);
    cur[2] = cur[4] = 1;                        /* gap 1: merged */
    cur[10] = cur[11] = cur[12] = cur[16] = 1;  /* gap 3: merged */
    cur[30] = 1;
    cur[40] = cur[45] = 1;                      /* gap 4: split */
    cur[63] = 1;
    n = spans(prev, cur, 64, st, ln, 16);
    CHECK(n == 6);
    for (i = 0; i < 6 && i < n; i++)
        CHECK(st[i] == es[i] && ln[i] == el[i]);
    memset(st, 0xEE, sizeof st);
    CHECK(spans(prev, cur, 64, st, ln, 2) == 6);
    CHECK(st[0] == 2 && st[1] == 10 && st[2] == 0xEEEEEEEEu);
    memset(cur, 9, 64);
    n = spans(prev, cur, 64, st, ln, 16);
    CHECK(n == 1 && st[0] == 0 && ln[0] == 64);
}

static void test_pass_seeds_differ(void)
{
    static uint8_t a[4000], b[4000];
    sim303_t s;
    link303_t l;
    FILE *f;
    char *rows;
    pat_fill(100, a, 4000);
    pat_fill(101, b, 4000);
    CHECK(a[3999] != b[3999]);
    CHECK(sim_init(&s) == 0);
    link_sim(&l, &s);
    f = rows_open();
    CHECK(run_write(&l, f, "C3WP", CMD_SRAM_W, 0x1000, 4000, FAST, 4000, 100, 2) == 0);
    rows = rows_take(f);
    CHECK(memcmp(s.sram + 0x1000, b, 4000) == 0);   /* the last pass used seed0 + 1 */
    CHECK(strstr(rows, "C3WP pass=0 seed=100 ") != NULL);
    CHECK(strstr(rows, "C3WP pass=1 seed=101 ") != NULL);
    CHECK(strstr(rows, "C3EN passes=2 stop=0 state=-1\n") != NULL);
    sim_free(&s);
}

static void test_build_cmd(void)
{
    uint8_t h[16];
    static const uint8_t sr[] = {0xA7, 0x1F, 0x23, 0x45, 1, 2, 0};
    static const uint8_t sw[] = {0xA8, 0x01, 0x23, 0x45, 1, 2};
    static const uint8_t br[] = {0xA9, 0x80, 0x10, 0, 3, 0};
    static const uint8_t bw[] = {0xAA, 0x00, 0x10, 0, 3};
    static const uint8_t nr[] = {0xAB, 0x1E, 0};
    static const uint8_t nw[] = {0xAC, 0x1E, 0x55, 0};
    static const uint8_t ve[] = {0xA1, 0};
    CHECK(build_cmd(CMD_SRAM_R, 0x1F2345, 0x0102, h) == 7 && !memcmp(h, sr, 7));
    CHECK(build_cmd(CMD_SRAM_W, 0x012345, 0x0102, h) == 6 && !memcmp(h, sw, 6));
    CHECK(build_cmd(CMD_BRAM_R, 0x8010, 3, h) == 6 && !memcmp(h, br, 6));
    CHECK(build_cmd(CMD_BRAM_W, 0x0010, 3, h) == 5 && !memcmp(h, bw, 5));
    CHECK(build_cmd(CMD_NR_R, 0x1E, 1, h) == 3 && !memcmp(h, nr, 3));
    CHECK(build_cmd(CMD_NR_W, 0x1E, 0x55, h) == 4 && !memcmp(h, nw, 4));
    CHECK(build_cmd(CMD_VERSION, 0, 2, h) == 2 && !memcmp(h, ve, 2));
    CHECK(build_cmd(0xA3, 0, 1, h) == 0);       /* CMD_SYSTEM is never built */
    CHECK(build_cmd(0x00, 0, 1, h) == 0);
}

static void test_range(void)
{
    CHECK(range_ok(CMD_SRAM_W, 0x1FFFFF, 1));
    CHECK(!range_ok(CMD_SRAM_W, 0x1FFFFF, 2));
    CHECK(!range_ok(CMD_SRAM_R, 0x200000, 1));
    CHECK(!range_ok(CMD_SRAM_W, 0, 0));
    CHECK(range_ok(CMD_BRAM_W, 0x3FFF, 1));
    CHECK(!range_ok(CMD_BRAM_W, 0x3FFF, 2));
    CHECK(!range_ok(CMD_BRAM_R, 0x4000, 1));
    CHECK(range_ok(CMD_BRAM_R, BRAM7_FLAG | 0x1FFF, 1));
    CHECK(!range_ok(CMD_BRAM_W, BRAM7_FLAG | 0x1FFF, 2));
    CHECK(!range_ok(CMD_BRAM_W, BRAM7_FLAG | 0x2000, 1));
    CHECK(!range_ok(CMD_BRAM_W, 0x10000, 1));
    CHECK(!range_ok(0xA3, 0, 1));
}

static void test_header_split(void)
{
    uint8_t hdr[8], pay[4000];
    struct xfer_desc d[2];
    sim303_t s;
    spy_t *sp;
    link303_t l;
    int i;
    size_t hl = build_cmd(CMD_SRAM_W, 0x1000, 4000, hdr);
    memset(pay, 0x5A, sizeof pay);
    plan_xfers(hdr, hl, pay, 4000, FAST, d);
    CHECK(d[0].tx == hdr && d[0].len == 6 && d[0].speed_hz == 2000000u);
    CHECK(d[0].cs_change == 0 && d[0].bits_per_word == 8 && d[0].rx == NULL);
    CHECK(d[1].tx == pay && d[1].len == 4000 && d[1].speed_hz == FAST);
    CHECK(d[1].cs_change == 0 && d[1].bits_per_word == 8);

    CHECK(sim_init(&s) == 0);
    sp = calloc(1, sizeof *sp);
    sp->sim = &s;
    link_spy(&l, sp);
    CHECK(lk_cmd(&l, CMD_SRAM_W, 0x2000, pay, NULL, 4000, 12000000u) == 0);
    CHECK(lk_cmd(&l, CMD_SRAM_R, 0x2000, NULL, pay, 4000, 12000000u) == 0);
    CHECK(lk_cmd(&l, 0xA3, 0, pay, NULL, 1, HDR_HZ) == E_ARG);
    CHECK(lk_cmd(&l, CMD_SRAM_W, 0x1FFFFF, pay, NULL, 2, HDR_HZ) == E_RANGE);
    CHECK(sp->nlog == 2);
    for (i = 0; i < sp->nlog; i++)
        CHECK(sp->log[i].n == 2 && sp->log[i].hdr_hz == 2000000u &&
              sp->log[i].pay_hz == 12000000u && !sp->log[i].cs0 && !sp->log[i].cs1);
    CHECK(s.faults == 0);
    free(sp);
    sim_free(&s);
}

/* Serve pipe over memory buffers. */
typedef struct { const uint8_t *in; size_t inlen, inpos; uint8_t out[65536]; size_t outlen; } mio_t;

static int mio_read(void *ctx, uint8_t *b, size_t n)
{
    mio_t *m = ctx;
    size_t k = m->inlen - m->inpos;
    if (k > n)
        k = n;
    memcpy(b, m->in + m->inpos, k);
    m->inpos += k;
    return (int)k;
}

static int mio_write(void *ctx, const uint8_t *b, size_t n)
{
    mio_t *m = ctx;
    if (m->outlen + n > sizeof m->out)
        return -1;
    memcpy(m->out + m->outlen, b, n);
    m->outlen += n;
    return 0;
}

static size_t req(uint8_t *p, uint8_t op, uint8_t cmd, uint32_t addr, uint16_t len, uint32_t hz)
{
    p[0] = op;
    p[1] = cmd;
    put_le(p + 2, addr, 3);
    put_le(p + 5, len, 2);
    put_le(p + 7, hz, 4);
    return SRV_HEAD;
}

static void test_serve_framing(void)
{
    static uint8_t in[40000], data[9000];
    sim303_t s;
    link303_t l;
    mio_t *m = calloc(1, sizeof *m);
    srv_io_t io;
    srv_req_t r;
    uint8_t h[3];
    size_t p = 0, o = 0;

    p += req(in, OP_WRITE, CMD_SRAM_W, 0x123456, 0x0BB8, FAST);
    srv_parse_head(in, &r);
    CHECK(r.op == 1 && r.cmd == 0xA8 && r.addr == 0x123456 && r.len == 3000 && r.hz == FAST);
    srv_reply_head(h, 2, 0x0102);
    CHECK(h[0] == 2 && h[1] == 0x02 && h[2] == 0x01);
    p = 0;

    pat_fill(4, data, 9000);
    p += req(in + p, OP_WRITE, CMD_SRAM_W, 0x4000, 3000, FAST);
    memcpy(in + p, data, 3000);
    p += 3000;
    p += req(in + p, OP_READ, CMD_SRAM_R, 0x4000, 3000, FAST);
    p += req(in + p, OP_PUSH, CMD_SRAM_W, 0x10000, 4000, FAST);
    put_le(in + p, 9000, 4);
    in[p + 4] = SRV_FLAG_VERIFY;
    put_le(in + p + 5, 0, 4);
    p += SRV_PUSH_EXT;
    memcpy(in + p, data, 9000);
    p += 9000;
    p += req(in + p, OP_PUSHSPANS, CMD_SRAM_W, 0x20000, 2, FAST);
    in[p] = 0;
    put_le(in + p + 1, 0, 4);
    p += SRV_SPANS_EXT;
    put_le(in + p, 0x10, 3);
    put_le(in + p + 3, 5, 2);
    put_le(in + p + 5, 0x2000, 3);
    put_le(in + p + 8, 4500, 2);
    p += 10;
    memcpy(in + p, data, 4505);
    p += 4505;
    p += req(in + p, OP_WRITE, CMD_SRAM_W, 0x1FFFFF, 2, FAST);  /* out of range */
    in[p++] = 1;
    in[p++] = 2;
    p += req(in + p, OP_WRITE, CMD_NR_W, 0x7F, 1, FAST);        /* not a memory command */
    in[p++] = 0x55;
    p += req(in + p, OP_READ, CMD_BRAM_R, BRAM7_FLAG | 0x10, 4, FAST);

    CHECK(sim_init(&s) == 0);
    memcpy(s.bram7 + 0x10, "abcd", 4);
    link_sim(&l, &s);
    m->in = in;
    m->inlen = p;
    io.read = mio_read;
    io.write = mio_write;
    io.ctx = m;
    CHECK(serve_loop(&l, &io) == 0);

    CHECK(memcmp(m->out + o, "\0\0\0", 3) == 0);
    o += 3;
    CHECK(m->out[o] == 0 && get_le(m->out + o + 1, 2) == 3000);
    CHECK(memcmp(m->out + o + 3, data, 3000) == 0);
    o += 3 + 3000;
    CHECK(m->out[o] == 0 && get_le(m->out + o + 1, 2) == SRV_PUSH_REPLY);
    CHECK(get_le(m->out + o + 3, 4) == 3 && get_le(m->out + o + 7, 4) == 0);
    o += 3 + SRV_PUSH_REPLY;
    CHECK(m->out[o] == 0 && get_le(m->out + o + 1, 2) == SRV_PUSH_REPLY);
    CHECK(get_le(m->out + o + 3, 4) == 3 && get_le(m->out + o + 7, 4) == 0);
    o += 3 + SRV_PUSH_REPLY;
    CHECK(m->out[o] == ST_BADREQ && get_le(m->out + o + 1, 2) == 0);
    o += 3;
    CHECK(m->out[o] == ST_BADREQ && get_le(m->out + o + 1, 2) == 0);
    o += 3;
    CHECK(m->out[o] == 0 && get_le(m->out + o + 1, 2) == 4 && !memcmp(m->out + o + 3, "abcd", 4));
    o += 7;
    CHECK(o == m->outlen);
    CHECK(memcmp(s.sram + 0x4000, data, 3000) == 0);
    CHECK(memcmp(s.sram + 0x10000, data, 9000) == 0);
    CHECK(memcmp(s.sram + 0x20010, data, 5) == 0);
    CHECK(memcmp(s.sram + 0x22000, data + 5, 4500) == 0);
    CHECK(s.sram[0x1FFFFF] == 0 && s.faults == 0);

    /* unknown op: status 1, then the loop gives up (pipe out of step) */
    memset(m, 0, sizeof *m);
    p = req(in, 9, CMD_SRAM_W, 0, 1, FAST);
    m->in = in;
    m->inlen = p;
    CHECK(serve_loop(&l, &io) == 3);
    CHECK(m->outlen == 3 && m->out[0] == ST_BADREQ);
    /* truncated payload */
    memset(m, 0, sizeof *m);
    p = req(in, OP_WRITE, CMD_SRAM_W, 0, 100, FAST);
    m->in = in;
    m->inlen = p + 10;
    CHECK(serve_loop(&l, &io) == 3);
    CHECK(m->outlen == 0);
    free(m);
    sim_free(&s);
}

static void test_write_detects_loss(void)
{
    sim303_t s;
    link303_t l;
    FILE *f;
    char *rows;
    CHECK(sim_init(&s) == 0);
    s.loss_tx = 1;
    s.loss_at = 100;
    link_sim(&l, &s);
    f = rows_open();
    CHECK(run_write(&l, f, "C3WP", CMD_SRAM_W, 0x1000, 9000, FAST, 4000, 5, 1) == 0);
    rows = rows_take(f);
    CHECK(strstr(rows, "C3WP pass=0 seed=5 hz=8000000 base=4096 bytes=9000 chunk=4000 ntx=3 ns=")
          != NULL);
    CHECK(strstr(rows, " bad_tx=1 first_tx=1 first=100 shift=1\n") != NULL);
    CHECK(strstr(rows, "C3TX pass=0 tx=1 mis=") != NULL);
    CHECK(strstr(rows, " first=100 shift=1\n") != NULL);
    sim_free(&s);

    /* bank 7: same detection through BRAM */
    CHECK(sim_init(&s) == 0);
    s.loss_tx = 2;
    s.loss_at = 7;
    link_sim(&l, &s);
    f = rows_open();
    CHECK(run_write(&l, f, "C3BP", CMD_BRAM_W, BRAM7_FLAG, BRAM7_SIZE, FAST, MAX_CHUNK, 9, 1) == 0);
    rows = rows_take(f);
    CHECK(strstr(rows, "C3BP pass=0 seed=9 hz=8000000 base=32768 bytes=8192 chunk=4000 ntx=3 ")
          != NULL);
    CHECK(strstr(rows, " bad_tx=1 first_tx=2 first=7 shift=1\n") != NULL);
    sim_free(&s);
}

static void test_read_pass(void)
{
    sim303_t s;
    link303_t l;
    FILE *f;
    char *rows;
    CHECK(sim_init(&s) == 0);
    pat_fill(21, s.sram + 0x8000, 8000);
    link_sim(&l, &s);
    f = rows_open();
    CHECK(run_read(&l, f, CMD_SRAM_R, 0x8000, 8000, FAST, 4000, 1, 21, 1) == 0);
    CHECK(run_read(&l, f, CMD_SRAM_R, 0x8000, 8000, FAST, 4000, 0, 0, 1) == 0);
    CHECK(run_read(&l, f, CMD_SRAM_R, 0x8000, 8000, FAST, 4000, 1, 22, 1) == 0);
    rows = rows_take(f);
    CHECK(strstr(rows, "C3RP pass=0 hz=8000000 base=32768 bytes=8000 chunk=4000 ntx=2 ns=") != NULL);
    CHECK(strstr(rows, " mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 ref=1\n") != NULL);
    CHECK(strstr(rows, " mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 ref=0\n") != NULL);
    CHECK(strstr(rows, " bad_tx=2 first_tx=0 first=0 ") != NULL);
    sim_free(&s);
}

static void test_hb_every_100ms(void)
{
    sim303_t s;
    spy_t *sp = calloc(1, sizeof *sp);
    link303_t l;
    FILE *f;
    char *rows;
    int i, nhb = 0;
    uint64_t last = 0;
    CHECK(sim_init(&s) == 0);
    s.step_ns = 10000000ull;
    prep_mailbox(&s, MB_READY);
    sp->sim = &s;
    link_spy(&l, sp);
    l.now_ns = spy_now;
    l.hb_mbox = MB;
    f = rows_open();
    CHECK(run_write(&l, f, "C3WP", CMD_SRAM_W, 0x1000, 40000, FAST, 4000, 1, 4) == 0);
    rows = rows_take(f);
    for (i = 0; i < sp->nlog; i++) {
        msg_t *m = &sp->log[i];
        if (m->cmd == CMD_SRAM_W && m->addr >= MB && m->addr < MB + 32) {
            CHECK(m->addr == MB + MB_HB_PI && m->len == 2 && m->pay_hz == HDR_HZ);
            if (nhb)
                CHECK(m->t - last >= HB_PERIOD_NS && m->t - last <= 130000000ull);
            last = m->t;
            nhb++;
        }
        if (m->cmd == CMD_SRAM_R && m->addr >= MB && m->addr < MB + 32)
            CHECK(m->pay_hz == HDR_HZ);
    }
    CHECK(nhb > 10 && (uint32_t)nhb == l.hb_bumps);
    CHECK(get_le(s.sram + MB + MB_HB_PI, 2) == (uint32_t)nhb);
    CHECK(sp->log[0].cmd == CMD_SRAM_R && sp->log[0].addr == MB + MB_HB_PI);
    CHECK(strstr(rows, "C3EN passes=4 stop=0 state=1\n") != NULL);
    CHECK(strstr(rows, "C3HB bumps=") != NULL);
    free(sp);
    sim_free(&s);
}

static void test_state_stops_passes(void)
{
    sim303_t s;
    spy_t *sp = calloc(1, sizeof *sp);
    link303_t l;
    FILE *f;
    char *rows;
    int i, seen = -1, later_w = 0;
    CHECK(sim_init(&s) == 0);
    prep_mailbox(&s, MB_READY);
    s.state_after = 20;
    s.state_mbox = MB;
    sp->sim = &s;
    link_spy(&l, sp);
    l.hb_mbox = MB;
    f = rows_open();
    CHECK(run_write(&l, f, "C3WP", CMD_SRAM_W, 0x1000, 8000, FAST, 4000, 1, 50) == 0);
    rows = rows_take(f);
    for (i = 0; i < sp->nlog; i++) {
        msg_t *m = &sp->log[i];
        if (seen < 0 && m->cmd == CMD_SRAM_R && m->addr == MB + MB_STATE && m->rx0 != 1)
            seen = i;
        else if (seen >= 0 && m->cmd == CMD_SRAM_W)
            later_w++;
    }
    CHECK(seen > 0 && later_w == 0);
    CHECK(strstr(rows, " stop=1 state=3\n") != NULL);
    CHECK(strstr(rows, "C3EN passes=50 ") == NULL);
    free(sp);
    sim_free(&s);
}

static int stop_after(void *ctx)
{
    int *k = ctx;
    return --*k < 0;
}

static void test_stream(void)
{
    static uint8_t src[8192];
    sim303_t s;
    link303_t l;
    FILE *f;
    char *rows;
    int k = 7;
    CHECK(sim_init(&s) == 0);
    prep_mailbox(&s, MB_READY);
    pat_fill(77, src, sizeof src);
    link_sim(&l, &s);
    l.hb_mbox = MB;
    f = rows_open();
    CHECK(run_stream(&l, f, CMD_BRAM_W, BRAM7_FLAG, src, BRAM7_SIZE, FAST, stop_after, &k) == 0);
    rows = rows_take(f);
    CHECK(memcmp(s.bram7, src, BRAM7_SIZE) == 0);
    CHECK(strstr(rows, "C3SM base=32768 bytes=8192 hz=8000000 passes=2 ntx=7 ns=") != NULL);
    CHECK(strstr(rows, " stop=0 state=1\n") != NULL);
    sim_free(&s);

    CHECK(sim_init(&s) == 0);
    prep_mailbox(&s, MB_READY);
    s.state_after = 30;
    s.state_mbox = MB;
    link_sim(&l, &s);
    l.hb_mbox = MB;
    k = 1 << 30;
    f = rows_open();
    CHECK(run_stream(&l, f, CMD_SRAM_W, 0x40000, src, 8192, FAST, stop_after, &k) == 0);
    rows = rows_take(f);
    CHECK(strstr(rows, " stop=1 state=3\n") != NULL);
    sim_free(&s);
}

static void test_push_verify(void)
{
    static uint8_t data[49152], table[10];
    sim303_t s;
    link303_t l;
    uint32_t ntx, bad;
    uint64_t ns;
    pat_fill(8, data, sizeof data);
    CHECK(sim_init(&s) == 0);
    s.loss_tx = 4;
    s.loss_at = 2000;
    link_sim(&l, &s);
    CHECK(run_push(&l, CMD_SRAM_W, 0x60000, data, 49152, FAST, 4000, 0, &ntx, &bad, &ns) == 0);
    CHECK(ntx == 13 && bad == 0);           /* timed pass: no read-back */
    CHECK(run_push(&l, CMD_SRAM_W, 0x60000, data, 49152, FAST, 4000, 1, &ntx, &bad, &ns) == 0);
    CHECK(ntx == 13 && bad == 0);
    s.loss_tx = (long)s.wtx + 5;
    CHECK(run_push(&l, CMD_SRAM_W, 0x60000, data, 49152, FAST, 4000, 1, &ntx, &bad, &ns) == 0);
    CHECK(ntx == 13 && bad == 1);
    CHECK(run_push(&l, CMD_SRAM_W, 0x1FC000, data, 49152, FAST, 4000, 1, &ntx, &bad, &ns)
          == E_RANGE);
    CHECK(run_push(&l, CMD_SRAM_W, 0x60000, data, 100, FAST, 4001, 0, &ntx, &bad, &ns) == E_ARG);

    put_le(table, 0, 3);
    put_le(table + 3, 9000, 2);             /* one span, three transactions */
    put_le(table + 5, 20000, 3);
    put_le(table + 8, 1, 2);
    s.loss_tx = (long)s.wtx + 3;            /* the 1-byte span: a loss leaves it stale */
    s.loss_at = 0;
    CHECK(run_spans(&l, CMD_SRAM_W, 0x80000, 2, table, data, FAST, 1, &ntx, &bad, &ns) == 0);
    CHECK(ntx == 4 && bad == 1);
    CHECK(memcmp(s.sram + 0x80000, data, 9000) == 0);
    put_le(table, 0x1F0000, 3);
    CHECK(run_spans(&l, CMD_SRAM_W, 0x80000, 1, table, data, FAST, 0, &ntx, &bad, &ns) == E_RANGE);
    sim_free(&s);
}

static void test_selftest(void)
{
    sim303_t s;
    link303_t l;
    FILE *f;
    char *rows;
    CHECK(sim_init(&s) == 0);
    link_sim(&l, &s);
    f = rows_open();
    CHECK(run_selftest(&l, f, 0x30000) == 0);
    s.loss_tx = (long)s.wtx;
    s.loss_at = 10;
    CHECK(run_selftest(&l, f, 0x30000) == 1);
    rows = rows_take(f);
    CHECK(strstr(rows, "C3ST ok=1 base=196608 mis=0 first=-1\n") != NULL);
    CHECK(strstr(rows, "C3ST ok=0 base=196608 mis=") != NULL);
    CHECK(s.faults == 0);
    sim_free(&s);
}

static void test_sim_rejects_fast_header(void)
{
    sim303_t s;
    uint8_t hdr[8], pay[4] = {1, 2, 3, 4};
    struct xfer_desc d[2];
    size_t hl = build_cmd(CMD_SRAM_W, 0x100, 4, hdr);
    CHECK(sim_init(&s) == 0);
    plan_xfers(hdr, hl, pay, 4, FAST, d);
    d[0].speed_hz = FAST;
    CHECK(sim_xfer(&s, d, 2) != 0 && s.faults == 1);
    plan_xfers(hdr, hl, pay, 4, FAST, d);
    d[0].cs_change = 1;
    CHECK(sim_xfer(&s, d, 2) != 0 && s.faults == 2);
    CHECK(s.sram[0x100] == 0);
    sim_free(&s);
}

static void test_rate_and_chunk_bounds(void)
{
    static uint8_t in[16384], buf[4096];
    sim303_t s;
    link303_t l;
    mio_t *m = calloc(1, sizeof *m);
    srv_io_t io;
    FILE *f;
    size_t p = 0;
    CHECK(sim_init(&s) == 0);
    link_sim(&l, &s);
    CHECK(lk_cmd(&l, CMD_SRAM_W, 0x1000, buf, NULL, 4, MAX_HZ + 1) == E_ARG);
    CHECK(lk_cmd(&l, CMD_SRAM_W, 0x1000, buf, NULL, MAX_CHUNK + 1, HDR_HZ) == E_ARG);
    CHECK(lk_cmd(&l, CMD_SRAM_R, 0x1000, NULL, buf, MAX_CHUNK + 1, HDR_HZ) == E_ARG);
    CHECK(s.msgs == 0);
    CHECK(lk_cmd(&l, CMD_SRAM_W, 0x1000, buf, NULL, MAX_CHUNK, MAX_HZ) == 0);
    f = rows_open();
    CHECK(run_write(&l, f, "C3WP", CMD_SRAM_W, 0x1000, 100, MAX_HZ + 1, 100, 1, 1) == E_ARG);
    CHECK(run_read(&l, f, CMD_SRAM_R, 0x1000, 100, MAX_HZ + 1, 100, 0, 0, 1) == E_ARG);
    rows_take(f);

    p += req(in + p, OP_WRITE, CMD_SRAM_W, 0x1000, MAX_CHUNK + 1, FAST);
    p += MAX_CHUNK + 1;
    p += req(in + p, OP_READ, CMD_SRAM_R, 0x1000, MAX_CHUNK + 1, FAST);
    p += req(in + p, OP_WRITE, CMD_SRAM_W, 0x1000, 1, MAX_HZ + 1);
    p += 1;
    p += req(in + p, OP_READ, CMD_SRAM_R, 0x1000, 1, MAX_HZ);
    m->in = in;
    m->inlen = p;
    io.read = mio_read;
    io.write = mio_write;
    io.ctx = m;
    CHECK(serve_loop(&l, &io) == 0);
    CHECK(m->outlen == 3 * 4 + 1);
    CHECK(m->out[0] == ST_BADREQ && m->out[3] == ST_BADREQ && m->out[6] == ST_BADREQ);
    CHECK(m->out[9] == ST_OK && get_le(m->out + 10, 2) == 1);
    free(m);
    sim_free(&s);
}

static void test_xfer_guard(void)
{
    uint8_t hdr[8], pay[4] = {0};
    struct xfer_desc d[2];
    size_t hl = build_cmd(CMD_SRAM_W, 0, 4, hdr);
    plan_xfers(hdr, hl, pay, 4, MAX_HZ, d);
    CHECK(xfer_guard(d, 2) == 0);
    d[1].speed_hz = 0;                  /* would mean the 12 MHz device max */
    CHECK(xfer_guard(d, 2) != 0);
    plan_xfers(hdr, hl, pay, 4, FAST, d);
    d[0].speed_hz = 0;
    CHECK(xfer_guard(d, 2) != 0);
    d[0].speed_hz = FAST;
    CHECK(xfer_guard(d, 2) != 0);
    d[0].speed_hz = HDR_HZ;
    CHECK(xfer_guard(d, 1) == 0);
    d[1].speed_hz = MAX_HZ + 1;
    CHECK(xfer_guard(d, 2) != 0);
}

static void test_smoke_eval(void)
{
    static const uint64_t lo[5] = {16000000, 16100000, 15900000, 90000000, 16050000};
    static const uint64_t hi_ok[5] = {2700000, 2750000, 2650000, 2700000, 40000000};
    static const uint64_t hi_clamp[5] = {16000000, 16020000, 15980000, 16010000, 15990000};
    static const uint64_t hi_edge[5] = {9630000, 9630000, 9630000, 9630000, 9630000};
    static const uint64_t zero[5] = {0, 0, 0, 0, 0};
    uint64_t nl, nh;
    uint32_t r;
    CHECK(smoke_eval(lo, hi_ok, &nl, &nh, &r) == 1);
    CHECK(nl == 16050000 && nh == 2700000 && r == 16);
    CHECK(smoke_eval(lo, hi_clamp, &nl, &nh, &r) == 0);
    CHECK(nh == 16000000 && r == 99);
    CHECK(smoke_eval(lo, hi_edge, &nl, &nh, &r) == 0);     /* exactly 0.6: not below */
    CHECK(smoke_eval(zero, hi_ok, &nl, &nh, &r) == 0 && r == 0);
    CHECK(smoke_eval(lo, zero, &nl, &nh, &r) == 0);         /* failed 12 MHz runs */
}

static void test_spans_bram_alias(void)
{
    static uint8_t data[64], table[5];
    sim303_t s;
    link303_t l;
    uint32_t ntx, bad;
    uint64_t ns;
    CHECK(sim_init(&s) == 0);
    link_sim(&l, &s);
    put_le(table, 0x8000, 3);           /* bank 5 base + 0x8000 would land in bank 7 */
    put_le(table + 3, 1, 2);
    CHECK(run_spans(&l, CMD_BRAM_W, 0, 1, table, data, FAST, 0, &ntx, &bad, &ns) == E_RANGE);
    put_le(table, 0x10, 3);
    CHECK(run_spans(&l, CMD_BRAM_W, BRAM7_FLAG, 1, table, data, FAST, 0, &ntx, &bad, &ns) == 0);
    CHECK(ntx == 1 && s.msgs == 1);
    sim_free(&s);
}

/* Fake spidev settings shared by every devcfg_t on it, like one /dev/spidev0.0. */
typedef struct { uint32_t v[2]; int fail_wr_hz, nwr; uint32_t wr[16][2]; } fdev_t;

static int fdev_rd(void *ctx, int what, uint32_t *v)
{
    *v = ((fdev_t *)ctx)->v[what];
    return 0;
}

static int fdev_wr(void *ctx, int what, uint32_t v)
{
    fdev_t *d = ctx;
    if (what == DEV_HZ && d->fail_wr_hz)
        return -1;
    if (d->nwr < 16) {
        d->wr[d->nwr][0] = (uint32_t)what;
        d->wr[d->nwr][1] = v;
    }
    d->nwr++;
    d->v[what] = v;
    return 0;
}

static void cfg_on(devcfg_t *c, fdev_t *d)
{
    memset(c, 0, sizeof *c);
    c->rd = fdev_rd;
    c->wr = fdev_wr;
    c->ctx = d;
}

static char emitted[256];
static int exit_code;

static void cap_emit(const char *s, size_t n)
{
    memcpy(emitted, s, n < sizeof emitted - 1 ? n : sizeof emitted - 1);
    emitted[n < sizeof emitted - 1 ? n : sizeof emitted - 1] = 0;
}

static void cap_exit(int code)
{
    exit_code = code;
}

static void test_devcfg_save_restore(void)
{
    fdev_t d;
    devcfg_t c, p;
    char row[160];
    memset(&d, 0, sizeof d);
    d.v[DEV_HZ] = 500000;
    cfg_on(&c, &d);
    CHECK(devcfg_open(&c) == 0);
    CHECK(c.have && c.saved_hz == 500000 && c.saved_mode == 0);
    CHECK(d.v[DEV_HZ] == MAX_HZ && d.nwr == 1);     /* mode already 0: untouched */
    CHECK(devcfg_restore(&c) == 0);                 /* normal exit */
    CHECK(d.v[DEV_HZ] == 500000 && c.own == 1 && c.restored_hz == 500000);
    devcfg_row(&c, row, sizeof row);
    CHECK(strcmp(row, "C3MX saved=500000 restored=500000 own=1 mode_saved=0 "
                      "mode_restored=0\n") == 0);
    CHECK(devcfg_restore(&c) == 0 && d.nwr == 2);   /* once only */

    /* mode 3 is set to 0 for the run and put back */
    memset(&d, 0, sizeof d);
    d.v[DEV_HZ] = 125000000;
    d.v[DEV_MODE] = 3;
    cfg_on(&c, &d);
    CHECK(devcfg_open(&c) == 0 && d.v[DEV_MODE] == 0 && d.v[DEV_HZ] == MAX_HZ);
    devcfg_restore(&c);
    CHECK(d.v[DEV_MODE] == 3 && d.v[DEV_HZ] == 125000000 && c.restored_mode == 3);

    /* error exit: the speed write fails after the mode was changed */
    memset(&d, 0, sizeof d);
    d.v[DEV_HZ] = 500000;
    d.v[DEV_MODE] = 1;
    d.fail_wr_hz = 1;
    cfg_on(&c, &d);
    CHECK(devcfg_open(&c) != 0 && c.have);
    devcfg_restore(&c);
    CHECK(d.v[DEV_MODE] == 1 && d.v[DEV_HZ] == 500000);

    /* nested: parent then child on one device; parent restores first */
    memset(&d, 0, sizeof d);
    d.v[DEV_HZ] = 500000;
    cfg_on(&p, &d);
    cfg_on(&c, &d);
    CHECK(devcfg_open(&p) == 0 && devcfg_open(&c) == 0 && c.saved_hz == MAX_HZ);
    devcfg_restore(&p);
    devcfg_restore(&c);
    CHECK(d.v[DEV_HZ] == 500000 && c.own == 0 && c.restored_hz == 500000);
    /* child first (LIFO) also ends at the original value */
    memset(&d, 0, sizeof d);
    d.v[DEV_HZ] = 500000;
    cfg_on(&p, &d);
    cfg_on(&c, &d);
    devcfg_open(&p);
    devcfg_open(&c);
    devcfg_restore(&c);
    devcfg_restore(&p);
    CHECK(d.v[DEV_HZ] == 500000);

    /* saved 12 MHz is never written back: a child that read 12M before the parent
       restored must not undo the parent (shared SIGINT/SIGHUP race) */
    memset(&d, 0, sizeof d);
    d.v[DEV_HZ] = MAX_HZ;
    cfg_on(&c, &d);
    CHECK(devcfg_open(&c) == 0 && c.saved_hz == MAX_HZ && d.nwr == 1);
    CHECK(devcfg_restore(&c) == 0);
    CHECK(d.nwr == 1 && c.own == 0 && c.restored_hz == MAX_HZ);
}

static void test_devcfg_signal(void)
{
    fdev_t d;
    devcfg_t c;
    memset(&d, 0, sizeof d);
    d.v[DEV_HZ] = 500000;
    cfg_on(&c, &d);
    CHECK(devcfg_open(&c) == 0);
    devcfg_active = &c;
    devcfg_emit = cap_emit;
    devcfg_exit = cap_exit;
    emitted[0] = 0;
    exit_code = 0;
    devcfg_on_signal(15);
    CHECK(d.v[DEV_HZ] == 500000 && exit_code == 128 + 15);
    CHECK(strcmp(emitted, "C3MX saved=500000 restored=500000 own=1 mode_saved=0 "
                          "mode_restored=0\n") == 0);
    emitted[0] = 0;
    devcfg_on_signal(13);                           /* already restored: no second row */
    CHECK(emitted[0] == 0 && exit_code == 128 + 13);
    devcfg_active = NULL;
    devcfg_emit = NULL;
    devcfg_exit = NULL;
}

static int hexval(const char *s, uint32_t *v)
{
    char *e;
    unsigned long x = strtoul(s, &e, 0);
    if (*s == 0 || *e != 0)
        return 0;
    *v = (uint32_t)x;
    return 1;
}

int main(int argc, char **argv)
{
    if (argc == 4 && strcmp(argv[1], "--dump") == 0) {
        uint32_t seed, n, i;
        uint8_t *b;
        if (!hexval(argv[2], &seed) || !hexval(argv[3], &n))
            return 2;
        b = malloc(n ? n : 1);
        pat_fill(seed, b, n);
        for (i = 0; i < n; i++)
            printf("%02x", b[i]);
        printf("\n");
        free(b);
        return 0;
    }
    if (argc >= 5 && (argc - 2) % 3 == 0 && strcmp(argv[1], "--hdr") == 0) {
        int a;
        for (a = 2; a < argc; a += 3) {
            uint32_t c, ad, ln;
            uint8_t h[16];
            size_t n, i;
            if (!hexval(argv[a], &c) || !hexval(argv[a + 1], &ad) || !hexval(argv[a + 2], &ln))
                return 2;
            n = build_cmd((uint8_t)c, ad, (uint16_t)ln, h);
            for (i = 0; i < n; i++)
                printf("%02x", h[i]);
            printf("\n");
        }
        return 0;
    }
    test_pattern();
    test_cmp();
    test_shift_stops_k_short();
    test_spans();
    test_pass_seeds_differ();
    test_build_cmd();
    test_range();
    test_header_split();
    test_serve_framing();
    test_write_detects_loss();
    test_read_pass();
    test_hb_every_100ms();
    test_state_stops_passes();
    test_stream();
    test_push_verify();
    test_selftest();
    test_sim_rejects_fast_header();
    test_rate_and_chunk_bounds();
    test_xfer_guard();
    test_smoke_eval();
    test_spans_bram_alias();
    test_devcfg_save_restore();
    test_devcfg_signal();
    if (fails) {
        printf("FAILED %d of %d\n", fails, checks);
        return 1;
    }
    printf("ALL PASS %d\n", checks);
    return 0;
}
