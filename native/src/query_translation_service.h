#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*SquirrelQueryTranslationCallback)(uint64_t generation,
                                                  const char* word,
                                                  const char* target,
                                                  const char* translation,
                                                  const char* phonetic,
                                                  void* context);

void SquirrelQueryTranslationSetGeneration(uint64_t generation);
void SquirrelQueryTranslationRequest(const char* word, const char* target,
                                     uint64_t generation,
                                     SquirrelQueryTranslationCallback callback,
                                     void* context);
void SquirrelQueryTranslationShutdown(void);

#ifdef __cplusplus
}
#endif
