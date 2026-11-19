# roc-apache-arrow API

The public API of release 0.0.1, module by module. The signatures are the
ones in `package/*.roc`, where each public item has a `##` doc comment. `_`
is a derived method.

Status:

| Mark | Meaning |
|---|---|
| tested | an `expect` calls it and checks the result |
| tested via X | an `expect` runs it only through X |
| not reached | no supported Roc type makes the derived code call it |
| not in 0.0.1 | an Arrow feature this release does not have |

`roc test package/tests.roc` runs every `expect` (265 on
nightly-2026-11-15-f25da45). Each status was checked by stubbing the item
with a `crash` and running the tests: an item marked tested or tested via X
fails at least one `expect` when it is stubbed.

## Module index

| Module | Type | Role |
|---|---|---|
| [DataType](#datatype) | `DataType := [...]`, `DataType.Field` | the Arrow logical type tree |
| [Format](#format) | `Format := [...]` | C Data Interface format strings |
| [TimeUnit, IntervalUnit, UnionMode](#timeunit-intervalunit-unionmode) | enums | parameters of `DataType` |
| [Metadata](#metadata) | `Metadata := { entries }` | key-value metadata and its C binary form |
| [Schema](#schema) | `Schema := { fields, metadata }` | a record batch schema |
| [Host](#host) | `Host :: []` (namespace) | the host ABI: `Host.Array`, `Host.Schema`, `Host.Buffer` |
| [Validity](#validity) | `Validity := [AllValid, Bits(List(U8), U64)]` | validity bitmaps |
| [Array](#array) | `Array :: {..}` (opaque), `Array.Body` | a checked array |
| [PrimitiveColumn](#primitivecolumn) | `PrimitiveColumn(a) :: {..}` | view, fixed-width types |
| [BoolColumn](#boolcolumn) | `BoolColumn :: {..}` | view, Boolean |
| [BinaryColumn](#binarycolumn) | `BinaryColumn :: {..}` | view, binary and text layouts |
| [Utf8Column](#utf8column) | `Utf8Column :: {..}` | view, Utf8, text checked once |
| [ListColumn](#listcolumn) | `ListColumn :: {..}` | view, List, LargeList, FixedSizeList, Map |
| [StructColumn](#structcolumn) | `StructColumn :: {..}` | view, Struct |
| [MapColumn](#mapcolumn) | `MapColumn :: {..}` | view, Map |
| [Items](#items) | `Items(item, src) :: {..}` | view of one list value |
| [ListItems](#listitems) | `ListItems(item) :: {..}` | the source of `Items.from_list` |
| [Writer](#writer) | `Writer := []` (namespace) | typed column writers |
| [Builder](#builder) | `Builder :: {..}` (opaque) | dynamic: build an array of a run-time type |
| [ArrowEncoding](#arrowencoding) | `ArrowEncoding := [Arrow]` | dynamic: the derived-codec format |
| [CodecError](#codecerror) | `CodecError := [...]` | the codec's error |
| [Probe](#probe) | `Probe := [Shapes]` | dynamic: the shape of a Roc type |
| [Shape](#shape) | `Shape := [...]`, `Shape.Slot` | dynamic: schema checks |
| [Decimal](#decimal) | `Decimal := {..}` | Decimal128 values |
| [Timestamp, Date32, Time64, Duration, IntervalYearMonth](#logical-values) | records | temporal values |

## DataType

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `DataType` | `[Null, Boolean, Int8 .. UInt64, Float16/32/64, Decimal32/64/128/256({ precision, scale }), Date32, Date64, Time32(TimeUnit), Time64(TimeUnit), Timestamp(TimeUnit, Str), Duration(TimeUnit), Interval(IntervalUnit), Binary, LargeBinary, BinaryView, FixedSizeBinary(U64), Utf8, LargeUtf8, Utf8View, List(Field), LargeList(Field), ListView(Field), LargeListView(Field), FixedSizeList(Field, U64), Struct(List(Field)), Map(Field, Bool), Union(UnionMode, List(I8), List(Field)), Dictionary(DataType, DataType, Bool), RunEndEncoded(Field, Field)]` | the Arrow logical type | tested |
| `Field` | `{ name : Str, data_type : DataType, nullable : Bool, metadata : Metadata }` | a named child | tested |
| `is_eq` | `_` | `==` | tested |
| `field` | `Str, DataType, Bool -> DataType.Field` | a field with no metadata | tested |
| `list_of` | `DataType -> DataType` | `List` of a nullable `item` field | tested |
| `map_of` | `DataType, DataType, Bool -> DataType` | `Map` of key, value, keys_sorted | tested |
| `children` | `DataType -> List(DataType.Field)` | the child fields of a nested type | tested |
| `byte_width` | `DataType -> Try(U64, [NotFixedWidth])` | bytes per value of a fixed-width type | tested |

## Format

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `Format` | `[Leaf(DataType), List, LargeList, ListView, LargeListView, FixedSizeList(U64), Struct, Map, Union(UnionMode, List(I8)), RunEndEncoded]` | the head of one format string | tested |
| `parse` | `Str -> Try(Format, [InvalidFormat(Str)])` | read a format string | tested |
| `print` | `DataType -> Str` | write the format string of a type | tested |
| `build` | `Format, List(DataType.Field) -> Try(DataType, [InvalidFormat(Str)])` | join a head with its children | tested |

## TimeUnit, IntervalUnit, UnionMode

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `TimeUnit` | `[Second, Millisecond, Microsecond, Nanosecond]` | time unit | tested |
| `TimeUnit.per_second` | `TimeUnit -> I64` | units in one second | tested via `convert` |
| `TimeUnit.convert` | `I64, TimeUnit, TimeUnit -> Try(I64, [Overflow, Inexact])` | exact unit change | tested |
| `IntervalUnit` | `[YearMonth, DayTime, MonthDayNano]` | interval unit | tested via `Format` |
| `UnionMode` | `[Sparse, Dense]` | union mode | tested via `Format` |

## Metadata

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `empty` | `Metadata` | no entries | tested |
| `from_pairs` | `List({ key : Str, value : Str }) -> Metadata` | make from pairs | tested |
| `to_pairs` | `Metadata -> List({ key : Str, value : Str })` | the pairs in order | tested |
| `get` | `Metadata, Str -> Try(Str, [NotFound])` | the value of a key | tested |
| `insert` | `Metadata, Str, Str -> Metadata` | set a key | tested |
| `decode` | `List(U8) -> Try(Metadata, [InvalidMetadata(Str)])` | read the C binary form | tested |
| `encode` | `Metadata -> List(U8)` | write the C binary form; empty for no entries | tested |

## Schema

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `new` | `List(Field) -> Schema` | a schema with no metadata | tested |
| `find` | `Schema, Str -> Try(Field, [NotFound(Str)])` | a field by name | tested |
| `to_data_type` | `Schema -> DataType` | the `Struct` of the fields | tested |
| `from_host` | `Host.Schema -> Try(Schema, [InvalidSchema(Str)])` | read a `+s` host schema | tested |
| `to_host` | `Schema -> Host.Schema` | write a host schema | tested |
| `field_from_host` | `Host.Schema -> Try(Field, [InvalidSchema(Str)])` | one field and its subtree | tested via `from_host` |
| `field_to_host` | `Field -> Host.Schema` | one field and its subtree | tested via `to_host` |

## Host

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `Host.Buffer` | `[Absent, F32s(List(F32)), F64s, I128s, I16s, I32s, I64s, I8s, U16s, U32s, U64s, U8s]` | one buffer; tag numbers 0 .. 11 in this order | tested |
| `Host.Buffer.len` | `Host.Buffer -> U64` | element count | tested |
| `Host.Array` | `{ length : I64, null_count : I64, offset : I64, buffers, children, dictionary, _ : {} }` | mirrors `ArrowArray`; 96 bytes | tested |
| `Host.Schema` | `{ format : List(U8), name, metadata, flags : I64, children, dictionary, _ : {} }` | mirrors `ArrowSchema`; 128 bytes | tested |
| `flag_dictionary_ordered` | `I64` (1) | C flag | tested |
| `flag_nullable` | `I64` (2) | C flag | tested |
| `flag_map_keys_sorted` | `I64` (4) | C flag | tested |
| `empty_array` | `I64 -> Host.Array` | an array with no buffers | tested |
| `glue/roc_platform_abi.h` | C header | the layout, with static asserts | checked by `scripts/glue.sh --check` |
| host rules | zero-copy import, the `I128s` rule, zero-copy export and release | | tested by `scripts/test-host.sh` (C, AddressSanitizer) |

## Validity

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `is_valid` | `Validity, U64 -> Bool` | row is not NULL | tested |
| `null_count` | `Validity, U64 -> U64` | NULL rows in the first n | tested |
| `skip` | `Validity, U64 -> Validity` | drop the first n rows (moves the bit offset) | tested via `Array.slice` |
| `from_bools` | `List(Bool) -> Validity` | from flags | tested |
| `to_bitmap` | `Validity, U64 -> Try(List(U8), [AllValid])` | an LSB bitmap at bit offset 0 | tested via `Array.to_host` |
| `bit` | `List(U8), U64 -> Bool` | one LSB bit | tested via `BoolColumn` |
| `pack` | `List(Bool) -> List(U8)` | flags to LSB bits | tested |
| `realign_bits` | `List(U8), U64, U64 -> List(U8)` | move bits to offset 0 | tested |

## Array

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `Array.Body` | `[NoBuffers, BoolBits, I8s .. U64s, F32s, F64s, I128s, Var32, Var64, Views, Fixed, List32, List64, FixedList, Children]` | typed buffers | tested |
| `from_host` | `Host.Array, DataType -> Try(Array, [InvalidArray(Str), Unsupported(Str)])` | check and slice a host array | tested |
| `to_host` | `Array -> Host.Array` | export, offset 0 | tested |
| `data_type` | `Array -> DataType` | the type | tested via the column views |
| `len` | `Array -> U64` | rows | tested |
| `validity` | `Array -> Validity` | the validity | tested |
| `body` | `Array -> Array.Body` | the typed buffers | tested via the column views |
| `is_valid` | `Array, U64 -> Bool` | row is not NULL | tested |
| `null_count` | `Array -> U64` | NULL rows | tested |
| `children` | `Array -> List(Array)` | child arrays | tested |
| `slice` | `Array, U64, U64 -> Array` | rows `start ..< start + count`, no copy | tested |
| `from_body` | `DataType, U64, Validity, Array.Body -> Try(Array, [InvalidArray(Str), Unsupported(Str)])` | make from typed buffers, checked | tested |
| `from_u8s` | `List(U8) -> Array` | a UInt8 array, no copy | tested |
| `from_i32s` | `List(I32) -> Array` | an Int32 array, no copy | tested |
| `from_i64s` | `List(I64) -> Array` | an Int64 array, no copy | tested |
| `from_f64s` | `List(F64) -> Array` | a Float64 array, no copy | tested |
| `from_strs` | `List(Str) -> Array` | a Utf8 array (copies) | tested |
| `reinterpret` | `Array, DataType -> Try(Array, [InvalidArray(Str), Unsupported(Str)])` | same layout, other type | tested |
| `with_validity` | `Array, Validity -> Array` | replace the validity | tested |
| `from_columns` | `Schema, List(Array) -> Try(Array, [InvalidArray(Str), Unsupported(Str)])` | a record batch Struct | tested |
| `nulls` | `U64 -> Array` | a Null array | tested |

## PrimitiveColumn

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `i16`, `i32`, `i64`, `f64` | `Array -> Try(PrimitiveColumn(_), [TypeMismatch(DataType)])` | the view | tested |
| `i8`, `u8`, `u16`, `u32`, `u64`, `f32`, `i128` | same | the view | tested |
| `len` | `PrimitiveColumn(a) -> U64` | rows | tested |
| `is_valid` | `PrimitiveColumn(a), U64 -> Bool` | row is not NULL | tested |
| `get` | `PrimitiveColumn(a), U64 -> Try(a, [Null, OutOfBounds])` | checked read | tested |
| `at` | `PrimitiveColumn(a), U64, a -> a` | loop read; the third value past the end | tested |
| `values` | `PrimitiveColumn(a) -> List(a)` | the values list, no copy | tested |
| `validity` | `PrimitiveColumn(a) -> Validity` | the validity | tested |
| `null_count` | `PrimitiveColumn(a) -> U64` | NULL rows | tested |
| `iter` | `PrimitiveColumn(a) -> Iter(Try(a, [Null]))` | rows in order | tested |

## BoolColumn

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `from_array` | `Array -> Try(BoolColumn, [TypeMismatch(DataType)])` | the view | tested |
| `len`, `is_valid`, `validity` | as in `PrimitiveColumn` | | tested |
| `at` | `BoolColumn, U64 -> Bool` | loop read | tested |
| `get` | `BoolColumn, U64 -> Try(Bool, [Null, OutOfBounds])` | checked read | tested |
| `iter` | `BoolColumn -> Iter(Try(Bool, [Null]))` | rows in order | tested |

## BinaryColumn

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `from_array` | `Array -> Try(BinaryColumn, [TypeMismatch(DataType)])` | Binary, LargeBinary, BinaryView, Utf8, LargeUtf8, Utf8View, FixedSizeBinary | tested |
| `len` | `BinaryColumn -> U64` | rows | tested |
| `is_valid`, `validity` | as in `PrimitiveColumn` | | tested |
| `bytes_at` | `BinaryColumn, U64 -> List(U8)` | loop read | tested |
| `data_len` | `BinaryColumn -> U64` | data bytes | tested |
| `is_utf8` | `BinaryColumn -> Bool` | the type is a text type | tested |
| `get_bytes` | `BinaryColumn, U64 -> Try(List(U8), [Null, OutOfBounds])` | checked read | tested |
| `get_str` | `BinaryColumn, U64 -> Try(Str, [Null, OutOfBounds, BadUtf8])` | checked read; checks UTF-8 per call | tested |
| `iter_bytes` | `BinaryColumn -> Iter(Try(List(U8), [Null]))` | rows in order | tested |

## Utf8Column

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `from_array` | `Array -> Try(Utf8Column, [TypeMismatch(DataType)])` | Utf8 only; checks the text once | tested |
| `len`, `is_valid` | as in `PrimitiveColumn` | | tested |
| `validity` | `Utf8Column -> Validity` | the validity | tested |
| `data_len` | `Utf8Column -> U64` | text bytes | tested |
| `is_valid_utf8` | `Utf8Column -> Bool` | the text passed the check | tested |
| `get` | `Utf8Column, U64 -> Try(Str, [Null, OutOfBounds])` | checked read | tested |
| `at` | `Utf8Column, U64 -> Str` | loop read, a slice | tested |
| LargeUtf8, Utf8View text views | | read them with `BinaryColumn.get_str` | not in 0.0.1 |

## ListColumn

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `from_array` | `Array -> Try(ListColumn, [TypeMismatch(DataType)])` | List, LargeList, FixedSizeList, Map | tested |
| `len` | `ListColumn -> U64` | rows | tested |
| `is_valid`, `validity` | as in `PrimitiveColumn` | | tested |
| `range_at` | `ListColumn, U64 -> { start : U64, len : U64 }` | loop read: the child range | tested |
| `values` | `ListColumn -> Array` | the child array | tested |
| `range` | `ListColumn, U64 -> Try({ start : U64, len : U64 }, [Null, OutOfBounds])` | checked child range | tested |
| `get` | `ListColumn, U64 -> Try(Array, [Null, OutOfBounds])` | the row's child slice | tested |

## StructColumn

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `from_array` | `Array -> Try(StructColumn, [TypeMismatch(DataType)])` | the view | tested |
| `len` | `StructColumn -> U64` | rows | tested |
| `is_valid`, `validity` | as in `PrimitiveColumn` | | tested |
| `fields` | `StructColumn -> List(Field)` | the fields | tested |
| `column` | `StructColumn, Str -> Try(Array, [NotFound(Str)])` | a child by name | tested |
| `column_at` | `StructColumn, U64 -> Try(Array, [OutOfBounds])` | a child by position | tested |

## MapColumn

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `from_array` | `Array -> Try(MapColumn, [TypeMismatch(DataType)])` | the view | tested |
| `len`, `is_valid` | as in `PrimitiveColumn` | | tested |
| `keys` | `MapColumn -> Array` | all keys | tested |
| `items` | `MapColumn -> Array` | all values | tested |
| `range` | `MapColumn, U64 -> Try({ start : U64, len : U64 }, [Null, OutOfBounds])` | the row's entry range | tested |

## Items

A source type has `item_at : src, U64 -> item` and
`iter_range : src, U64, U64 -> Iter(item)`.

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `view` | `src, U64, U64 -> Items(item, src) where [src.item_at : src, U64 -> item]` | rows `start ..< start + count`; O(1) | tested |
| `from_list` | `List(item) -> Items(item, ListItems(item))` | a view of a Roc list | tested |
| `len` | `Items(item, src) -> U64` | count | tested |
| `is_empty` | `Items(item, src) -> Bool` | count is 0 | tested |
| `get` | `Items(item, src), U64 -> Try(item, [OutOfBounds])` | item `j` | tested |
| `iter` | `Items(item, src) -> Iter(item) where [src.iter_range : ...]` | `for x in xs` | tested |
| `to_list` | `Items(item, src) -> List(item)` | the explicit copy | tested |
| `walk` | `src, U64, U64 -> Iter(item) where [src.item_at : ...]` | an `iter_range` for any source | tested via a test source |

## ListItems

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `wrap` | `List(item) -> ListItems(item)` | the source | tested via `Items.from_list` |
| `item_at` | `ListItems(item), U64 -> item` | one item; crashes past the end (Items never asks) | tested via `Items.get` |
| `iter_range` | `ListItems(item), U64, U64 -> Iter(item)` | a list slice iterator | tested via `Items.iter` |

## Writer

`Prim(a)`, `Bools`, `Var`, `LargeVar`, `Fixed`, `Views`, `Lists(w)`,
`LargeLists(w)`, `FixedLists(w)`, `Row` are record aliases. Each `*_finish`
takes `cleared : List(U64)`, more rows to make NULL, and gives a
`Host.Array` whose buffers are the writer's lists (no copy).

| Writer | Make | Push | NULL | Finish | Status |
|---|---|---|---|---|---|
| fixed-width | `prim : U64 -> Prim(a)` | `prim_push : Prim(a), a -> Prim(a)` | `prim_null : Prim(a), a -> Prim(a)` | `prim_finish : Prim(a), List(U64), (List(a) -> Host.Buffer) -> Host.Array` | tested |
| Boolean | `bools : U64 -> Bools` | `bools_push : Bools, Bool -> Bools` | `bools_null : Bools -> Bools` | `bools_finish : Bools, List(U64) -> Host.Array` | tested |
| Utf8, Binary | `varlen : U64, U64 -> Var` | `str_push : Var, Str -> Var`, `bytes_push : Var, List(U8) -> Var` | `var_null : Var -> Var` | `var_finish : Var, List(U64) -> Host.Array` | tested |
| LargeUtf8, LargeBinary | `large_varlen : U64, U64 -> LargeVar` | `large_str_push : LargeVar, Str -> LargeVar`, `large_bytes_push : LargeVar, List(U8) -> LargeVar` | `large_var_null : LargeVar -> LargeVar` | `large_var_finish : LargeVar, List(U64) -> Host.Array` | tested |
| FixedSizeBinary | `fixed : U64, U64 -> Fixed` | `fixed_push : Fixed, List(U8) -> Fixed` | `fixed_null : Fixed -> Fixed` | `fixed_finish : Fixed, List(U64) -> Host.Array` | tested |
| BinaryView, Utf8View | `views : U64, U64 -> Views` | `views_push : Views, List(U8) -> Views`, `views_str_push : Views, Str -> Views` | `views_null : Views -> Views` | `views_finish : Views, List(U64) -> Host.Array` | tested |
| List, Map | `lists : w -> Lists(w)` | `list_push : Lists(w), List(a), (w, a -> w) -> Lists(w)` | `list_null : Lists(w) -> Lists(w)` | `list_finish : Lists(w), List(U64), (w -> Host.Array) -> Host.Array` | tested |
| LargeList | `large_lists : w -> LargeLists(w)` | `large_list_push : LargeLists(w), List(a), (w, a -> w) -> LargeLists(w)` | `large_list_null : LargeLists(w) -> LargeLists(w)` | `large_list_finish : LargeLists(w), List(U64), (w -> Host.Array) -> Host.Array` | tested |
| FixedSizeList | `fixed_lists : U64, w -> FixedLists(w)` | `fixed_list_push : FixedLists(w), List(a), (w, a -> w), (w -> w) -> FixedLists(w)` | `fixed_list_null : FixedLists(w), (w -> w) -> FixedLists(w)` | `fixed_list_finish : FixedLists(w), List(U64), (w -> Host.Array) -> Host.Array` | tested |
| Struct | `row : U64 -> Row` | `row_push : Row -> Row` | `row_null : Row -> Row` | `row_finish : Row, List(U64), List(Host.Array) -> Host.Array` | tested |

## Builder

Every append returns `Err(ArrowErr(TypeMismatch(..)))` for a column of
another type. A builder that is the only reference grows in place.

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `Data` | `[NullD, BoolD, I8D .. I128D, VarD, LargeVarD, FixedD, ViewD, ListD, LargeListD, FixedListD, StructD]` | the typed buffers, one variant per layout | tested via the appends |
| `new` | `DataType, U64 -> Try(Builder, [Unsupported(Str)])` | a builder; capacity in rows. Every type but ListView, LargeListView, Union, Dictionary and RunEndEncoded | tested |
| `data_type` | `Builder -> DataType` | the type given to `new` | tested |
| `len` | `Builder -> U64` | rows | tested |
| `append_null` | `Builder -> Try(Builder, [ArrowErr(CodecError)])` | a NULL row | tested |
| `append_bool` | `Builder, Bool -> Try(Builder, [ArrowErr(CodecError)])` | Boolean | tested |
| `append_i8`, `append_i16`, `append_i32`, `append_i64`, `append_u8`, `append_u16`, `append_u32`, `append_u64`, `append_f32`, `append_f64`, `append_i128` | `Builder, T -> Try(Builder, [ArrowErr(CodecError)])` | one value of the column's physical type | tested |
| `append_dec` | `Builder, Dec -> Try(Builder, [ArrowErr(CodecError)])` | Decimal32, Decimal64, Decimal128: rounds to the scale; `OutOfRange` past the precision or the storage width | tested |
| `append_str` | `Builder, Str -> Try(Builder, [ArrowErr(CodecError)])` | Utf8, LargeUtf8, Utf8View; copies the bytes | tested |
| `append_bytes` | `Builder, List(U8) -> Try(Builder, [ArrowErr(CodecError)])` | Binary, LargeBinary, BinaryView; FixedSizeBinary of the exact width | tested |
| `update_child` | `Builder, U64, (Builder -> Try(Builder, [ArrowErr(CodecError)])) -> Try(Builder, [ArrowErr(CodecError)])` | change one child; the child stays unique, so it grows in place | tested |
| `end_list` | `Builder -> Try(Builder, [ArrowErr(CodecError)])` | close a list row | tested |
| `end_struct` | `Builder -> Try(Builder, [ArrowErr(CodecError)])` | close a struct row; pads children with NULL | tested |
| `take_children` | `Builder -> { shell : Builder, kids : List(Builder) }` | detach children | tested |
| `put_children` | `Builder, List(Builder) -> Builder` | attach children | tested |
| `child_len` | `Builder, U64 -> U64` | rows of a child | tested |
| `finish_host` | `Builder -> Host.Array` | export, no copy | tested |
| `finish` | `Builder -> Try(Array, [InvalidArray(Str), Unsupported(Str)])` | export and check | tested |

A list or struct column of n rows builds in O(n) through `update_child`,
`take_children` / `put_children` and `encode_row`; three 50k-row tests in
`BuilderTest.roc` guard it by their run time.

## ArrowEncoding

An error names the path of the value, for example `prices[1]` or `a.b`, for
decode and encode alike.

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `decode_row` | `Array, U64 -> Try(a, [ArrowErr(CodecError)]) where [a.Decodable]` | one row of a Struct into a Roc value | tested |
| `encode_row` | `Builder, a -> Try(Builder, [ArrowErr(CodecError)]) where [a.Encodable]` | one Roc value into a Struct builder | tested |
| `State`, `Frame`, `Out`, `Fill` | nested types | the protocol state | tested via the two above |
| `parse_null`, `parse_bool`, `parse_i8` .. `parse_i64`, `parse_u8` .. `parse_u64`, `parse_i128`, `parse_f32`, `parse_f64`, `parse_dec`, `parse_str` | protocol methods | called by derived `parser_for` | tested via `decode_row` |
| `parse_list_start`, `parse_list_next`, `parse_list_after_item`, `parse_record_start`, `parse_record_field`, `parse_record_after_field`, `parse_tuple_start`, `parse_tuple_next`, `parse_tuple_end`, `skip_record_field`, `missing_field`, `rename_field` | protocol methods | called by derived `parser_for` | tested via `decode_row` |
| `invalid_value` | protocol method | | not reached |
| `encode_null`, `encode_bool`, `encode_i8` .. `encode_i64`, `encode_u8` .. `encode_u64`, `encode_i128`, `encode_f32`, `encode_f64`, `encode_dec`, `encode_str`, `encode_list`, `encode_record`, `encode_tuple` | protocol methods | called by derived `encoder_for` | tested via `encode_row` |
| tag unions, `Dict`, `Set` in the codec | | | not in 0.0.1 |

## CodecError

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `CodecError` | `[TypeMismatch({ path, expected, found }), UnexpectedNull(Str), MissingField(Str), UnknownField(Str), ArityMismatch({ path, expected, found }), InvalidUtf8(Str), OutOfRange(Str), RowOutOfBounds(U64)]` | the codec's error | tested |
| `to_str` | `CodecError -> Str` | a message | tested |

## Probe

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `shape_of` | `(Probe.State -> Try({ value : a, rest : Probe.State }, [ProbeErr(Str)])) -> Try(Shape.Slot, [ProbeErr(Str)])` | the shape of a type, from its `parser_for(Probe.Shapes)` | tested |
| `State`, `Frame` | nested types | the probe state | tested via `shape_of` |
| protocol methods | as in `ArrowEncoding`, error `ProbeErr(Str)` | | tested via `shape_of`, except the rows below |
| `invalid_value`, `missing_field`, `skip_record_field`, `parse_list_next`, `parse_list_after_item` | protocol methods | a probe names every field and counts each list as one item | not reached |

## Shape

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `Shape` | `[Scalar(DataType), Dec, List(Shape.Slot), Record(List({ name, slot })), Tuple(List(Shape.Slot)), Unknown]` | the Arrow shape of a Roc type | tested |
| `Slot` | `{ shape : Shape, nullable : Bool }` | a shape and its nullability | tested |
| `to_data_type` | `Shape -> DataType` | the default type (`List(U8)` is Binary, `Dec` is Decimal128(38, 18)) | tested |
| `check_input` | `Shape.Slot, Field -> Try({}, [ShapeMismatch(Str)])` | can the type read the column | tested |
| `check_output` | `Shape.Slot, Field -> Try({}, [ShapeMismatch(Str)])` | can the column hold the type | tested |

## Decimal

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `new` | `I128, U8, I8 -> Try(Decimal, [OutOfRange])` | checks the digits | tested |
| `data_type` | `Decimal -> DataType` | Decimal128(p, s) | tested |
| `to_dec` | `Decimal -> Try(Dec, [OutOfRange])` | exact | tested |
| `from_dec` | `Dec, U8, I8 -> Try(Decimal, [OutOfRange])` | rounds half away from zero | tested |
| `unscaled_to_dec` | `I128, I8 -> Try(Dec, [OutOfRange])` | exact | tested |
| Decimal256 values | | | not in 0.0.1 |

## Logical values

| Item | Signature | Purpose | Status |
|---|---|---|---|
| `Timestamp.from_raw` | `I64, DataType -> Try(Timestamp, [TypeMismatch(DataType)])` | from a raw value and the column type | tested |
| `Timestamp.data_type` | `Timestamp -> DataType` | | tested |
| `Timestamp.to_unit` | `Timestamp, TimeUnit -> Try(Timestamp, [Overflow, Inexact])` | | tested |
| `Timestamp.split_day` | `Timestamp -> { days : I64, time_of_day : I64 }` | | tested |
| `Date32.from_days` | `I32 -> Date32` | | tested |
| `Date32.from_ymd` | `I32, U8, U8 -> Try(Date32, [InvalidDate])` | proleptic Gregorian | tested |
| `Date32.to_ymd` | `Date32 -> { year : I32, month : U8, day : U8 }` | | tested |
| `Time64.new` | `I64, TimeUnit -> Try(Time64, [OutOfRange])` | one day, us or ns | tested |
| `Time64.parts` | `Time64 -> { hour : U8, minute : U8, second : U8, fraction : I64 }` | | tested |
| `Duration.new` | `I64, TimeUnit -> Duration` | | tested |
| `Duration.to_unit` | `Duration, TimeUnit -> Try(Duration, [Overflow, Inexact])` | | tested |
| `IntervalYearMonth.from_months` | `I32 -> IntervalYearMonth` | | tested |
| `IntervalYearMonth.parts` | `IntervalYearMonth -> { years : I32, months : I32 }` | | tested |
| Interval(DayTime / MonthDayNano) values, a `FixedColumn` view | | | not in 0.0.1 |
| Arrow IPC (`Ipc` module) | | | not in 0.0.1 |
| ListView, Union, Dictionary, RunEndEncoded arrays | in `DataType` and `Format`; `from_host` gives `Unsupported` | | not in 0.0.1 |
