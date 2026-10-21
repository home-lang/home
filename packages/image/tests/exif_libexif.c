/* Independent test oracle only. Production does not link libexif. */
#include <libexif/exif-data.h>
#include <libexif/exif-utils.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern unsigned char *home_test_exif_fixture(size_t *length);
extern void home_test_exif_free(unsigned char *, size_t);
extern int home_test_exif_check(const unsigned char *, size_t);
#define CHECK(test) do { if (!(test)) { fprintf(stderr, "Exif check failed at line %d: %s\n", __LINE__, #test); exit(1); } } while (0)
static ExifEntry *entry(ExifData *data, ExifIfd ifd, unsigned int tag, ExifFormat format, unsigned long count) {
    ExifEntry *e = exif_content_get_entry(data->ifd[ifd], (ExifTag)tag);
    CHECK(e && e->format == format && e->components == count);
    return e;
}
static double rational(const unsigned char *data, ExifByteOrder order) {
    ExifRational value = exif_get_rational(data, order);
    CHECK(value.denominator != 0);
    return (double)value.numerator / value.denominator;
}
int main(void) {
    size_t length = 0;
    unsigned char *bytes = home_test_exif_fixture(&length);
    CHECK(bytes && length < 65534 && !memcmp(bytes, "Exif\0\0", 6));
    ExifData *data = exif_data_new();
    CHECK(data);
    /* Prevent libexif from repairing/defaulting the serialized fixture. */
    exif_data_unset_option(data, EXIF_DATA_OPTION_FOLLOW_SPECIFICATION);
    exif_data_unset_option(data, EXIF_DATA_OPTION_IGNORE_UNKNOWN_TAGS);
    exif_data_load_data(data, bytes, (unsigned int)length);
    ExifByteOrder order = exif_data_get_byte_order(data);
    CHECK(order == EXIF_BYTE_ORDER_INTEL);
    CHECK(!strcmp((char *)entry(data, EXIF_IFD_0, 0x010f, EXIF_FORMAT_ASCII, 20)->data, "Home Camera Company"));
    CHECK(!strcmp((char *)entry(data, EXIF_IFD_0, 0x0110, EXIF_FORMAT_ASCII, 13)->data, "Pi 5 fixture"));
    CHECK(exif_get_short(entry(data, EXIF_IFD_0, 0x0112, EXIF_FORMAT_SHORT, 1)->data, order) == 6);
    CHECK(exif_get_long(entry(data, EXIF_IFD_EXIF, 0xa002, EXIF_FORMAT_LONG, 1)->data, order) == 4608);
    CHECK(exif_get_long(entry(data, EXIF_IFD_EXIF, 0xa003, EXIF_FORMAT_LONG, 1)->data, order) == 2592);
    CHECK(exif_get_short(entry(data, EXIF_IFD_EXIF, 0x8827, EXIF_FORMAT_SHORT, 1)->data, order) == 65535);
    CHECK(exif_get_short(entry(data, EXIF_IFD_EXIF, 0x8830, EXIF_FORMAT_SHORT, 1)->data, order) == 3);
    CHECK(exif_get_long(entry(data, EXIF_IFD_EXIF, 0x8833, EXIF_FORMAT_LONG, 1)->data, order) == 102400);
    CHECK(fabs(rational(entry(data, EXIF_IFD_EXIF, 0x829a, EXIF_FORMAT_RATIONAL, 1)->data, order) - 0.012345) < 1e-9);
    ExifSRational bias = exif_get_srational(entry(data, EXIF_IFD_EXIF, 0x9204, EXIF_FORMAT_SRATIONAL, 1)->data, order);
    CHECK(bias.numerator == -2 && bias.denominator == 3);
    CHECK(entry(data, EXIF_IFD_GPS, 1, EXIF_FORMAT_ASCII, 2)->data[0] == 'S');
    CHECK(entry(data, EXIF_IFD_GPS, 3, EXIF_FORMAT_ASCII, 2)->data[0] == 'W');
    CHECK(fabs(rational(entry(data, EXIF_IFD_GPS, 2, EXIF_FORMAT_RATIONAL, 3)->data + 16, order) - 46.125) < 1e-9);
    CHECK(entry(data, EXIF_IFD_GPS, 5, EXIF_FORMAT_BYTE, 1)->data[0] == 1);
    CHECK(fabs(rational(entry(data, EXIF_IFD_GPS, 6, EXIF_FORMAT_RATIONAL, 1)->data, order) - 123.4) < 1e-9);
    CHECK(data->size == 4 && !memcmp(data->data, "\xff\xd8\xff\xd9", 4));
    CHECK(home_test_exif_check(bytes, length) == 0);
    home_test_exif_free(bytes, length);
    /* An independent writer supplies both endian inputs to the Home parser. */
    for (unsigned int i = 0; i < 2; ++i) {
        unsigned char *saved = NULL;
        unsigned int saved_length = 0;
        exif_data_set_byte_order(data, i == 0 ? EXIF_BYTE_ORDER_MOTOROLA : EXIF_BYTE_ORDER_INTEL);
        exif_data_save_data(data, &saved, &saved_length);
        CHECK(saved && saved_length);
        CHECK(home_test_exif_check(saved, saved_length) == 0);
        free(saved);
    }
    exif_data_unref(data);
    puts("Exif: independent libexif read and little/big-endian write checks passed");
    return 0;
}
