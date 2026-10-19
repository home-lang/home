/* Home ALSA capture bridge, MIT. Opaque system ABI; S16LE interleaved PCM. */
#ifndef HOME_NATIVE_CAPTURE_H
#define HOME_NATIVE_CAPTURE_H
#include <stdint.h>
typedef struct home_audio_capture home_audio_capture;
typedef struct { uint32_t sample_rate,channels,block_frames; } home_capture_config;
int home_audio_open(const home_capture_config *,const char *device,home_audio_capture **);
/* 0 success, 1 timeout, negative error. timestamp is first sample in CLOCK_BOOTTIME
 * ns. Anchored sample counting avoids scheduler jitter; measured error is returned.
 * XRUNs/disconnects or clock error >100 ms fail explicitly; no silent recovery. */
int home_audio_read(home_audio_capture *,uint8_t *,uint32_t capacity_frames,uint32_t timeout_ms,uint32_t *frames,uint64_t *timestamp_ns,int64_t *clock_error_ns);
void home_audio_close(home_audio_capture *);
#endif
