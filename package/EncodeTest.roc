## Tests for ArrowEncoding's encode path: values written then read back.
## Run: roc test package/tests.roc
EncodeTest :: []

import ArrowEncoding
import Builder
import DataType
import Array
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

## Every value through `encode_row`, in order.
encode_all : Builder, List(a) -> Try(Builder, [ArrowErr(CodecError)]) where [a.ArrowEncoding.Encodable]
encode_all = |b, values| {
	var $b = b
	for value in values {
		$b = ArrowEncoding.encode_row($b, value)?
	}
	Ok($b)
}

f : Str, DataType, Bool -> DataType.Field
f = |name, dt, nullable| DataType.field(name, dt, nullable)

Row : { id : I64, name : Try(Str, [Null]), tags : List(Str), price : Dec, blob : List(U8), pair : (I32, Bool) }

row_type : DataType
row_type = Struct([
	f("id", Int64, Bool.False),
	f("name", Utf8, Bool.True),
	f("tags", DataType.list_of(Utf8), Bool.False),
	f("price", Decimal128({ precision: 10, scale: 2 }), Bool.False),
	f("blob", Binary, Bool.False),
	f("pair", Struct([f("f0", Int32, Bool.False), f("f1", Boolean, Bool.False)]), Bool.False),
])

sample : List(Row)
sample = [
	{ id: 1, name: Ok("a"), tags: ["x", "y"], price: 1.25, blob: [1, 2], pair: (7, Bool.True) },
	{ id: 2, name: Err(Null), tags: [], price: 0.5, blob: [], pair: (8, Bool.False) },
]

# Encode then decode gives the same rows.
expect {
	b0 = Builder.new(row_type, 2) ?? crash "new"
	b1 = encode_all(b0, sample) ?? crash "encode"
	arr = b1.finish() ?? crash "finish"
	back : Try(List(Row), _)
	back = decode_all(arr)
	back == Ok(sample) and arr.len() == 2
}

# A Struct column the record lacks is filled with nulls.
expect {
	dt = Struct([f("a", Int64, Bool.False), f("b", Utf8, Bool.True)])
	b0 = Builder.new(dt, 1) ?? crash "new"
	b1 = ArrowEncoding.encode_row(b0, { a: 5.I64 }) ?? crash "encode"
	arr = b1.finish() ?? crash "finish"
	back : Try({ a : I64, b : Try(Str, [Null]) }, _)
	back = ArrowEncoding.decode_row(arr, 0)
	back == Ok({ a: 5, b: Err(Null) })
}

# A record field the Struct lacks is an error, as is a wrong physical type.
expect {
	dt = Struct([f("a", Int64, Bool.False)])
	b0 = Builder.new(dt, 1) ?? crash "new"
	unknown = ArrowEncoding.encode_row(b0, { a: 5.I64, zzz: 1.I64 })
	wrong = ArrowEncoding.encode_row(b0, { a: 5.I32 })
	unknown.is_err() and wrong.is_err()
}

# A Dec rounds to the column's scale; past the precision it fails.
expect {
	dt = Decimal128({ precision: 4, scale: 2 })
	b0 = Builder.new(dt, 2) ?? crash "new"
	ok = encode_all(b0, [1.234, 99.99])
	too_big = ArrowEncoding.encode_row(b0, 100.0)
	back : Try(List(Dec), _)
	back = decode_all((ok ?? crash "encode").finish() ?? crash "finish")
	back == Ok([1.23, 99.99]) and too_big.is_err()
}

# A map column written from a list of (key, value) tuples.
expect {
	dt = DataType.map_of(Utf8, Int64, Bool.True)
	b0 = Builder.new(dt, 2) ?? crash "new"
	rows : List(List((Str, Try(I64, [Null]))))
	rows = [[("a", Ok(1)), ("b", Err(Null))], []]
	b1 = encode_all(b0, rows) ?? crash "encode"
	back : Try(List(List((Str, Try(I64, [Null])))), _)
	back = decode_all(b1.finish() ?? crash "finish")
	back == Ok(rows)
}

# Timestamp(us) is written from I64 (physical type).
expect {
	b0 = Builder.new(Timestamp(Microsecond, "+00:00"), 1) ?? crash "new"
	b1 = ArrowEncoding.encode_row(b0, 1_700_000_000_000_000.I64) ?? crash "encode"
	back : Try(I64, _)
	back = ArrowEncoding.decode_row(b1.finish() ?? crash "finish", 0)
	back == Ok(1_700_000_000_000_000)
}

# Every scalar type writes its own physical column and reads back, at the edges of its range.
Scalars : { i8 : I8, i16 : I16, i32 : I32, i64 : I64, u8 : U8, u16 : U16, u32 : U32, u64 : U64, f32 : F32, f64 : F64, i128 : I128, dec : Dec, bool : Bool, str : Str }

scalar_type : DataType
scalar_type = Struct([
	f("i8", Int8, Bool.False),
	f("i16", Int16, Bool.False),
	f("i32", Int32, Bool.False),
	f("i64", Int64, Bool.False),
	f("u8", UInt8, Bool.False),
	f("u16", UInt16, Bool.False),
	f("u32", UInt32, Bool.False),
	f("u64", UInt64, Bool.False),
	f("f32", Float32, Bool.False),
	f("f64", Float64, Bool.False),
	f("i128", Decimal128({ precision: 38, scale: 0 }), Bool.False),
	f("dec", Decimal128({ precision: 20, scale: 3 }), Bool.False),
	f("bool", Boolean, Bool.False),
	f("str", LargeUtf8, Bool.False),
])

scalar_rows : List(Scalars)
scalar_rows = [
	{ i8: I8.lowest, i16: I16.lowest, i32: I32.lowest, i64: I64.lowest, u8: 0, u16: 0, u32: 0, u64: 0, f32: -0.25, f64: -1.0e300, i128: I128.lowest, dec: -1.234, bool: Bool.False, str: "" },
	{ i8: I8.highest, i16: I16.highest, i32: I32.highest, i64: I64.highest, u8: U8.highest, u16: U16.highest, u32: U32.highest, u64: U64.highest, f32: 3.5, f64: 2.5, i128: I128.highest, dec: 0.005, bool: Bool.True, str: "z" },
]

expect {
	b0 = Builder.new(scalar_type, 2) ?? crash "new"
	b1 = encode_all(b0, scalar_rows) ?? crash "encode"
	arr = b1.finish() ?? crash "finish"
	back : Try(List(Scalars), _)
	back = decode_all(arr)
	back == Ok(scalar_rows)
}

# Each scalar type refuses a column of another physical type and names the path.
expect {
	dt = Struct([f("a", Struct([f("b", Utf8, Bool.False)]), Bool.False)])
	b0 = Builder.new(dt, 1) ?? crash "new"
	m = |expected| Err(ArrowErr(TypeMismatch({ path: "a.b", expected, found: Utf8 })))
	at = |r| r.map_ok(|_| {})
	(at(ArrowEncoding.encode_row(b0, { a: { b: 1.I8 } })) == m("Int8"))
		and (at(ArrowEncoding.encode_row(b0, { a: { b: 1.I16 } })) == m("Int16"))
		and (at(ArrowEncoding.encode_row(b0, { a: { b: 1.I32 } })) == m("Int32"))
		and (at(ArrowEncoding.encode_row(b0, { a: { b: 1.I64 } })) == m("Int64"))
		and (at(ArrowEncoding.encode_row(b0, { a: { b: 1.U8 } })) == m("UInt8"))
		and (at(ArrowEncoding.encode_row(b0, { a: { b: 1.U16 } })) == m("UInt16"))
		and (at(ArrowEncoding.encode_row(b0, { a: { b: 1.U32 } })) == m("UInt32"))
		and (at(ArrowEncoding.encode_row(b0, { a: { b: 1.U64 } })) == m("UInt64"))
		and (at(ArrowEncoding.encode_row(b0, { a: { b: 1.F32 } })) == m("Float32"))
		and (at(ArrowEncoding.encode_row(b0, { a: { b: 1.F64 } })) == m("Float64"))
		and (at(ArrowEncoding.encode_row(b0, { a: { b: 1.I128 } })) == m("Decimal128"))
		and (at(ArrowEncoding.encode_row(b0, { a: { b: Bool.True } })) == m("Boolean"))
}

# An error inside a list names the item, as decode paths do.
expect {
	dt = Struct([f("prices", DataType.list_of(Decimal128({ precision: 4, scale: 2 })), Bool.False)])
	b0 = Builder.new(dt, 1) ?? crash "new"
	got = ArrowEncoding.encode_row(b0, { prices: [1.0, 100.0] }).map_ok(|_| {})
	got == Err(ArrowErr(OutOfRange("prices[1]")))
}

# A record field the Struct column does not have is refused by name.
expect {
	dt = Struct([f("a", Int64, Bool.False)])
	b0 = Builder.new(dt, 1) ?? crash "new"
	got = ArrowEncoding.encode_row(b0, { a: 1.I64, zz: 2.I64 }).map_ok(|_| {})
	got == Err(ArrowErr(UnknownField("zz")))
}
