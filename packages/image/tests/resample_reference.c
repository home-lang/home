/* Independent direct 2D, long-double reference (production uses cached
 * separable double rows). No Home image/resampler code is compiled here. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
extern int home_pixel_resize(uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint8_t **,size_t *);
extern void home_resample_free(uint8_t *,size_t);
static unsigned channels(unsigned f){return f==0?1:f==1?3:4;}
static long double sample(unsigned x,unsigned y,unsigned ch,unsigned bits){
    const uint8_t hi=(uint8_t)(x*37+y*53+ch*79+(x*y)%251),lo=(uint8_t)(x*17+y*29+ch*43);
    return bits==8?(unsigned)hi*257:((unsigned)hi<<8)|lo;
}
static long double kernel(unsigned filter,long double t){
    const long double x=fabsl(t),b=1.L/3,c=1.L/3;
    if(filter==1)return x<1?1-x:0;
    if(filter==2){
        if(x<1)return ((12-9*b-6*c)*x*x*x+(-18+12*b+6*c)*x*x+(6-2*b))/6;
        if(x<2)return ((-b-6*c)*x*x*x+(6*b+30*c)*x*x+(-12*b-48*c)*x+(8*b+24*c))/6;
        return 0;
    }
    const long double radius=filter==3?2:3,pi=acosl(-1.L),p=pi*x;
    return x>=radius?0:x<1e-12L?1:radius*sinl(p)*sinl(p/radius)/(p*p);
}
static unsigned reference(unsigned f,unsigned bits,unsigned filter,unsigned sw,unsigned sh,unsigned dw,unsigned dh,unsigned x,unsigned y,unsigned ch){
    if(filter==0||(sw==dw&&sh==dh)){
        unsigned sx=(unsigned)(((uint64_t)x*2+1)*sw/((uint64_t)dw*2));
        unsigned sy=(unsigned)(((uint64_t)y*2+1)*sh/((uint64_t)dh*2));
        const unsigned value=(unsigned)sample(sx,sy,ch,bits);
        return bits==8?value/257:value;
    }
    const long double sx=(long double)sw/dw,sy=(long double)sh/dh;
    const long double fx=fmaxl(1,sx),fy=fmaxl(1,sy),cx=(x+.5L)*sx-.5L,cy=(y+.5L)*sy-.5L;
    long double sum=0,alpha=0,total=0;
    for(unsigned j=0;j<sh;j++)for(unsigned i=0;i<sw;i++){
        const long double w=kernel(filter,((long double)i-cx)/fx)*kernel(filter,((long double)j-cy)/fy);
        const long double a=f==2?sample(i,j,3,bits):65535;
        total+=w;alpha+=a*w;
        sum+=sample(i,j,ch,bits)*(f==2&&ch<3?a/65535:1)*w;
    }
    long double value=f==2&&ch<3?(alpha>1e-12L?sum*65535/alpha:0):sum/total;
    value=fmaxl(0,fminl(65535,value));
    return (unsigned)floorl(value/(bits==8?257:1)+.5L);
}
int main(void){
    const unsigned dims[][4]={{1,1,5,3},{2,1,1,1},{1,5,7,1},{7,1,1,9},{17,9,3,2},{2,3,9,11},{7,5,7,5},{8,8,1,1},{31,17,16,9},{3,9,5,4},{3,257,2,3}};
    unsigned cases=0;
    for(unsigned f=0;f<3;f++)for(unsigned bits=8;bits<=16;bits+=8)for(unsigned big=0;big<2;big++)for(unsigned filter=0;filter<5;filter++)for(unsigned d=0;d<sizeof(dims)/sizeof(dims[0]);d++){
        const unsigned sw=dims[d][0],sh=dims[d][1],dw=dims[d][2],dh=dims[d][3];
        uint8_t *out=NULL;size_t length=0;
        if(home_pixel_resize(f,bits,big,filter,sw,sh,dw,dh,&out,&length)||length!=(size_t)dw*dh*channels(f)*(bits/8)){fputs("resize fixture failed\n",stderr);return 1;}
        for(unsigned y=0;y<dh;y++)for(unsigned x=0;x<dw;x++)for(unsigned ch=0;ch<channels(f);ch++){
            const size_t at=(((size_t)y*dw+x)*channels(f)+ch)*(bits/8);
            const unsigned actual=bits==8?out[at]:big?((unsigned)out[at]<<8)|out[at+1]:((unsigned)out[at+1]<<8)|out[at];
            const unsigned expected=reference(f,bits,filter,sw,sh,dw,dh,x,y,ch);
            const unsigned tolerance=filter==0||(sw==dw&&sh==dh)?0:1;
            if((actual>expected?actual-expected:expected-actual)>tolerance){fprintf(stderr,"resize mismatch format=%u bits=%u big=%u filter=%u %ux%u -> %ux%u pixel=%u,%u ch=%u actual=%u reference=%u\n",f,bits,big,filter,sw,sh,dw,dh,x,y,ch,actual,expected);return 2;}
        }
        home_resample_free(out,length);cases++;
    }
    printf("independent long-double reference validated %u gray/RGB/RGBA8/16 resize fixtures after source retirement\n",cases);
    return 0;
}
