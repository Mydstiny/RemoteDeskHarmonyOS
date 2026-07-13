#ifndef WINPR_BUILD_FLAGS_H
#define WINPR_BUILD_FLAGS_H

#define WINPR_CFLAGS "-fdata-sections -ffunction-sections -funwind-tables -fstack-protector-strong -no-canonical-prefixes -fno-addrsig -Wa,--noexecstack -Wformat -Werror=format-security  -D__MUSL__ -fvisibility=hidden -fno-omit-frame-pointer -Wredundant-decls -fsigned-char -Wimplicit-function-declaration -fvisibility=hidden -O2 -DNDEBUG "
#define WINPR_COMPILER_ID "Clang"
#define WINPR_COMPILER_VERSION "15.0.4"
#define WINPR_TARGET_ARCH ""
#define WINPR_BUILD_CONFIG ""
#define WINPR_BUILD_TYPE "Release"

#endif /* WINPR_BUILD_FLAGS_H */
