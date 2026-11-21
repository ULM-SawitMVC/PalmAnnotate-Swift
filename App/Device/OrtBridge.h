#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PalmOrtSession PalmOrtSession;

PalmOrtSession *PalmOrtCreate(const char *model, char *error, size_t errorCapacity);
void PalmOrtRelease(PalmOrtSession *session);
float *PalmOrtRun(PalmOrtSession *session, float *input, int64_t side,
                  int64_t *shape, size_t *count, char *error, size_t errorCapacity);
void PalmOrtFreeOutput(float *output);

#ifdef __cplusplus
}
#endif
