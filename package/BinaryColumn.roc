import Array
import DataType
import Validity

## A zero-copy view of any variable- or fixed-width byte column: Binary,
## Utf8, their Large and View forms, and FixedSizeBinary. `get_bytes` returns
## a slice of the data buffer; a View value of 12 bytes or less is inline in
## its view and so costs one small copy.
##
## `offs` and `data` repeat a Binary or Utf8 column's buffers (empty for the
## other layouts), so the loop read of the common layout is one sublist with
## no match on the body.
BinaryColumn :: { buffers : Array.Body, rows : U64, valid : Validity, utf8 : Bool, var32 : Bool, offs : List(I32), data : List(U8) }.{

	## The view of a Binary, LargeBinary, BinaryView, Utf8, LargeUtf8, Utf8View or
	## FixedSizeBinary array. O(1), no copy. Refuses any other type.
	from_array : Array -> Try(BinaryColumn, [TypeMismatch(DataType)])
	from_array = |arr| {
		utf8 = match arr.data_type() {
			Utf8 | LargeUtf8 | Utf8View => Bool.True
			_ => Bool.False
		}
		match arr.body() {
			Var32(_, _) | Var64(_, _) | Views(_, _) | Fixed(_, _) =>
				match arr.data_type() {
					Binary | LargeBinary | BinaryView | Utf8 | LargeUtf8 | Utf8View | FixedSizeBinary(_) => {
						(var32, offs, data) = match arr.body() {
							Var32(o, d) => (Bool.True, o, d)
							_ => (Bool.False, [], [])
						}
						Ok({ buffers: arr.body(), rows: arr.len(), valid: arr.validity(), utf8, var32, offs, data })
					}
					_ => Err(TypeMismatch(arr.data_type()))
				}
			_ => Err(TypeMismatch(arr.data_type()))
		}
	}

	## The row count. O(1).
	len : BinaryColumn -> U64
	len = |col| col.rows

	## Whether row `row` holds a value. False past the end.
	is_valid : BinaryColumn, U64 -> Bool
	is_valid = |col, row| row < col.rows and col.valid.is_valid(row)

	## The validity, at the column's bit offset. O(1), no copy.
	validity : BinaryColumn -> Validity
	validity = |col| col.valid

	## Row `row`'s bytes, null or not: the loop read. A slice of the data
	## buffer, or a small copy for a View value of 12 bytes or less; empty
	## past the end.
	bytes_at : BinaryColumn, U64 -> List(U8)
	bytes_at = |col, row|
		if col.var32 {
			start = (col.offs.get(row) ?? 0).to_u64_wrap()
			end = (col.offs.get(row + 1) ?? 0).to_u64_wrap()
			col.data.sublist({ start, len: end.minus_saturated(start) })
		} else {
			body_bytes(col.buffers, row)
		}

	## The byte length of every row's value together (for a View column, the
	## out-of-line data only): a size hint for a writer.
	data_len : BinaryColumn -> U64
	data_len = |col| match col.buffers {
		Var32(offs, _) => (offs.last() ?? 0).to_u64_wrap() - (offs.first() ?? 0).to_u64_wrap()
		Var64(offs, _) => (offs.last() ?? 0).to_u64_wrap() - (offs.first() ?? 0).to_u64_wrap()
		Fixed(w, _) => w * col.rows
		Views(_, datas) => datas.fold(0, |n, d| n + d.len())
		_ => 0
	}

	## Whether the column's type is a string type.
	is_utf8 : BinaryColumn -> Bool
	is_utf8 = |col| col.utf8

	## Row `row`'s bytes: `Null` at a NULL row, `OutOfBounds` past the end. A slice,
	## or a small copy for a View value of 12 bytes or less.
	get_bytes : BinaryColumn, U64 -> Try(List(U8), [Null, OutOfBounds])
	get_bytes = |col, row|
		if row >= col.rows {
			Err(OutOfBounds)
		} else if !col.valid.is_valid(row) {
			Err(Null)
		} else {
			Ok(body_bytes(col.buffers, row))
		}

	## The value as text. Validates UTF-8 on every call, also for a Binary
	## column; zero copy for values over 23 bytes.
	get_str : BinaryColumn, U64 -> Try(Str, [Null, OutOfBounds, BadUtf8])
	get_str = |col, row| {
		bytes = BinaryColumn.get_bytes(col, row)?
		Str.from_utf8(bytes).map_err(|_| BadUtf8)
	}

	## Every row in order, `Err(Null)` at a NULL row. Each item costs as `get_bytes`.
	iter_bytes : BinaryColumn -> Iter(Try(List(U8), [Null]))
	iter_bytes = |col| Iter.custom(
		0,
		Ok(col.rows),
		|row| match BinaryColumn.get_bytes(col, row) {
			Ok(x) => Ok((Ok(x), row + 1))
			Err(Null) => Ok((Err(Null), row + 1))
			Err(OutOfBounds) => Err(NoMore)
		},
	)
}

## Bytes of a row already known to be in range.
body_bytes : Array.Body, U64 -> List(U8)
body_bytes = |b, row| match b {
	Var32(offs, data) => {
		start = (offs.get(row) ?? 0).to_u64_wrap()
		end = (offs.get(row + 1) ?? 0).to_u64_wrap()
		data.sublist({ start, len: end.minus_saturated(start) })
	}
	Var64(offs, data) => {
		start = (offs.get(row) ?? 0).to_u64_wrap()
		end = (offs.get(row + 1) ?? 0).to_u64_wrap()
		data.sublist({ start, len: end.minus_saturated(start) })
	}
	Views(words, datas) => {
		size = (words.get(row * 4) ?? 0).to_u64()
		if size <= 12 {
			inline = [words.get(row * 4 + 1) ?? 0, words.get(row * 4 + 2) ?? 0, words.get(row * 4 + 3) ?? 0]
			inline.join_map(le_bytes).take_first(size)
		} else {
			index = (words.get(row * 4 + 2) ?? 0).to_u64()
			start = (words.get(row * 4 + 3) ?? 0).to_u64()
			(datas.get(index) ?? []).sublist({ start, len: size })
		}
	}
	Fixed(w, bytes) => bytes.sublist({ start: row * w, len: w })
	_ => []
}

le_bytes : U32 -> List(U8)
le_bytes = |x| [x.to_u8_wrap(), x.shr_zf_wrap(8).to_u8_wrap(), x.shr_zf_wrap(16).to_u8_wrap(), x.shr_zf_wrap(24).to_u8_wrap()]

import Host

utf8_host : Host.Array
utf8_host = { length: 3, null_count: 1, offset: 0, buffers: [U8s([0b101]), I32s([0, 2, 2, 7]), U8s("hiworld".to_utf8())], children: [], dictionary: [] }

expect {
	arr = Array.from_host(utf8_host, Utf8) ?? crash "import"
	col = BinaryColumn.from_array(arr) ?? crash "type"
	col.get_str(0) == Ok("hi") and col.get_str(1) == Err(Null) and col.get_str(2) == Ok("world") and col.is_utf8()
}

# Decreasing offsets are refused at import.
expect {
	bad = { ..utf8_host, buffers: [Absent, I32s([0, 5, 2, 7]), U8s("hiworld".to_utf8())] }
	Array.from_host(bad, Utf8).is_err()
}

# Offsets past the data are refused at import.
expect {
	bad = { ..utf8_host, buffers: [Absent, I32s([0, 2, 2, 9]), U8s("hiworld".to_utf8())] }
	Array.from_host(bad, Binary).is_err()
}

# Utf8View: one inline value (<= 12 bytes) and one in a data buffer.
expect {
	long = "a string over twelve".to_utf8()
	# "abc" inline: length 3, then bytes in the next 12 (little-endian words).
	words = [3, 0x00636261, 0, 0, long.len().to_u32_wrap(), 0x74732061, 0, 0]
	host = { length: 2, null_count: 0, offset: 0, buffers: [Absent, U32s(words), U8s(long), I64s([long.len().to_i64_wrap()])], children: [], dictionary: [] }
	arr = Array.from_host(host, Utf8View) ?? crash "import"
	col = BinaryColumn.from_array(arr) ?? crash "type"
	col.get_str(0) == Ok("abc") and col.get_str(1) == Ok("a string over twelve")
}

# A view pointing past its buffer is refused.
expect {
	words = [20, 0, 0, 5]
	host = { length: 1, null_count: 0, offset: 0, buffers: [Absent, U32s(words), U8s([1, 2, 3]), I64s([3])], children: [], dictionary: [] }
	Array.from_host(host, BinaryView).is_err()
}

expect {
	host = { length: 2, null_count: 0, offset: 1, buffers: [Absent, U8s([1, 2, 3, 4, 5, 6])], children: [], dictionary: [] }
	arr = Array.from_host(host, FixedSizeBinary(2)) ?? crash "import"
	col = BinaryColumn.from_array(arr) ?? crash "type"
	col.get_bytes(0) == Ok([3, 4]) and col.get_bytes(1) == Ok([5, 6])
}

# The same four rows in every layout, after a leading row cut off by the host
# offset: ["ab", NULL over "xyz", "", "hello world!!"].
expected_rows : List(Try(List(U8), [Null]))
expected_rows = [Ok("ab".to_utf8()), Err(Null), Ok([]), Ok("hello world!!".to_utf8())]

# Validity from bit 1; row 1 is NULL. Bits past the last row are set.
offset_bits : Host.Buffer
offset_bits = U8s([0xFB])

var_data : Host.Buffer
var_data = U8s("Qabxyzhello world!!".to_utf8())

binary_host : Host.Array
binary_host = { length: 4, null_count: 1, offset: 1, buffers: [offset_bits, I32s([0, 1, 3, 6, 6, 19]), var_data], children: [], dictionary: [] }

large_host : Host.Array
large_host = { ..binary_host, buffers: [offset_bits, I64s([0, 1, 3, 6, 6, 19]), var_data] }

fixed_host : Host.Array
fixed_host = { length: 3, null_count: 1, offset: 1, buffers: [U8s([0xFB]), U8s("..abxycd".to_utf8())], children: [], dictionary: [] }

view_host : Host.Array
view_host = {
	length: 4,
	null_count: 1,
	offset: 1,
	buffers: [
		offset_bits,
		U32s([4, 0x6b6e756a, 0, 0, 2, 0x6261, 0, 0, 3, 0x7a7978, 0, 0, 0, 0, 0, 0, 13, 0x6c6c6568, 1, 1]),
		U8s("pad".to_utf8()),
		U8s("Zhello world!!".to_utf8()),
		I64s([3, 14]),
	],
	children: [],
	dictionary: [],
}

bin_col : Host.Array, DataType -> BinaryColumn
bin_col = |host, dt| BinaryColumn.from_array(Array.from_host(host, dt) ?? crash "import") ?? crash "type"

# The loop read of every row, null or not.
all_bytes_at : BinaryColumn -> List(List(U8))
all_bytes_at = |col| (0.U64).until(col.len()).map(|i| col.bytes_at(i)).collect()

expect {
	col = bin_col(binary_host, Binary)
	col.iter_bytes().collect() == expected_rows and col.data_len() == 18 and !col.is_utf8()
}

expect {
	col = bin_col(large_host, LargeBinary)
	col.iter_bytes().collect() == expected_rows and col.data_len() == 18
}

expect {
	col = bin_col(view_host, BinaryView)
	col.iter_bytes().collect() == expected_rows and col.data_len() == 17
}

expect {
	col = bin_col(fixed_host, FixedSizeBinary(2))
	col.iter_bytes().collect() == [Ok("ab".to_utf8()), Err(Null), Ok("cd".to_utf8())] and col.data_len() == 6
}

# `bytes_at` reads the bytes under a NULL, and nothing past the end.
expect {
	want = ["ab", "xyz", "", "hello world!!", ""].map(Str.to_utf8)
	ok = |col| (0.U64).until(5).map(|i| col.bytes_at(i)).collect() == want
	ok(bin_col(binary_host, Binary)) and ok(bin_col(large_host, LargeBinary)) and ok(bin_col(view_host, BinaryView))
}

expect {
	col = bin_col(fixed_host, FixedSizeBinary(2))
	all_bytes_at(col) == ["ab", "xy", "cd"].map(Str.to_utf8) and col.bytes_at(3) == []
}

expect {
	all = [bin_col(binary_host, Binary), bin_col(large_host, LargeBinary), bin_col(view_host, BinaryView)]
	all.all(|col| col.is_valid(0) and !col.is_valid(1) and col.is_valid(3) and !col.is_valid(4) and col.validity().null_count(4) == 1)
}

expect {
	col = bin_col(fixed_host, FixedSizeBinary(2))
	col.is_valid(2) and !col.is_valid(1) and !col.is_valid(3) and !col.validity().is_valid(1)
}

# A slice of a slice keeps the last two rows in every layout.
expect {
	cut = |host, dt| BinaryColumn.from_array((Array.from_host(host, dt) ?? crash "import").slice(1, 3).slice(1, 2)) ?? crash "type"
	last_two = expected_rows.drop_first(2)
	b = cut(binary_host, Binary)
	l = cut(large_host, LargeBinary)
	v = cut(view_host, BinaryView)
	f = cut(fixed_host, FixedSizeBinary(2))
	b.iter_bytes().collect() == last_two
		and l.iter_bytes().collect() == last_two
		and v.iter_bytes().collect() == last_two
		and f.iter_bytes().collect() == [Ok("cd".to_utf8())]
		and b.data_len() == 13
		and l.data_len() == 13
		and f.data_len() == 2
		and all_bytes_at(b) == ["", "hello world!!"].map(Str.to_utf8)
		and b.bytes_at(2) == []
		and l.bytes_at(2) == []
}

# A type with a byte layout that is not a byte type is refused.
expect {
	host = { length: 1, null_count: 0, offset: 0, buffers: [Absent, U8s([0, 0, 0, 0, 0, 0, 0, 0])], children: [], dictionary: [] }
	arr = Array.from_host(host, Interval(DayTime)) ?? crash "import"
	match BinaryColumn.from_array(arr) {
		Err(TypeMismatch(Interval(DayTime))) => Bool.True
		_ => Bool.False
	}
}

expect BinaryColumn.from_array(Array.from_i32s([1])).is_err()

# Bad buffers are refused at import.
expect Array.from_host({ ..large_host, buffers: [Absent, I64s([0, 1, 6, 3, 6, 19]), var_data] }, LargeBinary).is_err()
expect Array.from_host({ ..large_host, buffers: [Absent, I64s([0, 1, 3, 6, 6, 20]), var_data] }, LargeBinary).is_err()
expect Array.from_host({ ..large_host, buffers: [Absent, I64s([0, 1, 3, 6, 6]), var_data] }, LargeBinary).is_err()
expect Array.from_host({ ..binary_host, buffers: [Absent, I64s([0, 1, 3, 6, 6, 19]), var_data] }, Binary).is_err()
expect Array.from_host({ ..fixed_host, buffers: [Absent, U8s("..abxyc".to_utf8())] }, FixedSizeBinary(2)).is_err()
expect Array.from_host({ ..view_host, length: 5 }, BinaryView).is_err()

# A long view whose prefix is not the start of its value is refused.
expect {
	long = "a string over twelve".to_utf8()
	host = |prefix| { length: 1, null_count: 0, offset: 0, buffers: [Absent, U32s([long.len().to_u32_wrap(), prefix, 0, 0]), U8s(long), I64s([long.len().to_i64_wrap()])], children: [], dictionary: [] }
	Array.from_host(host(0x74732061), Utf8View).is_ok() and Array.from_host(host(0x74732062), Utf8View).is_err()
}

# An inline view with a byte after its value is refused; zero padding is fine.
expect {
	host = |words| { length: 1, null_count: 0, offset: 0, buffers: [Absent, U32s(words), I64s([])], children: [], dictionary: [] }
	ok = [[3, 0x00636261, 0, 0], [12, 1, 2, 3], [0, 0, 0, 0], [4, 0x64636261, 0, 0]].all(|w| Array.from_host(host(w), BinaryView).is_ok())
	bad = [[3, 0x01636261, 0, 0], [0, 0, 0, 0x100], [4, 0x64636261, 1, 0], [11, 0, 0, 0xFF000000]].all(|w| Array.from_host(host(w), BinaryView).is_err())
	ok and bad
}
