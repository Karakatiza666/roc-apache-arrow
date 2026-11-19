## Tests for Builder. Run: roc test package/tests.roc
BuilderTest :: []

import Array
import ArrowEncoding
import Builder
import BoolColumn
import DataType
import PrimitiveColumn
import BinaryColumn
import ListColumn
import StructColumn

expect {
	b0 = Builder.new(Int64, 4) ?? crash "new"
	b1 = b0.append_i64(1) ?? crash "1"
	b2 = b1.append_null() ?? crash "null"
	b3 = b2.append_i64(3) ?? crash "3"
	arr = b3.finish() ?? crash "finish"
	PrimitiveColumn.i64(arr).map_ok(|c| c.iter().collect()) == Ok([Ok(1), Err(Null), Ok(3)])
}

# No null, no bitmap: the host sees an absent validity buffer.
expect {
	b = Builder.new(Float64, 2) ?? crash "new"
	host = ((b.append_f64(1.0) ?? crash "a").append_f64(2.0) ?? crash "b").finish_host()
	absent = match host.buffers.first() {
		Ok(Absent) => Bool.True
		_ => Bool.False
	}
	absent and host.null_count == 0
}

expect {
	b = Builder.new(Int64, 1) ?? crash "new"
	match b.append_str("x") {
		Err(e) => e == ArrowErr(TypeMismatch({ path: "", expected: "Utf8", found: Int64 }))
		Ok(_) => Bool.False
	}
}

expect {
	b = Builder.new(Utf8, 2) ?? crash "new"
	arr = (((b.append_str("ab") ?? crash "a").append_null() ?? crash "n").append_str("c") ?? crash "c").finish() ?? crash "finish"
	col = BinaryColumn.from_array(arr) ?? crash "type"
	col.get_str(0) == Ok("ab") and col.get_str(1) == Err(Null) and col.get_str(2) == Ok("c")
}

# Nested: a list of structs, filled through update_child.
expect {
	dt = DataType.list_of(Struct([DataType.field("x", Int32, Bool.False), DataType.field("y", Utf8, Bool.True)]))
	b0 = Builder.new(dt, 2) ?? crash "new"
	# Each struct row sets only x; end_struct pads y with a null.
	item : I32 -> (Builder -> Try(Builder, _))
	item = |x| |s| {
		filled = s.update_child(0, |c| c.append_i32(x))?
		filled.end_struct()
	}
	two = |s| {
		one = item(1)(s)?
		item(2)(one)
	}
	b1 = b0.update_child(0, two) ?? crash "items"
	b2 = b1.end_list() ?? crash "end"
	arr = b2.finish() ?? crash "finish"
	list = ListColumn.from_array(arr) ?? crash "list"
	row0 = list.get(0) ?? crash "row"
	xs = StructColumn.from_array(row0) ?? crash "struct"
	ys = xs.column("y") ?? crash "y"
	PrimitiveColumn.i32(xs.column("x") ?? crash "x").map_ok(|c| c.values()) == Ok([1, 2]) and ys.null_count() == 2
}

# Appends grow in place: 200k values build in linear time.
expect {
	n = 200_000
	b0 = Builder.new(Int64, 0) ?? crash "new"
	var $b = b0
	for i in (0.I64).until(n) {
		$b = $b.append_i64(i) ?? crash "append"
	}
	$b.len() == 200_000
}

expect {
	b0 = Builder.new(Utf8, 0) ?? crash "new"
	var $b = b0
	for i in (0.U64).until(50_000) {
		$b = (if (i % 7 == 0) $b.append_null() else $b.append_str("value ${i.to_str()}")) ?? crash "append"
	}
	$b.len() == 50_000
}

# Each typed append fills its own column and reads back with a NULL in row 1.
expect {
	three : DataType, (Builder -> Try(Builder, _)), (Builder -> Try(Builder, _)) -> Array
	three = |dt, first, last| {
		b0 = Builder.new(dt, 3) ?? crash "new"
		b1 = first(b0) ?? crash "first"
		b2 = b1.append_null() ?? crash "null"
		b3 = last(b2) ?? crash "last"
		b3.finish() ?? crash "finish"
	}
	i8s = three(Int8, |b| b.append_i8(-128), |b| b.append_i8(127))
	i16s = three(Int16, |b| b.append_i16(-32768), |b| b.append_i16(32767))
	u8s = three(UInt8, |b| b.append_u8(0), |b| b.append_u8(255))
	u16s = three(UInt16, |b| b.append_u16(1), |b| b.append_u16(65535))
	u32s = three(UInt32, |b| b.append_u32(2), |b| b.append_u32(4_294_967_295))
	u64s = three(UInt64, |b| b.append_u64(3), |b| b.append_u64(18_446_744_073_709_551_615))
	f32s = three(Float32, |b| b.append_f32(1.5), |b| b.append_f32(-2.25))
	i128s = three(Decimal128({ precision: 38, scale: 0 }), |b| b.append_i128(-1), |b| b.append_i128(170_141_183_460_469_231_731_687_303_715_884_105_727))
	List.all(
		[
			PrimitiveColumn.i8(i8s).map_ok(|c| c.iter().collect()) == Ok([Ok(-128), Err(Null), Ok(127)]),
			PrimitiveColumn.i16(i16s).map_ok(|c| c.iter().collect()) == Ok([Ok(-32768), Err(Null), Ok(32767)]),
			PrimitiveColumn.u8(u8s).map_ok(|c| c.iter().collect()) == Ok([Ok(0), Err(Null), Ok(255)]),
			PrimitiveColumn.u16(u16s).map_ok(|c| c.iter().collect()) == Ok([Ok(1), Err(Null), Ok(65535)]),
			PrimitiveColumn.u32(u32s).map_ok(|c| c.iter().collect()) == Ok([Ok(2), Err(Null), Ok(4_294_967_295)]),
			PrimitiveColumn.u64(u64s).map_ok(|c| c.iter().collect()) == Ok([Ok(3), Err(Null), Ok(18_446_744_073_709_551_615)]),
			PrimitiveColumn.f32(f32s).map_ok(|c| c.iter().collect()) == Ok([Ok(1.5), Err(Null), Ok(-2.25)]),
			PrimitiveColumn.i128(i128s).map_ok(|c| c.iter().collect()) == Ok([Ok(-1), Err(Null), Ok(170_141_183_460_469_231_731_687_303_715_884_105_727)]),
		],
		|ok| ok,
	)
}

# Each typed append refuses a column of another physical type and names what it expected.
expect {
	refused = |dt, append, expected| {
		b = Builder.new(dt, 1) ?? crash "new"
		append(b).map_ok(|_| {}) == Err(ArrowErr(TypeMismatch({ path: "", expected, found: dt })))
	}
	List.all(
		[
			refused(Int16, |b| b.append_i8(1), "Int8"),
			refused(Int8, |b| b.append_i16(1), "Int16"),
			refused(Int64, |b| b.append_i32(1), "Int32"),
			refused(Int32, |b| b.append_i64(1), "Int64"),
			refused(Int8, |b| b.append_u8(1), "UInt8"),
			refused(Float16, |b| b.append_u16(1), "UInt16"),
			refused(Int32, |b| b.append_u32(1), "UInt32"),
			refused(Int64, |b| b.append_u64(1), "UInt64"),
			refused(Float64, |b| b.append_f32(1), "Float32"),
			refused(Float32, |b| b.append_f64(1), "Float64"),
			refused(Int64, |b| b.append_i128(1), "Decimal128"),
			refused(Int32, |b| b.append_bool(Bool.True), "Boolean"),
			refused(Int64, |b| b.append_dec(1), "Decimal"),
			refused(Utf8, |b| b.append_bytes([1]), "Binary"),
		],
		|ok| ok,
	)
}

# append_bytes fills Binary and LargeBinary, and FixedSizeBinary only at its width.
expect {
	bin = Builder.new(Binary, 2) ?? crash "new"
	large = Builder.new(LargeBinary, 2) ?? crash "new"
	fixed = Builder.new(FixedSizeBinary(2), 2) ?? crash "new"
	read = |b, dt| {
		arr = (((b.append_bytes([1, 2]) ?? crash "a").append_null() ?? crash "n").append_bytes([3]) ?? crash "b").finish() ?? crash "finish"
		col = BinaryColumn.from_array(arr) ?? crash "type"
		arr.data_type() == dt and col.iter_bytes().collect() == [Ok([1, 2]), Err(Null), Ok([3])]
	}
	fixed_arr = (((fixed.append_bytes([1, 2]) ?? crash "a").append_null() ?? crash "n").append_bytes([3, 4]) ?? crash "b").finish() ?? crash "finish"
	fixed_col = BinaryColumn.from_array(fixed_arr) ?? crash "type"
	read(bin, Binary)
		and read(large, LargeBinary)
		and fixed_col.iter_bytes().collect() == [Ok([1, 2]), Err(Null), Ok([3, 4])]
		and fixed.append_bytes([1, 2, 3]).map_ok(|_| {}) == Err(ArrowErr(OutOfRange("")))
}

# data_type gives the type of new; child_len counts list values and struct children.
expect {
	dt = Struct([DataType.field("a", Int32, Bool.False), DataType.field("b", DataType.list_of(Int64), Bool.False)])
	b0 = Builder.new(dt, 1) ?? crash "new"
	b1 = b0.update_child(0, |c| c.append_i32(7)) ?? crash "a"
	b2 = b1.update_child(
		1,
		|l| {
			filled = l.update_child(0, |c| (c.append_i64(1)?).append_i64(2))?
			filled.end_list()
		},
	) ?? crash "b"
	inner = b2.take_children().kids.get(1) ?? crash "kid"
	b2.data_type() == dt
		and b2.child_len(0) == 1
		and b2.child_len(1) == 1
		and b2.child_len(2) == 0
		and inner.child_len(0) == 2
		and (Builder.new(Int64, 0) ?? crash "new").child_len(0) == 0
}

# Validity and Boolean bits land in the right byte past the first one.
expect {
	b0 = Builder.new(Boolean, 0) ?? crash "new"
	var $b = b0
	for i in (0.U64).until(20) {
		$b = (if (i == 9) $b.append_null() else $b.append_bool(i % 8 == 0 or i == 17)) ?? crash "append"
	}
	col = BoolColumn.from_array($b.finish() ?? crash "finish") ?? crash "type"
	trues = (0.U64).until(20).keep_if(|i| col.get(i) == Ok(Bool.True)).collect()
	trues == [0, 8, 16, 17] and col.get(9) == Err(Null) and col.validity().null_count(20) == 1
}

# A Dec rescales into Decimal32 and Decimal64 and reads back; past the precision it fails.
expect {
	d32 = Decimal32({ precision: 9, scale: 2 })
	d64 = Decimal64({ precision: 18, scale: 4 })
	b32 = Builder.new(d32, 3) ?? crash "new"
	b64 = Builder.new(d64, 3) ?? crash "new"
	a32 = ((b32.append_dec(1.234) ?? crash "a").append_dec(-9_999_999.99) ?? crash "b").finish() ?? crash "finish"
	a64 = ((b64.append_dec(1.23456) ?? crash "a").append_dec(-99_999_999_999_999.9999) ?? crash "b").finish() ?? crash "finish"
	back32 : Try(List(Dec), _)
	back32 = [0, 1].map_try(|row| ArrowEncoding.decode_row(a32, row))
	back64 : Try(List(Dec), _)
	back64 = [0, 1].map_try(|row| ArrowEncoding.decode_row(a64, row))
	PrimitiveColumn.i32(a32).map_ok(|c| c.values()) == Ok([123, -999_999_999])
		and PrimitiveColumn.i64(a64).map_ok(|c| c.values()) == Ok([12346, -999_999_999_999_999_999])
		and back32 == Ok([1.23, -9_999_999.99])
		and back64 == Ok([1.2346, -99_999_999_999_999.9999])
		and b32.append_dec(10_000_000).map_ok(|_| {}) == Err(ArrowErr(OutOfRange("")))
		and b64.append_dec(100_000_000_000_000).map_ok(|_| {}) == Err(ArrowErr(OutOfRange("")))
}

# A Decimal32 whose declared precision is wider than 32 bits refuses a value that does not fit.
expect {
	b = Builder.new(Decimal32({ precision: 12, scale: 0 }), 1) ?? crash "new"
	b.append_dec(3_000_000_000).map_ok(|_| {}) == Err(ArrowErr(OutOfRange(""))) and b.append_dec(2_000_000_000).is_ok()
}

# end_struct pads a missing child with a null on every row, and fills nothing twice.
expect {
	dt = Struct([DataType.field("x", Int32, Bool.False), DataType.field("y", Int32, Bool.True)])
	b0 = Builder.new(dt, 0) ?? crash "new"
	var $b = b0
	for i in (0.I32).until(3) {
		row = (if (i == 1) $b.update_child(1, |c| c.append_i32(i)) else $b.update_child(0, |c| c.append_i32(i))) ?? crash "fill"
		$b = row.end_struct() ?? crash "end"
	}
	col = StructColumn.from_array($b.finish() ?? crash "finish") ?? crash "type"
	xs = PrimitiveColumn.i32(col.column("x") ?? crash "x") ?? crash "i32"
	ys = PrimitiveColumn.i32(col.column("y") ?? crash "y") ?? crash "i32"
	xs.iter().collect() == [Ok(0), Err(Null), Ok(2)] and ys.iter().collect() == [Err(Null), Ok(1), Err(Null)]
}

# Nested appends keep each child unique: 50k list rows through update_child
# and through take_children, and 50k records with a list field through
# encode_row. These tests guard linear time by their run time: at 50k rows a
# quadratic append takes 0.5 s to 1.3 s per test, a linear one about 22 ms.
expect {
	n = 50_000
	b0 = Builder.new(DataType.list_of(Utf8), 0) ?? crash "new"
	var $b = b0
	for i in (0.U64).until(n) {
		filled = $b.update_child(0, |c| (c.append_str("a ${i.to_str()}")?).append_str("b")) ?? crash "fill"
		$b = filled.end_list() ?? crash "end"
	}
	$b.len() == n and $b.child_len(0) == 2 * n
}

expect {
	n = 50_000
	dt = Struct([DataType.field("tags", DataType.list_of(Utf8), Bool.False)])
	b0 = Builder.new(dt, 0) ?? crash "new"
	var $b = b0
	for i in (0.U64).until(n) {
		row = $b.update_child(
			0,
			|l| {
				{ shell, kids } = l.take_children()
				kid = match kids {
					[k] => k
					_ => crash "one child"
				}
				one = kid.append_str("a ${i.to_str()}")?
				shell.put_children([one]).end_list()
			},
		) ?? crash "fill"
		$b = row.end_struct() ?? crash "end"
	}
	$b.len() == n
}

expect {
	n = 50_000
	dt = Struct([DataType.field("tags", DataType.list_of(Utf8), Bool.False), DataType.field("pair", Struct([DataType.field("0", Int64, Bool.False), DataType.field("1", Utf8, Bool.False)]), Bool.False)])
	b0 = Builder.new(dt, 0) ?? crash "new"
	var $b = b0
	for i in (0.U64).until(n) {
		$b = ArrowEncoding.encode_row($b, { tags: ["a ${i.to_str()}", "b"], pair: (i.to_i64_wrap(), "p") }) ?? crash "encode"
	}
	arr = $b.finish() ?? crash "finish"
	back : Try({ tags : List(Str), pair : (I64, Str) }, _)
	back = ArrowEncoding.decode_row(arr, n - 1)
	back == Ok({ tags: ["a 49999", "b"], pair: (49_999, "p") })
}

# Utf8View and BinaryView build inline and out-of-line values and read back.
expect {
	long = "a value longer than twelve bytes"
	sv = Builder.new(Utf8View, 3) ?? crash "new"
	sbuilt = ((sv.append_str("short") ?? crash "a").append_null() ?? crash "n").append_str(long) ?? crash "b"
	sarr = sbuilt.finish() ?? crash "finish"
	# The last buffer holds the size of each data buffer.
	sizes_ok = match sbuilt.finish_host().buffers.last() {
		Ok(I64s(sizes)) => sizes == [long.count_utf8_bytes().to_i64_wrap()]
		_ => Bool.False
	}
	scol = BinaryColumn.from_array(sarr) ?? crash "type"
	bv = Builder.new(BinaryView, 3) ?? crash "new"
	bytes = List.repeat(7, 13)
	barr = (((bv.append_bytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]) ?? crash "a").append_bytes(bytes) ?? crash "b").append_null() ?? crash "n").finish() ?? crash "finish"
	bcol = BinaryColumn.from_array(barr) ?? crash "type"
	back : Try(Str, _)
	back = ArrowEncoding.decode_row(sarr, 2)
	sarr.data_type() == Utf8View
		and sizes_ok
		and scol.get_str(0) == Ok("short")
		and scol.get_str(1) == Err(Null)
		and scol.get_str(2) == Ok(long)
		and back == Ok(long)
		and bcol.iter_bytes().collect() == [Ok([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]), Ok(bytes), Err(Null)]
		and (Builder.new(BinaryView, 1) ?? crash "new").append_str("x").map_ok(|_| {}) == Err(ArrowErr(TypeMismatch({ path: "", expected: "Utf8", found: BinaryView })))
}

# A Utf8View column round-trips through encode_row and decode_row.
expect {
	b0 = Builder.new(Struct([DataType.field("s", Utf8View, Bool.True)]), 2) ?? crash "new"
	rows : List({ s : Try(Str, [Null]) })
	rows = [{ s: Ok("x") }, { s: Err(Null) }, { s: Ok("a string of more than twelve") }]
	built = rows.fold(b0, |b, r| ArrowEncoding.encode_row(b, r) ?? crash "encode")
	arr = built.finish() ?? crash "finish"
	back : Try(List({ s : Try(Str, [Null]) }), _)
	back = [0, 1, 2].map_try(|row| ArrowEncoding.decode_row(arr, row))
	back == Ok(rows)
}
