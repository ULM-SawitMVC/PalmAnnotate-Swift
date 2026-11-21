/* Hand-written for PalmCore. Replaces the CMake-generated jconfig.h of libjpeg-turbo 3.2.1.
 * Decode only, 8-bit, no SIMD, libjpeg API version 6.2 (the default build configuration). */
#define JPEG_LIB_VERSION  62
#define LIBJPEG_TURBO_VERSION  3.2.1
#define LIBJPEG_TURBO_VERSION_NUMBER  3002001

#define D_ARITH_CODING_SUPPORTED 1
#define MEM_SRCDST_SUPPORTED  1

#ifndef BITS_IN_JSAMPLE
#define BITS_IN_JSAMPLE  8
#endif
