// A C host that checks the Host ABI of the package against compiled Roc code
// (app.roc, linked as a static archive). It passes Arrow C Data Interface
// buffers into Roc as static lists, reads the results, exports them as
// ArrowArrays with zero copy, and releases them. Run it with
// scripts/test-host.sh, under AddressSanitizer.
//
// ARROW_HOST_FAULT=<name> breaks one host rule on purpose; the run must then
// fail. The script runs each fault to prove that the checks catch it.
#define _POSIX_C_SOURCE 200809L
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "roc_platform_abi.h"

// The ArrowArray of the Arrow C Data Interface specification.
struct ArrowArray {
    int64_t length;
    int64_t null_count;
    int64_t offset;
    int64_t n_buffers;
    int64_t n_children;
    const void **buffers;
    struct ArrowArray **children;
    struct ArrowArray *dictionary;
    void (*release)(struct ArrowArray *);
    void *private_data;
};

static const char *fault = "";
static bool faulty(const char *name) { return strcmp(fault, name) == 0; }

static int checks;
#define CHECK(cond, ...)                                                   \
    do {                                                                   \
        checks++;                                                          \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond); \
            fprintf(stderr, __VA_ARGS__);                                  \
            fprintf(stderr, "\n");                                         \
            exit(1);                                                       \
        }                                                                  \
    } while (0)

// ---------------------------------------------------------------------------
// Roc runtime hooks with a block registry: every block Roc allocates is
// recorded, so the test can tell a Roc buffer from a host buffer, see each
// block freed once, and refuse a free of memory Roc did not allocate. A freed
// block stays allocated until exit, so its address is never reused.

typedef struct {
    void *ptr;
    size_t size;
    int frees;
} Block;

static Block *blocks;
static size_t n_blocks, cap_blocks;

void *roc_alloc(size_t length, size_t alignment) {
    size_t align = alignment < 16 ? 16 : alignment;
    void *p = NULL;
    if (posix_memalign(&p, align, length ? length : 1) != 0) abort();
    if (n_blocks == cap_blocks) {
        cap_blocks = cap_blocks ? 2 * cap_blocks : 256;
        blocks = realloc(blocks, cap_blocks * sizeof *blocks);
        if (!blocks) abort();
    }
    blocks[n_blocks++] = (Block){p, length, 0};
    return p;
}

static Block *find_block(const void *p) {
    for (size_t i = n_blocks; i-- > 0;)
        if (blocks[i].ptr == p) return &blocks[i];
    return NULL;
}

void roc_dealloc(void *ptr, size_t alignment) {
    (void)alignment;
    Block *b = find_block(ptr);
    if (!b) {
        fprintf(stderr, "FAIL: Roc freed %p, which it did not allocate (a static host list?)\n", ptr);
        exit(1);
    }
    if (b->frees) {
        fprintf(stderr, "FAIL: Roc freed %p twice\n", ptr);
        exit(1);
    }
    b->frees = 1;
}

static void free_blocks(void) {
    for (size_t i = 0; i < n_blocks; i++) free(blocks[i].ptr);
    free(blocks);
}

void *roc_realloc(void *ptr, size_t new_length, size_t alignment) {
    Block *old = find_block(ptr);
    size_t old_size = old ? old->size : 0;
    void *fresh = roc_alloc(new_length, alignment);
    memcpy(fresh, ptr, old_size < new_length ? old_size : new_length);
    roc_dealloc(ptr, alignment);
    return fresh;
}

void roc_dbg(const uint8_t *bytes, size_t len) { fprintf(stderr, "[roc dbg] %.*s\n", (int)len, (const char *)bytes); }

void roc_expect_failed(const uint8_t *bytes, size_t len) {
    fprintf(stderr, "[roc expect] %.*s\n", (int)len, (const char *)bytes);
}

void roc_crashed(const uint8_t *bytes, size_t len) {
    fprintf(stderr, "FAIL: Roc crashed: %.*s\n", (int)len, (const char *)bytes);
    exit(1);
}

static size_t live_blocks(void) {
    size_t n = 0;
    for (size_t i = 0; i < n_blocks; i++) n += blocks[i].frees == 0;
    return n;
}

// The index of the live block that holds `p`, or -1.
static long block_holding(const void *p) {
    for (size_t i = n_blocks; i-- > 0;) {
        const uint8_t *start = blocks[i].ptr;
        if (!blocks[i].frees && (const uint8_t *)p >= start && (const uint8_t *)p < start + blocks[i].size) return (long)i;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// Static lists: a seamless slice whose allocation word points just past a
// refcount word of 0. Roc never frees or changes such a list. The word is in
// read-only memory, so a write by Roc faults.

static const intptr_t STATIC_RC[2] = {0, 0};
// The fault "static_rc_one": a refcount of 1 makes the list look owned.
static intptr_t OWNED_RC[2] = {1, 0};
static const _Alignas(16) uint8_t EMPTY[16];

static size_t static_word(void) {
    const intptr_t *rc = faulty("static_rc_one") ? OWNED_RC : STATIC_RC;
    return (size_t)&rc[1] | 1u;
}

static RocList static_list(const void *elements, size_t length) {
    RocList l = {(void *)(elements ? elements : EMPTY), length, static_word()};
    return l;
}

static bool is_static(RocList l) { return l.capacity_or_alloc_ptr == static_word(); }

#define LIST_OF(array) static_list((array), sizeof(array) / sizeof((array)[0]))

static HostSchema schema(const char *format, const char *name) {
    HostSchema s;
    memset(&s, 0, sizeof s);
    s.format = static_list(format, strlen(format));
    s.name = static_list(name, strlen(name));
    s.metadata = static_list(NULL, 0);
    s.flags = 2;  // nullable
    s.children = static_list(NULL, 0);
    s.dictionary = static_list(NULL, 0);
    return s;
}

static HostArray host_array(int64_t length, int64_t null_count, const HostBuffer *buffers, size_t n) {
    HostArray a = {length, null_count, 0, static_list(buffers, n), static_list(NULL, 0), static_list(NULL, 0)};
    return a;
}

// The I128s rule: a typed I128 list needs a 16-byte aligned pointer, else
// the host passes the bytes as U8s and Roc copies them.
static HostBuffer i128_buffer(const void *p, size_t count) {
    if ((uintptr_t)p % 16 == 0 || faulty("i128_unaligned")) return HostBuffer_make_i128s(static_list(p, count));
    return HostBuffer_make_u8s(static_list(p, count * 16));
}

static HostBuffer i64_buffer(const int64_t *p, size_t count) {
    if (faulty("i64_as_u8s")) return HostBuffer_make_u8s(static_list(p, count * 8));
    return HostBuffer_make_i64s(static_list(p, count));
}

static RocList buffer_list(const HostArray *a, size_t i) {
    CHECK(i < a->buffers.length, "buffer %zu of %zu", i, a->buffers.length);
    return HostBuffer_payload_u8s(&((const HostBuffer *)a->buffers.elements)[i]);
}

static uint8_t buffer_tag(const HostArray *a, size_t i) { return ((const HostBuffer *)a->buffers.elements)[i].tag; }

// Give a Roc result back to Roc, which frees what it owns.
static void drop(HostArray value) {
    HostSchema s = schema("n", "drop");
    HostArray empty = roc_run(value, s);
    CHECK(empty.length == 0 && empty.buffers.length == 0, "drop returns an empty array");
}

// ---------------------------------------------------------------------------
// Export: a Roc Host.Array as an ArrowArray. The buffers are the Roc lists'
// element pointers; the release callback hands the value back to Roc.

typedef struct {
    HostArray value;
    const void **buffers;
} Exported;

static void release_exported(struct ArrowArray *array) {
    Exported *e = array->private_data;
    if (!faulty("release_leaks")) drop(e->value);
    free(e->buffers);
    free(e);
    array->release = NULL;
    array->private_data = NULL;
}

static struct ArrowArray export_array(HostArray value) {
    CHECK(value.children.length == 0, "the test exports flat arrays only");
    Exported *e = calloc(1, sizeof *e);
    size_t n = value.buffers.length;
    e->value = value;
    e->buffers = calloc(n ? n : 1, sizeof(void *));
    if (!e || !e->buffers) abort();
    for (size_t i = 0; i < n; i++) {
        if (buffer_tag(&value, i) == HostBufferTag_Absent) continue;
        RocList l = buffer_list(&value, i);
        e->buffers[i] = l.length ? l.elements : (const void *)EMPTY;
    }
    struct ArrowArray out = {value.length, value.null_count, value.offset, (int64_t)n, 0, e->buffers,
                             NULL, NULL, release_exported, e};
    return out;
}

// Each non-empty buffer of `out` is the element pointer of the Roc list and
// lies in a live Roc block; the block indexes go to `held`.
static size_t check_zero_copy_export(const struct ArrowArray *out, long *held) {
    const Exported *e = out->private_data;
    size_t n = 0;
    for (int64_t i = 0; i < out->n_buffers; i++) {
        if (buffer_tag(&e->value, (size_t)i) == HostBufferTag_Absent) {
            CHECK(out->buffers[i] == NULL, "an Absent buffer exports as NULL");
            continue;
        }
        RocList l = buffer_list(&e->value, (size_t)i);
        if (!l.length) continue;
        CHECK(out->buffers[i] == l.elements, "buffer %lld is the Roc list itself", (long long)i);
        long b = block_holding(l.elements);
        CHECK(b >= 0, "buffer %lld lies in a live Roc block", (long long)i);
        held[n++] = b;
    }
    return n;
}

static void release_and_check(struct ArrowArray *out, size_t live_before) {
    long held[8];
    size_t n = check_zero_copy_export(out, held);
    out->release(out);
    CHECK(out->release == NULL, "release marks the array released");
    for (size_t i = 0; i < n; i++)
        CHECK(blocks[held[i]].frees == 1, "the block of exported buffer %zu was freed once", i);
    CHECK(live_blocks() == live_before, "no Roc block leaks (%zu live, %zu before)", live_blocks(), live_before);
}

// ---------------------------------------------------------------------------
// The input columns, as an Arrow producer holds them.

// Int64 with row 2 NULL.
static const _Alignas(16) int64_t I64_DATA[5] = {1, 2, 300, 4, 5};
static const uint8_t I64_VALID[1] = {0x1b};

// Decimal128 values; the high words make a wrong word order visible.
#define N128 4
static __int128 i128_value(int i) {
    static const int64_t hi[N128] = {0, -1, 3, -4};
    static const uint64_t lo[N128] = {7, (uint64_t)-2, 5, 11};
    return (__int128)(((unsigned __int128)(uint64_t)hi[i] << 64) | lo[i]);
}

static __int128 load_i128(const void *p) {
    __int128 v;
    memcpy(&v, p, 16);
    return v;
}

static void test_import_i64(void) {
    size_t live = live_blocks();
    HostBuffer bufs[2] = {HostBuffer_make_u8s(LIST_OF(I64_VALID)), i64_buffer(I64_DATA, 5)};
    HostArray in = host_array(5, 1, bufs, 2);

    // Roc reads the host buffer in place.
    HostArray sum = roc_run(in, schema("l", "sum_i64"));
    RocList s = buffer_list(&sum, 1);
    CHECK(s.length == 1 && ((const int64_t *)s.elements)[0] == 12, "sum of the valid rows");
    drop(sum);

    // A slice of the input comes back over the same memory: no copy either way.
    HostArray pass = roc_run(in, schema("l", "pass"));
    RocList values = buffer_list(&pass, 1);
    CHECK(buffer_tag(&pass, 1) == HostBufferTag_I64s, "Int64 values stay I64s");
    CHECK(values.elements == (const void *)&I64_DATA[1], "the slice points into the host buffer");
    CHECK(values.length == 4, "the slice has 4 rows");
    CHECK(is_static(values), "the slice keeps the static refcount word");
    CHECK(block_holding(values.elements) < 0, "the host buffer is no Roc block");
    drop(pass);
    CHECK(STATIC_RC[0] == 0, "the static refcount word is still 0");
    CHECK(live_blocks() == live, "no Roc block leaks");
}

static void test_import_i128(void) {
    // The same values at a 16-byte aligned address and at byte 8 of a second region.
    static _Alignas(16) uint8_t aligned16[16 * N128];
    static _Alignas(16) uint8_t shifted[16 * N128 + 8];
    for (int i = 0; i < N128; i++) {
        __int128 v = i128_value(i);
        memcpy(&aligned16[16 * i], &v, 16);
        memcpy(&shifted[8 + 16 * i], &v, 16);
    }
    __int128 want = 0;
    for (int i = 0; i < N128; i++) want += i128_value(i);

    const void *places[2] = {aligned16, &shifted[8]};
    for (int k = 0; k < 2; k++) {
        size_t live = live_blocks();
        const void *data = places[k];
        bool aligned = (uintptr_t)data % 16 == 0;
        HostBuffer bufs[2] = {HostBuffer_make_absent(), i128_buffer(data, N128)};
        HostArray in = host_array(N128, 0, bufs, 2);

        HostArray sum = roc_run(in, schema("d:38,2", "sum_i128"));
        RocList s = buffer_list(&sum, 1);
        CHECK(buffer_tag(&sum, 1) == HostBufferTag_I128s, "the sum is an I128s buffer");
        CHECK((uintptr_t)s.elements % 16 == 0, "Roc's I128 list is 16-byte aligned");
        CHECK(s.length == 1 && load_i128(s.elements) == want, "Decimal128 sum, %s input", aligned ? "aligned" : "8-byte aligned");
        drop(sum);

        HostArray pass = roc_run(in, schema("d:38,2", "pass"));
        RocList values = buffer_list(&pass, 1);
        CHECK(values.length == N128 - 1, "the slice has 3 rows");
        CHECK((uintptr_t)values.elements % 16 == 0, "a Decimal128 buffer Roc returns is 16-byte aligned");
        for (int i = 1; i < N128; i++)
            CHECK(load_i128((const uint8_t *)values.elements + 16 * (i - 1)) == i128_value(i), "row %d", i);
        if (aligned) {
            CHECK(values.elements == (const uint8_t *)data + 16, "aligned I128s: the slice points into the host buffer");
            CHECK(is_static(values), "aligned I128s: the slice keeps the static refcount word");
        } else {
            CHECK(block_holding(values.elements) >= 0, "8-byte aligned: Roc read the U8s and copied them");
        }
        drop(pass);
        CHECK(live_blocks() == live, "no Roc block leaks");
    }
}

static void test_export_i64(void) {
    size_t live = live_blocks();
    HostBuffer bufs[2] = {HostBuffer_make_u8s(LIST_OF(I64_VALID)), i64_buffer(I64_DATA, 5)};
    struct ArrowArray out = export_array(roc_run(host_array(5, 1, bufs, 2), schema("l", "double_i64")));
    CHECK(out.length == 5 && out.null_count == 1 && out.n_buffers == 2, "shape of the result");
    const uint8_t *valid = out.buffers[0];
    const int64_t *values = out.buffers[1];
    CHECK(valid && (valid[0] & 0x1f) == 0x1b, "the NULL of row 2 is kept (bits 0x%02x)", valid ? valid[0] : 0);
    for (int i = 0; i < 5; i++)
        if (i != 2) CHECK(values[i] == 2 * I64_DATA[i], "row %d doubled", i);
    release_and_check(&out, live);
}

static void test_export_utf8(void) {
    size_t live = live_blocks();
    static const char text[] = "abh\xc3\xa9llo";
    static const int32_t offsets[5] = {0, 2, 2, 2, 8};
    static const uint8_t valid[1] = {0x0b};  // row 2 NULL
    HostBuffer bufs[3] = {HostBuffer_make_u8s(LIST_OF(valid)), HostBuffer_make_i32s(LIST_OF(offsets)),
                          HostBuffer_make_u8s(static_list(text, 8))};
    struct ArrowArray out = export_array(roc_run(host_array(4, 1, bufs, 3), schema("u", "repeat_utf8")));
    CHECK(out.length == 4 && out.n_buffers == 3, "shape of the result");
    const int32_t *offs = out.buffers[1];
    const char *data = out.buffers[2];
    const char *want[4] = {"abab", "", NULL, "h\xc3\xa9lloh\xc3\xa9llo"};
    for (int i = 0; i < 4; i++) {
        bool is_valid = (((const uint8_t *)out.buffers[0])[0] >> i) & 1;
        CHECK(is_valid == (want[i] != NULL), "validity of row %d", i);
        if (!want[i]) continue;
        size_t len = (size_t)(offs[i + 1] - offs[i]);
        CHECK(len == strlen(want[i]) && memcmp(data + offs[i], want[i], len) == 0, "text of row %d", i);
    }
    release_and_check(&out, live);
}

int main(void) {
    const char *f = getenv("ARROW_HOST_FAULT");
    if (f) fault = f;
    test_import_i64();
    test_import_i128();
    test_export_i64();
    test_export_utf8();
    free_blocks();
    printf("host test: %d checks passed%s%s\n", checks, *fault ? " with fault " : "", fault);
    return 0;
}
