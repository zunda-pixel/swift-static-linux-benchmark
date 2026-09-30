// C++ operator new / delete on top of malloc, for the musl-mallocng variant.
//
// The Static Linux SDK removes stdlib_new_delete.cpp.o from libc++abi.a because its mimalloc.o
// provides these operators. When we link musl's own allocator instead, something still has to
// define them, or the linker would pull the SDK's mimalloc.o back in (and clash on malloc).
// This mirrors the set of operators in libc++abi's stdlib_new_delete.cpp. Allocation failure
// aborts instead of throwing std::bad_alloc (the benchmark never runs out of memory).

// No headers: this is compiled for the musl target without a C++ standard library.
typedef decltype(sizeof 0) size_t;

namespace std {
enum class align_val_t : size_t {};
struct nothrow_t;
}  // namespace std

extern "C" {
void *malloc(size_t);
void *aligned_alloc(size_t, size_t);
void free(void *);
[[noreturn]] void abort(void);
}

namespace {
void *allocate(size_t size) {
  void *p = malloc(size ? size : 1);
  if (!p) abort();
  return p;
}

void *allocate_aligned(size_t size, std::align_val_t alignment) {
  size_t align = static_cast<size_t>(alignment);
  if (align < sizeof(void *)) align = sizeof(void *);
  size_t rounded = (size + align - 1) / align * align;  // aligned_alloc wants a multiple
  void *p = aligned_alloc(align, rounded ? rounded : align);
  if (!p) abort();
  return p;
}
}  // namespace

void *operator new(size_t size) { return allocate(size); }
void *operator new[](size_t size) { return allocate(size); }
void *operator new(size_t size, const std::nothrow_t &) noexcept { return malloc(size ? size : 1); }
void *operator new[](size_t size, const std::nothrow_t &) noexcept { return malloc(size ? size : 1); }
void *operator new(size_t size, std::align_val_t a) { return allocate_aligned(size, a); }
void *operator new[](size_t size, std::align_val_t a) { return allocate_aligned(size, a); }
void *operator new(size_t size, std::align_val_t a, const std::nothrow_t &) noexcept { return allocate_aligned(size, a); }
void *operator new[](size_t size, std::align_val_t a, const std::nothrow_t &) noexcept { return allocate_aligned(size, a); }

void operator delete(void *p) noexcept { free(p); }
void operator delete[](void *p) noexcept { free(p); }
void operator delete(void *p, const std::nothrow_t &) noexcept { free(p); }
void operator delete[](void *p, const std::nothrow_t &) noexcept { free(p); }
void operator delete(void *p, size_t) noexcept { free(p); }
void operator delete[](void *p, size_t) noexcept { free(p); }
void operator delete(void *p, std::align_val_t) noexcept { free(p); }
void operator delete[](void *p, std::align_val_t) noexcept { free(p); }
void operator delete(void *p, std::align_val_t, const std::nothrow_t &) noexcept { free(p); }
void operator delete[](void *p, std::align_val_t, const std::nothrow_t &) noexcept { free(p); }
void operator delete(void *p, size_t, std::align_val_t) noexcept { free(p); }
void operator delete[](void *p, size_t, std::align_val_t) noexcept { free(p); }
