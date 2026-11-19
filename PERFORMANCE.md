# Performance

How fast the package is against arrow-rs on a realistic batch job, and why
it is slower where it is slower. The bench is not a microbenchmark: each
side imports every batch of a 1M-row table through the Arrow C Data
Interface, runs the whole job, and exports the result, as a host does.

| Item | Where |
|---|---|
| table and job, Roc and arrow-rs | [tests/contender/src/lineitem.rs](tests/contender/src/lineitem.rs), entry point `lineitem` in [tests/contender/app.roc](tests/contender/app.roc) |
| bench driver and sampling profiler | [tests/contender/src/bin/bench_lineitem.rs](tests/contender/src/bin/bench_lineitem.rs) |
| run it | `scripts/bench-contender.sh` (report in `tests/contender/target/bench-lineitem.md`); `bench.yml` in CI, by hand only |
| same output on both sides | `tests/contender/tests/lineitem.rs` in `scripts/test-contender.sh`, and a check of every batch before each timed run |

## Summary

On one pinned core, the Roc job takes 2.2 times the time of the arrow-rs row
loop with trusted text, and 2.5 times with checked text (1M rows, batches of
8192); 2.2 to 2.7 times over all runs, 1M and 6M rows, both batch sizes.
About 80% of the gap is the per-row text change and the export; the numeric
work is 1.7 times arrow-rs, and the import with trusted text costs about
3 ms more per 1M rows.

| Phase (1M rows, batch 8192) | arrow-rs rows ms | Roc, trusted text ms | Roc / arrow-rs | Main cause in Roc |
|---|---:|---:|---:|---|
| host | 0.0 | 1.8 | | the test host makes its `Host` values per batch |
| import | 2.3 | 5.0 | 2.2x | `Array.from_host` checks every buffer; arrow-rs `from_ffi` does not |
| numeric | 15.5 | 25.6 | 1.7x | checked `I128` multiply as a call; a `Str` slice per 1-character flag |
| text and export | 39.2 | 91.1 | 2.3x | eight out-of-line `Str` builtins per row, two copies of the text, refcounts |
| whole job | 57.0 | 123.5 | 2.2x | |

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
| comment_norm: trim, first word in ASCII uppercase; comment_len in bytes | `trim`, `split_first`, `with_ascii_uppercased`, interpolation, `Writer.str_push` | `trim`, `split_once`, `to_ascii_uppercase` into one reused `String`, `StringBuilder` | the same loop (arrow-rs has no kernel for it); `length` kernel |
| totals per (returnflag, linestatus): count, sums of quantity, extendedprice, disc_price, charge | a list of 6 records, `List.update` | an array of 6 structs | the same loop over the value slices |
| export: one Struct row of `rows` (List of Struct) and `groups` (List of Struct) | `Writer`, then the host exports the Roc lists with no copy | builders, `StructArray`, `ListArray`; `to_ffi` | the same |
| the consumer imports the result | `from_ffi`, no `validate_full` | `from_ffi`, no `validate_full` | the same |

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
1.99.0. The machine is shared: the 1-minute load average was 4 to 6 during both
runs (24 CPUs; it was higher earlier, see the 5- and 15-minute values in
the script's report), and each process was pinned to one
CPU. Under heavy load the same runs took up to 2.5 times longer on both
sides; compare the min column, and compare ratios, not absolute times.

### 1M rows

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

### 6M rows

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

## Why Roc is slower

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

What would close it: a `Writer` push that takes a text in parts (the upper
first word and the rest) with no `Str` in between, and a trim of ASCII white
space only, would remove two copies and three builtin calls per row. The
package does not have them in 0.0.2.

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
