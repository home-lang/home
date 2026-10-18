/* Header-checked Linux ALSA input. No subprocess, FFmpeg or unbounded queue. */
#define _POSIX_C_SOURCE 200809L
#include "native_capture.h"
#include <alsa/asoundlib.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
#include <limits.h>
struct home_audio_capture {
    snd_pcm_t *pcm;
    snd_pcm_status_t *status;
    home_capture_config config;
    snd_pcm_uframes_t buffer_frames;
    uint64_t anchor,samples;
    int started,anchored;
};
static uint64_t now_ns(clockid_t clock) {
    struct timespec ts;if(clock_gettime(clock,&ts)!=0)return 0;
    return (uint64_t)ts.tv_sec*1000000000u+(uint64_t)ts.tv_nsec;
}
void home_audio_close(home_audio_capture *s) {
    if(!s)return;
    if(s->pcm){snd_pcm_drop(s->pcm);snd_pcm_close(s->pcm);}
    if(s->status)snd_pcm_status_free(s->status);
    free(s);
}
int home_audio_open(const home_capture_config *cfg,const char *device,home_audio_capture **out) {
    if(!out)return -1;
    *out=NULL;
    if(!cfg || !device || !device[0] || cfg->sample_rate<8000 || cfg->sample_rate>192000 || cfg->channels<1 || cfg->channels>2 || cfg->block_frames<1 || cfg->block_frames>4096)return -1;
    home_audio_capture *s=calloc(1,sizeof(*s));if(!s)return -2;s->config=*cfg;
    snd_pcm_hw_params_t *hw=NULL;snd_pcm_sw_params_t *sw=NULL;
    if(snd_pcm_open(&s->pcm,device,SND_PCM_STREAM_CAPTURE,SND_PCM_NONBLOCK)<0)goto fail;
    if(snd_pcm_hw_params_malloc(&hw)<0 || snd_pcm_sw_params_malloc(&sw)<0 || snd_pcm_status_malloc(&s->status)<0)goto fail;
    snd_pcm_uframes_t period=cfg->block_frames,buffer=cfg->sample_rate/5;
    if(snd_pcm_hw_params_any(s->pcm,hw)<0 || snd_pcm_hw_params_set_access(s->pcm,hw,SND_PCM_ACCESS_RW_INTERLEAVED)<0 || snd_pcm_hw_params_set_format(s->pcm,hw,SND_PCM_FORMAT_S16_LE)<0 || snd_pcm_hw_params_set_channels(s->pcm,hw,cfg->channels)<0 || snd_pcm_hw_params_set_rate(s->pcm,hw,cfg->sample_rate,0)<0 || snd_pcm_hw_params_set_period_size_near(s->pcm,hw,&period,NULL)<0 || snd_pcm_hw_params_set_buffer_size_near(s->pcm,hw,&buffer)<0 || snd_pcm_hw_params(s->pcm,hw)<0)goto fail;
    s->buffer_frames=buffer;
    if(snd_pcm_sw_params_current(s->pcm,sw)<0 || snd_pcm_sw_params_set_tstamp_mode(s->pcm,sw,SND_PCM_TSTAMP_ENABLE)<0 || snd_pcm_sw_params_set_tstamp_type(s->pcm,sw,SND_PCM_TSTAMP_TYPE_MONOTONIC)<0 || snd_pcm_sw_params(s->pcm,sw)<0 || snd_pcm_prepare(s->pcm)<0)goto fail;
    snd_pcm_hw_params_free(hw);snd_pcm_sw_params_free(sw);*out=s;return 0;
fail:
    if(hw)snd_pcm_hw_params_free(hw);
    if(sw)snd_pcm_sw_params_free(sw);
    home_audio_close(s);return -3;
}
int home_audio_read(home_audio_capture *s,uint8_t *data,uint32_t capacity,uint32_t timeout_ms,uint32_t *frames,uint64_t *timestamp,int64_t *error_ns) {
    if(!s || !data || !frames || !timestamp || !error_ns || capacity<s->config.block_frames || timeout_ms>1000)return -1;
    *frames=0;*timestamp=0;*error_ns=0;
    if(!s->started){if(snd_pcm_start(s->pcm)<0)return -3;s->started=1;}
    const uint64_t deadline=now_ns(CLOCK_MONOTONIC)+(uint64_t)timeout_ms*1000000;
    snd_pcm_sframes_t n;
    for(;;) {
        n=snd_pcm_readi(s->pcm,data,s->config.block_frames);
        if(n>0)break;
        if(n<0 && n!=-EAGAIN && n!=-EINTR)return -3;
        uint64_t now=now_ns(CLOCK_MONOTONIC);if(now>=deadline)return 1;
        int wait=(int)((deadline-now+999999)/1000000);
        int rc=snd_pcm_wait(s->pcm,wait);if(rc<0 && rc!=-EINTR)return -3;
        if(rc==0)return 1;
    }
    if(snd_pcm_status(s->pcm,s->status)<0 || snd_pcm_status_get_state(s->status)!=SND_PCM_STATE_RUNNING)return -3;
    snd_htimestamp_t stamp;snd_pcm_status_get_htstamp(s->status,&stamp);
    const uint64_t mono=now_ns(CLOCK_MONOTONIC),boot=now_ns(CLOCK_BOOTTIME);
    const snd_pcm_uframes_t available=snd_pcm_status_get_avail(s->status);
    if(!mono || boot<mono || available>s->buffer_frames)return -3;
    const uint64_t status_ns=(uint64_t)stamp.tv_sec*1000000000u+(uint64_t)stamp.tv_nsec;
    const uint64_t backlog=((uint64_t)available+(uint64_t)n)*1000000000u/s->config.sample_rate;
    if(status_ns<backlog)return -3;
    const uint64_t measured=status_ns-backlog+(boot-mono);
    if(!s->anchored){s->anchor=measured;s->anchored=1;}
    __uint128_t value=(__uint128_t)s->anchor+(__uint128_t)s->samples*1000000000u/s->config.sample_rate;
    if(value>UINT64_MAX || s->samples>UINT64_MAX-(uint64_t)n)return -3;
    const uint64_t nominal=(uint64_t)value;
    uint64_t delta=measured>nominal ? measured-nominal : nominal-measured;
    if(delta>100000000u)return -3;
    *error_ns=measured>=nominal ? (int64_t)delta : -(int64_t)delta;
    *timestamp=nominal;*frames=(uint32_t)n;s->samples+=(uint64_t)n;return 0;
}
