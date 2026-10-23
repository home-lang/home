/* Independent giflib readback of native Home LZW bytes in a GIF container. */
#include <gif_lib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
extern int home_gif_lzw(const uint8_t *,size_t,uint8_t,uint8_t *,size_t,size_t *);
struct Reader {const uint8_t *data;size_t length,at;};
static int read_bytes(GifFileType *file,GifByteType *out,int wanted){
    struct Reader *r=file->UserData;if(wanted<0)return 0;
    size_t n=(size_t)wanted;if(n>r->length-r->at)n=r->length-r->at;
    memcpy(out,r->data+r->at,n);r->at+=n;return (int)n;
}
static void put16(uint8_t *out,size_t *at,unsigned value){out[(*at)++]=(uint8_t)value;out[(*at)++]=(uint8_t)(value>>8);}
static int check(unsigned minimum,size_t count,unsigned pattern){
    uint8_t *pixels=malloc(count),*compressed=malloc(count*2+1024);if(!pixels||!compressed)return 2;
    uint32_t seed=0x7ac0ffee;const unsigned mask=(1u<<minimum)-1;
    for(size_t i=0;i<count;i++){seed=seed*1664525u+1013904223u;pixels[i]=(uint8_t)((pattern==0?0:pattern==1?(unsigned)(i%4):seed>>24)&mask);}
    size_t length=0;if(home_gif_lzw(pixels,count,(uint8_t)minimum,compressed,count*2+1024,&length))return 3;
    size_t capacity=length+length/255+2048,at=0;uint8_t *gif=malloc(capacity);if(!gif)return 4;
    const unsigned width=count>65535?256:(unsigned)count,height=count>65535?(unsigned)(count/256):1;
    memcpy(gif,"GIF89a",6);at=6;put16(gif,&at,width);put16(gif,&at,height);
    gif[at++]=(uint8_t)(0x80|0x70|(minimum-1));gif[at++]=0;gif[at++]=0;
    for(unsigned i=0;i<=mask;i++){gif[at++]=(uint8_t)i;gif[at++]=(uint8_t)i;gif[at++]=(uint8_t)i;}
    gif[at++]=0x2c;put16(gif,&at,0);put16(gif,&at,0);put16(gif,&at,width);put16(gif,&at,height);gif[at++]=0;gif[at++]=(uint8_t)minimum;
    for(size_t p=0;p<length;){const size_t n=length-p>255?255:length-p;gif[at++]=(uint8_t)n;memcpy(gif+at,compressed+p,n);at+=n;p+=n;}
    gif[at++]=0;gif[at++]=0x3b;
    struct Reader reader={gif,at,0};int error=0;GifFileType *image=DGifOpen(&reader,read_bytes,&error);
    if(!image||DGifSlurp(image)!=GIF_OK){fprintf(stderr,"giflib failed minimum=%u length=%zu pattern=%u error=%d\n",minimum,count,pattern,image?image->Error:error);return 5;}
    if(image->ImageCount!=1||image->SWidth!=(int)width||image->SHeight!=(int)height||memcmp(image->SavedImages[0].RasterBits,pixels,count)){fprintf(stderr,"GIF mismatch minimum=%u length=%zu pattern=%u\n",minimum,count,pattern);return 6;}
    if(pattern==0&&count==1048576&&length>=count/32){fprintf(stderr,"repeated pixels were not dictionary compressed\n");return 7;}
    DGifCloseFile(image,&error);free(gif);free(compressed);free(pixels);return 0;
}
#ifdef HOME_VIDEO_GIF
extern int home_video_gif(const uint8_t *,size_t,uint16_t,uint16_t,uint8_t *,size_t,size_t *);
static void video_color(uint8_t out[3],unsigned frame,size_t pixel,unsigned pattern){
    const uint8_t colors[2][2][3]={{{255,0,0},{0,0,255}},{{0,255,0},{0,0,0}}};
    if(!pattern){memcpy(out,colors[frame][pixel%2],3);return;}
    if(pattern==2){
        const unsigned value=(unsigned)(pixel+frame*37)%4096;
        out[0]=(uint8_t)(((value>>8)&15)*17);out[1]=(uint8_t)(((value>>4)&15)*17);out[2]=(uint8_t)((value&15)*17);return;
    }
    /* 256 exact, equal-frequency hues; never collapse them by luminance or
     * by 5-bit histogram cells when the requested palette can represent all. */
    const unsigned value=(unsigned)(pixel+frame*37)%256;
    out[0]=(uint8_t)value;out[1]=(uint8_t)(value*73);out[2]=(uint8_t)(value*151);
}
static int check_video(unsigned width,unsigned height,unsigned pattern){
    const size_t pixels=(size_t)width*height,frame_bytes=pixels*3;
    const size_t capacity=frame_bytes*2+8192;uint8_t *input=malloc(frame_bytes*2),*output=malloc(capacity);if(!input||!output)return 10;
    for(unsigned frame=0;frame<2;frame++)for(size_t p=0;p<pixels;p++)video_color(input+frame*frame_bytes+p*3,frame,p,pattern);
    size_t written=0;int code=home_video_gif(input,frame_bytes*2,(uint16_t)width,(uint16_t)height,output,capacity,&written);
    if(code){fprintf(stderr,"video GIF fixture failed code=%d\n",code);return 11;}
    memset(input,0x7f,frame_bytes*2); /* no input or writer owner remains */
    struct Reader reader={output,written,0};int error=0;GifFileType *image=DGifOpen(&reader,read_bytes,&error);
    if(!image||DGifSlurp(image)!=GIF_OK||image->ImageCount!=2||image->SWidth!=(int)width||image->SHeight!=(int)height)return 12;
    for(unsigned frame=0;frame<2;frame++){
        SavedImage *saved=&image->SavedImages[frame];GraphicsControlBlock control;
        if(DGifSavedExtensionToGCB(image,(int)frame,&control)!=GIF_OK||control.DelayTime!=(int)((frame+1)*10)||control.DisposalMode!=2||control.TransparentColor!=NO_TRANSPARENT_COLOR)return 13;
        const ColorMapObject *map=saved->ImageDesc.ColorMap;
        if(!map||map->ColorCount!=256)return 14;
        for(size_t p=0;p<pixels;p++){
            const GifColorType c=map->Colors[saved->RasterBits[p]];uint8_t wanted[3];video_color(wanted,frame,p,pattern);
            const int tolerance=pattern==2?34:0;
            if(abs((int)c.Red-wanted[0])>tolerance||abs((int)c.Green-wanted[1])>tolerance||abs((int)c.Blue-wanted[2])>tolerance)return 15;
        }
    }
    DGifCloseFile(image,&error);free(output);free(input);
    printf("giflib decoded Home video GIF %ux%u pattern=%u, local palettes, disposal and delays; channel bound=%u\n",width,height,pattern,pattern==2?34:0);return 0;
}
#endif
int main(void){
    const size_t sizes[]={1,2,3,17,254,255,256,257,511,512,513,1023,1024,4095,4096,65536,1048576};
    unsigned cases=0;for(unsigned minimum=2;minimum<=8;minimum++)for(unsigned p=0;p<3;p++)for(size_t i=0;i<sizeof(sizes)/sizeof(sizes[0]);i++){int result=check(minimum,sizes[i],p);if(result)return result;cases++;}
    printf("giflib decoded %u Home LZW fixtures exactly across code widths, dictionary resets and large images\n",cases);
#ifdef HOME_VIDEO_GIF
    const unsigned dimensions[][2]={{1,1},{17,9},{257,1},{256,256},{256,4096}};
    for(unsigned pattern=0;pattern<2;pattern++)for(size_t i=0;i<sizeof(dimensions)/sizeof(dimensions[0]);i++){int result=check_video(dimensions[i][0],dimensions[i][1],pattern);if(result)return result;}
    {int result=check_video(64,64,2);if(result)return result;}
    return 0;
#else
    return 0;
#endif
}
