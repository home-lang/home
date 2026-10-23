/* Independent integer sample reference; no Home conversion code in this test. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
extern int home_pixel_convert(uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint8_t **,size_t *);
extern void home_pixel_free(uint8_t *,size_t);
static unsigned channels(unsigned format){return format==0?1:format==1?3:4;}
static uint16_t sample(unsigned x,unsigned y,unsigned channel,unsigned bits){
    const uint8_t hi=(uint8_t)(x*37+y*53+channel*79+(x*y)%251),lo=(uint8_t)(x*17+y*29+channel*43);
    return bits==8?(uint16_t)((unsigned)hi*257):(uint16_t)(((unsigned)hi<<8)|lo);
}
int main(void){
    const unsigned dims[][2]={{1,1},{2,2},{17,9},{64,64}};unsigned cases=0;
    for(unsigned sf=0;sf<3;sf++)for(unsigned sb=8;sb<=16;sb+=8)for(unsigned se=0;se<2;se++)
    for(unsigned tf=0;tf<3;tf++)for(unsigned tb=8;tb<=16;tb+=8)for(unsigned te=0;te<2;te++)for(unsigned d=0;d<4;d++){
        uint8_t *output=NULL;size_t length=0;const unsigned w=dims[d][0],h=dims[d][1];
        if(home_pixel_convert(sf,sb,se,tf,tb,te,w,h,&output,&length)||length!=(size_t)w*h*channels(tf)*(tb/8)){fputs("pixel fixture failed\n",stderr);return 1;}
        for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++){
            uint16_t values[4]={sample(x,y,0,sb),sample(x,y,sf==0?0:1,sb),sample(x,y,sf==0?0:2,sb),sf==2?sample(x,y,3,sb):65535};
            if(tf==0){
                const unsigned shift=sb==8?8:0;
                const uint32_t gray=((uint32_t)(values[0]>>shift)*299+(uint32_t)(values[1]>>shift)*587+(uint32_t)(values[2]>>shift)*114)/1000;
                values[0]=(uint16_t)(sb==8?gray*257:gray);
            }
            for(unsigned ch=0;ch<channels(tf);ch++){
                const size_t at=(((size_t)y*w+x)*channels(tf)+ch)*(tb/8);
                const unsigned actual=tb==8?output[at]:te?((unsigned)output[at]<<8)|output[at+1]:((unsigned)output[at+1]<<8)|output[at];
                const unsigned expected=tb==8?values[ch]>>8:values[ch];
                if(actual!=expected){fprintf(stderr,"pixel mismatch source=%u/%u/%u target=%u/%u/%u size=%ux%u pixel=%u,%u ch=%u actual=%u expected=%u\n",sf,sb,se,tf,tb,te,w,h,x,y,ch,actual,expected);return 2;}
            }
        }
        home_pixel_free(output,length);cases++;
    }
    printf("independent C reference validated %u gray/RGB/RGBA8/16 endian/stride conversion fixtures after source retirement\n",cases);return 0;
}
