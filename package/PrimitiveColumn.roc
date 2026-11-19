import Array
import DataType
import Validity

## A zero-copy view of a fixed-width column: the typed values list plus the
## validity. `values` holds an arbitrary value at a null row.
##
## Each constructor accepts every Arrow type with that physical layout, for
## example `i64` takes Int64, Date64, Time64, Timestamp, Duration and
## Decimal64.
PrimitiveColumn(a) :: { values : List(a), valid : Validity }.{

	## The view of an Int8 array. O(1), no copy. Refuses any
	## other layout.
	i8 : Array -> Try(PrimitiveColumn(I8), [TypeMismatch(DataType)])
	i8 = |arr| match arr.body() {
		I8s(xs) => Ok({ values: xs, valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The view of an Int16 array. O(1), no copy. Refuses any
	## other layout.
	i16 : Array -> Try(PrimitiveColumn(I16), [TypeMismatch(DataType)])
	i16 = |arr| match arr.body() {
		I16s(xs) => Ok({ values: xs, valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The view of an Int32, Date32, Time32, Interval(YearMonth) or Decimal32
	## array. O(1), no copy. Refuses any other layout.
	i32 : Array -> Try(PrimitiveColumn(I32), [TypeMismatch(DataType)])
	i32 = |arr| match arr.body() {
		I32s(xs) => Ok({ values: xs, valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The view of an Int64, Date64, Time64, Timestamp, Duration or Decimal64
	## array. O(1), no copy. Refuses any other layout.
	i64 : Array -> Try(PrimitiveColumn(I64), [TypeMismatch(DataType)])
	i64 = |arr| match arr.body() {
		I64s(xs) => Ok({ values: xs, valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The view of a UInt8 array. O(1), no copy. Refuses any
	## other layout.
	u8 : Array -> Try(PrimitiveColumn(U8), [TypeMismatch(DataType)])
	u8 = |arr| match arr.body() {
		U8s(xs) => Ok({ values: xs, valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The view of a UInt16 (Float16 bits too) array. O(1), no copy. Refuses any
	## other layout.
	u16 : Array -> Try(PrimitiveColumn(U16), [TypeMismatch(DataType)])
	u16 = |arr| match arr.body() {
		U16s(xs) => Ok({ values: xs, valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The view of a UInt32 array. O(1), no copy. Refuses any
	## other layout.
	u32 : Array -> Try(PrimitiveColumn(U32), [TypeMismatch(DataType)])
	u32 = |arr| match arr.body() {
		U32s(xs) => Ok({ values: xs, valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The view of a UInt64 array. O(1), no copy. Refuses any
	## other layout.
	u64 : Array -> Try(PrimitiveColumn(U64), [TypeMismatch(DataType)])
	u64 = |arr| match arr.body() {
		U64s(xs) => Ok({ values: xs, valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The view of a Float32 array. O(1), no copy. Refuses any
	## other layout.
	f32 : Array -> Try(PrimitiveColumn(F32), [TypeMismatch(DataType)])
	f32 = |arr| match arr.body() {
		F32s(xs) => Ok({ values: xs, valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The view of a Float64 array. O(1), no copy. Refuses any
	## other layout.
	f64 : Array -> Try(PrimitiveColumn(F64), [TypeMismatch(DataType)])
	f64 = |arr| match arr.body() {
		F64s(xs) => Ok({ values: xs, valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## Decimal128 unscaled values.
	i128 : Array -> Try(PrimitiveColumn(I128), [TypeMismatch(DataType)])
	i128 = |arr| match arr.body() {
		I128s(xs) => Ok({ values: xs, valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The row count. O(1).
	len : PrimitiveColumn(a) -> U64
	len = |col| col.values.len()

	## Whether row `row` holds a value. False past the end.
	is_valid : PrimitiveColumn(a), U64 -> Bool
	is_valid = |col, row| row < col.values.len() and col.valid.is_valid(row)

	## Row `row`'s value: `Null` at a NULL row, `OutOfBounds` past the end.
	get : PrimitiveColumn(a), U64 -> Try(a, [Null, OutOfBounds])
	get = |col, row| match col.values.get(row) {
		Ok(x) => if (col.valid.is_valid(row)) Ok(x) else Err(Null)
		Err(_) => Err(OutOfBounds)
	}

	## Row `row`'s value, null or not: the loop read. `zero` only past the end.
	at : PrimitiveColumn(a), U64, a -> a
	at = |col, row, zero| col.values.get(row) ?? zero

	## The raw values, zero copy. Null rows hold arbitrary values.
	values : PrimitiveColumn(a) -> List(a)
	values = |col| col.values

	## The validity, at the column's bit offset. O(1), no copy.
	validity : PrimitiveColumn(a) -> Validity
	validity = |col| col.valid

	## The NULL rows, counted from the bitmap. O(rows).
	null_count : PrimitiveColumn(a) -> U64
	null_count = |col| col.valid.null_count(col.values.len())

	## Every row in order, `Err(Null)` at a null row.
	iter : PrimitiveColumn(a) -> Iter(Try(a, [Null]))
	iter = |col| Iter.custom(
		0,
		Ok(col.values.len()),
		|row| match col.values.get(row) {
			Ok(x) => Ok((if (col.valid.is_valid(row)) Ok(x) else Err(Null), row + 1))
			Err(_) => Err(NoMore)
		},
	)
}

import Host

# Typed host buffers wrap with zero copy; offset 1 and a bitmap with row 1 null.
expect {
	host = { length: 3, null_count: 1, offset: 1, buffers: [U8s([0b0000_0111]), I64s([9, 10, 20, 30])], children: [], dictionary: [] }
	match Array.from_host(host, Int64) {
		Ok(arr) => {
			col = PrimitiveColumn.i64(arr) ?? crash "type"
			col.len() == 3 and col.get(0) == Ok(10) and col.get(1) == Ok(20) and col.get(2) == Err(Null) and col.get(3) == Err(OutOfBounds) and col.null_count() == 1
		}
		Err(_) => Bool.False
	}
}

# The pure path: U8s bytes decode (copy) into typed values.
expect {
	host = { length: 2, null_count: 0, offset: 0, buffers: [Absent, U8s([1, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255])], children: [], dictionary: [] }
	match Array.from_host(host, Timestamp(Microsecond, "")) {
		Ok(arr) => PrimitiveColumn.i64(arr).map_ok(|c| c.values()) == Ok([1, -1])
		Err(_) => Bool.False
	}
}

expect {
	host = { length: 2, null_count: 0, offset: 0, buffers: [Absent, F64s([0.5, 1.5])], children: [], dictionary: [] }
	match Array.from_host(host, Float64) {
		Ok(arr) => PrimitiveColumn.f64(arr).map_ok(|c| c.iter().collect()) == Ok([Ok(0.5), Ok(1.5)])
		Err(_) => Bool.False
	}
}

# A short value buffer is refused, not read out of bounds.
expect {
	host = { length: 3, null_count: 0, offset: 1, buffers: [Absent, I32s([1, 2, 3])], children: [], dictionary: [] }
	Array.from_host(host, Int32).is_err()
}

# A slice of a slice keeps the right rows and validity.
expect {
	host = { length: 4, null_count: 1, offset: 0, buffers: [U8s([0b0000_1101]), I16s([1, 2, 3, 4])], children: [], dictionary: [] }
	match Array.from_host(host, Int16) {
		Ok(arr) => {
			col = PrimitiveColumn.i16(arr.slice(1, 3).slice(0, 2)) ?? crash "type"
			col.get(0) == Err(Null) and col.get(1) == Ok(3) and col.len() == 2
		}
		Err(_) => Bool.False
	}
}

# Export then re-import gives the same rows.
expect {
	host = { length: 3, null_count: 1, offset: 2, buffers: [U8s([0b0011_0111]), I64s([0, 0, 5, 6, 7])], children: [], dictionary: [] }
	match Array.from_host(host, Int64) {
		Ok(arr) => {
			back = Array.from_host(arr.to_host(), Int64) ?? crash "re-import"
			PrimitiveColumn.i64(back).map_ok(|c| c.iter().collect()) == Ok([Ok(5), Err(Null), Ok(7)])
		}
		Err(_) => Bool.False
	}
}

# The vectorized round trip: map the raw values, keep the input's validity.
expect {
	host = { length: 3, null_count: 1, offset: 1, buffers: [U8s([0b0000_1011]), I64s([0, 1, 2, 3])], children: [], dictionary: [] }
	arg = Array.from_host(host, Int64) ?? crash "import"
	col = PrimitiveColumn.i64(arg) ?? crash "type"
	out = Array.from_i64s(col.values().map(|x| x * 2)).with_validity(col.validity())
	back = Array.from_host(out.to_host(), Int64) ?? crash "export"
	PrimitiveColumn.i64(back).map_ok(|c| c.iter().collect()) == Ok([Ok(2), Err(Null), Ok(6)])
}

# Hostile sizes fail validation instead of overflowing.
expect {
	host = { length: I64.highest, null_count: 0, offset: I64.highest, buffers: [Absent, U8s([1, 2])], children: [], dictionary: [] }
	Array.from_host(host, FixedSizeBinary(32)).is_err() and Array.from_host(host, Utf8View).is_err() and Array.from_host(host, Int64).is_err()
}

# Each other constructor reads its own layout and refuses another.
expect {
	host = { length: 2, null_count: 1, offset: 0, buffers: [U8s([0b0000_0001]), I8s([-3, 4])], children: [], dictionary: [] }
	arr = Array.from_host(host, Int8) ?? crash "import"
	PrimitiveColumn.i8(arr).map_ok(|c| c.iter().collect()) == Ok([Ok(-3), Err(Null)]) and PrimitiveColumn.u8(arr).is_err()
}

expect {
	arr = Array.from_u8s([7, 255])
	PrimitiveColumn.u8(arr).map_ok(|c| c.values()) == Ok([7, 255]) and PrimitiveColumn.i8(arr).map_ok(|c| c.values()) == Err(TypeMismatch(UInt8))
}

expect {
	host = { length: 2, null_count: 0, offset: 1, buffers: [Absent, U16s([1, 2, 65535])], children: [], dictionary: [] }
	arr = Array.from_host(host, UInt16) ?? crash "import"
	PrimitiveColumn.u16(arr).map_ok(|c| c.values()) == Ok([2, 65535]) and PrimitiveColumn.i16(arr).is_err()
}

expect {
	host = { length: 2, null_count: 0, offset: 0, buffers: [Absent, U32s([4_000_000_000, 5])], children: [], dictionary: [] }
	arr = Array.from_host(host, UInt32) ?? crash "import"
	PrimitiveColumn.u32(arr).map_ok(|c| c.values()) == Ok([4_000_000_000, 5]) and PrimitiveColumn.i32(arr).is_err()
}

expect {
	host = { length: 1, null_count: 0, offset: 0, buffers: [Absent, U64s([U64.highest])], children: [], dictionary: [] }
	arr = Array.from_host(host, UInt64) ?? crash "import"
	PrimitiveColumn.u64(arr).map_ok(|c| c.values()) == Ok([U64.highest]) and PrimitiveColumn.i64(arr).is_err()
}

expect {
	host = { length: 2, null_count: 0, offset: 0, buffers: [Absent, F32s([0.5, -2.0])], children: [], dictionary: [] }
	arr = Array.from_host(host, Float32) ?? crash "import"
	PrimitiveColumn.f32(arr).map_ok(|c| c.values()) == Ok([0.5, -2.0]) and PrimitiveColumn.f64(arr).is_err()
}

# i128 accepts Decimal128 and refuses Int64.
expect {
	host = { length: 2, null_count: 0, offset: 0, buffers: [Absent, I128s([12345, -1])], children: [], dictionary: [] }
	arr = Array.from_host(host, Decimal128({ precision: 10, scale: 2 })) ?? crash "import"
	PrimitiveColumn.i128(arr).map_ok(|c| c.values()) == Ok([12345, -1]) and PrimitiveColumn.i128(Array.from_i64s([1])).map_ok(|c| c.values()) == Err(TypeMismatch(Int64))
}
