/* Test-only independent APNG structure/CRC checks and libpng sample readback.
 * libpng decodes each reconstructed static frame. This does not pretend libpng
 * supplies APNG playback/compositing or validate Home's general PNG decoder. */
#include <png.h>
#include <zlib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int home_apng(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, unsigned char **, size_t *);
extern void home_apng_free(unsigned char *, size_t);
static void check(int ok, const char *message) {
    if (!ok) { fprintf(stderr, "APNG conformance: %s\n", message); exit(1); }
}
typedef struct { unsigned char *data; size_t length; } Bytes;
typedef struct { Bytes compressed; uint32_t width, height; } Frame;
static uint32_t be32(const unsigned char *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static void put32(unsigned char *p, uint32_t n) {
    p[0] = (unsigned char)(n >> 24); p[1] = (unsigned char)(n >> 16);
    p[2] = (unsigned char)(n >> 8); p[3] = (unsigned char)n;
}
static void append(Bytes *b, const void *data, size_t n) {
    check(n <= SIZE_MAX - b->length, "buffer overflow");
    if (!n) return;
    void *next = realloc(b->data, b->length + n);
    check(next != NULL, "allocation"); b->data = next;
    memcpy(b->data + b->length, data, n); b->length += n;
}
static void chunk(Bytes *out, const char *type, const unsigned char *data, size_t n) {
    unsigned char number[4]; check(n <= 0x7fffffff, "chunk size");
    put32(number, (uint32_t)n); append(out, number, 4); append(out, type, 4); append(out, data, n);
    uLong crc = crc32(0, (const Bytef *)type, 4);
    if (n) crc = crc32(crc, data, (uInt)n);
    put32(number, (uint32_t)crc); append(out, number, 4);
}
typedef struct { const unsigned char *data; size_t left; } Reader;
static void read_bytes(png_structp png, png_bytep out, png_size_t count) {
    Reader *r = png_get_io_ptr(png);
    if (count > r->left) png_error(png, "truncated independent input");
    memcpy(out, r->data, count); r->data += count; r->left -= count;
}
static uint16_t pattern(size_t x, size_t y, size_t c, size_t frame, unsigned bits) {
    unsigned hi = (unsigned)((x * 37 + y * 53 + c * 79 + frame * 91 + (x * y) % 251) % 256);
    unsigned lo = (unsigned)((x * 17 + y * 29 + c * 43 + frame * 61) % 256);
    return (uint16_t)(bits == 8 ? hi : hi * 256 + lo);
}
static void decode_frame(const unsigned char *ihdr, const Frame *frame, size_t id) {
    Bytes png_bytes = {0}; unsigned char header[13]; memcpy(header, ihdr, 13);
    put32(header, frame->width); put32(header + 4, frame->height);
    static const unsigned char signature[] = {137,80,78,71,13,10,26,10};
    append(&png_bytes, signature, 8); chunk(&png_bytes, "IHDR", header, 13);
    chunk(&png_bytes, "IDAT", frame->compressed.data, frame->compressed.length); chunk(&png_bytes, "IEND", NULL, 0);
    Reader reader = {png_bytes.data, png_bytes.length};
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL); check(png != NULL, "png owner");
    png_infop info = png_create_info_struct(png); check(info != NULL, "png info");
    if (setjmp(png_jmpbuf(png))) { fputs("independent libpng decode failed\n", stderr); exit(1); }
    png_set_crc_action(png, PNG_CRC_ERROR_QUIT, PNG_CRC_ERROR_QUIT);
    png_set_read_fn(png, &reader, read_bytes); png_read_info(png, info);
    check(png_get_image_width(png, info) == frame->width && png_get_image_height(png, info) == frame->height, "libpng geometry");
    unsigned bits = png_get_bit_depth(png, info), channels = png_get_channels(png, info);
    check(bits == ihdr[8] && (channels == 1 || channels == 3 || channels == 4), "libpng format");
    size_t row_size = (size_t)frame->width * channels * (bits / 8);
    check(png_get_rowbytes(png, info) == row_size, "libpng row size");
    unsigned char *row = malloc(row_size); check(row != NULL, "row allocation");
    for (size_t y = 0; y < frame->height; ++y) {
        png_read_row(png, row, NULL);
        for (size_t x = 0; x < frame->width; ++x) for (size_t c = 0; c < channels; ++c) {
            size_t at = (x * channels + c) * (bits / 8);
            uint16_t actual = bits == 8 ? row[at] : (uint16_t)((uint16_t)row[at] * 256 + row[at + 1]);
            check(actual == pattern(x, y, c, id, bits), "exact raster sample mismatch");
        }
    }
    png_read_end(png, info); free(row); png_destroy_read_struct(&png, &info, NULL); free(png_bytes.data);
}
static void fixture(unsigned format, unsigned bits, unsigned filter, unsigned poster, unsigned width, unsigned height) {
    unsigned char *data = NULL; size_t length = 0;
    check(home_apng(format, bits, filter, poster, width, height, &data, &length) == 0, "Home fixture encode");
    Frame images[4] = {0}; images[0].width = width; images[0].height = height;
    unsigned char ihdr[13] = {0}; unsigned fc_count = 0, sequence = 0, actl = 0, idat = 0, ended = 0, fdat = 0;
    size_t current = 0, at = 8;
    check(length >= 8 && !memcmp(data, "\211PNG\r\n\032\n", 8), "signature");
    while (at < length) {
        check(length - at >= 12, "chunk header"); uint32_t n = be32(data + at);
        check(n <= length - at - 12, "chunk span"); const unsigned char *type = data + at + 4, *body = type + 4;
        check(crc32(0, type, n + 4) == be32(body + n), "independent chunk CRC");
        if (!memcmp(type, "IHDR", 4)) {
            check(at == 8 && n == 13 && be32(body) == width && be32(body + 4) == height, "IHDR");
            memcpy(ihdr, body, 13); check(body[8] == bits && body[9] == (format == 0 ? 0 : format == 1 ? 2 : 6), "IHDR format");
        } else if (!memcmp(type, "acTL", 4)) {
            check(!actl++ && !idat && n == 8 && be32(body) == 3 && be32(body + 4) == 3, "animation control");
        } else if (!memcmp(type, "fcTL", 4)) {
            check(actl && n == 26 && fc_count < 3 && be32(body) == sequence++, "frame sequence");
            check(fc_count != 0 || (idat != 0) == (poster != 0), "default image participation");
            current = fc_count + poster;
            images[current].width = fc_count == 1 ? width - 1 : fc_count == 2 ? 1 : width;
            images[current].height = fc_count == 1 ? height - 1 : fc_count == 2 ? 1 : height;
            check(be32(body + 4) == images[current].width && be32(body + 8) == images[current].height, "frame dimensions");
            check(be32(body + 12) == (fc_count == 1 ? 1u : 0u) && be32(body + 16) == (fc_count == 1 ? 1u : 0u), "frame offsets");
            unsigned num = (unsigned)body[20] * 256 + body[21], den = (unsigned)body[22] * 256 + body[23];
            check(num == (fc_count == 0 ? 0u : fc_count == 1 ? 8192u : 7u) && den == (fc_count == 0 ? 1000u : fc_count == 1 ? 125u : 0u), "rational delay");
            check(body[24] == fc_count && body[25] == (fc_count == 1 ? 1 : 0), "disposal and blend"); ++fc_count;
        } else if (!memcmp(type, "IDAT", 4)) {
            check(actl && current == 0 && fc_count == (poster ? 0u : 1u) && !fdat, "IDAT ordering");
            ++idat; append(&images[0].compressed, body, n);
        } else if (!memcmp(type, "fdAT", 4)) {
            check(idat && fc_count && current > 0 && n >= 4 && be32(body) == sequence++, "fdAT sequence");
            ++fdat; append(&images[current].compressed, body + 4, n - 4);
        } else if (!memcmp(type, "IEND", 4)) {
            check(n == 0 && at + 12 == length, "IEND boundary"); ended = 1;
        } else check(0, "unexpected chunk");
        at += n + 12;
    }
    check(ended && actl == 1 && fc_count == 3 && idat && fdat, "complete animation");
    if (width == 256 && height == 256 && format == 2 && bits == 16) check(fdat > 2, "large frame splits across fdAT chunks");
    for (size_t i = 0; i < 3 + poster; ++i) {
        decode_frame(ihdr, &images[i], poster ? (i == 0 ? 9 : i - 1) : i);
        free(images[i].compressed.data);
    }
    home_apng_free(data, length);
}
int main(void) {
    unsigned count = 0;
    const unsigned dimensions[][2] = {{3,2}, {257,17}, {256,256}};
    for (unsigned f = 0; f < 3; ++f) for (unsigned b = 8; b <= 16; b += 8)
    for (unsigned filter = 0; filter < 6; ++filter) for (unsigned poster = 0; poster < 2; ++poster)
    for (unsigned d = 0; d < sizeof(dimensions) / sizeof(dimensions[0]); ++d) {
        fixture(f, b, filter, poster, dimensions[d][0], dimensions[d][1]); ++count;
    }
    printf("%u APNG fixtures: independent CRC/order/controls and libpng exact frame samples passed\n", count);
    return 0;
}
