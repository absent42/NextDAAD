/* Portable core for the Pi SPI tools: pattern, per-transaction compare, spans,
   command headers, split-rate transfer planning, serve pipe codec, pass loops.
   Mirrors tests/core303/pi/link.py (pattern, build_header, plan_split, ServeHelper). */
#ifndef CORE303PI_H
#define CORE303PI_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define HDR_HZ 2000000u
#define MAX_HZ 12000000u        /* ladder top; the spidev device max, which the core clamps to */
#define MAX_CHUNK 4000u         /* header + chunk stays under spidev bufsiz 4096 */
#define SRAM_SIZE 0x200000u
#define BRAM5_SIZE 0x4000u
#define BRAM7_SIZE 0x2000u
#define BRAM7_FLAG 0x8000u      /* readme L60: ADDR[15] = 1 selects bank 7 */

#define CMD_VERSION 0xA1
#define CMD_SRAM_R 0xA7
#define CMD_SRAM_W 0xA8
#define CMD_BRAM_R 0xA9
#define CMD_BRAM_W 0xAA
#define CMD_NR_R 0xAB
#define CMD_NR_W 0xAC

#define OP_WRITE 1
#define OP_READ 2
#define OP_PUSH 3
#define OP_PUSHSPANS 4
#define SRV_HEAD 11             /* [op][cmd][addr u24][len u16][hz u32] */
#define SRV_PUSH_EXT 9          /* [total u32][flags u8][hb u32] */
#define SRV_SPANS_EXT 5         /* [flags u8][hb u32] */
#define SRV_PUSH_REPLY 16       /* [ntx u32][bad u32][ns u64] */
#define SRV_FLAG_VERIFY 1
#define TAIL_VERIFY 16

#define ST_OK 0
#define ST_BADREQ 1
#define ST_XFER 2
#define ST_HB 3

#define MB_STATE 13
#define MB_HB_PI 16
#define MB_LEN 19
#define MB_READY 1
#define HB_PERIOD_NS 100000000ull
#define HB_RETRIES 3
#define MAX_TX_ROWS 16

/* Error codes; C3ER code= is the negated value. */
#define E_ARG (-1)
#define E_RANGE (-2)
#define E_XFER (-3)
#define E_HB (-4)
#define E_IO (-5)
#define E_MEM (-6)

struct xfer_desc {
    const uint8_t *tx;
    uint8_t *rx;
    uint32_t len;
    uint32_t speed_hz;
    uint8_t bits_per_word;
    uint8_t cs_change;
};

typedef struct { size_t mismatches; long first; int shift; } cmp_t;

void pat_fill(uint32_t seed, uint8_t *buf, size_t n);
cmp_t cmp_tx(const uint8_t *want, const uint8_t *got, size_t n);
/* Returns the total span count; only the first max are stored. */
size_t spans(const uint8_t *prev, const uint8_t *cur, size_t n,
             uint32_t *starts, uint32_t *lens, size_t max);
/* NR_W carries the register value in len. Returns 0 for any other command. */
size_t build_cmd(uint8_t cmd, uint32_t addr, uint16_t len, uint8_t *hdr);
void plan_xfers(const uint8_t *hdr, size_t hlen, const uint8_t *payload, size_t plen,
                uint32_t hz, struct xfer_desc out[2]);
int range_ok(uint8_t cmd, uint32_t addr, uint32_t n);
/* 0 when every speed is 1..MAX_HZ and the first transfer is at HDR_HZ. */
int xfer_guard(const struct xfer_desc *d, int n);
/* Medians of 5 timings at 2 and 12 MHz; 1 when ns_hi < 0.6 * ns_lo. */
int smoke_eval(const uint64_t lo[5], const uint64_t hi[5], uint64_t *ns_lo, uint64_t *ns_hi,
               uint32_t *ratio_x100);

/* Little-endian field helpers. */
uint32_t get_le(const uint8_t *p, int n);
void put_le(uint8_t *p, uint64_t v, int n);

typedef struct link303 {
    int (*xfer)(void *ctx, struct xfer_desc *d, int n);    /* 0 = ok */
    uint64_t (*now_ns)(void *ctx);
    void *ctx;
    uint32_t hb_mbox;           /* 0 = no heartbeat */
    uint64_t hb_last;
    int hb_started;
    uint32_t hb_bumps;
    int last_state;
} link303_t;

/* One command: header at 2 MHz, payload at hz, one message. */
int lk_cmd(link303_t *l, uint8_t cmd, uint32_t addr, const uint8_t *tx, uint8_t *rx,
           uint16_t n, uint32_t hz);
/* Bumps hb_pi when 100 ms have passed: read, +1, 2 MHz write, read back, 3 retries. */
int hb_tick(link303_t *l);
/* Reads state at 2 MHz; returns it or a negative error. */
int mb_state(link303_t *l);

int run_write(link303_t *l, FILE *out, const char *tag, uint8_t wcmd, uint32_t base,
              uint32_t bytes, uint32_t hz, uint32_t chunk, uint32_t seed0, uint32_t passes);
/* use_seed 0: the reference is a 2 MHz read of the same chunk. */
int run_read(link303_t *l, FILE *out, uint8_t rcmd, uint32_t base, uint32_t bytes,
             uint32_t hz, uint32_t chunk, int use_seed, uint32_t seed, uint32_t passes);
int run_stream(link303_t *l, FILE *out, uint8_t wcmd, uint32_t base, const uint8_t *data,
               uint32_t len, uint32_t hz, int (*stop)(void *), void *stop_ctx);
int run_selftest(link303_t *l, FILE *out, uint32_t phys);
/* Whole frame or span list; verify reads each transaction's last 16 bytes at 2 MHz. */
int run_push(link303_t *l, uint8_t wcmd, uint32_t base, const uint8_t *data, uint32_t total,
             uint32_t hz, uint32_t chunk, int verify, uint32_t *ntx, uint32_t *bad, uint64_t *ns);
int run_spans(link303_t *l, uint8_t wcmd, uint32_t base, uint32_t count, const uint8_t *table,
              const uint8_t *data, uint32_t hz, int verify, uint32_t *ntx, uint32_t *bad,
              uint64_t *ns);
void err_row(FILE *out, int code, int err, long arg);

/* Shared spidev settings (max speed, mode): saved at open and written back at exit,
   only if still at the value this process set, so a nested serve child cannot undo
   its parent's restore. The parent holds the bus lock throughout. */
#define DEV_HZ 0
#define DEV_MODE 1

typedef struct {
    int (*rd)(void *ctx, int what, uint32_t *v);    /* 0 = ok */
    int (*wr)(void *ctx, int what, uint32_t v);
    void *ctx;
    uint32_t saved_hz, saved_mode;
    int have, mode_set, done, own;
    long restored_hz, restored_mode;
} devcfg_t;

int devcfg_open(devcfg_t *c);
int devcfg_restore(devcfg_t *c);
/* C3MX row; formats without stdio so the signal path can use it. */
size_t devcfg_row(const devcfg_t *c, char *buf, size_t cap);
extern devcfg_t *devcfg_active;
extern void (*devcfg_emit)(const char *s, size_t n);
extern void (*devcfg_exit)(int code);
/* Signal handler: restore, emit the row, then devcfg_exit(128 + sig). */
void devcfg_on_signal(int sig);

typedef struct {
    int (*read)(void *ctx, uint8_t *buf, size_t n);         /* bytes read, < n at EOF */
    int (*write)(void *ctx, const uint8_t *buf, size_t n);  /* 0 = ok */
    void *ctx;
} srv_io_t;

typedef struct { uint8_t op, cmd; uint32_t addr; uint16_t len; uint32_t hz; } srv_req_t;

void srv_parse_head(const uint8_t b[SRV_HEAD], srv_req_t *r);
void srv_reply_head(uint8_t out[3], uint8_t status, uint16_t len);
/* Serves until EOF: 0 at a clean EOF, 3 on a truncated or unknown request. */
int serve_loop(link303_t *l, srv_io_t *io);

/* Memory model of the slave for host tests and spi303 --sim. */
typedef struct {
    uint8_t *sram, bram5[BRAM5_SIZE], bram7[BRAM7_SIZE];
    uint32_t wtx;               /* data write transactions so far */
    long loss_tx, loss_at;      /* drop byte loss_at of write transaction loss_tx */
    uint32_t faults;            /* header not at 2 MHz, CE released, bad header */
    uint32_t msgs;
    uint64_t t_ns, step_ns;     /* fake clock: advances step_ns per message */
    long state_after;           /* set state 3 at state_mbox after this many messages */
    uint32_t state_mbox;
    uint32_t dev[2];            /* fake spidev settings: DEV_HZ 500000, DEV_MODE 0 */
} sim303_t;

int sim_init(sim303_t *s);
void sim_free(sim303_t *s);
int sim_xfer(void *ctx, struct xfer_desc *d, int n);
uint64_t sim_now(void *ctx);
int sim_dev_rd(void *ctx, int what, uint32_t *v);
int sim_dev_wr(void *ctx, int what, uint32_t v);

#endif
