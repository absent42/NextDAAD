/* Portable core for spi303 and its host tests. Header layouts follow the slave
   readme (pi_debug_control/readme.txt L42-L77) and link.py build_header. */
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

#include "core303pi.h"

static const uint8_t zeros[65536];      /* readme: send 00 when the byte is undefined */

void pat_fill(uint32_t seed, uint8_t *buf, size_t n)
{
    uint32_t x = seed ? seed : 1;
    size_t i;
    for (i = 0; i < n; i++) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        buf[i] = (uint8_t)x;
    }
}

cmp_t cmp_tx(const uint8_t *want, const uint8_t *got, size_t n)
{
    cmp_t c = {0, -1, 0};
    size_t i, f = 0;
    int k;
    for (i = 0; i < n; i++) {
        if (want[i] != got[i]) {
            if (!c.mismatches)
                f = i;
            c.mismatches++;
        }
    }
    if (!c.mismatches)
        return c;
    c.first = (long)f;
    /* A loss of k leaves the last k bytes unwritten: test got[i] == want[i+k] up to n-k-1. */
    for (k = 1; k <= 8 && f + (size_t)k < n; k++) {
        for (i = f; i + (size_t)k < n; i++)
            if (got[i] != want[i + (size_t)k])
                break;
        if (i + (size_t)k >= n) {
            c.shift = k;
            break;
        }
    }
    return c;
}

size_t spans(const uint8_t *prev, const uint8_t *cur, size_t n,
             uint32_t *starts, uint32_t *lens, size_t max)
{
    size_t i = 0, cnt = 0;
    while (i < n) {
        size_t s, e, j;
        if (prev[i] == cur[i]) {
            i++;
            continue;
        }
        s = i;
        e = i + 1;
        for (j = e; j < n && j - e < 4; j++)
            if (prev[j] != cur[j])
                e = j + 1;
        if (cnt < max) {
            starts[cnt] = (uint32_t)s;
            lens[cnt] = (uint32_t)(e - s);
        }
        cnt++;
        i = j;
    }
    return cnt;
}

size_t build_cmd(uint8_t cmd, uint32_t addr, uint16_t len, uint8_t *h)
{
    uint8_t l1 = (uint8_t)(len >> 8), l0 = (uint8_t)len;
    h[0] = cmd;
    switch (cmd) {
    case CMD_SRAM_R:            /* readme L68: junk byte read before data */
    case CMD_SRAM_W:            /* readme L71 */
        h[1] = (uint8_t)((addr >> 16) & 0x1F);
        h[2] = (uint8_t)(addr >> 8);
        h[3] = (uint8_t)addr;
        h[4] = l1;
        h[5] = l0;
        h[6] = 0;
        return cmd == CMD_SRAM_R ? 7 : 6;
    case CMD_BRAM_R:            /* readme L60 */
    case CMD_BRAM_W:            /* readme L64 */
        h[1] = (uint8_t)(addr >> 8);
        h[2] = (uint8_t)addr;
        h[3] = l1;
        h[4] = l0;
        h[5] = 0;
        return cmd == CMD_BRAM_R ? 6 : 5;
    case CMD_NR_R:              /* readme L74 */
        h[1] = (uint8_t)addr;
        h[2] = 0;
        return 3;
    case CMD_NR_W:              /* readme L77: value then junk, all in the header */
        h[1] = (uint8_t)addr;
        h[2] = l0;
        h[3] = 0;
        return 4;
    case CMD_VERSION:           /* readme L42 */
        h[1] = 0;
        return 2;
    }
    return 0;
}

void plan_xfers(const uint8_t *hdr, size_t hlen, const uint8_t *payload, size_t plen,
                uint32_t hz, struct xfer_desc out[2])
{
    memset(out, 0, 2 * sizeof out[0]);
    out[0].tx = hdr;
    out[0].len = (uint32_t)hlen;
    out[0].speed_hz = HDR_HZ;
    out[0].bits_per_word = 8;
    out[1].tx = payload;
    out[1].len = (uint32_t)plen;
    out[1].speed_hz = hz;
    out[1].bits_per_word = 8;
}

int range_ok(uint8_t cmd, uint32_t addr, uint32_t n)
{
    uint32_t off, size;
    switch (cmd) {
    case CMD_SRAM_R:
    case CMD_SRAM_W:
        return n >= 1 && addr < SRAM_SIZE && n <= SRAM_SIZE - addr;
    case CMD_BRAM_R:
    case CMD_BRAM_W:
        if (addr > 0xFFFF)
            return 0;
        off = addr & 0x7FFF;
        size = (addr & BRAM7_FLAG) ? BRAM7_SIZE : BRAM5_SIZE;
        return n >= 1 && off < size && n <= size - off;
    case CMD_VERSION:
    case CMD_NR_R:
    case CMD_NR_W:
        return 1;
    }
    return 0;
}

uint32_t get_le(const uint8_t *p, int n)
{
    uint32_t v = 0;
    while (n--)
        v = (v << 8) | p[n];
    return v;
}

void put_le(uint8_t *p, uint64_t v, int n)
{
    int i;
    for (i = 0; i < n; i++, v >>= 8)
        p[i] = (uint8_t)v;
}

static int is_read(uint8_t cmd)
{
    return cmd == CMD_SRAM_R || cmd == CMD_BRAM_R || cmd == CMD_VERSION || cmd == CMD_NR_R;
}

int lk_cmd(link303_t *l, uint8_t cmd, uint32_t addr, const uint8_t *tx, uint8_t *rx,
           uint16_t n, uint32_t hz)
{
    uint8_t hdr[8];
    struct xfer_desc d[2];
    size_t hl = build_cmd(cmd, addr, n, hdr);
    int rd = is_read(cmd);
    if (!hl || cmd == CMD_NR_W || n == 0 || hz == 0 || (rd ? !rx : !tx))
        return E_ARG;
    if (!range_ok(cmd, addr, n))
        return E_RANGE;
    plan_xfers(hdr, hl, rd ? zeros : tx, n, hz, d);
    if (rd)
        d[1].rx = rx;
    return l->xfer(l->ctx, d, 2) ? E_XFER : 0;
}

int hb_tick(link303_t *l)
{
    uint8_t cur[2], want[2], back[2];
    uint32_t a;
    uint64_t now;
    int i;
    if (!l->hb_mbox)
        return 0;
    now = l->now_ns(l->ctx);
    if (l->hb_started && now - l->hb_last < HB_PERIOD_NS)
        return 0;
    l->hb_started = 1;
    l->hb_last = now;
    a = l->hb_mbox + MB_HB_PI;
    /* hb_pi only has to change; read-increment keeps it moving whoever wrote last */
    if (lk_cmd(l, CMD_SRAM_R, a, NULL, cur, 2, HDR_HZ))
        return E_HB;
    put_le(want, (get_le(cur, 2) + 1) & 0xFFFF, 2);
    for (i = 0; i <= HB_RETRIES; i++) {
        if (lk_cmd(l, CMD_SRAM_W, a, want, NULL, 2, HDR_HZ) ||
            lk_cmd(l, CMD_SRAM_R, a, NULL, back, 2, HDR_HZ))
            return E_HB;
        if (!memcmp(back, want, 2)) {
            l->hb_bumps++;
            return 0;
        }
    }
    return E_HB;
}

int mb_state(link303_t *l)
{
    uint8_t s;
    if (lk_cmd(l, CMD_SRAM_R, l->hb_mbox + MB_STATE, NULL, &s, 1, HDR_HZ))
        return E_HB;
    l->last_state = s;
    return s;
}

void err_row(FILE *out, int code, int err, long arg)
{
    fprintf(out, "C3ER code=%d errno=%d arg=%ld\n", -code, err, arg);
}

static void end_rows(link303_t *l, FILE *out, uint32_t passes, int stop)
{
    fprintf(out, "C3EN passes=%" PRIu32 " stop=%d state=%d\n", passes, stop, l->last_state);
    if (l->hb_mbox)
        fprintf(out, "C3HB bumps=%" PRIu32 "\n", l->hb_bumps);
}

/* Between passes: 1 = keep going, 0 = state is not ready, < 0 = error. */
static int pass_gate(link303_t *l)
{
    int st;
    if (!l->hb_mbox)
        return 1;
    st = mb_state(l);
    if (st < 0)
        return st;
    return st == MB_READY;
}

typedef struct { uint64_t mis; uint32_t bad; long first_tx, first; int shift, rows; } acc_t;

static void acc_tx(acc_t *a, FILE *out, uint32_t pass, uint32_t tx, cmp_t c)
{
    if (!c.mismatches)
        return;
    a->mis += c.mismatches;
    if (!a->bad++) {
        a->first_tx = (long)tx;
        a->first = c.first;
        a->shift = c.shift;
    }
    if (a->rows++ < MAX_TX_ROWS)
        fprintf(out, "C3TX pass=%" PRIu32 " tx=%" PRIu32 " mis=%" PRIu64 " first=%ld shift=%d\n",
                pass, tx, (uint64_t)c.mismatches, c.first, c.shift);
}

static void acc_init(acc_t *a)
{
    memset(a, 0, sizeof *a);
    a->first_tx = a->first = -1;
}

static int pass_args(uint8_t cmd, uint32_t base, uint32_t bytes, uint32_t hz, uint32_t chunk)
{
    if (chunk < 1 || chunk > MAX_CHUNK || hz == 0)
        return E_ARG;
    return range_ok(cmd, base, bytes) ? 0 : E_RANGE;
}

int run_write(link303_t *l, FILE *out, const char *tag, uint8_t wcmd, uint32_t base,
              uint32_t bytes, uint32_t hz, uint32_t chunk, uint32_t seed0, uint32_t passes)
{
    uint8_t rcmd = (uint8_t)(wcmd - 1), *want, *got;
    uint32_t p, off, n, tx, ntx;
    uint64_t ns, t0;
    int rc, stop = 0;
    acc_t a;
    if (wcmd != CMD_SRAM_W && wcmd != CMD_BRAM_W)
        return E_ARG;
    if ((rc = pass_args(wcmd, base, bytes, hz, chunk)) != 0)
        return rc;
    want = malloc(bytes);
    got = malloc(bytes);
    if (!want || !got) {
        rc = E_MEM;
        goto done;
    }
    if ((rc = hb_tick(l)) != 0)
        goto done;
    for (p = 0; p < passes; p++) {
        if ((rc = pass_gate(l)) < 0)
            goto done;
        if (rc == 0) {
            stop = 1;
            break;
        }
        rc = 0;
        pat_fill(seed0 + p, want, bytes);   /* seed0 + pass: a lost last byte never matches */
        ns = 0;
        ntx = 0;
        for (off = 0; off < bytes; off += n) {
            n = bytes - off < chunk ? bytes - off : chunk;
            t0 = l->now_ns(l->ctx);
            rc = lk_cmd(l, wcmd, base + off, want + off, NULL, (uint16_t)n, hz);
            ns += l->now_ns(l->ctx) - t0;
            if (rc || (rc = hb_tick(l)) != 0)
                goto done;
            ntx++;
        }
        acc_init(&a);
        for (off = 0, tx = 0; off < bytes; off += n, tx++) {
            n = bytes - off < chunk ? bytes - off : chunk;
            if ((rc = lk_cmd(l, rcmd, base + off, NULL, got + off, (uint16_t)n, HDR_HZ)) != 0 ||
                (rc = hb_tick(l)) != 0)
                goto done;
            acc_tx(&a, out, p, tx, cmp_tx(want + off, got + off, n));
        }
        fprintf(out, "%s pass=%" PRIu32 " seed=%" PRIu32 " hz=%" PRIu32 " base=%" PRIu32
                " bytes=%" PRIu32 " chunk=%" PRIu32 " ntx=%" PRIu32 " ns=%" PRIu64 " mis=%" PRIu64
                " bad_tx=%" PRIu32 " first_tx=%ld first=%ld shift=%d\n",
                tag, p, seed0 + p, hz, base, bytes, chunk, ntx, ns, a.mis, a.bad, a.first_tx,
                a.first, a.shift);
    }
    end_rows(l, out, p, stop);
done:
    free(want);
    free(got);
    return rc;
}

int run_read(link303_t *l, FILE *out, uint8_t rcmd, uint32_t base, uint32_t bytes,
             uint32_t hz, uint32_t chunk, int use_seed, uint32_t seed, uint32_t passes)
{
    uint8_t *want, *got;
    uint32_t p, off, n, tx;
    uint64_t ns, t0;
    int rc, stop = 0;
    acc_t a;
    if (rcmd != CMD_SRAM_R && rcmd != CMD_BRAM_R)
        return E_ARG;
    if ((rc = pass_args(rcmd, base, bytes, hz, chunk)) != 0)
        return rc;
    want = malloc(bytes);
    got = malloc(bytes);
    if (!want || !got) {
        rc = E_MEM;
        goto done;
    }
    if (use_seed)
        pat_fill(seed, want, bytes);
    if ((rc = hb_tick(l)) != 0)
        goto done;
    for (p = 0; p < passes; p++) {
        if ((rc = pass_gate(l)) < 0)
            goto done;
        if (rc == 0) {
            stop = 1;
            break;
        }
        rc = 0;
        ns = 0;
        acc_init(&a);
        for (off = 0, tx = 0; off < bytes; off += n, tx++) {
            n = bytes - off < chunk ? bytes - off : chunk;
            if (!use_seed &&
                ((rc = lk_cmd(l, rcmd, base + off, NULL, want + off, (uint16_t)n, HDR_HZ)) != 0 ||
                 (rc = hb_tick(l)) != 0))
                goto done;
            t0 = l->now_ns(l->ctx);
            rc = lk_cmd(l, rcmd, base + off, NULL, got + off, (uint16_t)n, hz);
            ns += l->now_ns(l->ctx) - t0;
            if (rc || (rc = hb_tick(l)) != 0)
                goto done;
            acc_tx(&a, out, p, tx, cmp_tx(want + off, got + off, n));
        }
        fprintf(out, "C3RP pass=%" PRIu32 " hz=%" PRIu32 " base=%" PRIu32 " bytes=%" PRIu32
                " chunk=%" PRIu32 " ntx=%" PRIu32 " ns=%" PRIu64 " mis=%" PRIu64 " bad_tx=%" PRIu32
                " first_tx=%ld first=%ld shift=%d ref=%d\n",
                p, hz, base, bytes, chunk, tx, ns, a.mis, a.bad, a.first_tx, a.first, a.shift,
                use_seed ? 1 : 0);
    }
    end_rows(l, out, p, stop);
done:
    free(want);
    free(got);
    return rc;
}

int run_stream(link303_t *l, FILE *out, uint8_t wcmd, uint32_t base, const uint8_t *data,
               uint32_t len, uint32_t hz, int (*stop)(void *), void *stop_ctx)
{
    uint32_t off, n, passes = 0, ntx = 0;
    uint64_t ns = 0, t0;
    int rc, why = -1;
    if (wcmd != CMD_SRAM_W && wcmd != CMD_BRAM_W)
        return E_ARG;
    if ((rc = pass_args(wcmd, base, len, hz, MAX_CHUNK)) != 0)
        return rc;
    if ((rc = hb_tick(l)) != 0)
        return rc;
    while (why < 0) {
        if ((rc = pass_gate(l)) < 0)
            return rc;
        if (rc == 0) {
            why = 1;
            break;
        }
        for (off = 0; off < len; off += n) {
            n = len - off < MAX_CHUNK ? len - off : MAX_CHUNK;
            if (stop(stop_ctx)) {
                why = 0;
                break;
            }
            t0 = l->now_ns(l->ctx);
            rc = lk_cmd(l, wcmd, base + off, data + off, NULL, (uint16_t)n, hz);
            ns += l->now_ns(l->ctx) - t0;
            if (rc || (rc = hb_tick(l)) != 0)
                return rc;
            ntx++;
        }
        if (why < 0)
            passes++;
    }
    fprintf(out, "C3SM base=%" PRIu32 " bytes=%" PRIu32 " hz=%" PRIu32 " passes=%" PRIu32
            " ntx=%" PRIu32 " ns=%" PRIu64 " stop=%d state=%d\n",
            base, len, hz, passes, ntx, ns, why, l->last_state);
    if (l->hb_mbox)
        fprintf(out, "C3HB bumps=%" PRIu32 "\n", l->hb_bumps);
    return 0;
}

int run_selftest(link303_t *l, FILE *out, uint32_t phys)
{
    uint8_t want[256], got[256];
    cmp_t c;
    int rc;
    pat_fill(0x303, want, sizeof want);
    if ((rc = lk_cmd(l, CMD_SRAM_W, phys, want, NULL, sizeof want, HDR_HZ)) != 0 ||
        (rc = lk_cmd(l, CMD_SRAM_R, phys, NULL, got, sizeof got, HDR_HZ)) != 0)
        return rc;
    c = cmp_tx(want, got, sizeof want);
    fprintf(out, "C3ST ok=%d base=%" PRIu32 " mis=%" PRIu64 " first=%ld\n",
            c.mismatches ? 0 : 1, phys, (uint64_t)c.mismatches, c.first);
    return c.mismatches ? 1 : 0;
}

/* One frame transaction; verify compares the transaction's last 16 bytes read at 2 MHz. */
static int push_tx(link303_t *l, uint8_t wcmd, uint32_t addr, const uint8_t *data, uint32_t n,
                   uint32_t hz, int verify, uint32_t *bad)
{
    uint8_t tail[TAIL_VERIFY];
    uint32_t t = n < TAIL_VERIFY ? n : TAIL_VERIFY;
    int rc = lk_cmd(l, wcmd, addr, data, NULL, (uint16_t)n, hz);
    if (rc)
        return rc;
    if (verify) {
        rc = lk_cmd(l, (uint8_t)(wcmd - 1), addr + n - t, NULL, tail, (uint16_t)t, HDR_HZ);
        if (rc)
            return rc;
        if (memcmp(tail, data + n - t, t))
            (*bad)++;
    }
    return hb_tick(l);
}

int run_push(link303_t *l, uint8_t wcmd, uint32_t base, const uint8_t *data, uint32_t total,
             uint32_t hz, uint32_t chunk, int verify, uint32_t *ntx, uint32_t *bad, uint64_t *ns)
{
    uint32_t off, n;
    uint64_t t0;
    int rc;
    *ntx = *bad = 0;
    *ns = 0;
    if (wcmd != CMD_SRAM_W && wcmd != CMD_BRAM_W)
        return E_ARG;
    if ((rc = pass_args(wcmd, base, total, hz, chunk)) != 0)
        return rc;
    t0 = l->now_ns(l->ctx);
    for (off = 0; off < total; off += n) {
        n = total - off < chunk ? total - off : chunk;
        if ((rc = push_tx(l, wcmd, base + off, data + off, n, hz, verify, bad)) != 0)
            return rc;
        (*ntx)++;
    }
    *ns = l->now_ns(l->ctx) - t0;
    return 0;
}

int run_spans(link303_t *l, uint8_t wcmd, uint32_t base, uint32_t count, const uint8_t *table,
              const uint8_t *data, uint32_t hz, int verify, uint32_t *ntx, uint32_t *bad,
              uint64_t *ns)
{
    uint32_t i, off, len, k, n;
    uint64_t t0;
    int rc;
    *ntx = *bad = 0;
    *ns = 0;
    if ((wcmd != CMD_SRAM_W && wcmd != CMD_BRAM_W) || hz == 0)
        return E_ARG;
    for (i = 0; i < count; i++) {       /* every span is checked before the first transfer */
        off = get_le(table + 5 * i, 3);
        len = get_le(table + 5 * i + 3, 2);
        if (len == 0)
            return E_ARG;
        if (!range_ok(wcmd, base + off, len))
            return E_RANGE;
    }
    t0 = l->now_ns(l->ctx);
    for (i = 0; i < count; i++) {
        off = get_le(table + 5 * i, 3);
        len = get_le(table + 5 * i + 3, 2);
        for (k = 0; k < len; k += n) {
            n = len - k < MAX_CHUNK ? len - k : MAX_CHUNK;
            if ((rc = push_tx(l, wcmd, base + off + k, data + k, n, hz, verify, bad)) != 0)
                return rc;
            (*ntx)++;
        }
        data += len;
    }
    *ns = l->now_ns(l->ctx) - t0;
    return 0;
}

void srv_parse_head(const uint8_t b[SRV_HEAD], srv_req_t *r)
{
    r->op = b[0];
    r->cmd = b[1];
    r->addr = get_le(b + 2, 3);
    r->len = (uint16_t)get_le(b + 5, 2);
    r->hz = get_le(b + 7, 4);
}

void srv_reply_head(uint8_t out[3], uint8_t status, uint16_t len)
{
    out[0] = status;
    put_le(out + 1, len, 2);
}

static int srv_take(srv_io_t *io, uint8_t *b, size_t n)
{
    return io->read(io->ctx, b, n) == (int)n ? 0 : -1;
}

static uint8_t *srv_grow(uint8_t **buf, size_t *cap, size_t need)
{
    if (need > *cap) {
        uint8_t *nb = realloc(*buf, need);
        if (!nb)
            return NULL;
        *buf = nb;
        *cap = need;
    }
    return *buf;
}

static uint8_t rc_status(int rc)
{
    if (rc == 0)
        return ST_OK;
    if (rc == E_ARG || rc == E_RANGE)
        return ST_BADREQ;
    return rc == E_HB ? ST_HB : ST_XFER;
}

static int srv_hb_ok(uint32_t hb)
{
    return hb == 0 || (hb < SRAM_SIZE && SRAM_SIZE - hb >= MB_LEN);
}

int serve_loop(link303_t *l, srv_io_t *io)
{
    uint8_t head[SRV_HEAD], ext[SRV_PUSH_EXT], rep[3 + SRV_PUSH_REPLY];
    uint8_t *buf = NULL;
    size_t cap = 0;
    srv_req_t r;
    int k, rc, res = 3;
    for (;;) {
        k = io->read(io->ctx, head, SRV_HEAD);
        if (k == 0) {
            res = 0;
            break;
        }
        if (k != SRV_HEAD)
            break;
        srv_parse_head(head, &r);
        if (r.op == OP_WRITE || r.op == OP_READ) {
            int wr = r.op == OP_WRITE;
            int okcmd = wr ? (r.cmd == CMD_SRAM_W || r.cmd == CMD_BRAM_W)
                           : (r.cmd == CMD_SRAM_R || r.cmd == CMD_BRAM_R);
            if (!srv_grow(&buf, &cap, r.len ? r.len : 1))
                break;
            if (wr && srv_take(io, buf, r.len))
                break;
            rc = okcmd ? lk_cmd(l, r.cmd, r.addr, buf, buf, r.len, r.hz) : E_ARG;
            srv_reply_head(rep, rc_status(rc), (uint16_t)(rc || wr ? 0 : r.len));
            if (io->write(io->ctx, rep, 3) || (!rc && !wr && io->write(io->ctx, buf, r.len)))
                break;
            continue;
        }
        if (r.op == OP_PUSH || r.op == OP_PUSHSPANS) {
            uint32_t total, hb, count = r.len, ntx = 0, bad = 0, i;
            uint8_t flags;
            uint64_t ns = 0;
            size_t tlen = 0;
            uint32_t save = l->hb_mbox;
            if (srv_take(io, ext, r.op == OP_PUSH ? SRV_PUSH_EXT : SRV_SPANS_EXT))
                break;
            if (r.op == OP_PUSH) {
                total = get_le(ext, 4);
                flags = ext[4];
                hb = get_le(ext + 5, 4);
            } else {
                flags = ext[0];
                hb = get_le(ext + 1, 4);
                tlen = (size_t)count * 5;
                if (!srv_grow(&buf, &cap, tlen + 1) || srv_take(io, buf, tlen))
                    break;
                for (total = 0, i = 0; i < count; i++)
                    total += get_le(buf + 5 * i + 3, 2);
            }
            if (total > SRAM_SIZE) {    /* cannot be skipped safely: report and stop */
                srv_reply_head(rep, ST_BADREQ, 0);
                io->write(io->ctx, rep, 3);
                break;
            }
            if (!srv_grow(&buf, &cap, tlen + total + 1) || srv_take(io, buf + tlen, total))
                break;
            if (!srv_hb_ok(hb)) {
                rc = E_ARG;
            } else {
                l->hb_mbox = hb;
                if (r.op == OP_PUSH)
                    rc = run_push(l, r.cmd, r.addr, buf, total, r.hz, r.len,
                                  flags & SRV_FLAG_VERIFY, &ntx, &bad, &ns);
                else
                    rc = run_spans(l, r.cmd, r.addr, count, buf, buf + tlen, r.hz,
                                   flags & SRV_FLAG_VERIFY, &ntx, &bad, &ns);
                l->hb_mbox = save;
            }
            srv_reply_head(rep, rc_status(rc), rc ? 0 : SRV_PUSH_REPLY);
            put_le(rep + 3, ntx, 4);
            put_le(rep + 7, bad, 4);
            put_le(rep + 11, ns, 8);
            if (io->write(io->ctx, rep, rc ? 3 : 3 + SRV_PUSH_REPLY))
                break;
            continue;
        }
        srv_reply_head(rep, ST_BADREQ, 0);      /* unknown op: the stream is out of step */
        io->write(io->ctx, rep, 3);
        break;
    }
    free(buf);
    return res;
}

int sim_init(sim303_t *s)
{
    memset(s, 0, sizeof *s);
    s->sram = calloc(SRAM_SIZE, 1);
    s->loss_tx = s->loss_at = s->state_after = -1;
    return s->sram ? 0 : E_MEM;
}

void sim_free(sim303_t *s)
{
    free(s->sram);
    s->sram = NULL;
}

uint64_t sim_now(void *ctx)
{
    return ((sim303_t *)ctx)->t_ns;
}

static uint8_t *sim_byte(sim303_t *s, uint8_t cmd, uint32_t addr, uint32_t i)
{
    uint32_t off;
    if (cmd == CMD_SRAM_R || cmd == CMD_SRAM_W)
        return &s->sram[(addr + i) & (SRAM_SIZE - 1)];
    off = (addr & 0x7FFF) + i;          /* readme L62: ADDR is modulo bank size */
    if (addr & BRAM7_FLAG)
        return &s->bram7[off % BRAM7_SIZE];
    return &s->bram5[off % BRAM5_SIZE];
}

int sim_xfer(void *ctx, struct xfer_desc *d, int n)
{
    sim303_t *s = ctx;
    uint8_t h[8], cmd;
    uint32_t addr = 0, len, i;
    size_t hl;
    int rc = 0;
    s->msgs++;
    if (s->state_after >= 0 && s->msgs > (uint32_t)s->state_after)
        s->sram[(s->state_mbox + MB_STATE) & (SRAM_SIZE - 1)] = 3;
    cmd = d[0].tx[0];
    hl = build_cmd(cmd, 0, 0, h);
    if (n != 2 || !hl || d[0].len != hl || d[0].speed_hz != HDR_HZ || d[0].cs_change ||
        d[1].cs_change || cmd == CMD_NR_W) {
        s->faults++;
        rc = -1;
        goto out;
    }
    len = d[1].len;
    if (cmd == CMD_SRAM_R || cmd == CMD_SRAM_W) {
        addr = ((uint32_t)(d[0].tx[1] & 0x1F) << 16) | ((uint32_t)d[0].tx[2] << 8) | d[0].tx[3];
        i = ((uint32_t)d[0].tx[4] << 8) | d[0].tx[5];
    } else if (cmd == CMD_BRAM_R || cmd == CMD_BRAM_W) {
        addr = ((uint32_t)d[0].tx[1] << 8) | d[0].tx[2];
        i = ((uint32_t)d[0].tx[3] << 8) | d[0].tx[4];
    } else {
        i = len;
    }
    if (i != len) {             /* header length must match the payload phase */
        s->faults++;
        rc = -1;
        goto out;
    }
    if (cmd == CMD_SRAM_W || cmd == CMD_BRAM_W) {
        long lost = (long)s->wtx++ == s->loss_tx ? s->loss_at : -1;
        for (i = 0; i < len; i++) {
            if (lost >= 0 && (long)i >= lost) {
                if (i + 1 < len)
                    *sim_byte(s, cmd, addr, i) = d[1].tx[i + 1];
            } else {
                *sim_byte(s, cmd, addr, i) = d[1].tx[i];
            }
        }
    } else if (d[1].rx) {
        for (i = 0; i < len; i++) {
            if (cmd == CMD_SRAM_R || cmd == CMD_BRAM_R)
                d[1].rx[i] = *sim_byte(s, cmd, addr, i);
            else
                d[1].rx[i] = cmd == CMD_VERSION && i == 0 ? 0x11 : (cmd == CMD_VERSION ? 0xFF : 0);
        }
    }
out:
    s->t_ns += s->step_ns;
    return rc;
}
