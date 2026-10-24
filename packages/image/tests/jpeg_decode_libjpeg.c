/* Independent JPEG producer/reference decoder; never linked into Home decoder. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <jpeglib.h>
extern int home_jpeg_decode(const uint8_t *,size_t,uint32_t,void **,uint64_t *,const uint8_t **,const uint8_t **,const uint8_t **);
extern void home_jpeg_free(void *);
extern int home_jpeg_reject(const uint8_t *,size_t);
static unsigned cases,largest_error;
static const uint8_t icc_bytes[]={9,8,7,6,5,4,3,2,1};
static const uint8_t exif_bytes[]={'I','I',42,0,8,0,0,0,0,0};
static uint8_t *encode(unsigned w,unsigned h,unsigned mode,unsigned progressive,unsigned restart,int quality,int separate,unsigned long *size){
 struct jpeg_compress_struct c;struct jpeg_error_mgr error;c.err=jpeg_std_error(&error);error.trace_level=-1;jpeg_create_compress(&c);
 unsigned char *output=NULL;jpeg_mem_dest(&c,&output,size);
 const unsigned channels=mode==6?1:mode>=8?4:3;
 c.image_width=w;c.image_height=h;c.input_components=(int)channels;c.in_color_space=channels==1?JCS_GRAYSCALE:channels==4?JCS_CMYK:JCS_RGB;
 jpeg_set_defaults(&c);
 if(mode==7)jpeg_set_colorspace(&c,JCS_RGB);
 if(mode==10)jpeg_set_colorspace(&c,JCS_YCCK);
 if(mode==9)c.write_Adobe_marker=FALSE;
 if(mode<6){static const unsigned sampling[][2]={{1,1},{2,2},{2,1},{1,2},{4,1},{3,1}};c.comp_info[0].h_samp_factor=(int)sampling[mode][0];c.comp_info[0].v_samp_factor=(int)sampling[mode][1];}
 jpeg_set_quality(&c,quality,FALSE);c.restart_interval=restart;
 jpeg_scan_info scans[40];memset(scans,0,sizeof(scans));
 if(progressive==2){
  unsigned n=0;scans[n].comps_in_scan=(int)channels;for(unsigned i=0;i<channels;i++)scans[n].component_index[i]=(int)i;scans[n].Al=3;n++;
  for(unsigned band=0;band<2;band++)for(unsigned i=0;i<channels;i++){scans[n].comps_in_scan=1;scans[n].component_index[0]=(int)i;scans[n].Ss=band?16:1;scans[n].Se=band?63:15;scans[n].Al=2;n++;}
  for(int bit=2;bit>0;bit--)for(unsigned band=0;band<2;band++)for(unsigned i=0;i<channels;i++){scans[n].comps_in_scan=1;scans[n].component_index[0]=(int)i;scans[n].Ss=band?16:1;scans[n].Se=band?63:15;scans[n].Ah=bit;scans[n].Al=bit-1;n++;}
  for(int bit=3;bit>0;bit--){scans[n].comps_in_scan=(int)channels;for(unsigned i=0;i<channels;i++)scans[n].component_index[i]=(int)i;scans[n].Ah=bit;scans[n].Al=bit-1;n++;}
  assert(n<40);c.scan_info=scans;c.num_scans=(int)n;
 }else if(progressive)jpeg_simple_progression(&c);
 else if(separate){for(unsigned i=0;i<channels;i++){scans[i].comps_in_scan=1;scans[i].component_index[0]=(int)i;scans[i].Ss=0;scans[i].Se=63;}c.scan_info=scans;c.num_scans=(int)channels;}
 jpeg_start_compress(&c,TRUE);
 uint8_t exif[6+sizeof(exif_bytes)]={'E','x','i','f',0,0};memcpy(exif+6,exif_bytes,sizeof(exif_bytes));jpeg_write_marker(&c,JPEG_APP0+1,exif,sizeof(exif));
 uint8_t icc[14+5]={'I','C','C','_','P','R','O','F','I','L','E',0,2,2};memcpy(icc+14,icc_bytes+5,4);jpeg_write_marker(&c,JPEG_APP0+2,icc,18);icc[12]=1;memcpy(icc+14,icc_bytes,5);jpeg_write_marker(&c,JPEG_APP0+2,icc,sizeof(icc));
 uint8_t *row=malloc((size_t)w*channels);assert(row);
 while(c.next_scanline<h){for(unsigned x=0;x<w;x++)for(unsigned ch=0;ch<channels;ch++)row[x*channels+ch]=(uint8_t)(x*13+c.next_scanline*23+ch*61+(x*c.next_scanline)%17);JSAMPROW p=row;assert(jpeg_write_scanlines(&c,&p,1)==1);}
 free(row);jpeg_finish_compress(&c);jpeg_destroy_compress(&c);return output;
}
static uint8_t *reference(const uint8_t *input,size_t length,unsigned nearest,size_t *size,unsigned *w,unsigned *h){
 struct jpeg_decompress_struct c;struct jpeg_error_mgr error;c.err=jpeg_std_error(&error);error.trace_level=-1;jpeg_create_decompress(&c);jpeg_mem_src(&c,input,length);assert(jpeg_read_header(&c,TRUE)==JPEG_HEADER_OK);
 const int cmyk=c.num_components==4;c.out_color_space=cmyk?JCS_CMYK:c.num_components==1?JCS_GRAYSCALE:JCS_RGB;c.dct_method=JDCT_FLOAT;c.do_fancy_upsampling=!nearest;
 jpeg_start_decompress(&c);*w=c.output_width;*h=c.output_height;const unsigned channels=cmyk?4:c.output_components;*size=(size_t)*w**h*(channels==1?1:3);uint8_t *out=malloc(*size),*row=malloc((size_t)*w*channels);assert(out&&row);
 while(c.output_scanline<*h){const unsigned y=c.output_scanline;JSAMPROW p=row;assert(jpeg_read_scanlines(&c,&p,1)==1);if(cmyk){for(unsigned x=0;x<*w;x++)for(unsigned ch=0;ch<3;ch++){const unsigned color=c.saw_Adobe_marker?row[x*4+ch]:255-row[x*4+ch],black=c.saw_Adobe_marker?row[x*4+3]:255-row[x*4+3];out[((size_t)y**w+x)*3+ch]=(uint8_t)((color*black+127)/255);}}else memcpy(out+(size_t)y**w*channels,row,(size_t)*w*channels);}
 free(row);jpeg_finish_decompress(&c);jpeg_destroy_decompress(&c);return out;
}
static void run(unsigned w,unsigned h,unsigned mode,unsigned progressive,unsigned restart,int quality,int separate,unsigned nearest){
 unsigned long size=0;uint8_t *input=encode(w,h,mode,progressive,restart,quality,separate,&size);size_t ref_size;unsigned rw,rh;uint8_t *ref=reference(input,size,nearest,&ref_size,&rw,&rh);
 void *owned=NULL;uint64_t info[11];const uint8_t *pixels=NULL,*icc=NULL,*exif=NULL;const int code=home_jpeg_decode(input,size,nearest,&owned,info,&pixels,&icc,&exif);
 if(code){fprintf(stderr,"FAILED JPEG %ux%u mode=%u progressive=%u restart=%u quality=%d separate=%d nearest=%u\n",w,h,mode,progressive,restart,quality,separate,nearest);abort();}
 assert(info[0]==rw&&info[1]==rh&&info[2]==(mode==6?1:mode>=8?4:3)&&info[3]==(progressive!=0)&&info[4]>0&&info[6]==ref_size);
 assert(info[7]==sizeof(icc_bytes)&&info[8]==sizeof(exif_bytes)&&!memcmp(icc,icc_bytes,sizeof(icc_bytes))&&!memcmp(exif,exif_bytes,sizeof(exif_bytes)));
 unsigned max=0;size_t at=0;for(size_t i=0;i<ref_size;i++){const unsigned e=(unsigned)abs((int)pixels[i]-ref[i]);if(e>max){max=e;at=i;}}
 if(max>3){fprintf(stderr,"PIXELS JPEG %ux%u mode=%u progressive=%u restart=%u quality=%d separate=%d nearest=%u max=%u at=%zu Home=%u libjpeg=%u\n",w,h,mode,progressive,restart,quality,separate,nearest,max,at,pixels[at],ref[at]);abort();}
 if(max>largest_error)largest_error=max;
 /* Every shortened prefix must reject, rather than fabricating EOI/entropy. */
 if(w==9&&mode==1&&quality==75&&restart==1&&nearest){for(size_t i=0;i<size;i++)assert(home_jpeg_reject(input,i)==1);for(size_t i=0;i+1<size;i++)if(input[i]==255&&input[i+1]>=208&&input[i+1]<=215){const uint8_t saved=input[i+1];input[i+1]=(uint8_t)(208+((saved-208+3)%8));assert(home_jpeg_reject(input,size)==1);input[i+1]=saved;break;}}
 memset(input,0,size);assert(!memcmp(icc,icc_bytes,sizeof(icc_bytes))&&!memcmp(exif,exif_bytes,sizeof(exif_bytes)));home_jpeg_free(owned);free(input);free(ref);cases++;
}
static unsigned argument(const char *text,unsigned max){char *end=NULL;const unsigned long value=strtoul(text,&end,10);assert(*text&&end&&!*end&&value<=max);return (unsigned)value;}
static void save(const char *path,const uint8_t *bytes,size_t size){FILE *file=fopen(path,"wb");assert(file);assert(fwrite(bytes,1,size,file)==size);assert(fclose(file)==0);}
int main(int argc,char **argv){
 if(argc==6){const unsigned mode=argument(argv[3],10),progressive=argument(argv[4],2),nearest=argument(argv[5],1);unsigned long size=0;uint8_t *input=encode(35,23,mode,progressive,3,75,0,&size);size_t output_size;unsigned w,h;uint8_t *output=reference(input,size,nearest,&output_size,&w,&h);assert(w==35&&h==23);save(argv[1],input,size);save(argv[2],output,output_size);free(output);free(input);return 0;}
 assert(argc==1);
 const unsigned dims[][2]={{1,1},{9,17},{35,23}};const int qualities[]={1,75,100};
 for(unsigned mode=0;mode<=10;mode++)for(unsigned p=0;p<2;p++)for(unsigned d=0;d<3;d++)for(unsigned r=0;r<3;r++)for(unsigned q=0;q<3;q++){
  run(dims[d][0],dims[d][1],mode,p,r==2?3:r,qualities[q],0,1);
  if(mode<4||mode>=6)run(dims[d][0],dims[d][1],mode,p,r==2?3:r,qualities[q],0,0);
 }
 for(unsigned mode=0;mode<=10;mode++){run(35,23,mode,0,3,75,1,1);run(35,23,mode,2,3,75,0,1);}
 printf("%u independent JPEG grayscale/YCbCr/RGB/CMYK/YCCK sequential/progressive, sampling, restart, quantization, metadata and truncation cases passed; maximum sample difference %u\n",cases,largest_error);return 0;
}
