// A memcpy for x86_64 musl builds that is fast for small copies.
//
// musl's x86_64 memcpy is `rep movsq` with byte loops for alignment and the tail. `rep movs`
// has a high startup cost, which dominates the many small copies Swift code makes (strings,
// arrays, Data). This version copies up to 256 bytes with overlapping unaligned vector loads
// and stores, and uses `rep movsb` (fast on CPUs with ERMS / FSRM) only above that.
//
// Linked into the musl-sdk-fastmemcpy variant as an object file, so it takes precedence over
// memcpy.lo in the SDK's libc.a. musl's memmove calls the hidden __memcpy_fwd for forward
// copies, which lives in the same memcpy.lo, so it is defined here too.
//
// Build with -O2 -ffreestanding so the compiler does not turn the copies back into memcpy calls.

// No headers, so it builds for the musl target without a sysroot.
typedef __SIZE_TYPE__ size_t;
typedef __UINT16_TYPE__ uint16_t;
typedef __UINT32_TYPE__ uint32_t;
typedef __UINT64_TYPE__ uint64_t;

#ifndef MEMCPY_NAME
#define MEMCPY_NAME memcpy
#endif

typedef uint16_t u16 __attribute__((aligned(1), may_alias));
typedef uint32_t u32 __attribute__((aligned(1), may_alias));
typedef uint64_t u64 __attribute__((aligned(1), may_alias));
typedef char v16 __attribute__((vector_size(16), aligned(1), may_alias));
typedef char v32 __attribute__((vector_size(32), aligned(1), may_alias));

// Every path loads before it stores, or copies strictly forward, so the function is also a
// correct forward copy for overlapping buffers with dst < src (what __memcpy_fwd must be).
// The parameters are deliberately not `restrict`: that would let the compiler reorder the
// stores before the loads, which breaks overlapping forward copies.
void *MEMCPY_NAME(void *dst, const void *src, size_t n) {
  char *d = dst;
  const char *s = src;

  if (n <= 16) {
    if (n >= 8) {
      u64 head = *(const u64 *)s, tail = *(const u64 *)(s + n - 8);
      *(u64 *)d = head;
      *(u64 *)(d + n - 8) = tail;
    } else if (n >= 4) {
      u32 head = *(const u32 *)s, tail = *(const u32 *)(s + n - 4);
      *(u32 *)d = head;
      *(u32 *)(d + n - 4) = tail;
    } else if (n >= 2) {
      u16 head = *(const u16 *)s, tail = *(const u16 *)(s + n - 2);
      *(u16 *)d = head;
      *(u16 *)(d + n - 2) = tail;
    } else if (n == 1) {
      *d = *s;
    }
    return dst;
  }
  if (n <= 32) {
    v16 head = *(const v16 *)s, tail = *(const v16 *)(s + n - 16);
    *(v16 *)d = head;
    *(v16 *)(d + n - 16) = tail;
    return dst;
  }
  if (n <= 64) {
    v32 head = *(const v32 *)s, tail = *(const v32 *)(s + n - 32);
    *(v32 *)d = head;
    *(v32 *)(d + n - 32) = tail;
    return dst;
  }
  if (n <= 256) {
    v32 tail = *(const v32 *)(s + n - 32);
    char *end = d + n - 32;
    for (; d < end; d += 32, s += 32) {
      *(v32 *)d = *(const v32 *)s;
    }
    *(v32 *)end = tail;
    return dst;
  }
#if defined(__x86_64__)
  __asm__ volatile("rep movsb" : "+D"(d), "+S"(s), "+c"(n) : : "memory");
#else
  for (; n >= 32; n -= 32, d += 32, s += 32) {
    *(v32 *)d = *(const v32 *)s;
  }
  for (; n; n--) {
    *d++ = *s++;
  }
#endif
  return dst;
}

#if !defined(FAST_MEMCPY_TEST) && defined(__x86_64__)
extern __typeof(MEMCPY_NAME) __memcpy_fwd __attribute__((alias("memcpy"), visibility("hidden")));
#endif

// Marker so scripts/verify.sh can check that memcpy resolves to this implementation.
#ifndef FAST_MEMCPY_TEST
extern __typeof(MEMCPY_NAME) benchmark_fast_memcpy __attribute__((alias("memcpy")));
#endif
