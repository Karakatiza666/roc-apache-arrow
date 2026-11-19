# roc-apache-arrow

Apache Arrow's in-memory columnar format for Roc. A host (Rust, Zig, C) gives
Roc Arrow arrays through the Arrow C Data Interface, and Roc reads and writes
them without a copy.

| Direction | API | Cost |
|---|---|---|
| In | column views (`PrimitiveColumn`, `Utf8Column`, `ListColumn`, ...) over the host's buffers | no copy; one check of the buffers at import, one UTF-8 check per text column |
| Out | typed column writers (`Writer`) | each value is written once, into the buffer the host gets; `*_finish` exports with no copy |
| Dynamic | `Builder`, `ArrowEncoding` (derived `parser_for` / `encoder_for`), `Probe` | copies each value; for types known only at run time |

The package holds only the Arrow format. A wrapper package adds the rules of
an application.

[API.md](API.md) lists every module and function, and its test status.

| Item | Value |
|---|---|
| Systems | Linux (x64, arm64) and macOS; Windows is not tested |
| Tests | 279 `expect`s, 3 examples, a C host test under AddressSanitizer, differential tests against arrow-rs |

## Use it

```roc
app [main!] {
    arrow: "https://github.com/Karakatiza666/roc-apache-arrow/releases/download/0.0.2/4ZaS9d8uUZi4wJSBC1zrwsGD8ncrfV1yzS1Ry7vtjPs8.tar.zst",
}

import arrow.Array
import arrow.PrimitiveColumn
```

The URL is the 0.0.2 release bundle. Its file name is the hash of its
content, so it changes when a module changes. The release notes give the
URL of each release.

The examples run with no host, for example `roc examples/main.roc`:

| Example | Shows |
|---|---|
| [examples/main.roc](examples/main.roc) | zero-copy views in, a typed writer out; one row decoded into a record |
| [examples/lists.roc](examples/lists.roc) | a List column read row by row through `ListColumn` and `Items`, with no copy |
| [examples/dynamic.roc](examples/dynamic.roc) | `Builder` and `encode_row` / `decode_row` for a type known at run time; `append_dec`; an encode error with its path |

## Compiler

| Item | Value |
|---|---|
| Compiler | the Zig-based Roc compiler (the `roc-lang/roc` nightlies of 2026) |
| Tested on | `nightly-2026-11-15-f25da45` ([.roc-version](.roc-version)) |
| Daily check | the latest nightly ([test-nightly-roc.yml](.github/workflows/test-nightly-roc.yml)) |

The derived-codec protocol and the list layout of this compiler change
between nightlies. Use the nightly in `.roc-version` if a newer one fails.

## Read: zero-copy views

`Array.from_host` checks every size and offset once. A view over the checked
`Array` costs O(1) and copies nothing. Each view has checked reads (`get`, a
`Try` with `Null` and `OutOfBounds`) and a loop read (`at`) that never checks
again.

```roc
nums = PrimitiveColumn.i64(Array.from_host(host_array, Int64)?)?
text = Utf8Column.from_array(Array.from_host(host_text, Utf8)?)?   # checks UTF-8 once
total = nums.at(0, 0) + text.at(0).count_utf8_bytes().to_i64_wrap()
```

A host that promises valid UTF-8 can pass the text buffer as a `Str`
(`Host.Buffer.Utf8`, see [Host ABI](#host-abi)). `Utf8Column` then uses that
`Str` and skips the UTF-8 check. For 100k rows of 32 bytes
(`scripts/bench-host.sh`, x86-64, `--opt speed`):

| Text | `U8s` (checked) | `Utf8` (trusted) |
|---|---|---|
| ASCII | 8.5 ns/row | 7.2 ns/row |
| Latin (2-byte characters) | 107 ns/row | 6.5 ns/row |
| CJK and emoji | 67 ns/row | 6.2 ns/row |

| View | Arrow types | Loop read |
|---|---|---|
| `PrimitiveColumn(a)` | Int8 .. UInt64, Float32, Float64, Decimal128 (as `I128`), and the date, time and timestamp types (as `I32` / `I64`) | `at(i, zero)` |
| `BoolColumn` | Boolean | `at(i)` |
| `Utf8Column` | Utf8 | `at(i)` gives a `Str` slice |
| `BinaryColumn` | Binary, LargeBinary, BinaryView, Utf8, LargeUtf8, Utf8View, FixedSizeBinary | `bytes_at(i)` |
| `ListColumn` | List, LargeList, FixedSizeList, Map | `range_at(i)` |
| `StructColumn` | Struct | `column(name)`, `column_at(i)` |
| `MapColumn` | Map | `keys`, `items`, `range(i)` |
| `Items(item, src)` | one list value, read on demand | `get(j)`, `iter()` |

`Items` holds a source type, not a closure, because this compiler boxes a
closure inside a `Try`, a tuple or a record (one allocation per value).

## Write: typed column writers

A writer is a record of plain Roc lists. Each push appends in place, and
`*_finish` gives a `Host.Array` whose buffers are those lists.

```roc
var $w = Writer.prim(rows)
for i in (0.U64).until(rows) {
    $w = if nums.is_valid(i) Writer.prim_push($w, nums.at(i, 0) * 2) else Writer.prim_null($w, 0)
}
out = Writer.prim_finish($w, [], |xs| I64s(xs))     # a Host.Array
```

| Writer | Arrow types | Push |
|---|---|---|
| `prim` | every fixed-width type | `prim_push` |
| `bools` | Boolean | `bools_push` |
| `varlen` | Utf8, Binary (`I32` offsets) | `str_push`, `bytes_push` |
| `large_varlen` | LargeUtf8, LargeBinary (`I64` offsets) | `large_str_push`, `large_bytes_push` |
| `fixed` | FixedSizeBinary | `fixed_push` |
| `views` | BinaryView, Utf8View | `views_push`, `views_str_push` |
| `lists` | List, Map (with a child writer) | `list_push` |
| `large_lists` | LargeList (with a child writer) | `large_list_push` |
| `fixed_lists` | FixedSizeList (with a child writer) | `fixed_list_push` |
| `row` | Struct (each field has its own writer) | `row_push` |

NULL rows go to a sparse list, so a column with no NULL gets no bitmap. The
`cleared` argument of each `*_finish` makes more rows NULL (for example, rows
that failed).

## Dynamic API

For code that knows its column types only at run time: tests, prototypes,
schema-driven tools. It copies each value, so it is not for a batch loop.

| Module | Use |
|---|---|
| `Builder` | build an array of a run-time `DataType`: every fixed-width type, Boolean, the binary and text types (view types included), List, LargeList, FixedSizeList, Map and Struct |
| `ArrowEncoding` | `decode_row` / `encode_row`: one Roc value per row, through the derived `parser_for` / `encoder_for` |
| `Probe`, `Shape` | find the Arrow shape of a Roc type, and check it against a schema field |

Nested appends (`update_child`, `take_children` / `put_children`,
`encode_row`) keep each child unique, so a list or struct column builds in
linear time. `append_dec` rounds a `Dec` to the column's scale for
Decimal32, Decimal64 and Decimal128, and refuses a value past the precision
or the storage width. A decode or encode error names the path of the value,
for example `at 'tags[0]': expected Int64, found Utf8`.

`Try(a, [Null])` is the nullable shape: an Arrow NULL decodes to `Err(Null)`.
The same Roc type reads JSON `null` too.

```roc
Row : { n : Try(I64, [Null]), s : Str }
row : Try(Row, _)
row = ArrowEncoding.decode_row(batch, 0)    # batch : Array of type Struct
```

## Loops

A view or `Items` value is cheap to iterate, but how the loop ends matters
on this compiler:

| Loop | Cost |
|---|---|
| `items.iter().fold(init, step)` | no copy |
| `while $j < n { .. items.get($j) .. }` | no copy |
| `for x in items { .. }` with `break` | no copy |
| `for x in items { .. }` with `return` or `?` in the body | copies the iterator once per item |

Use `fold`, a `while` loop with `get`, or `break`. Do not `return` or use
`?` inside `for x in items`; compute a `Try` after the loop.

## Host ABI

The host and Roc share three types, all in `Host`. They mirror `ArrowArray`
and `ArrowSchema` of the C Data Interface, with no callbacks and no
`private_data`.

| Type | Size (64-bit) | Mirrors |
|---|---|---|
| `Host.Array` | 96 bytes | `ArrowArray`: length, null_count, offset, buffers, children, dictionary |
| `Host.Schema` | 128 bytes | `ArrowSchema`: format, name, metadata, flags, children, dictionary |
| `Host.Buffer` | 32 bytes | one buffer: a tag (`Absent` = 0, `F32s` .. `U8s` = 11, `Utf8` = 12) and a Roc list, or a `Str` for `Utf8` |

[glue/roc_platform_abi.h](glue/roc_platform_abi.h) is the C header of these
types. `roc glue` writes it from [glue/platform.roc](glue/platform.roc), a
stub platform whose `requires` names `Host.Array, Host.Schema -> Host.Array`.
Its static asserts hold every offset.

Rules the host keeps:

| Rule | Why |
|---|---|
| `null_count` is trusted | `from_host` reads the bitmap only when `null_count` is not 0. Pass -1 when the count is not known; a 0 with NULL bits set makes every row valid |
| The bitmap may have bits set past the last row | Arrow allows it; Roc reads only the bits of `offset ..< offset + length` |
| Guard against a double release | after `release`, set `release` to NULL and never call it again. Roc cannot detect a second release |
| `I128s` only for a 16-byte aligned buffer | else pass `U8s`, and Roc copies it into an aligned list. On x86-64 a misaligned `I128s` does not crash today, but the list Roc returns then breaks the alignment rule |
| `Utf8` only for valid UTF-8 | Roc does not check the bytes of a `Utf8` buffer. Invalid bytes break the invariants of `Str`, and Roc's string functions can then give wrong results or crash. A host that cannot promise valid UTF-8 passes `U8s`, and Roc checks it |
| `Utf8` only as the data buffer of a text or binary array | buffer 2 of Utf8, LargeUtf8, Binary and LargeBinary. Roc keeps the `Str` for Utf8 and LargeUtf8 only; any other buffer refuses it |

How a platform uses it:

1. Put the `Host` types in the platform's own `requires`, the same way
   `glue/platform.roc` does, and run `roc glue` on the platform to get its
   header.
2. Wrap each foreign buffer as a Roc list with no copy: point the list's
   allocation word at a static refcount word of 0. Roc never frees or changes
   such a list. Pick the `Host.Buffer` variant from the buffer's role in the
   format string; `U8s` is always accepted, and Roc then copies it into the
   typed form.
3. Pass `I128s` only when the pointer is 16-byte aligned; else pass `U8s`
   (see the rules above).
4. For trusted text, build the `Str` in big form as a seamless slice over the
   data buffer: `bytes` is the buffer, `length` is its byte count (high bit
   clear), and `capacity_or_alloc_ptr` is the same static word as for a list.
   This form is valid at any length, 23 bytes or less included. Roc reads
   rows from it with no copy, and an export gives the same bytes back as
   `U8s`.
5. Keep every input `ArrowArray` alive until the result is released, because
   a result can hold slices of its inputs.
6. To export a list that Roc allocated, take one reference and use the list's
   element pointer as the buffer. The `release` callback drops the reference.

To make the header again (for example after a compiler change):

```sh
scripts/glue.sh            # writes glue/roc_platform_abi.h
scripts/glue.sh --check    # fails when the file is not what roc glue writes
```

The script gets the glue specs (`CGlue.roc`) from the source archive of the
nightly in `.roc-version`, and compiles the header with `cc -std=c11`. Use
`ZigGlue.roc` or `RustGlue.roc` from the same archive for a Zig or Rust host.

## Differential tests against arrow-rs

[tests/contender](tests/contender) checks the package against arrow-rs, the
Rust implementation of Apache Arrow, through the C Data Interface. A Rust
driver exports arrow-rs arrays, a Roc test app reads them with the package,
and arrow-rs imports and checks what Roc gives back.

```
arrow-rs array ──to_ffi──▶ C ArrowArray ──host──▶ Host.Array ──▶ app.roc (entry point)
                                                                    │
arrow-rs array ◀──from_ffi + validate_full── C ArrowArray ◀── Host.Array (Roc lists)
```

| Part | File | Does |
|---|---|---|
| test app | [app.roc](tests/contender/app.roc) | the entry points; the schema name of the input picks one |
| test platform | [platform/main.roc](tests/contender/platform/main.roc) | the `requires` of `glue/platform.roc`; a static archive for `x64glibc` and `arm64glibc` |
| build | [build.rs](tests/contender/build.rs) | `roc build` of the app with `ROC` and `ROC_OPT`, then links it |
| runtime | [src/roc.rs](tests/contender/src/roc.rs) | the `Host` types as `repr(C)`, `roc_alloc` and the other hooks (with a count of live blocks per thread), static lists over a read-only refcount word of 0 |
| in | [src/import.rs](tests/contender/src/import.rs) | `HostInput`: a C array as static Roc lists, with zero copy; the buffer sizes as a C host computes them, or the true sizes for invalid data |
| out | [src/export.rs](tests/contender/src/export.rs) | a Roc result as a C array over the Roc lists; its release callback gives the value back to Roc |
| checks | [src/check.rs](tests/contender/src/check.rs), [src/digest.rs](tests/contender/src/digest.rs) | identity, digest and accept checks, and a shrinker that cuts a failing array to the fewest rows |
| data | [src/gen.rs](tests/contender/src/gen.rs), [src/mutate.rs](tests/contender/src/mutate.rs) | seeded random arrays; mutations at the buffer level |
| load | [src/lineitem.rs](tests/contender/src/lineitem.rs), [src/bin/bench_lineitem.rs](tests/contender/src/bin/bench_lineitem.rs) | the lineitem table and job, written for Roc and for arrow-rs; the bench driver |

| Entry point | Gives |
|---|---|
| `identity` | the array read through the views (`PrimitiveColumn`, `BoolColumn`, `BinaryColumn`, `Utf8Column`, `ListColumn`, `StructColumn`, `MapColumn`) and written again with `Writer` |
| `digest` | a Utf8 column: one text per row, read with the checked reads and `Items` |
| `validate` | one row: `accept`, or `refuse` and the error of `from_host` or of a view |
| `lineitem` | a batch job over a table modeled on TPC-H lineitem: filter, Decimal128 prices, a text change, totals per group; see [PERFORMANCE.md](PERFORMANCE.md) |

To add an entry point, add a branch to the `match` of `run` in `app.roc`,
then run it from Rust:

```rust
let input = HostInput::from_array("my_entry", &array, Feed::TYPED); // once
let result = input.run();                     // the Roc call alone
let out = result.into_arrow(&DataType::Int64)?; // from_ffi and validate_full
```

`HostInput` owns its lists, so `run` can be called again on the same input,
for example in a timing loop. A `RocResult` that is not imported gives its
value back to Roc when it is dropped.

| Corpus | Cases | Checks |
|---|---|---|
| valid, random | `CONTENDER_CASES` arrays (5000 by default), from `CONTENDER_SEED` | `identity` output `==` input (arrow-rs logical equality) and passes `validate_full`; `digest` equals the digest of arrow-rs reads; `validate` accepts; no Roc block leaks; the static refcount word stays 0 |
| valid, matrix | every leaf type, alone and in List, LargeList, FixedSizeList and Struct, with no, some and all NULLs, at 0, 1 and 37 rows | the same |
| invalid | `2 × CONTENDER_CASES` arrays, each with every mutation that fits it | Roc's `validate` agrees with arrow-rs's `validate_full`, or the difference is in the list below |
| edges | `null_count` -1; NULL buffers for an array of no rows | the same digest; accept |
| lineitem | 20000 rows of the bench table, in batches of 8192 and of 7 rows | `lineitem` gives the output of an arrow-rs row loop and of arrow-rs kernels, with checked and trusted text |

Each case runs with three feeds: typed lists, every buffer as `U8s` (Roc
copies it), and the text of Utf8 and LargeUtf8 as a trusted `Utf8` `Str`.

The types: Null, Boolean, Int8 .. Int64, UInt8 .. UInt64, Float16, Float32
and Float64 (with NaN payloads, infinities, -0 and subnormals), Decimal32,
Decimal64, Decimal128, Date32, Date64, Time32, Time64, Timestamp (no time
zone, `UTC`, `+05:30`, `Asia/Tokyo`), Duration (every unit), Utf8,
LargeUtf8, Utf8View, Binary, LargeBinary, BinaryView, FixedSizeBinary, and
List, LargeList, FixedSizeList (sizes 0 to 3), Struct and Map nested to depth
3. Text mixes ASCII, Latin, CJK and emoji, at lengths around 12 bytes (the
inline limit of a view) and 23 bytes (a small Roc `Str`). Arrays are cut from
longer ones at any level, so offsets are not 0; a NULL list row may keep
items.

The mutations: offsets that decrease, end past the data or child, or start
below 0; short values and offsets buffers; bytes that are not UTF-8; an
offset inside a character; views with a missing data buffer, an end past
their buffer, a wrong prefix, or bytes after an inline value; a short child;
a `null_count` that lies; NULLs under a field that is not nullable. A C
`ArrowArray` holds no buffer sizes, so a short buffer cannot go through
`from_ffi`: the invalid corpus gives Roc the true size of each buffer, and
asks arrow-rs `validate_full` on the same `ArrayData`.

Intended differences (Roc accepts, arrow-rs refuses):

| Input | arrow-rs | Roc | Why |
|---|---|---|---|
| `null_count` that is not 0 and not the count of 0 bits | refuses | accepts and reads the bitmap | Roc trusts `null_count` (see [Host ABI](#host-abi)). With a `null_count` of 0 both read every row as valid |
| NULLs in the child of a field that is not nullable | refuses | accepts; a read gives the NULLs | Roc does not check the nullability of a field |
| trusted text (`Utf8`) with an offset inside a character | refuses | accepts; that row decodes with replacement characters | Roc does not check trusted text. Bytes that are not UTF-8 in a trusted `Str` are not tested: they break the host's promise |
| a NULL offsets buffer for an array of no rows | `from_ffi` refuses | accepts | Roc reads it as an empty offsets buffer, which arrow-rs accepts for no rows |

| Command | Does |
|---|---|
| `scripts/test-contender.sh` | the CI run: 5000 random cases per test, some seconds after the build |
| `CONTENDER_CASES=100000 scripts/test-contender.sh` | a long run |
| `CONTENDER_SEED=<n> scripts/test-contender.sh` | another base seed; a failure prints the seed and case to run again |

## Develop

| Command | Does |
|---|---|
| `scripts/install-roc.sh` | installs the pinned nightly, prints the path of `roc` |
| `scripts/test.sh` | `roc fmt --check`, `roc check`, every `expect`, the examples, the glue check |
| `scripts/test-host.sh` | the C host test (Linux x86-64): zero-copy import, the `I128s` rule, trusted text and zero-copy export under AddressSanitizer, and one run per injected host fault, each of which must fail |
| `scripts/test-contender.sh` | the differential tests against arrow-rs (Linux x64 and arm64), see [Differential tests against arrow-rs](#differential-tests-against-arrow-rs) |
| `scripts/bench-host.sh` | times `Utf8Column` over 100k rows with `U8s` and with `Utf8` text (Linux x86-64) |
| `scripts/bench-contender.sh` | the lineitem bench against arrow-rs (Linux x64 and arm64), see [PERFORMANCE.md](PERFORMANCE.md) |
| `scripts/bundle.sh` | writes `dist/<hash>.tar.zst` and checks that it holds every module |
| `scripts/test_bundle.sh` | runs the examples against the bundle, by path and over localhost |
| `scripts/glue.sh` | makes the C header again |

`package/main.roc` lists the public modules. `package/tests.roc` lists them
and the test modules (`*Test.roc`), so `roc test package/tests.roc` runs every
`expect`. The bundle holds only what `main.roc` imports, so the test modules
are not in it.

| Workflow | When |
|---|---|
| `test.yml` | each push to main and each pull request: Linux x64, Linux arm64, macOS; the C host test on Linux x64; the differential tests on Linux x64 and arm64 |
| `release.yml` | a pushed version tag: test, bundle, test the bundle, draft the release |
| `test-nightly-roc.yml` | daily: the latest release on the latest nightly |
| `deploy-docs.yml` | each push to main: `roc docs` to GitHub Pages |
| `bench.yml` | by hand only: the lineitem bench on Linux x64 and arm64; the report goes to the job summary and an artifact |

## Changelog

### 0.0.2

| Change | Effect |
|---|---|
| `Host.Buffer.Utf8(Str)`, tag 12 | trusted text: a host that promises valid UTF-8 passes the text buffer as a `Str`, and Roc does not check it. Tags 0 .. 11 keep their numbers, and `Host.Buffer` stays 32 bytes |
| `Array.from_host` | takes `Utf8(str)` as the data buffer of Utf8, LargeUtf8, Binary and LargeBinary, with no copy |
| `Array.trusted_text` | new: the host's `Str` of a Utf8 or LargeUtf8 array |
| `Array.to_host` | a trusted text buffer goes out as `U8s` over the same bytes |
| `Utf8Column.from_array` | uses the trusted `Str` and skips the UTF-8 check (about 10 to 16 times faster for non-ASCII text); a `U8s` buffer is checked as before |
| `glue/roc_platform_abi.h` | `HostBufferTag_Utf8`, `HostBuffer_make_utf8`, `HostBuffer_payload_utf8` |
| `Array.from_host` | takes an empty offsets buffer, and `Absent` (NULL) buffers, for an array of no rows, as arrow-rs does |
| `Array.from_host` | refuses a view whose prefix is not the start of its value, or an inline view with bytes after its value, as arrow-rs does |
| `Utf8Column.is_valid_utf8` | false when an offset of a `U8s` text is inside a character; each row then decodes its own bytes |

A 0.0.1 host works with no change: tags 0 .. 11 keep their numbers, and no
export of the package holds a `Utf8` buffer. Rebuild it against the new
header to use `Utf8`.

### 0.0.1

The first release.

## License

Universal Permissive License (UPL), Version 1.0. See [LICENSE](LICENSE).
