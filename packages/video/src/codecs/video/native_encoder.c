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
    const home_encoder_color color={sizeof(home_encoder_color),1,13,6,0};
    return home_encoder_open_color(c,&color,out);
}
int home_encoder_open_color(const home_encoder_config *c, const home_encoder_color *color, home_encoder **out) {
    const home_encoder_options options={sizeof(home_encoder_options),0,0,0};
    return home_encoder_open_options(c,color,&options,out);
}
int home_encoder_open_options(const home_encoder_config *c, const home_encoder_color *color, const home_encoder_options *options, home_encoder **out) {
    const home_encoder_limits limits={sizeof(home_encoder_limits),0,0,0};
    return home_encoder_open_limits(c,color,options,&limits,out);
}
/* HEVC Main-tier level facts (samples, samples/sec, kbit/sec, kbit CPB),
 * cross-checked with the vendor's Annex A table:
 * https://github.com/videolan/x265/blob/master/source/encoder/level.cpp
 * Check with integer rational arithmetic before the vendor's floating-point
 * nominal-rate conversion, so extreme rates cannot wrap its u32 intermediate. */
static int hevc_level_fits(const home_encoder_config *c, const home_encoder_limits *limits) {
    static const struct { uint32_t id,picture,rate,bitrate,cpb; } levels[]={
        {10,36864,552960,128,350},{20,122880,3686400,1500,1500},
        {21,245760,7372800,3000,3000},{30,552960,16588800,6000,6000},
        {31,983040,33177600,10000,10000},{40,2228224,66846720,12000,12000},
        {41,2228224,133693440,20000,20000},{50,8912896,267386880,25000,25000},
        {51,8912896,534773760,40000,40000},{52,8912896,1069547520,60000,60000},
        {60,35651584,1069547520,60000,60000},{61,35651584,2139095040,120000,120000},
        {62,35651584,4278190080U,240000,240000}
    };
    if(!limits->level) return 1;
    /* x265 otherwise changes CTU16 to CTU32 for a >=5.0 request, conflicting
     * with other adapter instances. Higher ceilings can contain a <=4.1 stream;
     * they do not lift this adapter's existing shared-CTU geometry constraint. */
    const uint32_t effective=limits->level>=50 ? 41 : limits->level;
    for(size_t i=0;i<sizeof(levels)/sizeof(levels[0]);i++) if(levels[i].id==effective) {
        const uint64_t picture=(uint64_t)c->width*c->height;
        return picture<=levels[i].picture && (uint64_t)c->width*c->width<=8*(uint64_t)levels[i].picture &&
            (uint64_t)c->height*c->height<=8*(uint64_t)levels[i].picture &&
            picture*c->fps_num<=(uint64_t)levels[i].rate*c->fps_den &&
            c->bitrate<=(uint64_t)levels[i].bitrate*1000 && limits->max_bitrate<=(uint64_t)levels[i].bitrate*1000 &&
            limits->buffer_bits<=(uint64_t)levels[i].cpb*1000;
    }
    return 0;
}
static int valid_limits(const home_encoder_config *c, const home_encoder_options *options, const home_encoder_limits *limits) {
    if (!limits || limits->struct_size!=sizeof(*limits) || (!limits->max_bitrate)!=(!limits->buffer_bits) ||
        limits->max_bitrate%1000 || limits->buffer_bits%1000 ||
        (limits->max_bitrate && (options->qp || c->bitrate>limits->max_bitrate ||
            (uint64_t)limits->buffer_bits*c->fps_num<(uint64_t)limits->max_bitrate*c->fps_den)) ||
        (c->codec==2 && limits->level && options->qp)) return 0;
    if (!limits->level) return 1;
    if (c->codec==1) {
        switch(limits->level) { case 10:case 11:case 12:case 13:case 20:case 21:case 22:case 30:case 31:case 32:case 40:case 41:case 42:case 50:case 51:case 52:case 60:case 61:case 62:break;default:return 0; }
        for (const x264_level_t *l=x264_levels;l->level_idc;l++) if (l->level_idc==limits->level) return 1;
        return 0;
    }
    switch(limits->level) { case 10:case 20:case 21:case 30:case 31:case 40:case 41:case 50:case 51:case 52:case 60:case 61:case 62:break;default:return 0; }
    return hevc_level_fits(c,limits);
}
static int constrain_avc(x264_param_t *p, const home_encoder_config *c, const home_encoder_limits *limits) {
    if (!limits->level) return 1;
    const x264_level_t *l=x264_levels;
    while(l->level_idc && l->level_idc!=limits->level) l++;
    if(!l->level_idc) return 0;
    const uint64_t w=(c->width+15)/16,h=(c->height+15)/16,frame=w*h;
    if(frame>(uint64_t)l->frame_size || w*w>8*(uint64_t)l->frame_size || h*h>8*(uint64_t)l->frame_size ||
        frame*c->fps_num>(uint64_t)l->mbps*c->fps_den) return 0;
    const uint64_t factor=p->analyse.b_transform_8x8 ? 5 : 4;
    const uint64_t rate=(uint64_t)l->bitrate*1000*factor/4,buffer=(uint64_t)l->cpb*1000*factor/4;
    if(c->bitrate>rate || limits->max_bitrate>rate || limits->buffer_bits>buffer) return 0;
    int references=(int)((uint64_t)l->dpb/frame);
    if(references<1) return 0;
    if(p->i_frame_reference>references) p->i_frame_reference=references;
    if(p->i_dpb_size>references) p->i_dpb_size=references;
    if(p->analyse.i_mv_range>l->mv_range) p->analyse.i_mv_range=l->mv_range;
    /* A ceiling must not inflate a small stream to that level. Keep vendor
     * minimum-level selection, then enforce the ceiling on emitted SPS below. */
    p->i_level_idc=-1;
    return 1;
}
/* Vendor level requests are advisory on some versions. Validate the emitted
 * requirement before a handle/header can escape. Payloads include 4-byte lengths. */
static int level_fits(home_encoder *e, uint32_t level) {
    if (!level) return 1;
    if(e->avc) {
        x264_nal_t *nal=NULL;int n=0;
        if(x264_encoder_headers(e->avc,&nal,&n)<0) return 0;
        for(int i=0;i<n;i++) if(nal[i].i_payload>=8 && (nal[i].p_payload[4]&31)==7) {
            const unsigned actual=nal[i].p_payload[7];
            /* High-profile level 1b uses raw IDC 9 but exceeds level 1.0. */
            return actual==9 ? level>=11 : actual>0 && actual<=level;
        }
        return 0;
    }
    x265_nal *nal=NULL;uint32_t n=0;
    if(x265_encoder_headers(e->hevc,&nal,&n)<0) return 0;
    for(uint32_t i=0;i<n;i++) if(nal[i].sizeBytes>=7 && ((nal[i].payload[4]>>1)&63)==33) {
        uint8_t rbsp[13];size_t count=0;unsigned zeros=0;
        for(uint32_t at=6;at<nal[i].sizeBytes && count<sizeof(rbsp);at++) {
            const uint8_t byte=nal[i].payload[at];
            if(zeros>=2 && byte==3) { zeros=0;continue; }
            rbsp[count++]=byte;zeros=byte==0 ? zeros+1 : 0;
        }
        return count==sizeof(rbsp) && (rbsp[1]&31)==1 && !(rbsp[1]&32) && rbsp[12]>=30 && rbsp[12]<=level*3;
    }
    return 0;
}
int home_encoder_open_limits(const home_encoder_config *c, const home_encoder_color *color, const home_encoder_options *options, const home_encoder_limits *limits, home_encoder **out) {
    if (!out) return -1;
    *out=NULL;
    if (!color || color->struct_size!=sizeof(*color) ||
        (color->primaries!=1 && color->primaries!=6 && color->primaries!=9) ||
        (color->transfer!=1 && color->transfer!=8 && color->transfer!=13) ||
        (color->matrix!=1 && color->matrix!=6 && color->matrix!=9) || color->full_range>1) return -1;
    if (!c || (c->codec!=1 && c->codec!=2) || c->width<16 || c->height<16 || c->width>8192 || c->height>8192 || (c->width|c->height)&1 || !c->fps_num || !c->fps_den || c->fps_num>1000000 || c->fps_den>1000000 || c->quality<1 || c->quality>100 || c->gop>INT_MAX || (c->bitrate && c->bitrate<1000)) return -1;
    if (!options || options->struct_size!=sizeof(*options) || options->profile>4 || options->preset>9 || options->qp>51 ||
        (options->qp && c->bitrate) || (c->codec==2 && options->profile!=0 && options->profile!=2)) return -1;
    if (!valid_limits(c,options,limits)) return -1;
    static const char *const presets[]={"veryfast","ultrafast","superfast","faster","fast","medium","slow","slower","veryslow","placebo"};
    home_encoder *e=calloc(1,sizeof(*e));
    if (!e) return -2;
    e->codec=c->codec; e->width=c->width; e->height=c->height;
    /* Quality 1..100 -> CRF 51..0; AVC clamps at 1 to keep High-profile
     * compatibility (CRF0 requires High444 lossless). bitrate>0 selects ABR. */
    const double crf=51.0*(100-c->quality)/99.0;
    if (c->codec==1) {
        x264_param_t p;
        if (x264_param_default_preset(&p,presets[options->preset],"zerolatency")<0) goto fail;
        p.i_width=(int)c->width; p.i_height=(int)c->height; p.i_csp=X264_CSP_I420;
        p.i_fps_num=c->fps_num; p.i_fps_den=c->fps_den;
        p.i_timebase_num=1; p.i_timebase_den=1000000; p.b_vfr_input=1;
        p.i_threads=1; p.i_bframe=0; p.rc.i_lookahead=0;
        p.i_keyint_max=c->gop ? (int)c->gop : 60; p.i_keyint_min=1; p.i_scenecut_threshold=0;
        p.b_open_gop=0; p.b_annexb=0; p.b_repeat_headers=0; p.i_log_level=X264_LOG_ERROR;
        p.vui.b_fullrange=(int)color->full_range; p.vui.i_colorprim=(int)color->primaries;
        p.vui.i_transfer=(int)color->transfer; p.vui.i_colmatrix=(int)color->matrix;
        p.rc.i_rc_method=c->bitrate ? X264_RC_ABR : X264_RC_CRF;
        p.rc.i_bitrate=(int)(c->bitrate/1000); p.rc.f_rf_constant=(float)(crf<1.0 ? 1.0 : crf);
        if (options->qp) {
            p.rc.i_rc_method=X264_RC_CQP; p.rc.i_qp_constant=(int)options->qp;
            p.rc.f_ip_factor=1.0f; p.rc.f_pb_factor=1.0f; p.rc.i_aq_mode=0; p.rc.b_mb_tree=0;
        }
        const char *profile=(options->profile==1 || options->profile==4) ? "baseline" : options->profile==2 ? "main" : "high";
        if (x264_param_apply_profile(&p,profile)<0) { x264_param_cleanup(&p); goto fail; }
        if(!constrain_avc(&p,c,limits)) { x264_param_cleanup(&p);goto invalid; }
        p.rc.i_vbv_max_bitrate=(int)(limits->max_bitrate/1000);p.rc.i_vbv_buffer_size=(int)(limits->buffer_bits/1000);
        e->avc=x264_encoder_open(&p);
        x264_param_cleanup(&p);
        if (!e->avc) goto fail;
    } else {
        e->param=x265_param_alloc(); e->in=x265_picture_alloc(); e->out=x265_picture_alloc();
        if (!e->param || !e->in || !e->out) goto fail;
        x265_param *p=e->param;
        if (x265_param_default_preset(p,presets[options->preset],"zerolatency")<0) goto fail;
        p->sourceWidth=(int)c->width; p->sourceHeight=(int)c->height;
        p->fpsNum=c->fps_num; p->fpsDenom=c->fps_den; p->internalCsp=X265_CSP_I420; p->internalBitDepth=8;
        p->bframes=0; p->lookaheadDepth=0; p->frameNumThreads=1;
        p->numaPools="none"; p->bEnableWavefront=0;
        p->keyframeMax=c->gop ? (int)c->gop : 60; p->keyframeMin=1; p->scenecutThreshold=0; p->bOpenGOP=0;
        p->bAnnexB=0; p->bRepeatHeaders=0; p->bEmitInfoSEI=0; p->logLevel=X265_LOG_ERROR;
        /* Fixed CTU sizes across instances avoid x265's process-global CTU conflict. */
        p->maxCUSize=16; p->minCUSize=8;
        /* Slow presets assume larger CTUs. Keep transform depth valid for the
         * fixed CTU16 shared-instance policy (log2(16)-log2(4)+1 == 3). */
        if (p->tuQTMaxInterDepth>3) p->tuQTMaxInterDepth=3;
        if (p->tuQTMaxIntraDepth>3) p->tuQTMaxIntraDepth=3;
        p->vui.bEnableVideoSignalTypePresentFlag=1; p->vui.bEnableVideoFullRangeFlag=(int)color->full_range;
        p->vui.bEnableColorDescriptionPresentFlag=1; p->vui.colorPrimaries=(int)color->primaries;
        p->vui.transferCharacteristics=(int)color->transfer; p->vui.matrixCoeffs=(int)color->matrix;
        p->rc.rateControlMode=c->bitrate ? X265_RC_ABR : X265_RC_CRF;
        p->rc.bitrate=(int)(c->bitrate/1000); p->rc.rfConstant=crf;
        if (options->qp) {
            p->rc.rateControlMode=X265_RC_CQP; p->rc.qp=(int)options->qp;
            p->rc.ipFactor=1.0; p->rc.pbFactor=1.0; p->rc.aqMode=0; p->rc.cuTree=0;
        }
        if (x265_param_apply_profile(p,"main")<0) goto fail;
        p->levelIdc=(int)(limits->level>=50 ? 41 : limits->level);p->bHighTier=0;p->bAllowNonConformance=0;
        p->rc.vbvMaxBitrate=(int)(limits->max_bitrate/1000);p->rc.vbvBufferSize=(int)(limits->buffer_bits/1000);
        e->hevc=x265_encoder_open(p);
        if (!e->hevc) goto fail;
        x265_picture_init(p,e->in); x265_picture_init(p,e->out);
        e->in->bitDepth=8;
    }
    if(!level_fits(e,limits->level)) goto invalid;
    *out=e; return 0;
invalid:
    home_encoder_close(e);return -1;
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
