/* Independent forward-coordinate and sample reference after Zig source retirement. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
extern int home_pixel_orient(uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint8_t **,size_t *,uint32_t *,uint32_t *);
extern void home_orient_free(uint8_t *,size_t);
int main(void){
    const unsigned dims[][2]={{1,1},{5,3},{1,4},{3,1},{64,65}};unsigned cases=0;
    for(unsigned format=0;format<3;format++)for(unsigned bits=8;bits<=16;bits+=8)for(unsigned big=0;big<2;big++)
    for(unsigned orientation=1;orientation<=8;orientation++)for(unsigned d=0;d<5;d++){
        const unsigned w=dims[d][0],h=dims[d][1],channels=format==0?1:format==1?3:4;
        uint8_t *output=NULL;size_t length=0;uint32_t ow=0,oh=0;
        if(home_pixel_orient(format,bits,big,orientation,w,h,&output,&length,&ow,&oh)||!output)return 1;
        if(ow!=(orientation>=5?h:w)||oh!=(orientation>=5?w:h)||length!=(size_t)ow*oh*channels*(bits/8))return 2;
        for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++)for(unsigned ch=0;ch<channels;ch++){
            unsigned dx=x,dy=y;
            switch(orientation){case 2:dx=w-1-x;break;case 3:dx=w-1-x;dy=h-1-y;break;case 4:dy=h-1-y;break;case 5:dx=y;dy=x;break;case 6:dx=y;dy=w-1-x;break;case 7:dx=h-1-y;dy=w-1-x;break;case 8:dx=h-1-y;dy=x;break;}
            const uint8_t hi=(uint8_t)(x*37+y*53+ch*79+(x*y)%251),lo=(uint8_t)(x*17+y*29+ch*43);
            const unsigned expected=bits==8?hi:((unsigned)hi<<8)|lo;
            const size_t at=(((size_t)dy*ow+dx)*channels+ch)*(bits/8);
            const unsigned actual=bits==8?output[at]:big?((unsigned)output[at]<<8)|output[at+1]:((unsigned)output[at+1]<<8)|output[at];
            if(actual!=expected){fprintf(stderr,"orientation mismatch %u/%u/%u orientation=%u source=%u,%u ch=%u actual=%x expected=%x\n",format,bits,big,orientation,x,y,ch,actual,expected);return 3;}
        }
        home_orient_free(output,length);cases++;
    }
    printf("independent C orientation reference validated %u gray/RGB/RGBA8/16 endian/stride fixtures after source retirement\n",cases);
    return 0;
}
