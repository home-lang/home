/* Home codec bridge, MIT. Compile against installed x264.h/x265.h. */
#ifndef HOME_NATIVE_ENCODER_H
#define HOME_NATIVE_ENCODER_H
#include <stddef.h>
#include <stdint.h>
typedef struct home_encoder home_encoder;
typedef struct { uint32_t codec, width, height, fps_num, fps_den, bitrate, quality, gop; } home_encoder_config;
/* Additive ABI; ISO color codes, not Home's portable enum IDs. Supported:
 * primaries 1/6/9, transfer 1/8/13, matrix 1/6/9, full_range 0/1.
 * Caller supplies matching I420 samples; this never converts pixels. */
typedef struct { uint32_t struct_size, primaries, transfer, matrix, full_range; } home_encoder_color;
/* Length-prefixed NAL units; borrowed until the next call. pts uses microseconds.
 * Low latency: no B frames/lookahead; AVC VFR buffers one input for duration.
 * Empty output means buffered. Drain flush() before close; serialize calls. */
typedef struct { const uint8_t *data; size_t size; int64_t pts; int key; } home_packet;
int home_encoder_open(const home_encoder_config *, home_encoder **);
int home_encoder_open_color(const home_encoder_config *, const home_encoder_color *, home_encoder **);
int home_encoder_headers(home_encoder *, home_packet *);
int home_encoder_encode(home_encoder *, const uint8_t *const planes[3], const int strides[3], int64_t pts, home_packet *);
int home_encoder_request_keyframe(home_encoder *);
int home_encoder_flush(home_encoder *, home_packet *);
void home_encoder_close(home_encoder *);
#endif
