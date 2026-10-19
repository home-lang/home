/* Home AAC-LC adapter, MIT. FDK AAC is an optional separately licensed codec. */
#ifndef HOME_NATIVE_AAC_H
#define HOME_NATIVE_AAC_H
#include <stdint.h>
typedef struct home_aac home_aac;
typedef struct { uint32_t sample_rate,channels,bitrate; } home_aac_config;
typedef struct { uint32_t frame_length,delay,config_size;uint8_t config[64]; } home_aac_info;
int home_aac_open(const home_aac_config *,home_aac **,home_aac_info *);
/* S16LE interleaved PCM; <=1024 frames/call. Output is raw AAC, not ADTS.
 * 0 success, negative invalid/allocation/codec error. No implicit partial drop. */
int home_aac_encode(home_aac *,const uint8_t *,uint32_t frames,uint8_t *,uint32_t capacity,uint32_t *bytes,uint32_t *consumed);
/* 1 EOF, 0 progress. Drain until EOF, then close. Never encode after draining. */
int home_aac_flush(home_aac *,uint8_t *,uint32_t capacity,uint32_t *bytes);
void home_aac_close(home_aac *);
#endif
