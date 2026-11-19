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
| Tests | 272 `expect`s, 3 examples, a C host test under AddressSanitizer |

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

## Develop

| Command | Does |
|---|---|
| `scripts/install-roc.sh` | installs the pinned nightly, prints the path of `roc` |
| `scripts/test.sh` | `roc fmt --check`, `roc check`, every `expect`, the examples, the glue check |
| `scripts/test-host.sh` | the C host test (Linux x86-64): zero-copy import, the `I128s` rule, trusted text and zero-copy export under AddressSanitizer, and one run per injected host fault, each of which must fail |
| `scripts/bench-host.sh` | times `Utf8Column` over 100k rows with `U8s` and with `Utf8` text (Linux x86-64) |
| `scripts/bundle.sh` | writes `dist/<hash>.tar.zst` and checks that it holds every module |
| `scripts/test_bundle.sh` | runs the examples against the bundle, by path and over localhost |
| `scripts/glue.sh` | makes the C header again |

`package/main.roc` lists the public modules. `package/tests.roc` lists them
and the test modules (`*Test.roc`), so `roc test package/tests.roc` runs every
`expect`. The bundle holds only what `main.roc` imports, so the test modules
are not in it.

| Workflow | When |
|---|---|
| `test.yml` | each push to main and each pull request: Linux x64, Linux arm64, macOS; the C host test on Linux x64 |
| `release.yml` | a pushed version tag: test, bundle, test the bundle, draft the release |
| `test-nightly-roc.yml` | daily: the latest release on the latest nightly |
| `deploy-docs.yml` | each push to main: `roc docs` to GitHub Pages |

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

A 0.0.1 host works with no change: tags 0 .. 11 keep their numbers, and no
export of the package holds a `Utf8` buffer. Rebuild it against the new
header to use `Utf8`.

### 0.0.1

The first release.

## License

Universal Permissive License (UPL), Version 1.0. See [LICENSE](LICENSE).
