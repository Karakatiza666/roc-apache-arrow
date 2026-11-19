import Array
import DataType
import Validity

## A zero-copy view of a Boolean column (bit-packed values).
BoolColumn :: { bits : List(U8), offset : U64, rows : U64, valid : Validity }.{

	## The view of a Boolean array. O(1), no copy. Refuses any other type.
	from_array : Array -> Try(BoolColumn, [TypeMismatch(DataType)])
	from_array = |arr| match arr.body() {
		BoolBits(bits, offset) => Ok({ bits, offset, rows: arr.len(), valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The row count. O(1).
	len : BoolColumn -> U64
	len = |col| col.rows

	## Whether row `row` holds a value. False past the end.
	is_valid : BoolColumn, U64 -> Bool
	is_valid = |col, row| row < col.rows and col.valid.is_valid(row)

	## The validity, at the column's bit offset. O(1), no copy.
	validity : BoolColumn -> Validity
	validity = |col| col.valid

	## Row `row`'s value, null or not: the loop read. False past the end.
	at : BoolColumn, U64 -> Bool
	at = |col, row| row < col.rows and Validity.bit(col.bits, col.offset + row)

	## Row `row`'s value: `Null` at a NULL row, `OutOfBounds` past the end.
	get : BoolColumn, U64 -> Try(Bool, [Null, OutOfBounds])
	get = |col, row|
		if row >= col.rows {
			Err(OutOfBounds)
		} else if !col.valid.is_valid(row) {
			Err(Null)
		} else {
			Ok(Validity.bit(col.bits, col.offset + row))
		}

	## Every row in order, `Err(Null)` at a NULL row.
	iter : BoolColumn -> Iter(Try(Bool, [Null]))
	iter = |col| Iter.custom(
		0,
		Ok(col.rows),
		|row| match BoolColumn.get(col, row) {
			Ok(x) => Ok((Ok(x), row + 1))
			Err(Null) => Ok((Err(Null), row + 1))
			Err(OutOfBounds) => Err(NoMore)
		},
	)
}

import Host

# Values from bit 3: rows [T, T, F, T, F, T]; row 1 is NULL over a set bit.
# Bit 9 is set past the last row.
bool_host : Host.Array
bool_host = { length: 6, null_count: 1, offset: 3, buffers: [U8s([0xEF, 0xFF]), U8s([0x5C, 0x03])], children: [], dictionary: [] }

bool_col : BoolColumn
bool_col = BoolColumn.from_array(Array.from_host(bool_host, Boolean) ?? crash "import") ?? crash "type"

expect bool_col.len() == 6

expect bool_col.iter().collect() == [Ok(Bool.True), Err(Null), Ok(Bool.False), Ok(Bool.True), Ok(Bool.False), Ok(Bool.True)]

# `at` reads the value under a NULL, and False past the end.
expect bool_col.at(1) and !bool_col.at(2) and bool_col.at(5) and !bool_col.at(6)

expect bool_col.get(1) == Err(Null) and bool_col.get(6) == Err(OutOfBounds) and bool_col.get(0) == Ok(Bool.True)

expect bool_col.is_valid(0) and !bool_col.is_valid(1) and !bool_col.is_valid(6)

expect bool_col.validity().null_count(6) == 1 and !bool_col.validity().is_valid(1)

# A slice of a slice: bit offset 6 crosses into the second byte.
expect {
	arr = Array.from_host(bool_host, Boolean) ?? crash "import"
	col = BoolColumn.from_array(arr.slice(1, 5).slice(2, 3)) ?? crash "type"
	col.iter().collect() == [Ok(Bool.True), Ok(Bool.False), Ok(Bool.True)] and !col.at(3)
}

# A slice that starts on the NULL row.
expect {
	arr = Array.from_host(bool_host, Boolean) ?? crash "import"
	col = BoolColumn.from_array(arr.slice(1, 2)) ?? crash "type"
	col.iter().collect() == [Err(Null), Ok(Bool.False)] and col.at(0)
}

expect {
	host = { length: 2, null_count: 0, offset: 0, buffers: [Absent, I8s([1, 0])], children: [], dictionary: [] }
	arr = Array.from_host(host, Int8) ?? crash "import"
	match BoolColumn.from_array(arr) {
		Err(TypeMismatch(Int8)) => Bool.True
		_ => Bool.False
	}
}

# A value buffer shorter than offset + length is refused.
expect Array.from_host({ ..bool_host, buffers: [Absent, U8s([0x5C])] }, Boolean).is_err()
