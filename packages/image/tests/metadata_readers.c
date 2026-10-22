/* Independent container/Exif/CMM/decoder oracle only; no production dependency. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <jpeglib.h>
#include <png.h>
#include <tiffio.h>
#include <lcms2.h>
#include <libexif/exif-data.h>
#include <libexif/exif-utils.h>
extern unsigned char *home_test_metadata_base(uint32_t, size_t *);
extern unsigned char *home_test_metadata_embed(uint32_t, const unsigned char *, size_t, const unsigned char *, size_t, int, size_t *);
extern unsigned char *home_test_metadata_defaults(const unsigned char *, size_t, size_t *);
extern unsigned char *home_test_metadata_inline_jpeg(const unsigned char *, size_t, int, size_t *);
extern void home_test_metadata_free(unsigned char *, size_t);
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"metadata check failed at line %d: %s\n",__LINE__,#x); exit(1); } } while(0)
static ExifEntry *field(ExifData *d, ExifIfd ifd, unsigned int tag, ExifFormat type, unsigned long count) {
    ExifEntry *e=exif_entry_new(); CHECK(e);
    e->tag=(ExifTag)tag; e->format=type; e->components=count;
    e->size=(unsigned int)(count*exif_format_get_size(type));
    e->data=calloc(1,e->size); CHECK(e->data);
    exif_content_add_entry(d->ifd[ifd],e); exif_entry_unref(e);
    return exif_content_get_entry(d->ifd[ifd],(ExifTag)tag);
}
static ExifEntry *get(ExifData *d, ExifIfd ifd, unsigned int tag, ExifFormat type, unsigned long count) {
    ExifEntry *e=exif_content_get_entry(d->ifd[ifd],(ExifTag)tag);
    CHECK(e && e->format==type && e->components==count); return e;
}
static ExifData *new_exif(void) {
    ExifData *d=exif_data_new(); CHECK(d);
    exif_data_unset_option(d,EXIF_DATA_OPTION_FOLLOW_SPECIFICATION);
    exif_data_unset_option(d,EXIF_DATA_OPTION_IGNORE_UNKNOWN_TAGS); return d;
}
static unsigned char *make_exif(int big, int replacement, unsigned int *length) {
    ExifData *d=new_exif();
    ExifByteOrder order=big ? EXIF_BYTE_ORDER_MOTOROLA : EXIF_BYTE_ORDER_INTEL;
    exif_data_set_byte_order(d,order);
    memcpy(field(d,EXIF_IFD_0,0x010f,EXIF_FORMAT_ASCII,20)->data,"Home Camera Company",20);
    exif_set_short(field(d,EXIF_IFD_0,0x0112,EXIF_FORMAT_SHORT,1)->data,order,6);
    exif_set_rational(field(d,EXIF_IFD_EXIF,0x829a,EXIF_FORMAT_RATIONAL,1)->data,order,(ExifRational){12345,1000000});
    exif_set_srational(field(d,EXIF_IFD_EXIF,0x9204,EXIF_FORMAT_SRATIONAL,1)->data,order,(ExifSRational){-2,3});
    exif_set_long(field(d,EXIF_IFD_EXIF,0xa002,EXIF_FORMAT_LONG,1)->data,order,1);
    exif_set_short(field(d,EXIF_IFD_EXIF,0x8827,EXIF_FORMAT_SHORT,1)->data,order,65535);
    exif_set_short(field(d,EXIF_IFD_EXIF,0x8830,EXIF_FORMAT_SHORT,1)->data,order,3);
    exif_set_long(field(d,EXIF_IFD_EXIF,0x8833,EXIF_FORMAT_LONG,1)->data,order,102400);
    memcpy(field(d,EXIF_IFD_GPS,1,EXIF_FORMAT_ASCII,2)->data,"S",2);
    ExifEntry *coordinates=field(d,EXIF_IFD_GPS,2,EXIF_FORMAT_RATIONAL,3);
    const uint32_t values[3]={40,26,46};
    for(unsigned int i=0;i<3;++i) exif_set_rational(coordinates->data+i*8,order,(ExifRational){values[i],1});
    field(d,EXIF_IFD_GPS,5,EXIF_FORMAT_BYTE,1)->data[0]=1;
    exif_set_rational(field(d,EXIF_IFD_GPS,6,EXIF_FORMAT_RATIONAL,1)->data,order,(ExifRational){1234,10});
    memcpy(field(d,EXIF_IFD_INTEROPERABILITY,1,EXIF_FORMAT_ASCII,4)->data,"R98",4);
    /* SOI/EOI-delimited metadata fixture only; not a thumbnail decoder test. */
    d->size=replacement?5:4; d->data=malloc(d->size); CHECK(d->data); memcpy(d->data,replacement?"\xff\xd8Z\xff\xd9":"\xff\xd8\xff\xd9",d->size);
    exif_set_short(field(d,EXIF_IFD_1,0x0103,EXIF_FORMAT_SHORT,1)->data,order,6);
    unsigned char *bytes=NULL; exif_data_save_data(d,&bytes,length);
    CHECK(bytes && *length); exif_data_unref(d); return bytes;
}
static void check_exif(const unsigned char *bytes, size_t length, int prefixed, int replacement, int defaults) {
    CHECK(length < UINT32_MAX);
    unsigned char *input=malloc(length+(prefixed?0:6)); CHECK(input);
    if(prefixed) memcpy(input,bytes,length);
    else { memcpy(input,"Exif\0\0",6); memcpy(input+6,bytes,length); length+=6; }
    ExifData *d=new_exif(); exif_data_load_data(d,input,(unsigned int)length); free(input);
    ExifByteOrder order=exif_data_get_byte_order(d);
    if(defaults) {
        CHECK(!strcmp((char*)get(d,EXIF_IFD_0,0x0110,EXIF_FORMAT_ASCII,14)->data,"Default Model"));
        CHECK(!strcmp((char*)get(d,EXIF_IFD_0,0x0131,EXIF_FORMAT_ASCII,11)->data,"zig-camera"));
        ExifRational aperture=exif_get_rational(get(d,EXIF_IFD_EXIF,0x829d,EXIF_FORMAT_RATIONAL,1)->data,order);
        CHECK(aperture.numerator==28 && aperture.denominator==10);
    }
    CHECK(!strcmp((char*)get(d,EXIF_IFD_0,0x010f,EXIF_FORMAT_ASCII,20)->data,"Home Camera Company"));
    CHECK(exif_get_short(get(d,EXIF_IFD_0,0x0112,EXIF_FORMAT_SHORT,1)->data,order)==6);
    ExifRational exposure=exif_get_rational(get(d,EXIF_IFD_EXIF,0x829a,EXIF_FORMAT_RATIONAL,1)->data,order);
    CHECK(exposure.numerator==12345 && exposure.denominator==1000000);
    ExifSRational bias=exif_get_srational(get(d,EXIF_IFD_EXIF,0x9204,EXIF_FORMAT_SRATIONAL,1)->data,order);
    CHECK(bias.numerator==-2 && bias.denominator==3);
    CHECK(exif_get_long(get(d,EXIF_IFD_EXIF,0x8833,EXIF_FORMAT_LONG,1)->data,order)==102400);
    CHECK(get(d,EXIF_IFD_GPS,1,EXIF_FORMAT_ASCII,2)->data[0]=='S');
    CHECK(get(d,EXIF_IFD_GPS,5,EXIF_FORMAT_BYTE,1)->data[0]==1);
    ExifRational altitude=exif_get_rational(get(d,EXIF_IFD_GPS,6,EXIF_FORMAT_RATIONAL,1)->data,order);
    CHECK(altitude.numerator==1234 && altitude.denominator==10);
    CHECK(!memcmp(get(d,EXIF_IFD_INTEROPERABILITY,1,EXIF_FORMAT_ASCII,4)->data,"R98",4));
    CHECK(d->size==(replacement?5u:4u) && !memcmp(d->data,replacement?"\xff\xd8Z\xff\xd9":"\xff\xd8\xff\xd9",d->size));
    exif_data_unref(d);
}
static void check_icc(const void *bytes,size_t size) {
    CHECK(bytes && size>=132 && size<=16*1024*1024);
    cmsHPROFILE p=cmsOpenProfileFromMem(bytes,(cmsUInt32Number)size); CHECK(p);
    CHECK(cmsGetColorSpace(p)==cmsSigRgbData); cmsCloseProfile(p);
}
static FILE *input_file(const unsigned char *bytes,size_t length) {
    FILE *f=tmpfile(); CHECK(f); CHECK(fwrite(bytes,1,length,f)==length); rewind(f); return f;
}
static void read_image(uint32_t format,const unsigned char *bytes,size_t length,int metadata,int icc,unsigned char rgb[3],toff_t second_page) {
    if(format==0) {
        struct jpeg_decompress_struct d; struct jpeg_error_mgr errors;
        d.err=jpeg_std_error(&errors); jpeg_create_decompress(&d); jpeg_mem_src(&d,bytes,(unsigned long)length);
        jpeg_save_markers(&d,JPEG_APP0+1,0xffff); jpeg_save_markers(&d,JPEG_APP0+2,0xffff);
        CHECK(jpeg_read_header(&d,TRUE)==JPEG_HEADER_OK);
        unsigned int found=0;
        for(jpeg_saved_marker_ptr m=d.marker_list;m;m=m->next) if(m->marker==JPEG_APP0+1 && m->data_length>=6 && !memcmp(m->data,"Exif\0\0",6)) { check_exif(m->data,m->data_length,1,metadata==2,icc); ++found; }
        CHECK(found==(metadata?1u:0u));
        JOCTET *profile=NULL; unsigned int size=0;
        int has=jpeg_read_icc_profile(&d,&profile,&size); CHECK(!!has==!!icc);
        if(has) { check_icc(profile,size); } free(profile);
        d.out_color_space=JCS_RGB; CHECK(jpeg_start_decompress(&d));
        CHECK(d.output_width==1 && d.output_height==1 && d.output_components==3);
        JSAMPROW row=rgb; CHECK(jpeg_read_scanlines(&d,&row,1)==1); CHECK(jpeg_finish_decompress(&d)); jpeg_destroy_decompress(&d); return;
    }
    FILE *f=input_file(bytes,length);
    if(format==1) {
        png_structp png=png_create_read_struct(PNG_LIBPNG_VER_STRING,NULL,NULL,NULL); CHECK(png);
        png_infop info=png_create_info_struct(png); CHECK(info);
        if(setjmp(png_jmpbuf(png))) { fputs("PNG reader failed\n",stderr); exit(1); }
        png_init_io(png,f); png_read_info(png,info);
        png_bytep exif=NULL; png_uint_32 exif_length=0;
        int has=png_get_eXIf_1(png,info,&exif_length,&exif); CHECK(!!has==!!metadata);
        if(has) check_exif(exif,exif_length,0,metadata==2,icc);
        png_charp name=NULL; int compression=0; png_bytep profile=NULL; png_uint_32 size=0;
        has=png_get_iCCP(png,info,&name,&compression,&profile,&size); CHECK(!!has==!!icc); if(has) check_icc(profile,size);
        CHECK(png_get_image_width(png,info)==1 && png_get_image_height(png,info)==1 && png_get_rowbytes(png,info)==3);
        png_read_row(png,rgb,NULL); png_read_end(png,info); png_destroy_read_struct(&png,&info,NULL); fclose(f); return;
    }
    TIFF *t=TIFFFdOpen(dup(fileno(f)),"fixture","r"); CHECK(t);
    uint32_t width=0,height=0,size=0; void *profile=NULL;
    CHECK(TIFFGetField(t,TIFFTAG_IMAGEWIDTH,&width) && width==1);
    CHECK(TIFFGetField(t,TIFFTAG_IMAGELENGTH,&height) && height==1);
    CHECK(TIFFScanlineSize(t)==3 && TIFFReadScanline(t,rgb,0,0)==1);
    int has=TIFFGetField(t,TIFFTAG_ICCPROFILE,&size,&profile); CHECK(!!has==!!icc); if(has) check_icc(profile,size);
    if(metadata) {
        char *make=NULL; uint16_t orientation=0; toff_t exif=0,gps=0;
        CHECK(TIFFGetField(t,TIFFTAG_MAKE,&make) && !strcmp(make,"Home Camera Company"));
        CHECK(TIFFGetField(t,TIFFTAG_ORIENTATION,&orientation) && orientation==6);
        CHECK(TIFFGetField(t,TIFFTAG_EXIFIFD,&exif) && TIFFGetField(t,TIFFTAG_GPSIFD,&gps));
        CHECK(TIFFReadEXIFDirectory(t,exif));
        uint32_t iso=0; CHECK(TIFFGetField(t,EXIFTAG_ISOSPEED,&iso) && iso==102400);
        CHECK(TIFFReadGPSDirectory(t,gps));
        uint8_t altitude_ref=0; double altitude=0;
        CHECK(TIFFGetField(t,GPSTAG_ALTITUDEREF,&altitude_ref) && altitude_ref==1);
        CHECK(TIFFGetField(t,GPSTAG_ALTITUDE,&altitude) && fabs(altitude-123.4)<1e-6);
        check_exif(bytes,length,0,metadata==2,icc);
    }
    if(second_page) {
        unsigned char pixel[3]; CHECK(TIFFSetSubDirectory(t,second_page));
        CHECK(TIFFScanlineSize(t)==3 && TIFFReadScanline(t,pixel,0,0)==1);
        CHECK(pixel[0]==0xaa && pixel[1]==0xbb && pixel[2]==0xcc);
    }
    TIFFClose(t); fclose(f);
}
static unsigned char *big_tiff(size_t *length,toff_t *second_page) {
    FILE *f=tmpfile(); CHECK(f);
    TIFF *t=TIFFFdOpen(dup(fileno(f)),"big fixture","wb"); CHECK(t);
    for(unsigned int page=0;page<2;++page) {
        CHECK(TIFFSetField(t,TIFFTAG_IMAGEWIDTH,1) && TIFFSetField(t,TIFFTAG_IMAGELENGTH,1));
        CHECK(TIFFSetField(t,TIFFTAG_BITSPERSAMPLE,8) && TIFFSetField(t,TIFFTAG_SAMPLESPERPIXEL,3));
        CHECK(TIFFSetField(t,TIFFTAG_PHOTOMETRIC,PHOTOMETRIC_RGB) && TIFFSetField(t,TIFFTAG_PLANARCONFIG,PLANARCONFIG_CONTIG));
        unsigned char first[3]={0x12,0x34,0x56},second[3]={0xaa,0xbb,0xcc};
        CHECK(TIFFWriteScanline(t,page?second:first,0,0)==1); CHECK(TIFFWriteDirectory(t));
    }
    TIFFClose(t);
    CHECK(fseek(f,0,SEEK_END)==0); long size=ftell(f); CHECK(size>0); rewind(f);
    unsigned char *bytes=malloc((size_t)size); CHECK(bytes); CHECK(fread(bytes,1,(size_t)size,f)==(size_t)size); CHECK(fflush(f)==0); int reader=dup(fileno(f)); CHECK(reader>=0 && lseek(reader,0,SEEK_SET)==0);
    t=TIFFFdOpen(reader,"second page","r"); CHECK(t && TIFFSetDirectory(t,1));
    *second_page=TIFFCurrentDirOffset(t); CHECK(*second_page); TIFFClose(t); fclose(f); *length=(size_t)size; return bytes;
}
int main(void) {
    unsigned int cases=0;
    for(uint32_t format=0;format<3;++format) for(int source_big=0;source_big<(format==2?2:1);++source_big) {
        size_t base_length=0; toff_t second_page=0; unsigned char *base=source_big?big_tiff(&base_length,&second_page):home_test_metadata_base(format,&base_length); CHECK(base);
        unsigned char expected[3]; read_image(format,base,base_length,0,0,expected,second_page);
        for(int exif_big=0;exif_big<2;++exif_big) for(int icc=0;icc<2;++icc) {
            unsigned int exif_length=0; unsigned char *exif=make_exif(exif_big,0,&exif_length);
            size_t defaults_length=0; unsigned char *filled=icc?home_test_metadata_defaults(exif,exif_length,&defaults_length):NULL; CHECK(!icc || filled);
            size_t length=0; unsigned char *image=home_test_metadata_embed(format,base,base_length,filled?filled:exif,filled?defaults_length:exif_length,icc,&length); CHECK(image);
            if(format==0) {
                size_t inline_length=0;
                unsigned char *inlined=home_test_metadata_inline_jpeg(filled?filled:exif,filled?defaults_length:exif_length,icc,&inline_length); CHECK(inlined);
                unsigned char pixel[3]; read_image(format,inlined,inline_length,1,icc,pixel,0); CHECK(!memcmp(pixel,expected,3));
                home_test_metadata_free(inlined,inline_length);
            }
            if(filled) home_test_metadata_free(filled,defaults_length);
            unsigned char actual[3]; read_image(format,image,length,1,icc,actual,second_page); CHECK(!memcmp(actual,expected,3));
            /* Replacing metadata retains independent decoding and one active Exif. */
            unsigned int replacement_length=0; unsigned char *replacement=make_exif(!exif_big,1,&replacement_length);
            filled=icc?home_test_metadata_defaults(replacement,replacement_length,&defaults_length):NULL; CHECK(!icc || filled);
            size_t again_length=0; unsigned char *again=home_test_metadata_embed(format,image,length,filled?filled:replacement,filled?defaults_length:replacement_length,icc,&again_length); CHECK(again);
            if(filled) home_test_metadata_free(filled,defaults_length);
            free(replacement);
            read_image(format,again,again_length,2,icc,actual,second_page); CHECK(!memcmp(actual,expected,3));
            home_test_metadata_free(again,again_length); home_test_metadata_free(image,length); free(exif); ++cases;
        }
        if(source_big) free(base); else home_test_metadata_free(base,base_length);
    }
    printf("Metadata: %u independent endian/profile/container cases and replacements passed\n",cases); return 0;
}
