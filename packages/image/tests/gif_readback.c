/* Test-only independent giflib sample/control readback. No production codec. */
#include <gif_lib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct {const uint8_t *data;size_t length,at;} Reader;
static void require(int ok,const char *why){if(!ok){fprintf(stderr,"giflib readback: %s\n",why);exit(1);}}
static int read_bytes(GifFileType *file,GifByteType *out,int wanted){
    Reader *r=file->UserData;if(wanted<0)return 0;size_t n=(size_t)wanted;if(n>r->length-r->at)n=r->length-r->at;
    memcpy(out,r->data+r->at,n);r->at+=n;return (int)n;
}
static GifFileType *open_image(Reader *reader,GraphicsControlBlock *control){
    int error=0;GifFileType *image=DGifOpen(reader,read_bytes,&error);require(image!=NULL,"open");
    require(DGifSlurp(image)==GIF_OK,"decode");require(image->ImageCount==1&&image->SWidth>0&&image->SHeight>0,"one still image");
    require((size_t)image->SWidth*image->SHeight<=64*1024*1024,"pixel cap");
    const GifImageDesc *desc=&image->SavedImages[0].ImageDesc;
    require(!desc->Left&&!desc->Top&&desc->Width==image->SWidth&&desc->Height==image->SHeight&&!desc->Interlace,"full noninterlaced rectangle");
    require(DGifSavedExtensionToGCB(image,0,control)==GIF_OK,"graphic control");return image;
}
static void pixel(const GifFileType *image,const GraphicsControlBlock *control,size_t at,uint8_t rgba[4]){
    const SavedImage *frame=&image->SavedImages[0];const ColorMapObject *map=frame->ImageDesc.ColorMap?frame->ImageDesc.ColorMap:image->SColorMap;
    require(map&&map->ColorCount>=2&&map->ColorCount<=256,"palette");const unsigned index=frame->RasterBits[at];require(index<(unsigned)map->ColorCount,"index");
    if((int)index==control->TransparentColor){memset(rgba,0,4);return;}
    const GifColorType c=map->Colors[index];rgba[0]=c.Red;rgba[1]=c.Green;rgba[2]=c.Blue;rgba[3]=255;
}
#ifdef HOME_GIF_FIXTURE
extern int home_gif_raster(uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint8_t **,size_t *);
extern void home_gif_free(uint8_t *,size_t);
static uint8_t value(size_t index,unsigned channel,unsigned mode){
    if(channel==3)return mode==2||mode==4?0:mode==1?(index%4==0?127:index%4==1?128:255):255;
    if(mode==3)return (uint8_t)(((index>>((2-channel)*4))&15)*17);
    const unsigned factor[3]={1,73,151};return (uint8_t)(index*factor[channel]);
}
static void check(unsigned format,unsigned bits,unsigned big,unsigned mode,unsigned width,unsigned height){
    uint8_t *encoded=NULL;size_t size=0;require(!home_gif_raster(format,bits,big,mode,width,height,&encoded,&size),"Home fixture");
    Reader reader={encoded,size,0};GraphicsControlBlock control;GifFileType *image=open_image(&reader,&control);
    require(image->SWidth==(int)width&&image->SHeight==(int)height,"geometry");require(control.DelayTime==0&&control.DisposalMode==0,"still controls");
    const int transparent=format==2&&(mode==1||mode==2);require((control.TransparentColor!=NO_TRANSPARENT_COLOR)==transparent,"transparency flag");
    for(size_t at=0;at<(size_t)width*height;at++){
        uint8_t rgba[4];pixel(image,&control,at,rgba);const int alpha=format==2&&mode!=4&&value(at,3,mode)<128?0:255;
        require(rgba[3]==alpha,"one-bit alpha");if(!alpha)continue;
        for(unsigned ch=0;ch<3;ch++){
            const uint8_t expected=value(at,format==0?0:ch,mode);const int delta=abs((int)rgba[ch]-expected);
            if(delta>(mode==3&&format!=0?34:0)){fprintf(stderr,"case format=%u bits=%u endian=%u mode=%u size=%ux%u pixel=%zu channel=%u actual=%u expected=%u\n",format,bits,big,mode,width,height,at,ch,rgba[ch],expected);exit(1);}
        }
    }
    int error=0;DGifCloseFile(image,&error);home_gif_free(encoded,size);
}
int main(void){
    const unsigned dimensions[][2]={{1,1},{2,1},{17,9},{257,1},{256,256}};unsigned cases=0;
    for(unsigned format=0;format<3;format++)for(unsigned bits=8;bits<=16;bits+=8)for(unsigned big=0;big<2;big++)for(unsigned mode=0;mode<5;mode++){
        if(mode==3){check(format,bits,big,mode,64,64);cases++;continue;}
        for(size_t i=0;i<sizeof(dimensions)/sizeof(dimensions[0]);i++){check(format,bits,big,mode,dimensions[i][0],dimensions[i][1]);cases++;}
    }
    printf("giflib validated %u Home raster GIF fixtures: samples, stride/endian, high-byte reduction, alpha and retired inputs\n",cases);return 0;
}
#else
static void output(uint32_t n){uint8_t data[4]={(uint8_t)(n>>24),(uint8_t)(n>>16),(uint8_t)(n>>8),(uint8_t)n};require(fwrite(data,1,4,stdout)==4,"stdout");}
int main(int argc,char **argv){
    require(argc==2,"usage: decode-gif file");FILE *file=fopen(argv[1],"rb");require(file!=NULL,"file");require(!fseek(file,0,SEEK_END),"seek");long size=ftell(file);require(size>=13&&(size_t)size<=256*1024*1024,"input cap");rewind(file);
    uint8_t *data=malloc((size_t)size);require(data!=NULL,"allocation");require(fread(data,1,(size_t)size,file)==(size_t)size,"read");fclose(file);
    Reader reader={data,(size_t)size,0};GraphicsControlBlock control;GifFileType *image=open_image(&reader,&control);
    require(fwrite("ZCGF",1,4,stdout)==4,"stdout");output((uint32_t)image->SWidth);output((uint32_t)image->SHeight);
    for(size_t at=0;at<(size_t)image->SWidth*image->SHeight;at++){uint8_t rgba[4];pixel(image,&control,at,rgba);require(fwrite(rgba,1,4,stdout)==4,"stdout");}
    int error=0;DGifCloseFile(image,&error);free(data);return 0;
}
#endif
