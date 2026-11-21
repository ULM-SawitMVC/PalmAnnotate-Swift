/* Hand-written for PalmCore. Replaces the CMake-generated jconfigint.h of libjpeg-turbo 3.2.1.
 * Targets Apple arm64 and x86_64 (iOS, macOS, simulators) with clang. No SIMD. */
#define BUILD  "palmcore"
#define HIDDEN  __attribute__((visibility("hidden")))

#undef inline
#define INLINE  inline __attribute__((always_inline))
#define THREAD_LOCAL  __thread

#define PACKAGE_NAME  "libjpeg-turbo"
#define VERSION  "3.2.1"

#define SIZEOF_SIZE_T  8
#if !defined(__LP64__)
#error "PalmCore's libjpeg-turbo configuration assumes a 64-bit target."
#endif
#define HAVE_BUILTIN_CTZL

#define FALLTHROUGH  __attribute__((fallthrough));

#ifndef BITS_IN_JSAMPLE
#define BITS_IN_JSAMPLE  8
#endif

#undef C_ARITH_CODING_SUPPORTED
#undef D_ARITH_CODING_SUPPORTED
#undef WITH_SIMD

#if BITS_IN_JSAMPLE == 8
#define D_ARITH_CODING_SUPPORTED 1
#endif
