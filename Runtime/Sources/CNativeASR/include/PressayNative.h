#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct pressay_asr pressay_asr;
// Returns an owned handle. The error buffer is always NUL-terminated.
pressay_asr *pressay_asr_load(const char *library, const char *model, int orukeet,
                             char *error, size_t error_size);
// text is owned by the handle until its next call. A nonzero result may carry
// partial text; the caller must split/retry instead of silently accepting it.
int pressay_asr_run(pressay_asr *, const float *, size_t, const char **text,
                    char *error, size_t error_size);
void pressay_asr_free(pressay_asr *);
#ifdef __cplusplus
}
#endif
