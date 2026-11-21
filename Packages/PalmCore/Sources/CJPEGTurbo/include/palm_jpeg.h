#ifndef PALM_JPEG_H
#define PALM_JPEG_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Decodes an 8-bit baseline or progressive JPEG to packed RGB (3 bytes per pixel, no padding).
///
/// The decoder is libjpeg-turbo with its defaults (accurate integer DCT, fancy upsampling, block
/// smoothing for progressive scans), which is what Android decodes with.
///
/// On success it returns 0 and stores the size and a malloc'ed buffer in the out parameters. Release
/// the buffer with palm_jpeg_free. It returns a non-zero value and touches nothing when the data is not
/// a decodable JPEG with 8-bit samples and a gray, YCbCr or RGB color space (CMYK, YCCK and 12-bit
/// data are rejected).
int palm_jpeg_decode_rgb(const uint8_t *data, size_t length, int *width, int *height, uint8_t **pixels);

void palm_jpeg_free(uint8_t *pixels);

#ifdef __cplusplus
}
#endif

#endif
