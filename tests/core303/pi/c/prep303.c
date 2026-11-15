/* P2 frame preparation timing on the Pi: libjpeg decode, RGB to RRRGGGBB, span extraction.
   prep303 <frames_dir> <rgb_dir> <n> prints P2JD/P2CV/P2SP rows; prep303 --cv in.rgb out.raw.
   No jpeglib.h: #SKIP P2JD NOHDR; header but -DNO_JPEG (-ljpeg failed): NOLINK. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "core303pi.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif

#if defined(__has_include)
#if __has_include(<jpeglib.h>)
#define JPEG_HDR 1
#endif
#endif
#if defined(JPEG_HDR) && !defined(NO_JPEG)
#define HAVE_JPEG 1
#endif
#ifdef HAVE_JPEG
#include <setjmp.h>
#include <jpeglib.h>
#endif

#define FW 256
#define FH 192
#define NPIX (FW * FH)
#define MAXSP NPIX

static uint64_t now_ns(void)
{
#ifdef _WIN32
    LARGE_INTEGER c, f;
    QueryPerformanceCounter(&c);
    QueryPerformanceFrequency(&f);
    return (uint64_t)((double)c.QuadPart * 1e9 / (double)f.QuadPart);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

static uint8_t *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    uint8_t *b;
    long sz;
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    b = (uint8_t *)malloc(sz > 0 ? (size_t)sz : 1);
    if (b && fread(b, 1, (size_t)sz, f) != (size_t)sz) {
        free(b);
        b = NULL;
    }
    fclose(f);
    *len = (size_t)sz;
    return b;
}

static void convert(const uint8_t *rgb, uint8_t *out)
{
    int i;
    for (i = 0; i < NPIX; i++)
        out[i] = (uint8_t)((rgb[3 * i] & 0xE0) | ((rgb[3 * i + 1] & 0xE0) >> 3) |
                           (rgb[3 * i + 2] >> 6));
}

#ifdef HAVE_JPEG
struct jerr { struct jpeg_error_mgr pub; jmp_buf jb; };

static void jfail(j_common_ptr c)
{
    longjmp(((struct jerr *)c->err)->jb, 1);
}

static int jdecode(const uint8_t *jpg, size_t len, uint8_t *rgb)
{
    struct jpeg_decompress_struct ci;
    struct jerr je;
    memset(&ci, 0, sizeof ci);
    ci.err = jpeg_std_error(&je.pub);
    je.pub.error_exit = jfail;
    if (setjmp(je.jb)) {
        jpeg_destroy_decompress(&ci);
        return -1;
    }
    jpeg_create_decompress(&ci);
    jpeg_mem_src(&ci, jpg, (unsigned long)len);
    jpeg_read_header(&ci, TRUE);
    ci.out_color_space = JCS_RGB;
    jpeg_start_decompress(&ci);
    if (ci.output_width != FW || ci.output_height != FH || ci.output_components != 3) {
        jpeg_destroy_decompress(&ci);
        return -1;
    }
    while (ci.output_scanline < ci.output_height) {
        JSAMPROW row = rgb + (size_t)ci.output_scanline * FW * 3;
        jpeg_read_scanlines(&ci, &row, 1);
    }
    jpeg_finish_decompress(&ci);
    jpeg_destroy_decompress(&ci);
    return 0;
}
#endif

static int cv_file(const char *in, const char *out)
{
    size_t n;
    uint8_t *rgb = slurp(in, &n), *o;
    FILE *f;
    if (!rgb || n != (size_t)NPIX * 3)
        return 2;
    o = (uint8_t *)malloc(NPIX);
    convert(rgb, o);
    f = fopen(out, "wb");
    if (!f || fwrite(o, 1, NPIX, f) != NPIX)
        return 2;
    fclose(f);
    free(rgb);
    free(o);
    return 0;
}

#ifdef HAVE_JPEG
static int run_jd(const char *fdir, int n)
{
    char path[1024];
    uint8_t *rgb = (uint8_t *)malloc((size_t)NPIX * 3);
    uint64_t ns = 0, t0;
    int i;
    for (i = 0; i < n; i++) {
        size_t len;
        uint8_t *jpg;
        snprintf(path, sizeof path, "%s/F%03d.jpg", fdir, i);
        jpg = slurp(path, &len);
        if (!jpg)
            return 2;
        t0 = now_ns();
        if (jdecode(jpg, len, rgb))
            return 2;
        ns += now_ns() - t0;
        free(jpg);
    }
    free(rgb);
    printf("P2JD ns=%llu frames=%d impl=1\n", (unsigned long long)ns, n);
    return 0;
}
#endif

static int run_all(const char *fdir, const char *rdir, int n)
{
    char path[1024];
    uint8_t *conv = (uint8_t *)malloc((size_t)NPIX * (n > 0 ? n : 1));
    uint32_t *st = (uint32_t *)malloc(sizeof(uint32_t) * MAXSP);
    uint32_t *ln = (uint32_t *)malloc(sizeof(uint32_t) * MAXSP);
    uint64_t ns = 0, t0, total = 0;
    int i;
    if (!conv || !st || !ln)
        return 2;
#ifdef HAVE_JPEG
    if (run_jd(fdir, n))
        return 2;
#elif defined(JPEG_HDR) || defined(JPEG_NOLINK)
    printf("#SKIP P2JD NOLINK\n");
#else
    printf("#SKIP P2JD NOHDR\n");
#endif
    for (i = 0; i < n; i++) {
        size_t len;
        uint8_t *rgb;
        snprintf(path, sizeof path, "%s/F%03d.rgb", rdir, i);
        rgb = slurp(path, &len);
        if (!rgb || len != (size_t)NPIX * 3)
            return 2;
        t0 = now_ns();
        convert(rgb, conv + (size_t)i * NPIX);
        ns += now_ns() - t0;
        free(rgb);
    }
    printf("P2CV ns=%llu frames=%d impl=1\n", (unsigned long long)ns, n);
    ns = 0;
    for (i = 1; i < n; i++) {
        t0 = now_ns();
        total += spans(conv + (size_t)(i - 1) * NPIX, conv + (size_t)i * NPIX, NPIX,
                       st, ln, MAXSP);
        ns += now_ns() - t0;
    }
    printf("P2SP ns=%llu frames=%d impl=1 spans=%llu\n", (unsigned long long)ns,
           n > 1 ? n - 1 : 0, (unsigned long long)total);
    free(conv);
    free(st);
    free(ln);
    (void)fdir;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 4 && !strcmp(argv[1], "--cv"))
        return cv_file(argv[2], argv[3]);
    if (argc == 4)
        return run_all(argv[1], argv[2], atoi(argv[3]));
    fprintf(stderr, "usage: prep303 <frames_dir> <rgb_dir> <n> | --cv in.rgb out.raw\n");
    return 2;
}
