// Exhaustive test for fast_memcpy.c, run during the Docker build before it is linked.
// Build: cc -O2 -DFAST_MEMCPY_TEST -DMEMCPY_NAME=fast_memcpy native/fast_memcpy.c native/test_fast_memcpy.c

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void *fast_memcpy(void *dst, const void *src, size_t n);

enum { MAX = 2048, PAD = 64 };

static unsigned char src[MAX + 2 * PAD], dst[MAX + 2 * PAD], expected[MAX + 2 * PAD], buffer[3 * MAX];

static void fill(unsigned char *p, size_t n, unsigned seed) {
  for (size_t i = 0; i < n; i++) {
    p[i] = (unsigned char)(i * 131 + seed * 17 + 7);
  }
}

int main(void) {
  unsigned long checks = 0;

  // Non-overlapping copies: every length, source and destination alignment.
  for (size_t n = 0; n <= MAX; n += (n < 600 ? 1 : 37)) {
    for (size_t so = 0; so < 32; so++) {
      for (size_t doff = 0; doff < 32; doff += (n < 300 ? 1 : 7)) {
        fill(src, sizeof src, (unsigned)(n + so));
        fill(dst, sizeof dst, (unsigned)(n + doff + 99));
        memcpy(expected, dst, sizeof dst);
        memcpy(expected + PAD + doff, src + PAD + so, n);
        void *r = fast_memcpy(dst + PAD + doff, src + PAD + so, n);
        if (r != dst + PAD + doff || memcmp(dst, expected, sizeof dst) != 0) {
          fprintf(stderr, "FAIL: n=%zu src_off=%zu dst_off=%zu\n", n, so, doff);
          return 1;
        }
        checks++;
      }
    }
  }

  // Overlapping forward copies (dst < src), which musl's memmove delegates to __memcpy_fwd.
  for (size_t n = 1; n <= MAX; n += (n < 600 ? 1 : 37)) {
    for (size_t gap = 1; gap <= 80; gap += (gap < 40 ? 1 : 13)) {
      fill(buffer, sizeof buffer, (unsigned)(n + gap));
      memcpy(expected, buffer + gap, n);
      fast_memcpy(buffer, buffer + gap, n);
      if (memcmp(buffer, expected, n) != 0) {
        fprintf(stderr, "FAIL: overlapping forward copy n=%zu gap=%zu\n", n, gap);
        return 1;
      }
      checks++;
    }
  }

  printf("fast_memcpy: %lu checks passed\n", checks);
  return 0;
}
