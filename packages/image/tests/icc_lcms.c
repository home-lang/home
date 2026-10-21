/* Independent Little CMS inspection/transform tests; no production dependency. */
#include <lcms2.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern uint8_t *home_test_srgb(size_t *);
extern void home_test_icc_free(uint8_t *,size_t);
static void require(int ok,const char *why) { if(!ok){fprintf(stderr,"%s\n",why);exit(1);} }
static double linear(double x) { return x<=0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4); }
int main(void) {
    size_t size=0;uint8_t *data=home_test_srgb(&size);
    require(data && size>=132 && size<65536,"generate bounded profile");
    cmsHPROFILE profile=cmsOpenProfileFromMem(data,(cmsUInt32Number)size);
    require(profile!=NULL,"Little CMS must open generated profile");
    require(cmsGetDeviceClass(profile)==cmsSigDisplayClass && cmsGetColorSpace(profile)==cmsSigRgbData && cmsGetPCS(profile)==cmsSigXYZData,"profile class/color/PCS");
    require(fabs(cmsGetProfileVersion(profile)-2.4)<1e-6,"retain v2.4 interoperability");
    char text[128];
    require(cmsGetProfileInfoASCII(profile,cmsInfoDescription,"en","US",text,sizeof(text))>0 && !strcmp(text,"sRGB IEC61966-2.1"),"complete v2 description type");
    require(cmsGetProfileInfoASCII(profile,cmsInfoCopyright,"en","US",text,sizeof(text))>0 && !strcmp(text,"Public Domain"),"v2 copyright text type");
    cmsTagSignature tags[]={cmsSigRedTRCTag,cmsSigGreenTRCTag,cmsSigBlueTRCTag};
    double maximum_curve_error=0;
    for(unsigned channel=0;channel<3;channel++) {
        const cmsToneCurve *curve=(const cmsToneCurve *)cmsReadTag(profile,tags[channel]);
        require(curve!=NULL,"read each actual tone curve");
        for(unsigned code=0;code<=65535;code++) {
            const double x=code/65535.0, error=fabs(cmsEvalToneCurveFloat(curve,(cmsFloat32Number)x)-linear(x));
            if(error>maximum_curve_error)maximum_curve_error=error;
            require(error<0.000025,"sRGB curve differs from independent IEC piecewise reference");
        }
    }
    cmsHPROFILE xyz=cmsCreateXYZProfile();require(xyz!=NULL,"create independent XYZ destination");
    cmsHTRANSFORM transform=cmsCreateTransform(profile,TYPE_RGB_DBL,xyz,TYPE_XYZ_DBL,INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_NOOPTIMIZE|cmsFLAGS_NOCACHE);
    require(transform!=NULL,"CMM must build matrix/TRC transform");
    const double matrix[3][3]={
        {0.436030342570117,0.385101860087134,0.143067806654203},
        {0.222438466210245,0.716942745571917,0.060618777416563},
        {0.013897440074263,0.097076381494207,0.713926257896652}
    };
    double maximum_xyz_error=0;
    for(unsigned r=0;r<=16;r++)for(unsigned g=0;g<=16;g++)for(unsigned b=0;b<=16;b++) {
        double input[3]={r/16.0,g/16.0,b/16.0},output[3],samples[3]={linear(input[0]),linear(input[1]),linear(input[2])};
        cmsDoTransform(transform,input,output,1);
        for(unsigned component=0;component<3;component++) {
            double expected=0;
            for(unsigned i=0;i<3;i++)expected+=matrix[component][i]*samples[i];
            const double error=fabs(output[component]-expected);
            if(error>maximum_xyz_error)maximum_xyz_error=error;
            require(error<0.00008,"independent CMM XYZ differs from published D50 reference");
        }
    }
    cmsDeleteTransform(transform);cmsCloseProfile(xyz);cmsCloseProfile(profile);home_test_icc_free(data,size);
    printf("Little CMS: 196608 curve values and 4913 RGB patches; max curve %.9f XYZ %.9f\n",maximum_curve_error,maximum_xyz_error);
    return 0;
}
