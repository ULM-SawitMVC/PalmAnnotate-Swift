#ifndef PALM_JPEG_H
#define PALM_JPEG_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int palm_jpeg_decode_rgb(const uint8_t *data, size_t length, int *width, int *height, uint8_t **pixels);

void palm_jpeg_free(uint8_t *pixels);

#ifdef __cplusplus
}
#endif

#endif
