# Performance

How fast the package is against arrow-rs on a realistic batch job, and why
it is slower where it is slower. The bench is not a microbenchmark: each
side imports every batch of a 1M-row table through the Arrow C Data
Interface, runs the whole job, and exports the result, as a host does.

| Item | Where |
|---|---|
| table and job, Roc and arrow-rs | [tests/contender/src/lineitem.rs](tests/contender/src/lineitem.rs), entry points `lineitem` and `lineitem_str` in [tests/contender/app.roc](tests/contender/app.roc) |
| bench driver and sampling profiler | [tests/contender/src/bin/bench_lineitem.rs](tests/contender/src/bin/bench_lineitem.rs) |
| run it | `scripts/bench-contender.sh` (report in `tests/contender/target/bench-lineitem.md`); `bench.yml` in CI, by hand only |
| same output on both sides | `tests/contender/tests/lineitem.rs` in `scripts/test-contender.sh`, and a check of every batch before each timed run |

## Summary

On one pinned core, the Roc job takes 1.07 times the time of the arrow-rs
row loop with trusted text (1M rows, batches of 8192), and 1.06 times at
batches of 65536. With checked text it takes 1.4 times: the extra is the
UTF-8 check at import. The same job written with a `Str` per text read and
write (`lineitem_str`, the style of the first bench) takes 2.0 to 2.2 times.

The byte reads of `Utf8Column` and the writer's parts closed the text gap:
the text change and the export now take less time in Roc than in arrow-rs.
What is left is in the numeric work and the import.

| Phase (1M rows, batch 8192, trusted text) | arrow-rs rows ms | Roc before ms | Roc now ms | Roc now / arrow-rs | What changed |
|---|---:|---:|---:|---:|---|
| host | 0.0 | 1.8 | 2.1 | | nothing (the test host makes its `Host` values per batch) |
| import | 2.6 | 5.0 | 5.1 | 2.0x | nothing (`Array.from_host` checks every buffer) |
| numeric | 19.4 | 25.6 | 24.8 | 1.3x | flags read with `byte_len` and `byte_at`: no `Str` slice and no reference count per flag |
| text and export | 41.6 | 91.1 | 35.8 | 0.86x | `trim_ascii`, `find_byte`, then `part_upper` and `part_range` into the writer: each byte copied once, no `Str` |
| whole job | 63.7 | 123.5 | 67.8 | 1.07x | |

"Roc before" is the first run of this bench (0.0.2 before the byte reads and
the parts, [below](#before-the-byte-reads-and-the-parts)); "arrow-rs rows"
and "Roc now" are from the same run. That run of arrow-rs took 57.0 ms: the
machine load was the same (1-minute load average 5.5 and 5.4), but compare
ratios, not absolute times.

## Method

### Data

A deterministic generator (SplitMix64, fixed seed) makes a table modeled on
TPC-H `lineitem`: orders of 1 to 7 lines, sparse order keys, prices from
the part key, dates from 1992 to 1998, and returnflag and linestatus from
the dates as TPC-H sets them.

| Column | Type | Values |
|---|---|---|
| orderkey, partkey, suppkey | Int64 | keys |
| linenumber | Int32 | 1 to 7 |
| quantity, extendedprice | Decimal128(15, 2) | 1 to 50; quantity times the part's price |
| discount, tax | Decimal128(15, 2), 5% NULL | 0.00 to 0.10; 0.00 to 0.08 |
| returnflag, linestatus | Utf8, 1 character | A, N, R; F, O |
| shipdate, commitdate | Date32 | |
| receiptdate | Date32, 5% NULL | |
| shipinstruct | Utf8 | 4 values |
| shipmode | Utf8, 5% NULL | 7 values |
| comment | Utf8, 5% NULL | 10 to 44 characters (mean 23.6, 25.1 bytes); 30% hold Latin with accents, CJK, Hangul, Cyrillic or emoji; 10% have spaces before or after |

1M rows are 167 MB of Arrow buffers; `LINEITEM_ROWS=6000000` gives the
6M-row table (TPC-H scale factor 1). The table is cut into batches of 8192
and of 65536 rows, each a copy at offset 0, as a producer sends them.

### Job

The same job on each side, per batch, written the usual way for each:

| Step | Roc (`lineitem` in app.roc) | arrow-rs rows (`by_rows`) | arrow-rs kernels (`by_kernels`) |
|---|---|---|---|
| import | the host wraps the C buffers as Roc lists (no copy); `Array.from_host`, `StructColumn`, `PrimitiveColumn`, `Utf8Column` | `to_ffi`, `from_ffi`, `make_array` | the same |
| filter: 1994-01-01 <= shipdate < 1997-03-01 (51% of rows) | `if` in the row loop | `continue` in the row loop | `gt_eq`, `lt`, `and`, then one `FilterBuilder` for 8 columns |
| disc_price = extendedprice * (1 - discount), Decimal128(38, 4); charge = disc_price * (1 + tax), Decimal128(38, 6) | `I128` arithmetic | `i128` arithmetic | `sub`, `mul`, `add` kernels |
| comment_norm: trim, first word in ASCII uppercase; comment_len in bytes | `trim_ascii`, `find_byte` of the first space, then `Writer.str_begin`, `part_upper` of the first word, `part_range` of the rest, `part_len`, `str_end` | `trim`, `split_once`, `to_ascii_uppercase` into one reused `String`, `StringBuilder` | the same loop (arrow-rs has no kernel for it); `length` kernel |
| totals per (returnflag, linestatus): count, sums of quantity, extendedprice, disc_price, charge | the group from `byte_len` and `byte_at` of each flag; a list of 6 records, `List.update` | an array of 6 structs | the same loop over the value slices |
| export: one Struct row of `rows` (List of Struct) and `groups` (List of Struct) | `Writer`, then the host exports the Roc lists with no copy | builders, `StructArray`, `ListArray`; `to_ffi` | the same |
| the consumer imports the result | `from_ffi`, no `validate_full` | `from_ffi`, no `validate_full` | the same |

`lineitem_str` is the same job with a `Str` per text read and write: the
flags as `Utf8Column.at` slices, and comment_norm with `trim`, `split_first`,
`with_ascii_uppercased`, interpolation and `Writer.str_push`.

arrow-rs `trim` removes Unicode white space, and `trim_ascii` only ASCII
white space. Each Unicode white space character outside ASCII starts with
0xC2, 0xE1, 0xE2 or 0xE3, so `lineitem` gives a comment whose trimmed span
starts with one of those bytes, or has one 2 or 3 bytes before its end, to
the `Str` path; the other comments trim the same. The bench data holds none
of them (0.4% of its comments go to the `Str` path for other characters,
for example a final "✅"); `tests/contender/tests/lineitem.rs` checks comments
with Unicode white space at the ends.

Before it times, each run checks its output against `by_rows` on every
batch with arrow-rs logical equality, and checks it with `validate_full`.
The differential test in `scripts/test-contender.sh` does the same on a
smaller table and on batches of 7 rows. A fault in either side fails it (for
example, a Roc `normalize` with no `trim`).

### Measurement

| Item | Value |
|---|---|
| builds | Roc `--opt speed` (LLVM); Rust `--release` (opt-level 3) |
| threads | one on each side; the process is pinned to one CPU with `taskset` |
| passes | one warm-up pass, then 9 timed passes over every batch; median, min and max |
| rates | rows/s and input MB/s from the median, over all input rows and buffer bytes |
| memory | peak RSS (VmHWM) of the process, which holds the table; RSS growth is the peak over the RSS before the timed passes (`/proc/self/clear_refs` resets the peak) |
| allocations | heap blocks per input row, Rust's (a counting global allocator) and Roc's (`roc_alloc` and `roc_realloc`) together |
| phases | each phase run stops after that phase; a phase costs the difference to the run before it |
| profile | `perf` is not allowed on the bench machine (`perf_event_paranoid` 4), so the driver samples the program counter on SIGPROF (`LINEITEM_PROFILE=1`) and `nm` names the symbol |

### What is the same on both sides, and what is not

| Item | Roc | arrow-rs | Effect |
|---|---|---|---|
| memory allocator | glibc `malloc` and `realloc` through `roc_alloc` and `roc_realloc` | glibc `malloc` through Rust's system allocator | the same |
| import checks | `Array.from_host` checks offsets, lengths and buffer sizes of every column; a `U8s` text buffer is checked as UTF-8 | `from_ffi` trusts the producer and checks nothing | Roc pays for safety arrow-rs does not give; trusted text drops the UTF-8 check |
| integer overflow | `*` and `+` on `I128` crash on overflow | `*` and `+` on `i128` wrap in release; the kernels check | Roc pays for a check the row loop does not make |
| host values | the test host makes `Host.Array` and `Host.Schema` values from the C structs for each batch ("host" phase) | none | part of the Roc time; a real host does the same |

## Results

AMD Ryzen AI 9 HX 370 (x86-64), Linux, Roc nightly-2026-11-15-f25da45, rustc
1.99.0. The machine is shared: the 1-minute load average was 3.5 to 5.5
during the runs (24 CPUs), and each process was pinned to one CPU. Under
heavy load the same runs took up to 2.5 times longer on both sides; compare
the min column, and compare ratios, not absolute times.

### 1M rows

Whole job, time per pass over all rows (9 timed passes). "Roc" is
`lineitem`, "Roc Str" is `lineitem_str`:

| Way | Batch rows | Median ms | Min ms | Max ms | Mrows/s | Input MB/s | Time vs arrow-rs rows | Peak RSS MiB | RSS growth MiB | Allocations per row |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| arrow-rs rows | 8192 | 63.7 | 63.4 | 83.0 | 15.71 | 2616 | 1.00x | 169 | 0.5 | 0.59 |
| arrow-rs kernels | 8192 | 78.7 | 78.6 | 81.0 | 12.70 | 2115 | 1.24x | 170 | 0.1 | 0.59 |
| Roc, checked text | 8192 | 90.2 | 90.0 | 90.9 | 11.09 | 1846 | 1.42x | 169 | 0.0 | 0.12 |
| Roc, trusted text | 8192 | 67.8 | 67.1 | 68.4 | 14.74 | 2455 | 1.07x | 169 | 0.0 | 0.12 |
| Roc Str, checked text | 8192 | 152.5 | 151.8 | 153.3 | 6.56 | 1092 | 2.40x | 169 | 0.0 | 0.38 |
| Roc Str, trusted text | 8192 | 129.5 | 129.1 | 132.1 | 7.72 | 1286 | 2.03x | 169 | 0.0 | 0.38 |
| arrow-rs rows | 65536 | 53.9 | 53.8 | 55.2 | 18.54 | 3088 | 1.00x | 171 | 0.0 | 0.50 |
| arrow-rs kernels | 65536 | 65.5 | 65.3 | 65.6 | 15.26 | 2542 | 1.21x | 176 | 0.1 | 0.50 |
| Roc, checked text | 65536 | 75.7 | 75.3 | 76.3 | 13.22 | 2201 | 1.40x | 172 | 0.0 | 0.02 |
| Roc, trusted text | 65536 | 57.4 | 56.7 | 57.7 | 17.41 | 2900 | 1.06x | 171 | 0.0 | 0.02 |
| Roc Str, checked text | 65536 | 136.3 | 135.6 | 136.7 | 7.34 | 1222 | 2.53x | 172 | 0.0 | 0.28 |
| Roc Str, trusted text | 65536 | 117.1 | 116.9 | 118.1 | 8.54 | 1422 | 2.17x | 171 | 0.0 | 0.28 |

Phases, median ms per pass:

| Way | Batch rows | host | import | numeric | text and export | full |
|---|---:|---:|---:|---:|---:|---:|
| arrow-rs rows | 8192 | 0.0 | 2.6 | 19.4 | 41.6 | 63.7 |
| Roc, checked text | 8192 | 2.1 | 24.5 | 26.6 | 36.9 | 90.2 |
| Roc, trusted text | 8192 | 2.1 | 5.1 | 24.8 | 35.8 | 67.8 |
| Roc Str, trusted text | 8192 | 2.2 | 5.1 | 29.6 | 92.6 | 129.5 |
| arrow-rs rows | 65536 | 0.0 | 0.3 | 16.3 | 37.3 | 53.9 |
| Roc, checked text | 65536 | 0.2 | 21.4 | 22.6 | 31.4 | 75.7 |
| Roc, trusted text | 65536 | 0.2 | 3.3 | 22.9 | 31.0 | 57.4 |
| Roc Str, trusted text | 65536 | 0.2 | 3.3 | 28.3 | 85.3 | 117.1 |

Roc makes 0.12 heap allocations per input row at batch 8192 (0.02 at
65536), against 0.59 (0.50) for arrow-rs and 0.38 (0.28) for the `Str`
style: a row written in parts allocates nothing.

### Before the byte reads and the parts

The first run of this bench, before `Utf8Column` had the byte reads and
`Writer` had the parts: the Roc job was the `Str` style that `lineitem_str`
keeps. The 1-minute load average was 4 to 6.

#### 1M rows

Whole job, time per pass over all rows (9 timed passes):

| Way | Batch rows | Median ms | Min ms | Max ms | Mrows/s | Input MB/s | Time vs arrow-rs rows | Peak RSS MiB | RSS growth MiB | Allocations per row |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| arrow-rs rows | 8192 | 57.0 | 57.0 | 57.9 | 17.53 | 2919 | 1.00x | 169 | 0.5 | 0.59 |
| arrow-rs kernels | 8192 | 69.0 | 68.4 | 69.5 | 14.49 | 2413 | 1.21x | 170 | 0.1 | 0.59 |
| Roc, checked text | 8192 | 141.5 | 140.7 | 145.0 | 7.06 | 1177 | 2.48x | 169 | 0.0 | 0.38 |
| Roc, trusted text | 8192 | 123.5 | 122.6 | 125.2 | 8.10 | 1349 | 2.16x | 169 | 0.0 | 0.38 |
| arrow-rs rows | 65536 | 55.3 | 51.5 | 70.8 | 18.09 | 3013 | 1.00x | 171 | 0.1 | 0.50 |
| arrow-rs kernels | 65536 | 62.8 | 61.8 | 77.1 | 15.93 | 2652 | 1.14x | 176 | 0.0 | 0.50 |
| Roc, checked text | 65536 | 134.4 | 133.5 | 137.4 | 7.44 | 1239 | 2.43x | 171 | 0.0 | 0.28 |
| Roc, trusted text | 65536 | 127.5 | 115.7 | 146.4 | 7.84 | 1306 | 2.31x | 171 | 0.0 | 0.28 |

Phases, median ms per pass:

| Way | Batch rows | host | import | numeric | text and export | full |
|---|---:|---:|---:|---:|---:|---:|
| arrow-rs rows | 8192 | 0.0 | 2.3 | 15.5 | 39.2 | 57.0 |
| Roc, checked text | 8192 | 1.8 | 22.5 | 26.1 | 91.2 | 141.5 |
| Roc, trusted text | 8192 | 1.8 | 5.0 | 25.6 | 91.1 | 123.5 |
| arrow-rs rows | 65536 | 0.0 | 0.3 | 14.6 | 40.3 | 55.3 |
| Roc, checked text | 65536 | 0.2 | 20.5 | 26.2 | 87.5 | 134.4 |
| Roc, trusted text | 65536 | 0.2 | 3.1 | 25.6 | 98.5 | 127.5 |

#### 6M rows

Whole job (7 timed passes):

| Way | Batch rows | Median ms | Min ms | Max ms | Mrows/s | Input MB/s | Time vs arrow-rs rows | Peak RSS MiB | RSS growth MiB | Allocations per row |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| arrow-rs rows | 8192 | 352.7 | 350.0 | 363.8 | 17.01 | 2832 | 1.00x | 983 | 0.0 | 0.59 |
| arrow-rs kernels | 8192 | 439.9 | 421.9 | 499.6 | 13.64 | 2271 | 1.25x | 987 | 0.1 | 0.59 |
| Roc, checked text | 8192 | 866.7 | 863.3 | 877.2 | 6.92 | 1153 | 2.46x | 986 | 0.0 | 0.37 |
| Roc, trusted text | 8192 | 761.3 | 758.5 | 765.3 | 7.88 | 1312 | 2.16x | 986 | 0.0 | 0.37 |
| arrow-rs rows | 65536 | 306.4 | 305.0 | 308.8 | 19.58 | 3261 | 1.00x | 971 | 0.0 | 0.50 |
| arrow-rs kernels | 65536 | 373.9 | 371.3 | 374.1 | 16.05 | 2672 | 1.22x | 975 | 0.0 | 0.50 |
| Roc, checked text | 65536 | 823.8 | 816.0 | 927.8 | 7.28 | 1213 | 2.69x | 972 | 0.0 | 0.27 |
| Roc, trusted text | 65536 | 726.4 | 708.3 | 781.3 | 8.26 | 1375 | 2.37x | 971 | 0.0 | 0.27 |

Phases, median ms per pass:

| Way | Batch rows | host | import | numeric | text and export | full |
|---|---:|---:|---:|---:|---:|---:|
| arrow-rs rows | 8192 | 0.0 | 17.2 | 95.2 | 240.4 | 352.7 |
| Roc, checked text | 8192 | 12.6 | 137.0 | 160.2 | 556.8 | 866.7 |
| Roc, trusted text | 8192 | 12.7 | 29.6 | 162.7 | 556.4 | 761.3 |
| arrow-rs rows | 65536 | 0.0 | 1.7 | 87.9 | 216.8 | 306.4 |
| Roc, checked text | 65536 | 1.3 | 121.4 | 176.7 | 524.5 | 823.8 |
| Roc, trusted text | 65536 | 1.6 | 18.4 | 162.6 | 543.7 | 726.4 |

## What is left

The profile of the whole Roc job (trusted text, batch 8192;
`BENCH_PROFILE=1`, the default of the script). The `roc__p...` names are
Roc procedures, named by a hash: the phase runs put `pb0385...` in the
import (50% of the import samples) and `p6112...` and `p844d...` in the row
loop (59% of the numeric samples).

```
samples	1164
 37.8%	roc__p7f5494624c23d5d439e4b41c3bd28c96.fast
 25.0%	roc__p6112f2e3e33114e8af5eccb75f8ffe28.fast
  7.9%	roc__p844da0cc989cbc6d0546e6df8a80a405.fast
  6.4%	roc__pb0385ac3fa8f4c20b3a2ddc16eb05a58.fast
  5.6%	dev_wrappers.roc_builtins_num_mul_with_overflow_i128
  4.8%	(shared libraries: libc malloc, free, memcpy)
  3.4%	memcpy
  0.7%	__rustc::__rust_alloc
  0.5%	roc_llvm_rc_decref_185
  0.4%	roc_llvm_rc_incref_185
  0.3%	roc_llvm_rc_decref_84
  0.3%	roc_llvm_rc_decref_27
  0.3%	roc_cold_shim.roc_builtins_list_reserve_for_append
  0.3%	roc__p7f519a79a5d47000557d05972726fb84.fast
  0.3%	__rustc::__rust_no_alloc_shim_is_unstable_v2
  0.3%	<arrow_array::ffi::ImportedArrowArray>::consume
  0.3%	<arrow_array::array::byte_array::GenericByteArray<arrow_array::types::GenericStringType<i32>> as arrow_array::
  0.2%	roc_llvm_rc_incref_59
  0.2%	roc__p95d52a98025dafa3d9a7804e77c169f2.fast
  0.2%	list.listReserveForAppend
```

No `Str` builtin is left in the profile (before: about 40% of the samples
in `roc_builtins_str_*` and their helpers), and the reference counts fell
from 8% to under 2%. The Roc numeric phase alone:

```
samples	536
 42.4%	roc__p6112f2e3e33114e8af5eccb75f8ffe28.fast
 16.8%	roc__p844da0cc989cbc6d0546e6df8a80a405.fast
 14.4%	roc__pb0385ac3fa8f4c20b3a2ddc16eb05a58.fast
 12.1%	dev_wrappers.roc_builtins_num_mul_with_overflow_i128
  4.5%	(shared libraries: libc malloc, free, memcpy)
  0.9%	roc_llvm_rc_incref_185
  0.9%	roc_llvm_rc_decref_84
  0.7%	__rustc::__rust_alloc
  0.6%	roc_llvm_rc_decref_93
  0.6%	roc_llvm_rc_decref_185
```

The rest of the gap, 4.1 ms per 1M rows at batch 8192 and 3.5 ms at 65536:

| Cost | Evidence | Size | Owner |
|---|---|---|---|
| `I128` multiply with an overflow check is a call to `num_mul_with_overflow_i128`, not inline; arrow-rs `i128 *` wraps and is inline | 12% of the numeric phase, 5.6% of the job | about 3 ms | compiler: the builtin is not inlined. The bench keeps the usual check of each side, so the app does not use `times_wrap` |
| `Array.from_host` checks the offsets, lengths and buffer sizes of every column; `from_ffi` checks nothing | import phase 5.1 ms against 2.6 ms at batch 8192 (3.3 against 0.3 at 65536) | 2.5 to 3 ms | package, by design: the checks are what make the views safe |
| the test host makes its `Host` values from the C structs for each batch | host phase 2.1 ms at batch 8192, 0.2 ms at 65536 | a cost per batch | test host; a real host does the same |
| row loop: the views' `at` and `is_valid`, the `Writer` pushes, `List.update` of the totals | `p6112...`, `p844d...` | numeric work 1.3 times arrow-rs | compiler code generation; no builtin call or reference count is left in it |

The text change and the export are now 14% faster than in arrow-rs: the
ASCII trim and the first-space search are byte loops that LLVM inlines,
and each byte goes once from the column's buffer to the writer's, where
arrow-rs `normalize` decodes code points for `trim` and copies the
uppercase first word through a temporary `String`.

## Why the Str style is slower

This is the analysis of the first run. It holds for `lineitem_str` today.

### Text: 2.3 times arrow-rs, about 80% of the gap

The text change and the export take 91 ms in Roc and 39 ms in arrow-rs:
about 178 ns and 76 ns per kept row. The profile of the whole Roc job
(trusted text, batch 8192; `BENCH_PROFILE=1`, the default of the script):

```
samples	2460
 29.3%	roc__pddf9214452190c9ba2bc7db5b5ca3e83.fast
  9.1%	dev_wrappers.roc_builtins_str_trim
  6.9%	dev_wrappers.roc_builtins_str_with_ascii_uppercased
  5.9%	roc_llvm_rc_decref_1
  5.1%	str.RocStr.copyKeepingCapacity
  4.8%	(shared libraries: libc malloc, free, memcpy)
  3.8%	dev_wrappers.roc_builtins_str_split_first
  3.8%	mem.findPos__func_444
  3.5%	memcpy
  3.1%	dev_wrappers.roc_builtins_str_from_parts
  2.8%	roc__pb0385ac3fa8f4c20b3a2ddc16eb05a58.fast
  2.6%	unicode.utf8Decode
  2.4%	dev_wrappers.roc_builtins_str_to_utf8
  2.4%	dev_wrappers.roc_builtins_num_mul_with_overflow_i128
  2.3%	dev_wrappers.roc_builtins_str_substring_unsafe
  2.0%	str.RocStr.reallocateFresh
  1.9%	dev_wrappers.roc_builtins_list_append_sublist
  1.5%	roc_llvm_rc_decref_35
  0.9%	list.listReserveForAppend
  0.9%	roc_llvm_rc_incref_165
```

The same for the arrow-rs row loop:

```
samples	1151
 22.9%	contender::lineitem::row_loop
 17.7%	(shared libraries: libc malloc, free, memcpy)
 12.9%	core::slice::memchr::memchr_aligned
 10.8%	contender::lineitem::normalize
  7.6%	__rustc::__rust_alloc
  7.2%	<str>::trim_matches::<<char>::is_whitespace>
  4.7%	<arrow_array::builder::primitive_builder::PrimitiveBuilder<arrow_array::types::Decimal128Type>>::append_value
  3.6%	<arrow_array::builder::generic_bytes_builder::GenericByteBuilder<arrow_array::types::GenericStringType<i32>>>:
  2.4%	__rustc::__rust_no_alloc_shim_is_unstable_v2
  1.7%	<arrow_array::builder::primitive_builder::PrimitiveBuilder<arrow_array::types::Int32Type>>::append_value
  1.2%	<arrow_array::builder::primitive_builder::PrimitiveBuilder<arrow_array::types::Int64Type>>::append_value
  0.4%	<arrow_buffer::builder::null::NullBufferBuilder>::materialize_if_needed
  0.3%	arrow_data::data::layout
  0.3%	<arrow_array::builder::primitive_builder::PrimitiveBuilder<arrow_array::types::Decimal128Type>>::append_null
  0.3%	<arrow_array::array::byte_array::GenericByteArray<arrow_array::types::GenericStringType<i32>> as arrow_array::
  0.3%	__rustc::__rust_dealloc
  0.3%	<arrow_array::ffi::ImportedArrowArray>::buffer_len
  0.2%	core::ptr::drop_glue::<arrow_array::array::struct_array::StructArray>
  0.2%	arrow_array::array::make_array
  0.2%	<core::iter::adapters::map::Map<core::ops::range::Range<usize>, <arrow_array::ffi::ImportedArrowArray>::buffer
```

| Cost | Evidence (share of Roc samples) | arrow-rs |
|---|---|---|
| Each `Str` operation is a call into the builtins, not inlined into the row loop: `trim`, `split_first`, `with_ascii_uppercased`, interpolation (`str_from_parts`), `to_utf8`, `append_sublist` | about 40% in `roc_builtins_str_*`, `roc_builtins_list_*` and their helpers (`findPos`, `utf8Decode`, `substring_unsafe`, `copyKeepingCapacity`) | `trim`, `split_once` (`memchr`) and `to_ascii_uppercase` inline into one function |
| `with_ascii_uppercased` of a slice copies the text into a new `Str` (`copyKeepingCapacity`, `reallocateFresh`), then interpolation copies it again into the result, then `Writer.str_push` copies the result into the column | 7% in `copyKeepingCapacity` and `reallocateFresh`, 3.5% `memcpy` | one `String` buffer, reused, then one copy into the builder |
| `trim` decodes the code points at both ends to test for Unicode white space | 9% `str_trim`, 3% `utf8Decode` | `trim_matches` 7% |
| Every slice of the column text holds a reference: an increment and a decrement per row and column | 8% in `roc_llvm_rc_decref_*` and `rc_incref_*` | borrowed `&str`, no count |

Roc makes fewer heap allocations than arrow-rs (0.38 against 0.59 per row,
since a `Str` of 23 bytes or less is not on the heap), so the gap is not
the allocator: it is calls, copies and reference counts per row.

The writer's parts (`part_upper`, `part_range`) and `trim_ascii` remove
these copies and builtin calls; see [What is left](#what-is-left).

### Numeric work: 1.7 times arrow-rs

The filter, the prices and the totals take 25.6 ms in Roc and 15.5 ms in
arrow-rs. The profile of the Roc numeric phase:

```
samples	1285
 55.4%	roc__pddf9214452190c9ba2bc7db5b5ca3e83.fast
 11.0%	roc__pb0385ac3fa8f4c20b3a2ddc16eb05a58.fast
  9.6%	dev_wrappers.roc_builtins_num_mul_with_overflow_i128
  5.5%	dev_wrappers.roc_builtins_str_substring_unsafe
  4.2%	(shared libraries: libc malloc, free, memcpy)
  4.1%	roc_llvm_rc_decref_1
  1.8%	roc_llvm_rc_incref_165
  1.7%	roc_llvm_rc_decref_84
  0.6%	__rustc::__rust_alloc
  0.5%	roc_llvm_rc_decref_201
  0.5%	roc_llvm_rc_decref_165
  0.5%	<core::iter::adapters::map::Map<core::iter::adapters::enumerate::Enumerate<core::slice::iter::Iter<contender::
```

| Cost | Evidence | arrow-rs |
|---|---|---|
| `I128` multiply with an overflow check is a call to `num_mul_with_overflow_i128` | 10% of the phase | `i128 *` is inline and does not check |
| `Utf8Column.at` gives returnflag and linestatus as `Str` slices: two cuts and a reference count per row and column | 5.5% `str_substring_unsafe`, 8% `rc_decref` and `rc_incref` | `value(i)` is a `&str` from two offsets |

The row loop itself (the views' `at` and `is_valid`, the `Writer` pushes,
`List.update` of the totals) compiles to tight code: most samples are in the
main Roc function, and the phase is within 1.7 times of arrow-rs.

### Import

With trusted text (`Host.Buffer.Utf8`) the import costs 5 ms per 1M rows
against 2.3 ms for arrow-rs; the extra is `Array.from_host` checking every
buffer, which `from_ffi` does not do. With checked text (`U8s`), Roc checks
the three text columns it reads (returnflag, linestatus, comment) as UTF-8
when it makes their views: 17.5 ms more for about 26 MB of text (1.5 GB/s),
which is the whole difference between the two Roc lines. A host that knows
its text is valid UTF-8 (arrow-rs arrays are) should pass it as `Utf8`.

The "host" phase (1.8 ms at batch 8192, 0.2 ms at 65536) is the test host
making its `Host` values for each batch: a cost per batch, not per row.

### Where Roc is not slower

| Item | Result |
|---|---|
| memory | the same peak RSS: the job's working set is small next to the table, and the `Writer` lists go to arrow-rs with no copy |
| allocations | fewer than arrow-rs (small `Str` values are not on the heap) |
| batch size | both sides gain a little from larger batches; the ratio stays at 2.2 to 2.7 |
| arrow-rs kernels | slower than the arrow-rs row loop here (1.1 to 1.25 times): the filter copies 8 columns before the arithmetic, and the text still needs a loop |
