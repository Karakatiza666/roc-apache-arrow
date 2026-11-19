import ByteScan
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

	## Row `row`'s byte length, NULL or not: 0 past the end. No `Str`.
	byte_len : Utf8Column, U64 -> U64
	byte_len = |col, row| {
		(start, end) = bounds(col, row)
		end - start
	}

	## Byte `index` of row `row`, NULL or not. No `Str`.
	byte_at : Utf8Column, U64, U64 -> Try(U8, [OutOfBounds])
	byte_at = |col, row, index| {
		(start, end) = bounds(col, row)
		if (index < end - start) col.data.get(start + index) else Err(OutOfBounds)
	}

	## Whether row `row` holds exactly the text `s`, NULL or not. A row past
	## the end holds no bytes. No `Str` per row.
	eq_str : Utf8Column, U64, Str -> Bool
	eq_str = |col, row, s| {
		(start, end) = bounds(col, row)
		ByteScan.eq_str(col.data, start, end, s)
	}

	## Whether row `row` holds exactly the bytes `xs`. No `Str` per row.
	eq_bytes : Utf8Column, U64, List(U8) -> Bool
	eq_bytes = |col, row, xs| {
		(start, end) = bounds(col, row)
		ByteScan.eq_bytes(col.data, start, end, xs)
	}

	## The byte span of row `row` with ASCII white space trimmed at both ends,
	## relative to the row's start. Only space, tab, line feed, vertical tab,
	## form feed and carriage return count: other Unicode white space (for
	## example U+00A0) stays. No `Str`.
	trim_ascii : Utf8Column, U64 -> { start : U64, len : U64 }
	trim_ascii = |col, row| {
		(start, end) = bounds(col, row)
		ByteScan.trim(col.data, start, end)
	}

	## The part of `span` (relative to the row's start) before its first
	## ASCII white space byte: the first word of a trimmed span.
	first_word : Utf8Column, U64, { start : U64, len : U64 } -> { start : U64, len : U64 }
	first_word = |col, row, span| {
		(start, end) = bounds(col, row)
		ByteScan.first_word(col.data, start, end, span)
	}

	## The index (relative to the row's start) of the first `byte` in `span`.
	find_byte : Utf8Column, U64, { start : U64, len : U64 }, U8 -> Try(U64, [NotFound])
	find_byte = |col, row, span, byte| {
		(start, end) = bounds(col, row)
		ByteScan.find(col.data, start, end, span, byte)
	}

	## Append `span` of row `row` to `out`, as is or in ASCII upper or lower
	## case: one copy, no `Str`. The span is cut to the row, and an end inside
	## a character moves back to that character's first byte, so `out` gets
	## whole characters, and spans that meet give the row with no loss. When
	## the column is not valid UTF-8, the span decodes with replacement
	## characters, as `at` does. `Writer.part_range` calls it.
	append_span : Utf8Column, U64, { start : U64, len : U64 }, [AsIs, AsciiUpper, AsciiLower], List(U8) -> List(U8)
	append_span = |col, row, span, case, out| {
		(start, end) = bounds(col, row)
		if Utf8Column.is_valid_utf8(col) {
			ByteScan.append(col.data, start, end, span, case, Bool.True, out)
		} else {
			{ s, e } = ByteScan.clamp(start, end, span)
			fixed = Str.from_utf8_lossy(col.data.sublist({ start: s, len: e - s })).to_utf8()
			ByteScan.append(fixed, 0, fixed.len(), { start: 0, len: fixed.len() }, case, Bool.True, out)
		}
	}
}

## The byte bounds of row `row` in the data buffer; an empty span past the end.
bounds : Utf8Column, U64 -> (U64, U64)
bounds = |col, row| {
	start = (col.offs.get(row) ?? 0).to_u64_wrap()
	end = (col.offs.get(row + 1) ?? 0).to_u64_wrap()
	(start, end.max(start))
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

# Byte reads of every script row, whole and at an offset, trusted and
# checked: the byte length and bytes equal those of the row's text, under a
# NULL row too, and nothing past the end.
expect {
	text = Str.join_with(script_rows, "")
	view = |data, offset, length| Utf8Column.from_array(Array.from_host(script_host(data, offset, length), Utf8) ?? crash "import") ?? crash "view"
	ok = |col, rows| {
		each = rows.map_with_index(
			|r, i| {
				bytes = r.to_utf8()
				col.byte_len(i) == bytes.len()
					and bytes.map_with_index(|b, k| col.byte_at(i, k) == Ok(b)).all(|x| x)
					and col.byte_at(i, bytes.len()) == Err(OutOfBounds)
					and col.eq_str(i, r)
					and col.eq_bytes(i, bytes)
					and !col.eq_str(i, "${r}x")
					and !col.eq_bytes(i, bytes.append(0))
			},
		)
		n = rows.len()
		each.all(|b| b) and col.byte_len(n) == 0 and col.byte_at(n, 0) == Err(OutOfBounds) and col.eq_str(n, "") and !col.eq_str(n, "a")
	}
	ok(view(Utf8(text), 0, 8), script_rows) and ok(view(U8s(text.to_utf8()), 0, 8), script_rows) and ok(view(Utf8(text), 2, 5), script_rows.sublist({ start: 2, len: 5 })) and ok(view(U8s(text.to_utf8()), 3, 4), script_rows.sublist({ start: 3, len: 4 }))
}

# A row that differs only in its last byte, or is a prefix, is not equal.
expect {
	col = Utf8Column.from_array(Array.from_strs(["été", "ét"])) ?? crash "view"
	!col.eq_str(0, "étè") and !col.eq_str(0, "ét") and !col.eq_str(1, "été") and col.eq_str(1, "ét")
}

trim_rows : List(Str)
trim_rows = ["  ab cd  ", "\t\n\u(B)\u(C)\r x \r", "", "   ", "\u(A0)é日\u(A0)", " 🎉 🚀", "word", "  naïve 東京 "]

trim_col : Utf8Column
trim_col = Utf8Column.from_array(Array.from_strs(trim_rows).slice(0, 8)) ?? crash "view"

# The text of `span` of row `row`, through `append_span`.
span_text : Utf8Column, U64, { start : U64, len : U64 }, [AsIs, AsciiUpper, AsciiLower] -> Str
span_text = |col, row, span, case| Str.from_utf8(col.append_span(row, span, case, [])) ?? "!bad"

# ASCII white space only: U+00A0 at the ends of row 4 stays.
expect {
	spans = (0.U64).until(8).map(|i| trim_col.trim_ascii(i)).collect()
	spans == [{ start: 2, len: 5 }, { start: 6, len: 1 }, { start: 0, len: 0 }, { start: 3, len: 0 }, { start: 0, len: 9 }, { start: 1, len: 9 }, { start: 0, len: 4 }, { start: 2, len: 13 }]
		and (0.U64).until(8).map(|i| span_text(trim_col, i, trim_col.trim_ascii(i), AsIs)).collect() == ["ab cd", "x", "", "", "\u(A0)é日\u(A0)", "🎉 🚀", "word", "naïve 東京"]
		and trim_col.trim_ascii(8) == { start: 0, len: 0 }
}

expect {
	word = |i| span_text(trim_col, i, trim_col.first_word(i, trim_col.trim_ascii(i)), AsIs)
	(0.U64).until(8).map(word).collect() == ["ab", "x", "", "", "\u(A0)é日\u(A0)", "🎉", "word", "naïve"]
		and trim_col.first_word(0, { start: 0, len: 2 }) == { start: 0, len: 0 }
		and trim_col.first_word(0, { start: 50, len: 3 }) == { start: 9, len: 0 }
}

expect {
	find = |i| trim_col.find_byte(i, { start: 0, len: 100 }, ' ')
	(0.U64).until(9).map(find).collect() == [Ok(0), Ok(5), Err(NotFound), Ok(0), Err(NotFound), Ok(0), Err(NotFound), Ok(0), Err(NotFound)]
		and trim_col.find_byte(0, { start: 2, len: 5 }, ' ') == Ok(4)
		and trim_col.find_byte(0, { start: 2, len: 2 }, ' ') == Err(NotFound)
}

# ASCII case maps only ASCII letters; a span is cut to the row.
expect {
	all = { start: 0, len: 1000 }
	span_text(trim_col, 7, all, AsciiUpper) == "  NAïVE 東京 "
		and span_text(trim_col, 4, all, AsciiLower) == "\u(A0)é日\u(A0)"
		and span_text(trim_col, 0, { start: 2, len: 2 }, AsciiUpper) == "AB"
		and span_text(Utf8Column.from_array(Array.from_strs(["MiXeD ÉtÉ"])) ?? crash "view", 0, all, AsciiLower) == "mixed ÉtÉ"
		and span_text(trim_col, 0, { start: 20, len: 2 }, AsIs) == ""
		and span_text(trim_col, 9, all, AsIs) == ""
}

# A span end inside a character moves back to its first byte, so spans that
# meet give the row back at every cut.
expect {
	row = "aé日🎉"
	col = Utf8Column.from_array(Array.from_strs([row])) ?? crash "view"
	n = row.count_utf8_bytes()
	cuts_ok = (0.U64).until(n + 1).fold(
		Bool.True,
		|acc, k| {
			out = col.append_span(0, { start: k, len: n }, AsIs, col.append_span(0, { start: 0, len: k }, AsIs, []))
			acc and out == row.to_utf8()
		},
	)
	cuts_ok and span_text(col, 0, { start: 1, len: 1 }, AsIs) == "" and span_text(col, 0, { start: 2, len: 2 }, AsIs) == "é" and span_text(col, 0, { start: 4, len: 3 }, AsIs) == "日"
}

# A column that is not valid UTF-8 appends its spans with replacement characters.
expect {
	host = { length: 1, null_count: 0, offset: 0, buffers: [Absent, I32s([0, 3]), U8s([0x61, 0xFF, 0x62])], children: [], dictionary: [] }
	col = Utf8Column.from_array(Array.from_host(host, Utf8) ?? crash "import") ?? crash "view"
	span_text(col, 0, { start: 0, len: 3 }, AsciiUpper) == "A\u(FFFD)B" and col.byte_len(0) == 3 and col.byte_at(0, 1) == Ok(0xFF)
}

# Case maps reach both ends of each ASCII letter range and leave the bytes
# just outside them; a first word ends at any ASCII white space; a shorter
# or longer row is not equal.
expect {
	col = Utf8Column.from_array(Array.from_strs(["az AZ @[`{", "ab\tcd", "ab\ncd", "abc"])) ?? crash "view"
	all = { start: 0, len: 100 }
	span_text(col, 0, all, AsciiUpper) == "AZ AZ @[`{"
		and span_text(col, 0, all, AsciiLower) == "az az @[`{"
		and col.first_word(1, all) == { start: 0, len: 2 }
		and col.first_word(2, all) == { start: 0, len: 2 }
		and !col.eq_bytes(3, "ab".to_utf8())
		and !col.eq_bytes(3, "abcd".to_utf8())
		and !col.eq_str(3, "ab")
		and col.eq_bytes(3, "abc".to_utf8())
}
