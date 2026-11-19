import Array
import DataType
import Validity

## A zero-copy view of a Utf8 column that validates its text once.
## `from_array` checks the bytes from the first row's start to the last row's
## end as one UTF-8 string, and each offset as the start of a character; a
## row is then a cut of that string at its offsets: no copy and no second
## validation. When the text is not valid UTF-8 or an offset cuts a
## character (Arrow promises neither happens), each row decodes its own
## bytes, with replacement characters for the bad ones, and the column never
## fails.
##
## When the host passed the data buffer as `Host.Buffer.Utf8(str)`, the view
## uses that `Str` and does not check it: the host promises valid UTF-8, and
## invalid bytes break the invariants of `Str`. A `U8s` data buffer is
## always checked.
Utf8Column :: { offs : List(I32), data : List(U8), valid : Validity, text : Str, base : U64, bytes : U64 }.{

	## The view of a Utf8 array. Checks the text once as UTF-8 (O(text bytes)),
	## or not at all for a trusted `Str` (see `Array.trusted_text`), and copies
	## nothing. Refuses any other type, LargeUtf8 and Utf8View included.
	from_array : Array -> Try(Utf8Column, [TypeMismatch(DataType)])
	from_array = |arr| match (arr.data_type(), arr.body()) {
		(Utf8, Var32(offs, data)) => {
			base = (offs.first() ?? 0).to_u64_wrap()
			end = (offs.last() ?? 0).to_u64_wrap()
			# Zero copy either way: the Str shares the data buffer.
			cut = match arr.trusted_text() {
				Ok(all) =>
					match all.drop_first_bytes(base) {
						Ok(rest) => rest.drop_last_bytes(data.len() - end)
						Err(e) => Err(e)
					}
				Err(NoText) => Err(BadUtf8)
			}
			text = match cut {
				Ok(str) => str
				Err(_) =>
					if on_char_starts(offs, data, end) {
						Str.from_utf8(data.sublist({ start: base, len: end - base })) ?? ""
					} else {
						""
					}
			}
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

	## Whether the column's bytes are valid UTF-8 and every offset starts a
	## character (each row then costs one cut). Trusted text is not checked.
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

## Whether every offset before `end` is at the first byte of a character:
## a byte that is not `0b10xx_xxxx`.
on_char_starts : List(I32), List(U8), U64 -> Bool
on_char_starts = |offs, data, end| {
	var $i = 0
	while $i < offs.len() {
		at = (offs.get($i) ?? 0).to_u64_wrap()
		if at < end and (data.get(at) ?? 0).bitwise_and(0xC0) == 0x80 {
			return Bool.False
		}
		$i = $i + 1
	}
	Bool.True
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

# Every row, `Err(Null)` at a NULL row.
rows_of : Utf8Column -> List(Try(Str, [Null, OutOfBounds]))
rows_of = |col| {
	var $out = []
	for i in (0.U64).until(col.len()) {
		$out = $out.append(col.get(i))
	}
	$out
}

# Text rows in several scripts, with empty and NULL rows, as the host sends them.
script_rows : List(Str)
script_rows = ["abc", "", "été", "日本語", "🎉x", "gone", "naïve 🐦", ""]

script_host : Host.Buffer, I64, I64 -> Host.Array
script_host = |data, offset, length| {
	offs = script_rows.fold([0.I32], |acc, r| acc.append((acc.last() ?? 0) + r.count_utf8_bytes().to_i32_wrap()))
	# Row 5 is NULL.
	{ length, null_count: -1, offset, buffers: [U8s([0b1101_1111]), I32s(offs), data], children: [], dictionary: [] }
}

script_want : List(Try(Str, [Null, OutOfBounds]))
script_want = script_rows.map_with_index(|r, i| if (i == 5) Err(Null) else Ok(r))

# A trusted Str and the same bytes give the same rows, whole and at an offset.
expect {
	text = Str.join_with(script_rows, "")
	read = |data, offset, length| {
		arr = Array.from_host(script_host(data, offset, length), Utf8) ?? crash "import"
		rows_of(Utf8Column.from_array(arr) ?? crash "view")
	}
	trusted = read(Utf8(text), 0, 8)
	trusted == script_want and read(U8s(text.to_utf8()), 0, 8) == script_want and read(Utf8(text), 2, 5) == script_want.sublist({ start: 2, len: 5 }) and read(U8s(text.to_utf8()), 2, 5) == read(Utf8(text), 2, 5)
}

# A trusted column exports bytes, and the bytes read back as the same rows.
expect {
	text = Str.join_with(script_rows, "")
	arr = Array.from_host(script_host(Utf8(text), 1, 6), Utf8) ?? crash "import"
	out = arr.to_host()
	back = Array.from_host(out, Utf8) ?? crash "round trip"
	bytes_out = match out.buffers.get(2) {
		Ok(U8s(bytes)) => bytes == text.to_utf8()
		_ => Bool.False
	}
	bytes_out and rows_of(Utf8Column.from_array(back) ?? crash "view") == script_want.sublist({ start: 1, len: 6 })
}

# A trusted column with no rows, and one of empty rows only.
expect {
	none = { length: 0, null_count: 0, offset: 0, buffers: [Absent, I32s([0]), Utf8("")], children: [], dictionary: [] }
	empty = { length: 2, null_count: 0, offset: 0, buffers: [Absent, I32s([0, 0, 0]), Utf8("")], children: [], dictionary: [] }
	a = Utf8Column.from_array(Array.from_host(none, Utf8) ?? crash "import") ?? crash "view"
	b = Utf8Column.from_array(Array.from_host(empty, Utf8) ?? crash "import") ?? crash "view"
	a.len() == 0 and rows_of(b) == [Ok(""), Ok("")] and b.is_valid_utf8()
}

# An array of no rows with an empty offsets buffer is a column of no rows.
expect {
	host = { length: 0, null_count: 0, offset: 0, buffers: [Absent, I32s([]), U8s([])], children: [], dictionary: [] }
	col = Utf8Column.from_array(Array.from_host(host, Utf8) ?? crash "import") ?? crash "view"
	col.len() == 0 and col.get(0) == Err(OutOfBounds) and col.is_valid_utf8()
}

# An offset inside a character: the bytes are UTF-8, but the cut is not, so
# the column is not valid UTF-8 and each row decodes its own bytes.
expect {
	host = |offs| { length: 2, null_count: 0, offset: 0, buffers: [Absent, I32s(offs), U8s("aéb".to_utf8())], children: [], dictionary: [] }
	split = Utf8Column.from_array(Array.from_host(host([0, 2, 4]), Utf8) ?? crash "import") ?? crash "view"
	whole = Utf8Column.from_array(Array.from_host(host([0, 3, 4]), Utf8) ?? crash "import") ?? crash "view"
	!split.is_valid_utf8() and split.at(0) == "a\u(FFFD)" and split.at(1) == "\u(FFFD)b" and whole.is_valid_utf8() and whole.at(0) == "aé"
}
