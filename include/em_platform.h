#ifndef EMBER_PLATFORM_H
#define EMBER_PLATFORM_H
//
// em_platform.h — the freestanding platform layer (compiled with -DEMBER_FREESTANDING).
//
// The Ember runtime (src/runtime.c) is written against a small slice of libc: an allocator, the
// mem/str functions, a printf family, and process termination. A bare-metal target has none of
// these. Rather than fork the runtime (a second implementation would drift — see
// docs/architecture.md "two extern mechanisms"), the SAME runtime.c is compiled freestanding, with
// its libc includes replaced by these declarations. The definitions live in the target's platform
// translation unit (kernel/platform.c for the QEMU `virt` spike): a bump allocator over a fixed
// .bss arena, byte-wise mem/str, a minimal printf routed to the platform sink (the UART), and a
// panic-on-termination. See docs/design/kernel-freestanding.md.
//
// This header is included by ember_rt.h under EMBER_FREESTANDING, so every TU that sees the runtime
// sees the same declarations. Only the freestanding C headers (<stddef.h>/<stdint.h>/<stdarg.h>,
// available even under -ffreestanding -nostdlib) are used.
//
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>

// --- memory: a bump allocator over a fixed .bss arena (free is a no-op; the arena resets wholesale).
// Each block is size-prefixed so realloc knows the old length. ------------------------------------
void  *malloc(size_t n);
void  *calloc(size_t count, size_t size);
void  *realloc(void *p, size_t n);
void   free(void *p);

// --- mem / str ------------------------------------------------------------------------------------
void  *memcpy(void *dst, const void *src, size_t n);
void  *memmove(void *dst, const void *src, size_t n);
void  *memset(void *dst, int c, size_t n);
int    memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);

// --- formatted output: a minimal printf family routed to the platform sink (the UART). fprintf and
// fwrite ignore the stream (all output is the one console). ---------------------------------------
typedef struct EmFile FILE;
extern FILE *stderr;
extern FILE *stdout;
int     snprintf(char *buf, size_t n, const char *fmt, ...);
int     vsnprintf(char *buf, size_t n, const char *fmt, va_list ap);
int     fprintf(FILE *stream, const char *fmt, ...);
size_t  fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);
int     fputc(int c, FILE *stream);

// --- termination: no OS to return to, so a fault/OOM prints (if it can) and halts. ----------------
void   exit(int code);
void   abort(void);

#endif // EMBER_PLATFORM_H
