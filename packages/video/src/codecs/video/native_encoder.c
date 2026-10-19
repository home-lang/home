/* Home's header-checked x264/x265 adapter. No hand-declared vendor structures. */
#include "native_encoder.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <x264.h>
#include <x265.h>
struct home_encoder {
    uint32_t codec;
    x264_t *avc;
    x265_encoder *hevc;
    x265_param *param;
    x265_picture *in, *out;
    uint8_t *buffer;
    size_t capacity;
    uint32_t width, height;
    int force_key;
};
void home_encoder_close(home_encoder *e) {
    if (!e) return;
    if (e->avc) x264_encoder_close(e->avc);
    if (e->hevc) x265_encoder_close(e->hevc);
    if (e->in) x265_picture_free(e->in);
    if (e->out) x265_picture_free(e->out);
    if (e->param) x265_param_free(e->param);
    free(e->buffer); free(e);
}
int home_encoder_open(const home_encoder_config *c, home_encoder **out) {
    if (!out) return -1;
    *out=NULL;
    if (!c || (c->codec!=1 && c->codec!=2) || c->width<16 || c->height<16 || c->width>8192 || c->height>8192 || (c->width|c->height)&1 || !c->fps_num || !c->fps_den || c->fps_num>1000000 || c->fps_den>1000000 || c->quality<1 || c->quality>100 || c->gop>INT_MAX || (c->bitrate && c->bitrate<1000)) return -1;
    home_encoder *e=calloc(1,sizeof(*e));
    if (!e) return -2;
    e->codec=c->codec; e->width=c->width; e->height=c->height;
    /* Quality 1..100 -> CRF 51..0; AVC clamps at 1 to keep High-profile
     * compatibility (CRF0 requires High444 lossless). bitrate>0 selects ABR. */
    const double crf=51.0*(100-c->quality)/99.0;
    if (c->codec==1) {
        x264_param_t p;
        if (x264_param_default_preset(&p,"veryfast","zerolatency")<0) goto fail;
        p.i_width=(int)c->width; p.i_height=(int)c->height; p.i_csp=X264_CSP_I420;
        p.i_fps_num=c->fps_num; p.i_fps_den=c->fps_den;
        p.i_timebase_num=1; p.i_timebase_den=1000000; p.b_vfr_input=1;
        p.i_threads=1; p.i_bframe=0; p.rc.i_lookahead=0;
        p.i_keyint_max=c->gop ? (int)c->gop : 60; p.i_keyint_min=1; p.i_scenecut_threshold=0;
        p.b_open_gop=0; p.b_annexb=0; p.b_repeat_headers=0; p.i_log_level=X264_LOG_ERROR;
        p.vui.b_fullrange=0; p.vui.i_colorprim=1; p.vui.i_transfer=13; p.vui.i_colmatrix=6;
        p.rc.i_rc_method=c->bitrate ? X264_RC_ABR : X264_RC_CRF;
        p.rc.i_bitrate=(int)(c->bitrate/1000); p.rc.f_rf_constant=(float)(crf<1.0 ? 1.0 : crf);
        if (x264_param_apply_profile(&p,"high")<0) { x264_param_cleanup(&p); goto fail; }
        e->avc=x264_encoder_open(&p);
        x264_param_cleanup(&p);
        if (!e->avc) goto fail;
    } else {
        e->param=x265_param_alloc(); e->in=x265_picture_alloc(); e->out=x265_picture_alloc();
        if (!e->param || !e->in || !e->out) goto fail;
        x265_param *p=e->param;
        if (x265_param_default_preset(p,"veryfast","zerolatency")<0) goto fail;
        p->sourceWidth=(int)c->width; p->sourceHeight=(int)c->height;
        p->fpsNum=c->fps_num; p->fpsDenom=c->fps_den; p->internalCsp=X265_CSP_I420; p->internalBitDepth=8;
        p->bframes=0; p->lookaheadDepth=0; p->frameNumThreads=1;
        p->numaPools="none"; p->bEnableWavefront=0;
        p->keyframeMax=c->gop ? (int)c->gop : 60; p->keyframeMin=1; p->scenecutThreshold=0; p->bOpenGOP=0;
        p->bAnnexB=0; p->bRepeatHeaders=0; p->bEmitInfoSEI=0; p->logLevel=X265_LOG_ERROR;
        /* Fixed CTU sizes across instances avoid x265's process-global CTU conflict. */
        p->maxCUSize=16; p->minCUSize=8;
        p->vui.bEnableVideoSignalTypePresentFlag=1; p->vui.bEnableVideoFullRangeFlag=0;
        p->vui.bEnableColorDescriptionPresentFlag=1; p->vui.colorPrimaries=1;
        p->vui.transferCharacteristics=13; p->vui.matrixCoeffs=6;
        p->rc.rateControlMode=c->bitrate ? X265_RC_ABR : X265_RC_CRF;
        p->rc.bitrate=(int)(c->bitrate/1000); p->rc.rfConstant=crf;
        if (x265_param_apply_profile(p,"main")<0) goto fail;
        e->hevc=x265_encoder_open(p);
        if (!e->hevc) goto fail;
        x265_picture_init(p,e->in); x265_picture_init(p,e->out);
        e->in->bitDepth=8;
    }
    *out=e; return 0;
fail:
    home_encoder_close(e); return -3;
}
static int collect(home_encoder *e, x264_nal_t *a, x265_nal *h, uint32_t count, home_packet *out) {
    size_t total=0;
    for (uint32_t i=0;i<count;i++) {
        size_t n=a ? (size_t)a[i].i_payload : h[i].sizeBytes;
        if (n>SIZE_MAX-total) return -2;
        total+=n;
    }
    if (total>e->capacity) {
        uint8_t *p=realloc(e->buffer,total);
        if (!p) return -2;
        e->buffer=p; e->capacity=total;
    }
    size_t offset=0;
    for (uint32_t i=0;i<count;i++) {
        size_t n=a ? (size_t)a[i].i_payload : h[i].sizeBytes;
        memcpy(e->buffer+offset,a ? a[i].p_payload : h[i].payload,n); offset+=n;
    }
    out->data=e->buffer; out->size=total; return 0;
}
int home_encoder_headers(home_encoder *e, home_packet *out) {
    memset(out,0,sizeof(*out));
    if (e->avc) {
        x264_nal_t *nal=NULL; int n=0;
        if (x264_encoder_headers(e->avc,&nal,&n)<0 || n<=0) return -3;
        return collect(e,nal,NULL,(uint32_t)n,out);
    }
    x265_nal *nal=NULL; uint32_t n=0;
    if (x265_encoder_headers(e->hevc,&nal,&n)<0 || !n) return -3;
    return collect(e,NULL,nal,n,out);
}
int home_encoder_encode(home_encoder *e, const uint8_t *const planes[3], const int strides[3], int64_t pts, home_packet *out) {
    memset(out,0,sizeof(*out));
    if (!planes[0] || !planes[1] || !planes[2] || strides[0]<(int)e->width || strides[1]<(int)e->width/2 || strides[2]<(int)e->width/2) return -1;
    if (e->avc) {
        x264_picture_t in, decoded; x264_picture_init(&in); x264_picture_init(&decoded);
        in.i_type=e->force_key ? X264_TYPE_IDR : X264_TYPE_AUTO;
        e->force_key=0;
        in.img.i_csp=X264_CSP_I420; in.img.i_plane=3; in.i_pts=pts;
        for (int i=0;i<3;i++) { in.img.plane[i]=(uint8_t *)planes[i]; in.img.i_stride[i]=strides[i]; }
        x264_nal_t *nal=NULL; int n=0;
        int ret=x264_encoder_encode(e->avc,&nal,&n,&in,&decoded);
        if(ret<0) return -3;
        if(ret==0) return 0;
        out->pts=decoded.i_pts; out->key=decoded.b_keyframe;
        return collect(e,nal,NULL,(uint32_t)n,out);
    }
    for (int i=0;i<3;i++) { e->in->planes[i]=(void *)planes[i]; e->in->stride[i]=strides[i]; }
    e->in->pts=pts;
    e->in->sliceType=e->force_key ? X265_TYPE_IDR : X265_TYPE_AUTO;e->force_key=0;
    x265_nal *nal=NULL; uint32_t n=0;
    if (x265_encoder_encode(e->hevc,&nal,&n,e->in,e->out)<=0 || !n) return -3;
    out->pts=e->out->pts; out->key=IS_X265_TYPE_I(e->out->sliceType);
    return collect(e,NULL,nal,n,out);
}

int home_encoder_flush(home_encoder *e, home_packet *out) {
    memset(out,0,sizeof(*out));
    if(e->avc) {
        if(!x264_encoder_delayed_frames(e->avc)) return 0;
        x264_picture_t picture; x264_picture_init(&picture);
        x264_nal_t *nal=NULL; int n=0;
        int ret=x264_encoder_encode(e->avc,&nal,&n,NULL,&picture);
        if(ret<0) return -3;
        if(ret==0) return 0;
        out->pts=picture.i_pts;out->key=picture.b_keyframe;
        return collect(e,nal,NULL,(uint32_t)n,out);
    }
    x265_nal *nal=NULL;uint32_t n=0;
    int ret=x265_encoder_encode(e->hevc,&nal,&n,NULL,e->out);
    if(ret<0) return -3;
    if(ret==0) return 0;
    out->pts=e->out->pts;out->key=IS_X265_TYPE_I(e->out->sliceType);
    return collect(e,NULL,nal,n,out);
}

int home_encoder_request_keyframe(home_encoder *e) { if(!e)return -1;e->force_key=1;return 0; }
