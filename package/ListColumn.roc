import Array
import DataType
import Validity

## A zero-copy view of List, LargeList, FixedSizeList and Map columns. A row
## is a range of the child array; `get` returns that range as a sliced child.
ListColumn :: { buffers : Array.Body, rows : U64, valid : Validity }.{

	## The view of a List, LargeList, FixedSizeList or Map array. O(1), no copy.
	## Refuses any other type.
	from_array : Array -> Try(ListColumn, [TypeMismatch(DataType)])
	from_array = |arr| match arr.body() {
		List32(_, _) | List64(_, _) | FixedList(_, _) => Ok({ buffers: arr.body(), rows: arr.len(), valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The row count. O(1).
	len : ListColumn -> U64
	len = |col| col.rows

	## Whether row `row` holds a value. False past the end.
	is_valid : ListColumn, U64 -> Bool
	is_valid = |col, row| row < col.rows and col.valid.is_valid(row)

	## The validity, at the column's bit offset. O(1), no copy.
	validity : ListColumn -> Validity
	validity = |col| col.valid

	## Where row `row`'s values sit in `values`, null or not: the loop read.
	## Empty past the end.
	range_at : ListColumn, U64 -> { start : U64, len : U64 }
	range_at = |col, row| if (row < col.rows) body_range(col.buffers, row) else { start: 0, len: 0 }

	## All values of all rows (the child array).
	values : ListColumn -> Array
	values = |col| match col.buffers {
		List32(_, c) | List64(_, c) | FixedList(_, c) => c
		_ => Array.nulls(0)
	}

	## Where row `row`'s values sit in `values`.
	range : ListColumn, U64 -> Try({ start : U64, len : U64 }, [Null, OutOfBounds])
	range = |col, row|
		if row >= col.rows {
			Err(OutOfBounds)
		} else if !col.valid.is_valid(row) {
			Err(Null)
		} else {
			Ok(body_range(col.buffers, row))
		}

	## Row `row`'s values as a sliced child array.
	get : ListColumn, U64 -> Try(Array, [Null, OutOfBounds])
	get = |col, row| {
		r = ListColumn.range(col, row)?
		Ok(ListColumn.values(col).slice(r.start, r.len))
	}
}

body_range : Array.Body, U64 -> { start : U64, len : U64 }
body_range = |b, row| match b {
	List32(offs, _) => {
		start = (offs.get(row) ?? 0).to_u64_wrap()
		{ start, len: (offs.get(row + 1) ?? 0).to_u64_wrap() - start }
	}
	List64(offs, _) => {
		start = (offs.get(row) ?? 0).to_u64_wrap()
		{ start, len: (offs.get(row + 1) ?? 0).to_u64_wrap() - start }
	}
	FixedList(size, _) => { start: row * size, len: size }
	_ => { start: 0, len: 0 }
}

import Host
import PrimitiveColumn

# [[1, 2], null, [3]] as List(Int64), read through a slice.
expect {
	child = { length: 3, null_count: 0, offset: 0, buffers: [Absent, I64s([1, 2, 3])], children: [], dictionary: [] }
	host = { length: 3, null_count: 1, offset: 0, buffers: [U8s([0b101]), I32s([0, 2, 2, 3])], children: [child], dictionary: [] }
	arr = Array.from_host(host, DataType.list_of(Int64)) ?? crash "import"
	col = ListColumn.from_array(arr.slice(0, 3)) ?? crash "type"
	first = col.get(0) ?? crash "row 0"
	third = col.get(2) ?? crash "row 2"
	PrimitiveColumn.i64(first).map_ok(|c| c.values()) == Ok([1, 2]) and col.get(1).is_err() and PrimitiveColumn.i64(third).map_ok(|c| c.values()) == Ok([3])
}

# An offset past the child is refused.
expect {
	child = { length: 1, null_count: 0, offset: 0, buffers: [Absent, I64s([1])], children: [], dictionary: [] }
	host = { length: 1, null_count: 0, offset: 0, buffers: [Absent, I32s([0, 2])], children: [child], dictionary: [] }
	Array.from_host(host, DataType.list_of(Int64)).is_err()
}

# Rows after a leading row cut off by the host offset: [[1, 2], NULL over [3],
# [], [4, 5, 6]]. Validity bits past the last row are set.
list_bits : Host.Buffer
list_bits = U8s([0xFB])

list_child : Host.Array
list_child = { length: 7, null_count: 0, offset: 0, buffers: [Absent, I64s([0, 1, 2, 3, 4, 5, 6])], children: [], dictionary: [] }

list_host : Host.Array
list_host = { length: 4, null_count: 1, offset: 1, buffers: [list_bits, I32s([0, 1, 3, 4, 4, 7])], children: [list_child], dictionary: [] }

large_list_host : Host.Array
large_list_host = { ..list_host, buffers: [list_bits, I64s([0, 1, 3, 4, 4, 7])] }

# Rows of two after a leading row: [2, 3], NULL over [4, 5], [6, 7], [8, 9].
fixed_list_host : Host.Array
fixed_list_host = {
	length: 4,
	null_count: 1,
	offset: 1,
	buffers: [list_bits],
	children: [{ ..list_child, length: 10, buffers: [Absent, I64s([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])] }],
	dictionary: [],
}

# The entries of `list_host` as a map from "a" .. "g" to 0 .. 6.
map_host : Host.Array
map_host = {
	..list_host,
	children: [
		{
			length: 7,
			null_count: 0,
			offset: 0,
			buffers: [Absent],
			children: [
				{ length: 7, null_count: 0, offset: 0, buffers: [Absent, I32s([0, 1, 2, 3, 4, 5, 6, 7]), U8s("abcdefg".to_utf8())], children: [], dictionary: [] },
				list_child,
			],
			dictionary: [],
		},
	],
}

fixed_list_type : DataType
fixed_list_type = FixedSizeList(DataType.field("item", Int64, Bool.True), 2)

large_list_type : DataType
large_list_type = LargeList(DataType.field("item", Int64, Bool.True))

list_col : Host.Array, DataType -> ListColumn
list_col = |host, dt| ListColumn.from_array(Array.from_host(host, dt) ?? crash "import") ?? crash "type"

ranges_at : ListColumn -> List({ start : U64, len : U64 })
ranges_at = |col| (0.U64).until(col.len() + 1).map(|i| col.range_at(i)).collect()

ranges : ListColumn -> List(Try({ start : U64, len : U64 }, [Null, OutOfBounds]))
ranges = |col| (0.U64).until(col.len() + 1).map(|i| col.range(i)).collect()

# Offset layouts: ranges are absolute into the child.
expect {
	want_at = [{ start: 1, len: 2 }, { start: 3, len: 1 }, { start: 4, len: 0 }, { start: 4, len: 3 }, { start: 0, len: 0 }]
	want = [Ok({ start: 1, len: 2 }), Err(Null), Ok({ start: 4, len: 0 }), Ok({ start: 4, len: 3 }), Err(OutOfBounds)]
	cols = [list_col(list_host, DataType.list_of(Int64)), list_col(large_list_host, large_list_type), list_col(map_host, DataType.map_of(Utf8, Int64, Bool.True))]
	cols.all(|col| col.len() == 4 and ranges_at(col) == want_at and ranges(col) == want and col.values().len() == 7)
}

# FixedSizeList: the child is already cut to the rows, so ranges start at 0.
expect {
	col = list_col(fixed_list_host, fixed_list_type)
	want_at = [{ start: 0, len: 2 }, { start: 2, len: 2 }, { start: 4, len: 2 }, { start: 6, len: 2 }, { start: 0, len: 0 }]
	want = [Ok({ start: 0, len: 2 }), Err(Null), Ok({ start: 4, len: 2 }), Ok({ start: 6, len: 2 }), Err(OutOfBounds)]
	first = col.get(0) ?? crash "row 0"
	ranges_at(col) == want_at and ranges(col) == want and PrimitiveColumn.i64(first).map_ok(|c| c.values()) == Ok([2, 3])
}

expect {
	cols = [
		list_col(list_host, DataType.list_of(Int64)),
		list_col(large_list_host, large_list_type),
		list_col(fixed_list_host, fixed_list_type),
		list_col(map_host, DataType.map_of(Utf8, Int64, Bool.True)),
	]
	cols.all(|col| col.is_valid(0) and !col.is_valid(1) and col.is_valid(3) and !col.is_valid(4) and col.validity().null_count(4) == 1 and !col.validity().is_valid(1))
}

# A slice of a slice keeps the last two rows.
expect {
	cut = |host, dt| ListColumn.from_array((Array.from_host(host, dt) ?? crash "import").slice(1, 3).slice(1, 2)) ?? crash "type"
	l = cut(large_list_host, large_list_type)
	f = cut(fixed_list_host, fixed_list_type)
	m = cut(map_host, DataType.map_of(Utf8, Int64, Bool.True))
	last = l.get(1) ?? crash "row 1"
	fixed_last = f.get(1) ?? crash "row 1"
	ranges(l) == [Ok({ start: 4, len: 0 }), Ok({ start: 4, len: 3 }), Err(OutOfBounds)]
		and ranges(m) == ranges(l)
		and ranges_at(f) == [{ start: 0, len: 2 }, { start: 2, len: 2 }, { start: 0, len: 0 }]
		and PrimitiveColumn.i64(last).map_ok(|c| c.values()) == Ok([4, 5, 6])
		and PrimitiveColumn.i64(fixed_last).map_ok(|c| c.values()) == Ok([8, 9])
}

expect {
	match ListColumn.from_array(Array.from_i64s([1])) {
		Err(TypeMismatch(Int64)) => Bool.True
		_ => Bool.False
	}
}

# Bad buffers are refused at import.
expect Array.from_host({ ..large_list_host, buffers: [Absent, I64s([0, 1, 4, 3, 4, 7])] }, large_list_type).is_err()
expect Array.from_host({ ..large_list_host, buffers: [Absent, I64s([0, 1, 3, 4, 4, 8])] }, large_list_type).is_err()
expect Array.from_host({ ..large_list_host, buffers: [Absent, I64s([0, -1, 3, 4, 4, 7])] }, large_list_type).is_err()
expect Array.from_host({ ..list_host, buffers: [Absent, I64s([0, 1, 3, 4, 4, 7])] }, DataType.list_of(Int64)).is_err()
expect Array.from_host({ ..list_host, children: [] }, DataType.list_of(Int64)).is_err()
expect Array.from_host({ ..fixed_list_host, length: 5 }, fixed_list_type).is_err()
expect Array.from_host({ ..map_host, buffers: [Absent, I32s([0, 1, 3, 4, 4, 8])] }, DataType.map_of(Utf8, Int64, Bool.True)).is_err()
