## Byte-level reads of one row of a byte column: the row is `data` from
## `start` to `end`. The column views call these, so a read makes no `Str`
## and no slice. Not exposed: `Utf8Column` and `BinaryColumn` are the API.
ByteScan := [].{

	## ASCII white space: space, tab, line feed, vertical tab, form feed and
	## carriage return. These are the only bytes the trims remove.
	is_space : U8 -> Bool
	is_space = |b| b == 32 or (b >= 9 and b <= 13)

	## The row's span with ASCII white space removed at both ends, relative
	## to `start`.
	trim : List(U8), U64, U64 -> { start : U64, len : U64 }
	trim = |data, start, end| {
		var $s = start
		while $s < end and ByteScan.is_space(data.get($s) ?? 0) {
			$s = $s + 1
		}
		var $e = end
		while $e > $s and ByteScan.is_space(data.get($e - 1) ?? 0) {
			$e = $e - 1
		}
		{ start: $s - start, len: $e - $s }
	}

	## `span` (relative to `start`) cut to the row.
	clamp : U64, U64, { start : U64, len : U64 } -> { s : U64, e : U64 }
	clamp = |start, end, span| {
		s = start + span.start.min(end - start)
		{ s, e: s + span.len.min(end - s) }
	}

	## The part of `span` before its first ASCII white space byte.
	first_word : List(U8), U64, U64, { start : U64, len : U64 } -> { start : U64, len : U64 }
	first_word = |data, start, end, span| {
		{ s, e } = ByteScan.clamp(start, end, span)
		var $i = s
		while $i < e and !ByteScan.is_space(data.get($i) ?? 0) {
			$i = $i + 1
		}
		{ start: s - start, len: $i - s }
	}

	## The index (relative to `start`) of the first `byte` in `span`.
	find : List(U8), U64, U64, { start : U64, len : U64 }, U8 -> Try(U64, [NotFound])
	find = |data, start, end, span, byte| {
		{ s, e } = ByteScan.clamp(start, end, span)
		var $i = s
		while $i < e {
			if data.get($i) == Ok(byte) {
				return Ok($i - start)
			}
			$i = $i + 1
		}
		Err(NotFound)
	}

	## Whether the row holds exactly `xs`.
	eq_bytes : List(U8), U64, U64, List(U8) -> Bool
	eq_bytes = |data, start, end, xs| {
		if end - start != xs.len() {
			return Bool.False
		}
		var $i = 0
		while $i < xs.len() {
			if data.get(start + $i) != xs.get($i) {
				return Bool.False
			}
			$i = $i + 1
		}
		Bool.True
	}

	## Whether the row holds exactly the UTF-8 bytes of `s`.
	eq_str : List(U8), U64, U64, Str -> Bool
	eq_str = |data, start, end, s| {
		if end - start != s.count_utf8_bytes() {
			return Bool.False
		}
		var $i = start
		for b in s.iter_utf8() {
			if data.get($i) != Ok(b) {
				return Bool.False
			}
			$i = $i + 1
		}
		Bool.True
	}

	## Append `span` of the row to `out`, mapped by `case`. With `utf8`, an
	## end of the span inside a character moves back to that character's
	## first byte, so the bytes appended are whole characters, and spans that
	## meet append the row's bytes with no loss.
	append : List(U8), U64, U64, { start : U64, len : U64 }, [AsIs, AsciiUpper, AsciiLower], Bool, List(U8) -> List(U8)
	append = |data, start, end, span, case, utf8, out| {
		{ s, e } = ByteScan.clamp(start, end, span)
		from = if (utf8) char_start(data, start, s) else s
		to = if (utf8 and e < end) char_start(data, start, e) else e
		match case {
			AsIs => out.append_sublist(data, { start: from, len: to - from })
			AsciiUpper => {
				var $o = out
				var $i = from
				while $i < to {
					b = data.get($i) ?? 0
					$o = $o.append(if (b >= 97 and b <= 122) b - 32 else b)
					$i = $i + 1
				}
				$o
			}
			AsciiLower => {
				var $o = out
				var $i = from
				while $i < to {
					b = data.get($i) ?? 0
					$o = $o.append(if (b >= 65 and b <= 90) b + 32 else b)
					$i = $i + 1
				}
				$o
			}
		}
	}
}

## `at`, or the first byte of the character it is in (not before `start`).
char_start : List(U8), U64, U64 -> U64
char_start = |data, start, at| {
	var $i = at
	while $i > start and (data.get($i) ?? 0).bitwise_and(0xC0) == 0x80 {
		$i = $i - 1
	}
	$i
}

# Every ASCII white space byte is trimmed at both ends, none inside.
expect {
	row = " \t\n\u(B)\u(C)\rab c \r\n".to_utf8()
	ByteScan.trim(row, 0, row.len()) == { start: 6, len: 4 }
}
