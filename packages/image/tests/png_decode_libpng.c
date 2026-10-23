/* Independent libpng writer, expected native sample reference, no Home encoder. */
#include <png.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern int home_png_decode(const uint8_t *,size_t,uint8_t **,size_t *,uint32_t *,uint32_t *,uint32_t *,uint32_t *);
extern void home_png_free(uint8_t *,size_t);
struct buffer { uint8_t *data; size_t size; };
static void write_bytes(png_structp png,png_bytep data,png_size_t count) {
    struct buffer *b=png_get_io_ptr(png);
    uint8_t *p=realloc(b->data,b->size+count);
    if (!p) png_error(png,"allocation");
    memcpy(p+b->size,data,count); b->data=p; b->size+=count;
}
static void flush_bytes(png_structp png) { (void)png; }
static unsigned sample(unsigned x,unsigned y,unsigned ch,unsigned depth) {
    /* Equal high bytes with different low words make tRNS precision observable. */
    return depth==16 ? (0x1200u+((x*17+y*43+ch*71)&255)) : ((x*37+y*53+ch*79)&((1u<<depth)-1));
}
static int run(unsigned color,unsigned depth,unsigned width,unsigned height,unsigned interlace,int filter,unsigned trns) {
    png_structp png=png_create_write_struct(PNG_LIBPNG_VER_STRING,NULL,NULL,NULL);
    png_infop info=png_create_info_struct(png);
    struct buffer b={0};
    if (!png||!info) return 1;
    if (setjmp(png_jmpbuf(png))) { free(b.data); png_destroy_write_struct(&png,&info); return 2; }
    png_set_write_fn(png,&b,write_bytes,flush_bytes);
    png_set_IHDR(png,info,width,height,depth,color,interlace?PNG_INTERLACE_ADAM7:PNG_INTERLACE_NONE,PNG_COMPRESSION_TYPE_BASE,PNG_FILTER_TYPE_BASE);
    png_set_filter(png,PNG_FILTER_TYPE_BASE,filter);
    png_color palette[256]; png_byte alpha[256];
    unsigned count=depth<8?(1u<<depth):256;
    if (color==PNG_COLOR_TYPE_PALETTE) {
        for(unsigned i=0;i<count;i++) { palette[i]=(png_color){(uint8_t)(i*37),(uint8_t)(i*79),(uint8_t)(i*113)}; alpha[i]=(uint8_t)(i*59); }
        png_set_PLTE(png,info,palette,(int)count);
        if(trns) png_set_tRNS(png,info,alpha,(int)count,NULL);
    }
    png_color_16 key={0}; key.gray=(png_uint_16)sample(0,0,0,depth); key.red=key.gray; key.green=(png_uint_16)sample(0,0,1,depth); key.blue=(png_uint_16)sample(0,0,2,depth);
    if(trns&&color!=PNG_COLOR_TYPE_PALETTE) png_set_tRNS(png,info,NULL,0,&key);
    unsigned channels=color==0||color==3?1:color==2?3:color==4?2:4;
    size_t row=((size_t)width*channels*depth+7)/8;
    uint8_t *source=calloc(height,row); png_bytep *rows=malloc(height*sizeof(*rows));
    if(!source||!rows) abort();
    for(unsigned y=0;y<height;y++) {
        rows[y]=source+y*row;
        for(unsigned x=0;x<width;x++) for(unsigned ch=0;ch<channels;ch++) {
            unsigned v=sample(x,y,ch,depth); size_t i=(size_t)x*channels+ch;
            if(depth<8) rows[y][i*depth/8]|=(uint8_t)(v<<(8-depth-(i*depth)%8));
            else if(depth==8) rows[y][i]=(uint8_t)v;
            else { rows[y][i*2]=(uint8_t)(v>>8); rows[y][i*2+1]=(uint8_t)v; }
        }
    }
    png_write_info(png,info); png_write_image(png,rows); png_write_end(png,info);
    png_destroy_write_struct(&png,&info); memset(source,0xee,height*row); free(source); free(rows);
    uint8_t *pixels=NULL; size_t size=0; uint32_t w=0,h=0,format=0,bits=0;
    int rc=home_png_decode(b.data,b.size,&pixels,&size,&w,&h,&format,&bits);
    memset(b.data,0xaa,b.size); free(b.data);
    unsigned out_channels=color==0&&!trns?1:color==2&&!trns?3:4;
    unsigned out_bits=depth==16?16:8;
    if(rc||w!=width||h!=height||format!=(out_channels==1?0:out_channels==3?1:2)||bits!=out_bits||size!=(size_t)width*height*out_channels*(out_bits/8)) return 3;
    for(unsigned y=0;y<height;y++) for(unsigned x=0;x<width;x++) {
        unsigned values[4]={0,0,0,out_bits==16?65535:255};
        if(color==3) {
            unsigned index=sample(x,y,0,depth);
            values[0]=palette[index].red; values[1]=palette[index].green; values[2]=palette[index].blue;
            values[3]=trns?alpha[index]:255;
        } else if(color==0||color==4) {
            unsigned v=sample(x,y,0,depth);
            values[0]=values[1]=values[2]=depth<8?v*255/((1u<<depth)-1):v;
            if(color==4) values[3]=sample(x,y,1,depth); else if(trns&&v==key.gray) values[3]=0;
        } else {
            for(unsigned ch=0;ch<3;ch++) values[ch]=sample(x,y,ch,depth);
            if(color==6) values[3]=sample(x,y,3,depth); else if(trns&&values[0]==key.red&&values[1]==key.green&&values[2]==key.blue) values[3]=0;
        }
        for(unsigned ch=0;ch<out_channels;ch++) {
            size_t at=((size_t)y*width*out_channels+x*out_channels+ch)*(out_bits/8);
            unsigned actual=out_bits==8?pixels[at]:pixels[at]|((unsigned)pixels[at+1]<<8);
            if(actual!=values[ch]) { fprintf(stderr,"sample mismatch color=%u depth=%u interlace=%u trns=%u x=%u y=%u ch=%u got=%u expected=%u\n",color,depth,interlace,trns,x,y,ch,actual,values[ch]); home_png_free(pixels,size); return 4; }
        }
    }
    home_png_free(pixels,size); return 0;
}
int main(void) {
    const unsigned colors[]={0,2,3,4,6},depths[]={1,2,4,8,16};
    const int filters[]={PNG_FILTER_NONE,PNG_FILTER_SUB,PNG_FILTER_UP,PNG_FILTER_AVG,PNG_FILTER_PAETH,PNG_ALL_FILTERS};
    unsigned cases=0;
    for(unsigned c=0;c<5;c++) for(unsigned d=0;d<5;d++) {
        unsigned color=colors[c],depth=depths[d];
        if((color==3&&depth==16)||((color==2||color==4||color==6)&&depth<8)) continue;
        for(unsigned interlace=0;interlace<2;interlace++) for(unsigned f=0;f<6;f++) for(unsigned small=0;small<3;small++) for(unsigned trns=0;trns<(color==4||color==6?1u:2u);trns++) {
            unsigned width=small==0?17:small==1?1:2,height=small==0?13:small==1?1:3;
            int rc=run(color,depth,width,height,interlace,filters[f],trns);
            if(rc) { fprintf(stderr,"PNG independent failure %d color=%u depth=%u %ux%u interlace=%u filter=%d trns=%u\n",rc,color,depth,width,height,interlace,filters[f],trns); return rc; }
            cases++;
        }
    }
    printf("%u independent libpng PNG decode cases passed\n",cases); return 0;
}
