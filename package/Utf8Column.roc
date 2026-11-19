import Array
import DataType
import Validity

## A zero-copy view of a Utf8 column that validates its text once.
## `from_array` checks the bytes from the first row's start to the last row's
## end as one UTF-8 string; a row is then a cut of that string at its offsets:
## no copy and no second validation. When the text is not valid UTF-8 (Arrow
## promises it is), each row decodes its own bytes, with replacement
## characters for the bad ones, and the column never fails.
Utf8Column :: { offs : List(I32), data : List(U8), valid : Validity, text : Str, base : U64, bytes : U64 }.{

	## The view of a Utf8 array. Checks the text once as UTF-8 (O(text bytes)) and
	## copies nothing. Refuses any other type, LargeUtf8 and Utf8View included.
	from_array : Array -> Try(Utf8Column, [TypeMismatch(DataType)])
	from_array = |arr| match (arr.data_type(), arr.body()) {
		(Utf8, Var32(offs, data)) => {
			base = (offs.first() ?? 0).to_u64_wrap()
			end = (offs.last() ?? 0).to_u64_wrap()
			# Zero copy: the Str shares the data buffer.
			text = Str.from_utf8(data.sublist({ start: base, len: end - base })) ?? ""
			Ok({ offs, data, valid: arr.validity(), text, base, bytes: end - base })
		}
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The row count. O(1).
	len : Utf8Column -> U64
	len = |col| col.offs.len() - 1

	## The validity, at the column's bit offset. O(1), no copy.
	validity : Utf8Column -> Validity
	validity = |col| col.valid

	## Whether row `row` holds a value. False past the end.
	is_valid : Utf8Column, U64 -> Bool
	is_valid = |col, row| row + 1 < col.offs.len() and col.valid.is_valid(row)

	## The byte length of every row's text together.
	data_len : Utf8Column -> U64
	data_len = |col| col.bytes

	## Whether the column's bytes are valid UTF-8 (each row then costs one cut).
	is_valid_utf8 : Utf8Column -> Bool
	is_valid_utf8 = |col| col.bytes == 0 or !col.text.is_empty()

	## Row `row`'s text: `Null` at a NULL row, `OutOfBounds` past the end. A slice,
	## no copy, when the column is valid UTF-8.
	get : Utf8Column, U64 -> Try(Str, [Null, OutOfBounds])
	get = |col, row|
		if row + 1 >= col.offs.len() {
			Err(OutOfBounds)
		} else if !col.valid.is_valid(row) {
			Err(Null)
		} else {
			Ok(Utf8Column.at(col, row))
		}

	## Row `row`'s text, null or not: the loop read. Empty past the end.
	at : Utf8Column, U64 -> Str
	at = |col, row| {
		start = (col.offs.get(row) ?? 0).to_u64_wrap()
		end = (col.offs.get(row + 1) ?? 0).to_u64_wrap()
		cut =
			if col.text.is_empty() {
				Err(BadUtf8)
			} else {
				match col.text.drop_first_bytes(start - col.base) {
					Ok(rest) => rest.drop_last_bytes(col.bytes - (end - col.base))
					Err(e) => Err(e)
				}
			}
		match cut {
			Ok(s) => s
			Err(_) => Str.from_utf8_lossy(col.data.sublist({ start, len: end - start }))
		}
	}
}

import Host

expect {
	host = { length: 3, null_count: 1, offset: 0, buffers: [U8s([0b101]), I32s([0, 2, 2, 7]), U8s("hiworld".to_utf8())], children: [], dictionary: [] }
	arr = Array.from_host(host, Utf8) ?? crash "import"
	col = Utf8Column.from_array(arr) ?? crash "view"
	col.at(0) == "hi" and col.at(2) == "world" and col.get(1) == Err(Null) and col.get(3) == Err(OutOfBounds) and col.data_len() == 7
}

# Rows 1 and 2 of three: the text starts at row 1, and a row with a two-byte
# character is cut at its code point boundaries.
expect {
	host = { length: 2, null_count: 0, offset: 1, buffers: [Absent, I32s([0, 2, 5, 8]), U8s("hiaébcd".to_utf8())], children: [], dictionary: [] }
	arr = Array.from_host(host, Utf8) ?? crash "import"
	col = Utf8Column.from_array(arr) ?? crash "view"
	col.at(0) == "aé" and col.at(1) == "bcd" and col.is_valid_utf8() and col.len() == 2
}

# Bytes that are not UTF-8 decode row by row, with replacement characters.
expect {
	host = { length: 2, null_count: 0, offset: 0, buffers: [Absent, I32s([0, 1, 3]), U8s([0xFF, 0x6F, 0x6B])], children: [], dictionary: [] }
	arr = Array.from_host(host, Utf8) ?? crash "import"
	col = Utf8Column.from_array(arr) ?? crash "view"
	col.at(0) == "\u(FFFD)" and col.at(1) == "ok" and !col.is_valid_utf8()
}

# A Binary column is not text.
expect {
	host = { length: 1, null_count: 0, offset: 0, buffers: [Absent, I32s([0, 1]), U8s([65])], children: [], dictionary: [] }
	arr = Array.from_host(host, Binary) ?? crash "import"
	Utf8Column.from_array(arr).is_err()
}

# The validity marks the NULL row; a column with no bitmap is all valid.
expect {
	host = { length: 3, null_count: 1, offset: 0, buffers: [U8s([0b101]), I32s([0, 1, 1, 2]), U8s("ab".to_utf8())], children: [], dictionary: [] }
	col = Utf8Column.from_array(Array.from_host(host, Utf8) ?? crash "import") ?? crash "view"
	all = Utf8Column.from_array(Array.from_strs(["x"])) ?? crash "view"
	v = col.validity()
	[v.is_valid(0), v.is_valid(1), v.is_valid(2)] == [Bool.True, Bool.False, Bool.True] and v.null_count(3) == 1 and all.validity() == AllValid
}

# is_valid is False at a NULL row and past the end.
expect {
	host = { length: 2, null_count: 1, offset: 0, buffers: [U8s([0b10]), I32s([0, 0, 1]), U8s("z".to_utf8())], children: [], dictionary: [] }
	col = Utf8Column.from_array(Array.from_host(host, Utf8) ?? crash "import") ?? crash "view"
	all = Utf8Column.from_array(Array.from_strs(["x"])) ?? crash "view"
	[col.is_valid(0), col.is_valid(1), col.is_valid(2), all.is_valid(0), all.is_valid(1)] == [Bool.False, Bool.True, Bool.False, Bool.True, Bool.False]
}
