/* Home header-checked, bounded AAC-LC adapter. No FFmpeg/Libav. */
#include "native_aac.h"
/* FDK publishes unused static helpers in its public C header. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#include <fdk-aac/aacenc_lib.h>
#pragma GCC diagnostic pop
#include <stdlib.h>
#include <string.h>
_Static_assert(sizeof(INT_PCM)==2,"FDK must use 16-bit input samples");
struct home_aac { HANDLE_AACENCODER codec;uint32_t channels;int draining,ended,failed; };
void home_aac_close(home_aac *s) {
    if(!s)return;
    if(s->codec)aacEncClose(&s->codec);
    free(s);
}
int home_aac_open(const home_aac_config *cfg,home_aac **out,home_aac_info *info) {
    if(!out || !info)return -1;
    *out=NULL;memset(info,0,sizeof(*info));
    if(!cfg || cfg->channels<1 || cfg->channels>2 || cfg->bitrate<16000 || cfg->bitrate>320000)return -1;
    switch(cfg->sample_rate) {case 8000:case 11025:case 12000:case 16000:case 22050:case 24000:case 32000:case 44100:case 48000:break;default:return -1;}
    home_aac *s=calloc(1,sizeof(*s));if(!s)return -2;
    s->channels=cfg->channels;
    if(aacEncOpen(&s->codec,1,cfg->channels)!=AACENC_OK)goto fail;
    if(aacEncoder_SetParam(s->codec,AACENC_AOT,2)!=AACENC_OK ||
       aacEncoder_SetParam(s->codec,AACENC_SAMPLERATE,cfg->sample_rate)!=AACENC_OK ||
       aacEncoder_SetParam(s->codec,AACENC_CHANNELMODE,cfg->channels==1?MODE_1:MODE_2)!=AACENC_OK ||
       aacEncoder_SetParam(s->codec,AACENC_CHANNELORDER,1)!=AACENC_OK ||
       aacEncoder_SetParam(s->codec,AACENC_BITRATE,cfg->bitrate)!=AACENC_OK ||
       aacEncoder_SetParam(s->codec,AACENC_TRANSMUX,TT_MP4_RAW)!=AACENC_OK ||
       aacEncoder_SetParam(s->codec,AACENC_AFTERBURNER,1)!=AACENC_OK ||
       aacEncEncode(s->codec,NULL,NULL,NULL,NULL)!=AACENC_OK)goto fail;
    AACENC_InfoStruct native={0};
    if(aacEncInfo(s->codec,&native)!=AACENC_OK || native.frameLength!=1024 || native.confSize!=2 || native.maxOutBufBytes>8192 || native.inputChannels!=cfg->channels || native.nDelay>16384)goto fail;
    info->frame_length=native.frameLength;info->delay=native.nDelay;info->config_size=native.confSize;
    memcpy(info->config,native.confBuf,native.confSize);*out=s;return 0;
fail:
    home_aac_close(s);return -3;
}
static int run(home_aac *s,const uint8_t *pcm,uint32_t frames,int flush,uint8_t *data,uint32_t capacity,uint32_t *bytes,uint32_t *consumed) {
    if(!s || !data || !bytes || !consumed || capacity<8192 || capacity>0x7fffffff || (!flush && (!pcm || !frames || frames>1024)))return -1;
    *bytes=0;*consumed=0;
    if(s->failed || (!flush && s->draining))return -3;
    if(s->ended)return 1;
    INT_PCM samples[2048];
    if(!flush)for(uint32_t i=0;i<frames*s->channels;i++) {
        uint16_t value=(uint16_t)pcm[2*i]|(uint16_t)((uint16_t)pcm[2*i+1]<<8);
        memcpy(&samples[i],&value,2);
    }
    void *input=samples,*output=data;
    INT input_id=IN_AUDIO_DATA,output_id=OUT_BITSTREAM_DATA;
    INT input_size=(INT)(frames*s->channels*2),output_size=(INT)capacity,input_element=2,output_element=1;
    AACENC_BufDesc in={1,&input,&input_id,&input_size,&input_element};
    AACENC_BufDesc out={1,&output,&output_id,&output_size,&output_element};
    AACENC_InArgs args={0};AACENC_OutArgs result={0};
    args.numInSamples=flush?-1:(INT)(frames*s->channels);
    if(flush)s->draining=1;
    AACENC_ERROR error=aacEncEncode(s->codec,&in,&out,&args,&result);
    if(error==AACENC_ENCODE_EOF){s->ended=1;return 1;}
    if(error!=AACENC_OK || result.numOutBytes<0 || result.numOutBytes>(INT)capacity || result.numInSamples<0 || (!flush && ((uint32_t)result.numInSamples>frames*s->channels || (uint32_t)result.numInSamples%s->channels))) {s->failed=1;return -3;}
    *bytes=(uint32_t)result.numOutBytes;*consumed=(uint32_t)result.numInSamples/s->channels;
    if(!flush && !*bytes && !*consumed){s->failed=1;return -3;}
    return 0;
}
int home_aac_encode(home_aac *s,const uint8_t *pcm,uint32_t frames,uint8_t *data,uint32_t capacity,uint32_t *bytes,uint32_t *consumed) {return run(s,pcm,frames,0,data,capacity,bytes,consumed);}
int home_aac_flush(home_aac *s,uint8_t *data,uint32_t capacity,uint32_t *bytes) {uint32_t consumed=0;return run(s,NULL,0,1,data,capacity,bytes,&consumed);}
