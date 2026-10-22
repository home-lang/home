/* Test-only independent Exif inspector for generated JPEG/PNG/classic TIFF.
 * No production code links libexif or these container readers. */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <jpeglib.h>
#include <png.h>
#include <libexif/exif-data.h>
#include <libexif/exif-utils.h>
static ExifEntry *entry(ExifData *d,ExifIfd ifd,unsigned int tag) { return exif_content_get_entry(d->ifd[ifd],(ExifTag)tag); }
static void string(const unsigned char *bytes,size_t length) {
    putchar('"');
    for(size_t i=0;i<length && bytes[i];++i) {
        unsigned char c=bytes[i];
        if(c=='"' || c=='\\') { putchar('\\'); putchar(c); }
        else if(c<32) printf("\\u%04x",c);
        else putchar(c);
    }
    putchar('"');
}
static void text(ExifData *d,ExifIfd ifd,unsigned int tag) {
    ExifEntry *e=entry(d,ifd,tag);
    if(e && e->format==EXIF_FORMAT_ASCII && e->size) string(e->data,e->size); else fputs("null",stdout);
}
static int number(ExifData *d,ExifIfd ifd,unsigned int tag,uint32_t *out) {
    ExifEntry *e=entry(d,ifd,tag); if(!e || !e->components)return 0;
    ExifByteOrder order=exif_data_get_byte_order(d);
    if(e->format==EXIF_FORMAT_SHORT && e->size>=2) { *out=exif_get_short(e->data,order); return 1; }
    if(e->format==EXIF_FORMAT_LONG && e->size>=4) { *out=exif_get_long(e->data,order); return 1; }
    return 0;
}
static void scalar(ExifData *d,ExifIfd ifd,unsigned int tag) { uint32_t n; if(number(d,ifd,tag,&n))printf("%u",n); else fputs("null",stdout); }
static void rational(ExifData *d,unsigned int tag,int signed_value) {
    ExifEntry *e=entry(d,EXIF_IFD_EXIF,tag);
    if(!e || e->components!=1 || e->size<8) { fputs("null",stdout); return; }
    ExifByteOrder order=exif_data_get_byte_order(d);
    if(signed_value && e->format==EXIF_FORMAT_SRATIONAL) { ExifSRational n=exif_get_srational(e->data,order); printf("[%d,%d]",n.numerator,n.denominator); }
    else if(!signed_value && e->format==EXIF_FORMAT_RATIONAL) { ExifRational n=exif_get_rational(e->data,order); printf("[%u,%u]",n.numerator,n.denominator); }
    else fputs("null",stdout);
}
static double fraction(const unsigned char *bytes,ExifByteOrder order) { ExifRational r=exif_get_rational(bytes,order); return r.denominator?(double)r.numerator/r.denominator:0; }
static void coordinate(ExifData *d,unsigned int tag) {
    ExifEntry *e=entry(d,EXIF_IFD_GPS,tag),*ref=entry(d,EXIF_IFD_GPS,tag-1);
    if(!e || e->format!=EXIF_FORMAT_RATIONAL || e->components!=3 || e->size<24 || !ref || ref->size<1) { fputs("null",stdout); return; }
    ExifByteOrder order=exif_data_get_byte_order(d);
    double value=fraction(e->data,order)+fraction(e->data+8,order)/60+fraction(e->data+16,order)/3600;
    if(ref->data[0]=='S' || ref->data[0]=='W')value=-value;
    printf("%.12g",value);
}
static ExifData *load(const unsigned char *bytes,size_t length,int prefix) {
    if(length>64u*1024u*1024u)return NULL;
    ExifData *d=exif_data_new(); if(!d)return NULL;
    exif_data_unset_option(d,EXIF_DATA_OPTION_FOLLOW_SPECIFICATION);
    exif_data_unset_option(d,EXIF_DATA_OPTION_IGNORE_UNKNOWN_TAGS);
    if(prefix)exif_data_load_data(d,bytes,(unsigned int)length);
    else {
        unsigned char *input=malloc(length+6); if(!input) { exif_data_unref(d); return NULL; }
        memcpy(input,"Exif\0\0",6); memcpy(input+6,bytes,length);
        exif_data_load_data(d,input,(unsigned int)(length+6)); free(input);
    }
    return d;
}
static void emit(ExifData *d,int carried) {
    if(!d) { puts("{\"hasExif\":false}"); return; }
    uint32_t n;
    const int has=carried || entry(d,EXIF_IFD_0,0x010e)!=NULL || entry(d,EXIF_IFD_0,0x010f)!=NULL || entry(d,EXIF_IFD_0,0x0110)!=NULL || entry(d,EXIF_IFD_0,0x0131)!=NULL || entry(d,EXIF_IFD_0,0x0132)!=NULL || entry(d,EXIF_IFD_0,0x013b)!=NULL || entry(d,EXIF_IFD_0,0x8298)!=NULL || d->ifd[EXIF_IFD_EXIF]->count!=0 || d->ifd[EXIF_IFD_GPS]->count!=0;
    printf("{\"hasExif\":%s,\"byteOrder\":\"%s\",\"make\":",has?"true":"false",exif_data_get_byte_order(d)==EXIF_BYTE_ORDER_INTEL?"little":"big"); text(d,EXIF_IFD_0,0x010f);
    fputs(",\"model\":",stdout);text(d,EXIF_IFD_0,0x0110);
    fputs(",\"software\":",stdout);text(d,EXIF_IFD_0,0x0131);
    fputs(",\"artist\":",stdout);text(d,EXIF_IFD_0,0x013b);
    fputs(",\"copyright\":",stdout);text(d,EXIF_IFD_0,0x8298);
    fputs(",\"dateTime\":",stdout);text(d,EXIF_IFD_0,0x0132);
    fputs(",\"dateTimeOriginal\":",stdout);text(d,EXIF_IFD_EXIF,0x9003);
    fputs(",\"offsetTimeOriginal\":",stdout);text(d,EXIF_IFD_EXIF,0x9011);
    fputs(",\"subSecTimeOriginal\":",stdout);text(d,EXIF_IFD_EXIF,0x9291);
    fputs(",\"width\":",stdout);if(number(d,EXIF_IFD_EXIF,0xa002,&n))printf("%u",n);else scalar(d,EXIF_IFD_0,0x0100);
    fputs(",\"height\":",stdout);if(number(d,EXIF_IFD_EXIF,0xa003,&n))printf("%u",n);else scalar(d,EXIF_IFD_0,0x0101);
    fputs(",\"orientation\":",stdout);scalar(d,EXIF_IFD_0,0x0112);
    fputs(",\"iso\":",stdout);if(number(d,EXIF_IFD_EXIF,0x8833,&n))printf("%u",n);else scalar(d,EXIF_IFD_EXIF,0x8827);
    fputs(",\"exposureTime\":",stdout);rational(d,0x829a,0);
    fputs(",\"fNumber\":",stdout);rational(d,0x829d,0);
    fputs(",\"exposureBias\":",stdout);rational(d,0x9204,1);
    fputs(",\"gpsLatitude\":",stdout);coordinate(d,2);
    fputs(",\"gpsLongitude\":",stdout);coordinate(d,4);
    fputs(",\"gpsAltitude\":",stdout);
    ExifEntry *alt=entry(d,EXIF_IFD_GPS,6),*ref=entry(d,EXIF_IFD_GPS,5);
    if(alt && alt->format==EXIF_FORMAT_RATIONAL && alt->size>=8) { double value=fraction(alt->data,exif_data_get_byte_order(d)); if(ref && ref->size && ref->data[0]==1)value=-value; printf("%.12g",value); } else fputs("null",stdout);
    fputs(",\"thumbnailHex\":\"",stdout);for(unsigned int i=0;i<d->size;++i)printf("%02x",d->data[i]);
    puts("\"}");
}
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    FILE *f=fopen(argv[2],"rb");if(!f)return 3;
    ExifData *d=NULL; int carried=0;
    if(!strcmp(argv[1],"jpeg")) {
        struct jpeg_decompress_struct jpeg; struct jpeg_error_mgr errors;
        jpeg.err=jpeg_std_error(&errors);jpeg_create_decompress(&jpeg);jpeg_stdio_src(&jpeg,f);jpeg_save_markers(&jpeg,JPEG_APP0+1,0xffff);
        if(jpeg_read_header(&jpeg,TRUE)!=JPEG_HEADER_OK)return 4;
        for(jpeg_saved_marker_ptr m=jpeg.marker_list;m;m=m->next)if(m->marker==JPEG_APP0+1 && m->data_length>=6 && !memcmp(m->data,"Exif\0\0",6)) { carried=1;d=load(m->data,m->data_length,1);break; }
        jpeg_destroy_decompress(&jpeg);
    } else if(!strcmp(argv[1],"png")) {
        png_structp png=png_create_read_struct(PNG_LIBPNG_VER_STRING,NULL,NULL,NULL);if(!png)return 5;
        png_infop info=png_create_info_struct(png);if(!info)return 6;
        if(setjmp(png_jmpbuf(png)))return 7;
        png_init_io(png,f);png_read_info(png,info);
        png_bytep bytes=NULL;png_uint_32 length=0;if(png_get_eXIf_1(png,info,&length,&bytes)) { carried=1;d=load(bytes,length,0); }
        png_destroy_read_struct(&png,&info,NULL);
    } else if(!strcmp(argv[1],"tiff")) {
        if(fseek(f,0,SEEK_END)!=0)return 8;
        long length=ftell(f);
        if(length<8 || length>64*1024*1024)return 8;
        rewind(f);unsigned char *bytes=malloc((size_t)length);if(!bytes)return 9;
        if(fread(bytes,1,(size_t)length,f)!=(size_t)length)return 10;
        d=load(bytes,(size_t)length,0);free(bytes);
    } else return 11;
    emit(d,carried);if(d)exif_data_unref(d);fclose(f);return 0;
}
