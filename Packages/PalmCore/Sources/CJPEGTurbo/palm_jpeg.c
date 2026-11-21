#include "palm_jpeg.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>

#include "jpeglib.h"

typedef struct {
    struct jpeg_error_mgr base;
    jmp_buf escape;
} palm_error_manager;

static void palm_error_exit(j_common_ptr cinfo) {
    palm_error_manager *manager = (palm_error_manager *)cinfo->err;
    longjmp(manager->escape, 1);
}

static void palm_output_message(j_common_ptr cinfo) { (void)cinfo; }

/* Largest accepted decoded size. libjpeg allows 65500 x 65500, which would need 12 GB of RGB. */
#define PALM_JPEG_MAX_BYTES ((size_t)1 << 30)

int palm_jpeg_decode_rgb(const uint8_t *data, size_t length, int *width, int *height, uint8_t **pixels) {
    if (data == NULL || length == 0 || width == NULL || height == NULL || pixels == NULL) return 1;

    struct jpeg_decompress_struct cinfo;
    palm_error_manager manager;
    uint8_t *volatile buffer = NULL;

    cinfo.err = jpeg_std_error(&manager.base);
    manager.base.error_exit = palm_error_exit;
    manager.base.output_message = palm_output_message;
    if (setjmp(manager.escape)) {
        jpeg_destroy_decompress(&cinfo);
        free(buffer);
        return 2;
    }

    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, data, (unsigned long)length);
    jpeg_read_header(&cinfo, TRUE);

    if (cinfo.data_precision != 8) {
        jpeg_destroy_decompress(&cinfo);
        return 3;
    }
    switch (cinfo.jpeg_color_space) {
    case JCS_GRAYSCALE:
    case JCS_YCbCr:
    case JCS_RGB:
        break;
    default:
        jpeg_destroy_decompress(&cinfo);
        return 4;
    }
    size_t rowBytes = (size_t)cinfo.image_width * 3;
    if (cinfo.image_width == 0 || cinfo.image_height == 0 || (size_t)cinfo.image_height > PALM_JPEG_MAX_BYTES / rowBytes) {
        jpeg_destroy_decompress(&cinfo);
        return 5;
    }

    /* Everything else keeps the libjpeg defaults: JDCT_ISLOW, fancy upsampling, block smoothing. */
    cinfo.out_color_space = JCS_RGB;
    buffer = malloc(rowBytes * cinfo.image_height);
    if (buffer == NULL) {
        jpeg_destroy_decompress(&cinfo);
        return 6;
    }
    jpeg_start_decompress(&cinfo);
    while (cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW row = buffer + (size_t)cinfo.output_scanline * rowBytes;
        if (jpeg_read_scanlines(&cinfo, &row, 1) != 1) longjmp(manager.escape, 1);
    }
    jpeg_finish_decompress(&cinfo);

    *width = (int)cinfo.image_width;
    *height = (int)cinfo.image_height;
    *pixels = buffer;
    jpeg_destroy_decompress(&cinfo);
    return 0;
}

void palm_jpeg_free(uint8_t *pixels) { free(pixels); }
