## Tests for ArrowEncoding's decode path. Run: roc test package/tests.roc
DecodeTest :: []

import Array
import ArrowEncoding
import DataType
import Host
import CodecError

## Every row through `decode_row`; stops at the first row that fails.
decode_all : Array -> Try(List(a), [ArrowErr(CodecError)]) where [a.ArrowEncoding.Decodable]
decode_all = |arr| {
	var $out = List.with_capacity(arr.len())
	for i in (0.U64).until(arr.len()) {
		$out = $out.append(ArrowEncoding.decode_row(arr, i)?)
	}
	Ok($out)
}

## Every row through `decode_row`, one result per row.
decode_each : Array -> List(Try(a, [ArrowErr(CodecError)])) where [a.ArrowEncoding.Decodable]
decode_each = |arr| (0.U64).until(arr.len()).map(|i| ArrowEncoding.decode_row(arr, i)).collect()

prim : I64, Host.Buffer -> Host.Array
prim = |n, values| { length: n, null_count: 0, offset: 0, buffers: [Absent, values], children: [], dictionary: [] }

with_nulls : Host.Array, U8 -> Host.Array
with_nulls = |host, bits| { ..host, null_count: -1, buffers: host.buffers.set(0, U8s([bits])) ?? host.buffers }

utf8 : List(Str) -> Host.Array
utf8 = |xs| Array.from_strs(xs).to_host()

strct : I64, List(Host.Array) -> Host.Array
strct = |n, kids| { length: n, null_count: 0, offset: 0, buffers: [Absent], children: kids, dictionary: [] }

list32 : List(I32), Host.Array -> Host.Array
list32 = |offs, child| { length: offs.len().to_i64_wrap() - 1, null_count: 0, offset: 0, buffers: [Absent, I32s(offs)], children: [child], dictionary: [] }

f : Str, DataType -> DataType.Field
f = |name, dt| DataType.field(name, dt, Bool.True)

load : Host.Array, DataType -> Array
load = |host, dt| Array.from_host(host, dt) ?? crash "import failed"

row_type : DataType
row_type = Struct([f("f0", Int64), f("f1", Utf8), f("f2", Float64)])

rows : Array
rows = load(strct(2, [prim(2, I64s([1, 2])), utf8(["hi", "bye"]), prim(2, F64s([0.5, 1.5]))]), row_type)

Row : { f0 : I64, f1 : Str, f2 : F64 }

# Records match Struct children by name, in any declared order.
expect {
	got : Try(Row, _)
	got = ArrowEncoding.decode_row(rows, 1)
	got == Ok({ f0: 2, f1: "bye", f2: 1.5 })
}

expect {
	got : Try(List(Row), _)
	got = decode_all(rows)
	got == Ok([{ f0: 1, f1: "hi", f2: 0.5 }, { f0: 2, f1: "bye", f2: 1.5 }])
}

# A column the record does not name is skipped.
expect {
	got : Try({ f1 : Str }, _)
	got = ArrowEncoding.decode_row(rows, 0)
	got == Ok({ f1: "hi" })
}

# A field the struct lacks is an error.
expect {
	got : Try({ f1 : Str, f9 : I64 }, _)
	got = ArrowEncoding.decode_row(rows, 0)
	got == Err(ArrowErr(MissingField("f9")))
}

# A wrong physical type names the path.
expect {
	got : Try({ f0 : I32 }, _)
	got = ArrowEncoding.decode_row(rows, 0)
	got == Err(ArrowErr(TypeMismatch({ path: "f0", expected: "Int32", found: Int64 })))
}

expect {
	got : Try(Row, _)
	got = ArrowEncoding.decode_row(rows, 2)
	got == Err(ArrowErr(RowOutOfBounds(2)))
}

# Tuples read Struct children by position.
expect {
	got : Try((I64, Str, F64), _)
	got = ArrowEncoding.decode_row(rows, 0)
	got == Ok((1, "hi", 0.5))
}

expect {
	got : Try((I64, Str), _)
	got = ArrowEncoding.decode_row(rows, 0)
	got == Err(ArrowErr(ArityMismatch({ path: "", expected: 2, found: 3 })))
}

# Nested struct: the parent's focus is restored after the child record.
Nested : { f0 : I64, f1 : { f0 : Str, f1 : F64 }, f2 : I64 }

nested : Array
nested = load(
	strct(2, [prim(2, I64s([7, 8])), strct(2, [utf8(["a", "bc"]), prim(2, F64s([2.5, 3.5]))]), prim(2, I64s([70, 80]))]),
	Struct([f("f0", Int64), f("f1", Struct([f("f0", Utf8), f("f1", Float64)])), f("f2", Int64)]),
)

expect {
	got : Try(List(Nested), _)
	got = decode_all(nested)
	got == Ok([{ f0: 7, f1: { f0: "a", f1: 2.5 }, f2: 70 }, { f0: 8, f1: { f0: "bc", f1: 3.5 }, f2: 80 }])
}

# Try(a, [Null]) reads nulls; a plain type at a null row is an error.
nullable : Array
nullable = load(
	strct(3, [with_nulls(prim(3, I64s([1, 0, 3])), 0b101), with_nulls(utf8(["x", "y", ""]), 0b011)]),
	Struct([f("a", Int64), f("b", Utf8)]),
)

Opt : { a : Try(I64, [Null]), b : Try(Str, [Null]) }

expect {
	got : Try(List(Opt), _)
	got = decode_all(nullable)
	got == Ok([{ a: Ok(1), b: Ok("x") }, { a: Err(Null), b: Ok("y") }, { a: Ok(3), b: Err(Null) }])
}

expect {
	got : Try({ a : I64 }, _)
	got = ArrowEncoding.decode_row(nullable, 1)
	got == Err(ArrowErr(UnexpectedNull("a")))
}

# The same Nullable shape reads JSON null: one type works with both formats.
expect {
	got : Try(Opt, _)
	got = Json.parse("{\"a\":null,\"b\":\"z\"}")
	got == Ok({ a: Err(Null), b: Ok("z") })
}

# decode_each keeps going past a bad row.
expect {
	got : List(Try({ a : I64 }, _))
	got = decode_each(nullable)
	got == [Ok({ a: 1 }), Err(ArrowErr(UnexpectedNull("a"))), Ok({ a: 3 })]
}

# Lists, nested lists and nullable items.
expect {
	arr = load(list32([0, 2, 2, 3], prim(3, I64s([1, 2, 3]))), DataType.list_of(Int64))
	got : Try(List(List(I64)), _)
	got = decode_all(arr)
	got == Ok([[1, 2], [], [3]])
}

expect {
	inner = list32([0, 1, 3, 3], prim(3, I64s([1, 2, 3])))
	arr = load(list32([0, 2, 3], inner), DataType.list_of(DataType.list_of(Int64)))
	got : Try(List(List(List(I64))), _)
	got = decode_all(arr)
	got == Ok([[[1], [2, 3]], [[]]])
}

expect {
	arr = load(list32([0, 3], with_nulls(prim(3, I32s([1, 0, 3])), 0b101)), DataType.list_of(Int32))
	got : Try(List(Try(I32, [Null])), _)
	got = ArrowEncoding.decode_row(arr, 0)
	got == Ok([Ok(1), Err(Null), Ok(3)])
}

# A list inside a record inside a list: every level restores its parent.
expect {
	items = strct(3, [prim(3, I64s([1, 2, 3])), list32([0, 1, 1, 3], utf8(["a", "b", "c"]))])
	arr = load(list32([0, 2, 3], items), DataType.list_of(Struct([f("id", Int64), f("tags", DataType.list_of(Utf8))])))
	got : Try(List(List({ id : I64, tags : List(Str) })), _)
	got = decode_all(arr)
	got == Ok([[{ id: 1, tags: ["a"] }, { id: 2, tags: [] }], [{ id: 3, tags: ["b", "c"] }]])
}

# Binary reads as List(U8); Str does not read Binary.
expect {
	host = { length: 2, null_count: 0, offset: 0, buffers: [Absent, I32s([0, 2, 5]), U8s([1, 2, 3, 4, 5])], children: [], dictionary: [] }
	arr = load(host, Binary)
	got : Try(List(List(U8)), _)
	got = decode_all(arr)
	bad : Try(Str, _)
	bad = ArrowEncoding.decode_row(arr, 0)
	got == Ok([[1, 2], [3, 4, 5]]) and bad.is_err()
}

# FixedSizeBinary(16), for example a UUID, reads as List(U8).
expect {
	bytes = (0.U8).until(32).collect()
	arr = load({ length: 2, null_count: 0, offset: 0, buffers: [Absent, U8s(bytes)], children: [], dictionary: [] }, FixedSizeBinary(16))
	got : Try(List(U8), _)
	got = ArrowEncoding.decode_row(arr, 1)
	got.map_ok(|b| b.len()) == Ok(16) and got.map_ok(|b| b.first() ?? 0) == Ok(16)
}

# Map entries read as a list of (key, value) tuples or of { key, value } records.
map_arr : Array
map_arr = load(
	list32([0, 2, 3], strct(3, [utf8(["a", "b", "c"]), with_nulls(prim(3, I64s([1, 0, 3])), 0b101)])),
	DataType.map_of(Utf8, Int64, Bool.True),
)

expect {
	got : Try(List(List((Str, Try(I64, [Null])))), _)
	got = decode_all(map_arr)
	got == Ok([[("a", Ok(1)), ("b", Err(Null))], [("c", Ok(3))]])
}

expect {
	got : Try(List({ key : Str, value : Try(I64, [Null]) }), _)
	got = ArrowEncoding.decode_row(map_arr, 1)
	got == Ok([{ key: "c", value: Ok(3) }])
}

# Decimal128(10, 2) reads as Dec exactly, and as the unscaled I128.
expect {
	arr = load(prim(2, I128s([12345, -1])), Decimal128({ precision: 10, scale: 2 }))
	got : Try(List(Dec), _)
	got = decode_all(arr)
	raw : Try(List(I128), _)
	raw = decode_all(arr)
	got == Ok([123.45, -0.01]) and raw == Ok([12345, -1])
}

# Logical types decode by physical type: Timestamp(us) reads as I64.
expect {
	arr = load(prim(1, I64s([1_700_000_000_000_000])), Timestamp(Microsecond, "+00:00"))
	got : Try(I64, _)
	got = ArrowEncoding.decode_row(arr, 0)
	got == Ok(1_700_000_000_000_000)
}

expect {
	arr = load({ length: 3, null_count: 0, offset: 0, buffers: [Absent, U8s([0b110])], children: [], dictionary: [] }, Boolean)
	got : Try(List(Bool), _)
	got = decode_all(arr)
	got == Ok([Bool.False, Bool.True, Bool.True])
}

# Every scalar type reads its own physical column, at the edges of its range.
Scalars : { i8 : I8, i16 : I16, i32 : I32, i64 : I64, u8 : U8, u16 : U16, u32 : U32, u64 : U64, f32 : F32, f64 : F64, i128 : I128, dec : Dec, bool : Bool, str : Str }

scalar_type : DataType
scalar_type = Struct([
	f("i8", Int8),
	f("i16", Int16),
	f("i32", Int32),
	f("i64", Int64),
	f("u8", UInt8),
	f("u16", UInt16),
	f("u32", UInt32),
	f("u64", UInt64),
	f("f32", Float32),
	f("f64", Float64),
	f("i128", Decimal128({ precision: 38, scale: 0 })),
	f("dec", Decimal64({ precision: 18, scale: 3 })),
	f("bool", Boolean),
	f("str", Utf8),
])

scalars : Array
scalars = load(
	strct(
		2,
		[
			prim(2, I8s([I8.lowest, I8.highest])),
			prim(2, I16s([I16.lowest, I16.highest])),
			prim(2, I32s([I32.lowest, I32.highest])),
			prim(2, I64s([I64.lowest, I64.highest])),
			prim(2, U8s([0, U8.highest])),
			prim(2, U16s([0, U16.highest])),
			prim(2, U32s([0, U32.highest])),
			prim(2, U64s([0, U64.highest])),
			prim(2, F32s([-0.25, 3.5])),
			prim(2, F64s([-1.0e300, 2.5])),
			prim(2, I128s([I128.lowest, I128.highest])),
			prim(2, I64s([-1234, 5])),
			{ length: 2, null_count: 0, offset: 0, buffers: [Absent, U8s([0b10])], children: [], dictionary: [] },
			utf8(["", "z"]),
		],
	),
	scalar_type,
)

expect {
	got : Try(List(Scalars), _)
	got = decode_all(scalars)
	low = { i8: I8.lowest, i16: I16.lowest, i32: I32.lowest, i64: I64.lowest, u8: 0, u16: 0, u32: 0, u64: 0, f32: -0.25, f64: -1.0e300, i128: I128.lowest, dec: -1.234, bool: Bool.False, str: "" }
	high = { i8: I8.highest, i16: I16.highest, i32: I32.highest, i64: I64.highest, u8: U8.highest, u16: U16.highest, u32: U32.highest, u64: U64.highest, f32: 3.5, f64: 2.5, i128: I128.highest, dec: 0.005, bool: Bool.True, str: "z" }
	got == Ok([low, high])
}

# Each scalar type refuses a column of another physical type and names the path.
expect {
	found = Utf8
	m = |expected| Err(ArrowErr(TypeMismatch({ path: "str", expected, found })))
	i8 : Try({ str : I8 }, _)
	i8 = ArrowEncoding.decode_row(scalars, 0)
	i16 : Try({ str : I16 }, _)
	i16 = ArrowEncoding.decode_row(scalars, 0)
	i32 : Try({ str : I32 }, _)
	i32 = ArrowEncoding.decode_row(scalars, 0)
	i64 : Try({ str : I64 }, _)
	i64 = ArrowEncoding.decode_row(scalars, 0)
	u8 : Try({ str : U8 }, _)
	u8 = ArrowEncoding.decode_row(scalars, 0)
	u16 : Try({ str : U16 }, _)
	u16 = ArrowEncoding.decode_row(scalars, 0)
	u32 : Try({ str : U32 }, _)
	u32 = ArrowEncoding.decode_row(scalars, 0)
	u64 : Try({ str : U64 }, _)
	u64 = ArrowEncoding.decode_row(scalars, 0)
	f32 : Try({ str : F32 }, _)
	f32 = ArrowEncoding.decode_row(scalars, 0)
	f64 : Try({ str : F64 }, _)
	f64 = ArrowEncoding.decode_row(scalars, 0)
	i128 : Try({ str : I128 }, _)
	i128 = ArrowEncoding.decode_row(scalars, 0)
	dec : Try({ str : Dec }, _)
	dec = ArrowEncoding.decode_row(scalars, 0)
	bool : Try({ str : Bool }, _)
	bool = ArrowEncoding.decode_row(scalars, 0)
	(i8 == m("Int8"))
		and (i16 == m("Int16"))
		and (i32 == m("Int32"))
		and (i64 == m("Int64"))
		and (u8 == m("UInt8"))
		and (u16 == m("UInt16"))
		and (u32 == m("UInt32"))
		and (u64 == m("UInt64"))
		and (f32 == m("Float32"))
		and (f64 == m("Float64"))
		and (i128 == m("Decimal128"))
		and (dec == m("Decimal"))
		and (bool == m("Boolean"))
}

# Same width, other sign or kind: I32 does not read UInt32, F32 does not read Int32.
expect {
	signed : Try({ u32 : I32 }, _)
	signed = ArrowEncoding.decode_row(scalars, 0)
	float : Try({ i32 : F32 }, _)
	float = ArrowEncoding.decode_row(scalars, 0)
	signed == Err(ArrowErr(TypeMismatch({ path: "u32", expected: "Int32", found: UInt32 })))
		and float == Err(ArrowErr(TypeMismatch({ path: "i32", expected: "Float32", found: Int32 })))
}

# Float16 shares U16's buffer, but a U16 does not read it.
expect {
	arr = load(prim(1, U16s([0x3C00])), Float16)
	got : Try(U16, _)
	got = ArrowEncoding.decode_row(arr, 0)
	got == Err(ArrowErr(TypeMismatch({ path: "", expected: "UInt16", found: Float16 })))
}

# Text that is not UTF-8 is refused with the path of the value.
expect {
	bad = { length: 1, null_count: 0, offset: 0, buffers: [Absent, I32s([0, 2]), U8s([0x68, 0xFF])], children: [], dictionary: [] }
	arr = load(strct(1, [bad]), Struct([f("s", Utf8)]))
	got : Try({ s : Str }, _)
	got = ArrowEncoding.decode_row(arr, 0)
	got == Err(ArrowErr(InvalidUtf8("s")))
}
