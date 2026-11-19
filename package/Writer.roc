import Host

## Typed column writers. A writer appends one row at a time to plain Roc
## lists, which grow in place while the writer is the only reference, and
## `*_finish` hands the lists to a host as a `Host.Array` with zero copy:
## every value is written once, into the buffer the host receives.
##
## NULL rows go to a sparse list of row numbers, so a column with no NULL
## never builds a bitmap; `*_finish` takes more rows to clear (`cleared`, for
## example rows that failed) and builds the bitmap once.
##
## Rules every function keeps (each one is a measured quadratic trap):
## - take the writer apart before an append (`{ values, nulls } = w`): a list
##   read out of a record that stays alive is shared, and the append copies it;
## - read a length into a name before an append in the same record literal;
## - append bytes with `append_sublist`, never `concat`: `concat` onto an
##   empty list returns its second argument and drops the reserved capacity.
Writer := [].{

	## Fixed-width values: integers, floats, Decimal128 unscaled values, and
	## every logical type stored as one of them.
	Prim(a) : { values : List(a), nulls : List(U64) }

	## Bit-packed Boolean values.
	Bools : { bits : List(U8), len : U64, nulls : List(U64) }

	## Utf8 or Binary: offsets and one data buffer.
	Var : { offs : List(I32), data : List(U8), nulls : List(U64) }

	## LargeUtf8 or LargeBinary: 64-bit offsets and one data buffer.
	LargeVar : { offs : List(I64), data : List(U8), nulls : List(U64) }

	## FixedSizeBinary.
	Fixed : { width : U64, data : List(U8), nulls : List(U64) }

	## BinaryView or Utf8View: four u32 words per row; values over 12 bytes go
	## to one data buffer.
	Views : { words : List(U32), data : List(U8), nulls : List(U64) }

	## List or Map: offsets into a child writer.
	Lists(w) : { offs : List(I32), child : w, nulls : List(U64) }

	## LargeList: 64-bit offsets into a child writer.
	LargeLists(w) : { offs : List(I64), child : w, nulls : List(U64) }

	## FixedSizeList: `size` child values per row, a NULL row included.
	FixedLists(w) : { size : U64, len : U64, child : w, nulls : List(U64) }

	## The rows of a Struct; each field has its own writer.
	Row : { len : U64, nulls : List(U64) }

	## One open row of a text or binary writer, written in parts: each
	## `part_*` appends to the data buffer, and the `*_end` of the writer that
	## began the row closes it. `w` is the rest of that writer. An open row is
	## not a writer and a writer is not an open row, so a push, a NULL or a
	## finish inside a row, a part outside one, and a second end are type
	## errors.
	Text(w) : { open : w, data : List(U8), start : U64 }

	## The rest of a `Var` while a row is open.
	VarOpen : { offs : List(I32), nulls : List(U64) }

	## The rest of a `LargeVar` while a row is open.
	LargeVarOpen : { offs : List(I64), nulls : List(U64) }

	## The rest of a `Views` while a row is open.
	ViewsOpen : { words : List(U32), nulls : List(U64) }

	## Room for `rows` values.
	prim : U64 -> Writer.Prim(a)
	prim = |rows| { values: List.with_capacity(rows), nulls: [] }

	## One value.
	prim_push : Writer.Prim(a), a -> Writer.Prim(a)
	prim_push = |w, x| {
		{ values, nulls } = w
		{ values: values.append(x), nulls }
	}

	## A NULL row; `zero` fills its slot.
	prim_null : Writer.Prim(a), a -> Writer.Prim(a)
	prim_null = |w, zero| {
		{ values, nulls } = w
		null_row = values.len()
		{ values: values.append(zero), nulls: nulls.append(null_row) }
	}

	## `wrap` names the typed host buffer, for example `|xs| I64s(xs)`.
	prim_finish : Writer.Prim(a), List(U64), (List(a) -> Host.Buffer) -> Host.Array
	prim_finish = |w, cleared, wrap| {
		{ values, nulls } = w
		leaf(values.len(), nulls, cleared, [wrap(values)])
	}

	## Room for `rows` values.
	bools : U64 -> Writer.Bools
	bools = |rows| { bits: List.with_capacity((rows + 7) // 8), len: 0, nulls: [] }

	## One value, as one bit.
	bools_push : Writer.Bools, Bool -> Writer.Bools
	bools_push = |w, x| {
		{ bits, len, nulls } = w
		grown = if (len.bitwise_and(7) == 0) bits.append(0) else bits
		next =
			if x {
				match grown.update(len.shr_zf_wrap(3), |b| b.bitwise_or((1.U8).shl_wrap(len.bitwise_and(7).to_u8_wrap()))) {
					Ok(set) => set
					Err(OutOfBounds) => grown
				}
			} else {
				grown
			}
		{ bits: next, len: len + 1, nulls }
	}

	## A NULL row; its bit is 0.
	bools_null : Writer.Bools -> Writer.Bools
	bools_null = |w| {
		{ bits, len, nulls } = w
		pushed = Writer.bools_push({ bits, len, nulls: [] }, Bool.False)
		{ ..pushed, nulls: nulls.append(len) }
	}

	## Export: an LSB bitmap of values. Zero copy.
	bools_finish : Writer.Bools, List(U64) -> Host.Array
	bools_finish = |w, cleared| {
		{ bits, len, nulls } = w
		leaf(len, nulls, cleared, [U8s(bits)])
	}

	## Room for `rows` values and `bytes` bytes of data (at least 8 per row).
	## A caller that knows the input's byte length passes it, so a result of
	## about the input's size never grows the data buffer.
	varlen : U64, U64 -> Writer.Var
	varlen = |rows, bytes| { offs: List.with_capacity(rows + 1).append(0), data: List.with_capacity(bytes.max(rows * 8)), nulls: [] }

	## A string's UTF-8 bytes. Strings of 23 bytes or less are copied byte by
	## byte (`to_utf8` of a small string allocates); longer ones in one copy.
	str_push : Writer.Var, Str -> Writer.Var
	str_push = |w, s| {
		{ offs, data, nulls } = w
		grown = put_str(data, s)
		end = grown.len().to_i32_wrap()
		{ offs: offs.append(end), data: grown, nulls }
	}

	## One Binary value; its bytes are copied once into the data buffer. Offsets are
	## `I32`, so the data must stay under 2 GiB.
	bytes_push : Writer.Var, List(U8) -> Writer.Var
	bytes_push = |w, xs| {
		{ offs, data, nulls } = w
		grown = put_bytes(data, xs)
		end = grown.len().to_i32_wrap()
		{ offs: offs.append(end), data: grown, nulls }
	}

	## A NULL row; it takes no data bytes.
	var_null : Writer.Var -> Writer.Var
	var_null = |w| {
		{ offs, data, nulls } = w
		null_row = offs.len() - 1
		end = data.len().to_i32_wrap()
		{ offs: offs.append(end), data, nulls: nulls.append(null_row) }
	}

	## Export: `I32` offsets and the data buffer. Zero copy.
	var_finish : Writer.Var, List(U64) -> Host.Array
	var_finish = |w, cleared| {
		{ offs, data, nulls } = w
		leaf(offs.len() - 1, nulls, cleared, [I32s(offs), U8s(data)])
	}

	## Open a row to write in parts. Close it with `str_end`.
	str_begin : Writer.Var -> Writer.Text(Writer.VarOpen)
	str_begin = |w| {
		{ offs, data, nulls } = w
		start = data.len()
		{ open: { offs, nulls }, data, start }
	}

	## Close a row that `str_begin` opened: its bytes are the parts.
	str_end : Writer.Text(Writer.VarOpen) -> Writer.Var
	str_end = |t| {
		{ open, data, .. } = t
		{ offs, nulls } = open
		end = data.len().to_i32_wrap()
		{ offs: offs.append(end), data, nulls }
	}

	## Append a string's UTF-8 bytes to an open row.
	part_str : Writer.Text(w), Str -> Writer.Text(w)
	part_str = |t, s| {
		{ open, data, start } = t
		{ open, data: put_str(data, s), start }
	}

	## Append bytes to an open row, as they are. In a Utf8 column, keep the
	## row valid UTF-8 (as with `bytes_push`).
	part_bytes : Writer.Text(w), List(U8) -> Writer.Text(w)
	part_bytes = |t, xs| {
		{ open, data, start } = t
		{ open, data: put_bytes(data, xs), start }
	}

	## Append `span` of row `at` of a column (`Utf8Column` or `BinaryColumn`)
	## to an open row: one copy, no `Str` and no slice. The span is relative
	## to the row's start and cut to the row; see the column's `append_span`.
	part_range : Writer.Text(w), c, U64, { start : U64, len : U64 } -> Writer.Text(w)
		where [c.append_span : c, U64, { start : U64, len : U64 }, [AsIs, AsciiUpper, AsciiLower], List(U8) -> List(U8)]
	part_range = |t, col, at, span| {
		{ open, data, start } = t
		{ open, data: col.append_span(at, span, AsIs, data), start }
	}

	## `part_range` with ASCII letters in upper case; other bytes as they are.
	part_upper : Writer.Text(w), c, U64, { start : U64, len : U64 } -> Writer.Text(w)
		where [c.append_span : c, U64, { start : U64, len : U64 }, [AsIs, AsciiUpper, AsciiLower], List(U8) -> List(U8)]
	part_upper = |t, col, at, span| {
		{ open, data, start } = t
		{ open, data: col.append_span(at, span, AsciiUpper, data), start }
	}

	## `part_range` with ASCII letters in lower case; other bytes as they are.
	part_lower : Writer.Text(w), c, U64, { start : U64, len : U64 } -> Writer.Text(w)
		where [c.append_span : c, U64, { start : U64, len : U64 }, [AsIs, AsciiUpper, AsciiLower], List(U8) -> List(U8)]
	part_lower = |t, col, at, span| {
		{ open, data, start } = t
		{ open, data: col.append_span(at, span, AsciiLower, data), start }
	}

	## The bytes written to an open row so far.
	part_len : Writer.Text(w) -> U64
	part_len = |t| t.data.len() - t.start

	## Room for `rows` values and `bytes` bytes of data (at least 8 per row).
	large_varlen : U64, U64 -> Writer.LargeVar
	large_varlen = |rows, bytes| { offs: List.with_capacity(rows + 1).append(0), data: List.with_capacity(bytes.max(rows * 8)), nulls: [] }

	## A string's UTF-8 bytes, copied as `str_push` copies them.
	large_str_push : Writer.LargeVar, Str -> Writer.LargeVar
	large_str_push = |w, s| {
		{ offs, data, nulls } = w
		grown = put_str(data, s)
		end = grown.len().to_i64_wrap()
		{ offs: offs.append(end), data: grown, nulls }
	}

	## One LargeBinary value; its bytes are copied once into the data buffer.
	large_bytes_push : Writer.LargeVar, List(U8) -> Writer.LargeVar
	large_bytes_push = |w, xs| {
		{ offs, data, nulls } = w
		grown = put_bytes(data, xs)
		end = grown.len().to_i64_wrap()
		{ offs: offs.append(end), data: grown, nulls }
	}

	## A NULL row; it takes no data bytes.
	large_var_null : Writer.LargeVar -> Writer.LargeVar
	large_var_null = |w| {
		{ offs, data, nulls } = w
		null_row = offs.len() - 1
		end = data.len().to_i64_wrap()
		{ offs: offs.append(end), data, nulls: nulls.append(null_row) }
	}

	## Export: `I64` offsets and the data buffer. Zero copy.
	large_var_finish : Writer.LargeVar, List(U64) -> Host.Array
	large_var_finish = |w, cleared| {
		{ offs, data, nulls } = w
		leaf(offs.len() - 1, nulls, cleared, [I64s(offs), U8s(data)])
	}

	## Open a row to write in parts. Close it with `large_str_end`.
	large_str_begin : Writer.LargeVar -> Writer.Text(Writer.LargeVarOpen)
	large_str_begin = |w| {
		{ offs, data, nulls } = w
		start = data.len()
		{ open: { offs, nulls }, data, start }
	}

	## Close a row that `large_str_begin` opened.
	large_str_end : Writer.Text(Writer.LargeVarOpen) -> Writer.LargeVar
	large_str_end = |t| {
		{ open, data, .. } = t
		{ offs, nulls } = open
		end = data.len().to_i64_wrap()
		{ offs: offs.append(end), data, nulls }
	}

	## Values of `width` bytes, room for `rows` of them.
	fixed : U64, U64 -> Writer.Fixed
	fixed = |width, rows| { width, data: List.with_capacity(width * rows), nulls: [] }

	## Exactly `width` bytes: a longer value is cut, a shorter one padded with
	## zeros (check the length first where that is an error).
	fixed_push : Writer.Fixed, List(U8) -> Writer.Fixed
	fixed_push = |w, xs| {
		{ width, data, nulls } = w
		cut = put_bytes(data, xs.take_first(width))
		{ width, data: pad(cut, width - xs.len().min(width)), nulls }
	}

	## A NULL row; its `width` bytes are zero.
	fixed_null : Writer.Fixed -> Writer.Fixed
	fixed_null = |w| {
		{ width, data, nulls } = w
		null_row = data.len() // width.max(1)
		{ width, data: pad(data, width), nulls: nulls.append(null_row) }
	}

	## Export: the data buffer. Zero copy.
	fixed_finish : Writer.Fixed, List(U64) -> Host.Array
	fixed_finish = |w, cleared| {
		{ width, data, nulls } = w
		leaf(data.len() // width.max(1), nulls, cleared, [U8s(data)])
	}

	## Room for `rows` views and `bytes` bytes of long values.
	views : U64, U64 -> Writer.Views
	views = |rows, bytes| { words: List.with_capacity(rows * 4), data: List.with_capacity(bytes), nulls: [] }

	## One BinaryView value: 12 bytes or less inline in the view, a longer one copied
	## to the data buffer.
	views_push : Writer.Views, List(U8) -> Writer.Views
	views_push = |w, xs| {
		{ words, data, nulls } = w
		size = xs.len()
		if size <= 12 {
			next = words.append(size.to_u32_wrap()).append(le_u32(xs, 0)).append(le_u32(xs, 4)).append(le_u32(xs, 8))
			{ words: next, data, nulls }
		} else {
			at = data.len().to_u32_wrap()
			next = words.append(size.to_u32_wrap()).append(le_u32(xs, 0)).append(0).append(at)
			{ words: next, data: put_bytes(data, xs), nulls }
		}
	}

	## A string for Utf8View. A string of 23 bytes or less is read byte by
	## byte (`to_utf8` of a small string allocates); a longer one goes to
	## `views_push` as a slice.
	views_str_push : Writer.Views, Str -> Writer.Views
	views_str_push = |w, s| {
		size = s.count_utf8_bytes()
		if size > 23 {
			return Writer.views_push(w, s.to_utf8())
		}
		{ words, data, nulls } = w
		at = data.len().to_u32_wrap()
		var $w1 = 0.U32
		var $w2 = 0.U32
		var $w3 = 0.U32
		var $d = data
		var $i = 0.U64
		for b in s.iter_utf8() {
			x = b.to_u32().shl_wrap($i.bitwise_and(3).to_u8_wrap() * 8)
			if $i < 4 {
				$w1 = $w1.bitwise_or(x)
			} else if $i < 8 {
				$w2 = $w2.bitwise_or(x)
			} else {
				$w3 = $w3.bitwise_or(x)
			}
			if size > 12 {
				$d = $d.append(b)
			}
			$i = $i + 1
		}
		if size <= 12 {
			{ words: words.append(size.to_u32_wrap()).append($w1).append($w2).append($w3), data, nulls }
		} else {
			{ words: words.append(size.to_u32_wrap()).append($w1).append(0).append(at), data: $d, nulls }
		}
	}

	## Open a row to write in parts. Close it with `views_str_end`. The parts
	## go to the data buffer; a row of 12 bytes or less moves into its view
	## at the end.
	views_str_begin : Writer.Views -> Writer.Text(Writer.ViewsOpen)
	views_str_begin = |w| {
		{ words, data, nulls } = w
		start = data.len()
		{ open: { words, nulls }, data, start }
	}

	## Close a row that `views_str_begin` opened.
	views_str_end : Writer.Text(Writer.ViewsOpen) -> Writer.Views
	views_str_end = |t| {
		{ open, data, start } = t
		{ words, nulls } = open
		size = data.len() - start
		if size <= 12 {
			next = words.append(size.to_u32_wrap()).append(le_u32(data, start)).append(le_u32(data, start + 4)).append(le_u32(data, start + 8))
			{ words: next, data: data.take_first(start), nulls }
		} else {
			next = words.append(size.to_u32_wrap()).append(le_u32(data, start)).append(0).append(start.to_u32_wrap())
			{ words: next, data, nulls }
		}
	}

	## A NULL row; its view is four zero words.
	views_null : Writer.Views -> Writer.Views
	views_null = |w| {
		{ words, data, nulls } = w
		null_row = words.len() // 4
		{ words: words.append(0).append(0).append(0).append(0), data, nulls: nulls.append(null_row) }
	}

	## Export: the views, one data buffer, and its size (the `I64s` buffer of a
	## View array). Zero copy.
	views_finish : Writer.Views, List(U64) -> Host.Array
	views_finish = |w, cleared| {
		{ words, data, nulls } = w
		size = data.len().to_i64_wrap()
		leaf(words.len() // 4, nulls, cleared, [U32s(words), U8s(data), I64s([size])])
	}

	## A List or Map writer over `child`, the writer of the values.
	lists : w -> Writer.Lists(w)
	lists = |child| { offs: [0], child, nulls: [] }

	## One list row: `item` appends each value to the child writer.
	list_push : Writer.Lists(w), List(a), (w, a -> w) -> Writer.Lists(w)
	list_push = |w, xs, item| {
		{ offs, child, nulls } = w
		var $c = child
		for x in xs {
			$c = item($c, x)
		}
		end = (offs.last() ?? 0) + xs.len().to_i32_wrap()
		{ offs: offs.append(end), child: $c, nulls }
	}

	## A NULL row; it takes no child values.
	list_null : Writer.Lists(w) -> Writer.Lists(w)
	list_null = |w| {
		{ offs, child, nulls } = w
		null_row = offs.len() - 1
		end = offs.last() ?? 0
		{ offs: offs.append(end), child, nulls: nulls.append(null_row) }
	}

	## Export: `I32` offsets, and the child that `child_finish` exports. Zero copy.
	list_finish : Writer.Lists(w), List(U64), (w -> Host.Array) -> Host.Array
	list_finish = |w, cleared, child_finish| {
		{ offs, child, nulls } = w
		base = leaf(offs.len() - 1, nulls, cleared, [I32s(offs)])
		{ ..base, children: [child_finish(child)] }
	}

	## A LargeList writer over `child`, the writer of the values.
	large_lists : w -> Writer.LargeLists(w)
	large_lists = |child| { offs: [0], child, nulls: [] }

	## One list row: `item` appends each value to the child writer.
	large_list_push : Writer.LargeLists(w), List(a), (w, a -> w) -> Writer.LargeLists(w)
	large_list_push = |w, xs, item| {
		{ offs, child, nulls } = w
		var $c = child
		for x in xs {
			$c = item($c, x)
		}
		end = (offs.last() ?? 0) + xs.len().to_i64_wrap()
		{ offs: offs.append(end), child: $c, nulls }
	}

	## A NULL row; it takes no child values.
	large_list_null : Writer.LargeLists(w) -> Writer.LargeLists(w)
	large_list_null = |w| {
		{ offs, child, nulls } = w
		null_row = offs.len() - 1
		end = offs.last() ?? 0
		{ offs: offs.append(end), child, nulls: nulls.append(null_row) }
	}

	## Export: `I64` offsets, and the child that `child_finish` exports. Zero copy.
	large_list_finish : Writer.LargeLists(w), List(U64), (w -> Host.Array) -> Host.Array
	large_list_finish = |w, cleared, child_finish| {
		{ offs, child, nulls } = w
		base = leaf(offs.len() - 1, nulls, cleared, [I64s(offs)])
		{ ..base, children: [child_finish(child)] }
	}

	## A FixedSizeList writer of `size` values per row over `child`.
	fixed_lists : U64, w -> Writer.FixedLists(w)
	fixed_lists = |size, child| { size, len: 0, child, nulls: [] }

	## One list row of exactly `size` values: a longer list is cut, a shorter
	## one padded with `item_null` (check the length first where that is an
	## error).
	fixed_list_push : Writer.FixedLists(w), List(a), (w, a -> w), (w -> w) -> Writer.FixedLists(w)
	fixed_list_push = |w, xs, item, item_null| {
		{ size, len, child, nulls } = w
		var $c = child
		for x in xs.take_first(size) {
			$c = item($c, x)
		}
		for _ in xs.len().until(size) {
			$c = item_null($c)
		}
		{ size, len: len + 1, child: $c, nulls }
	}

	## A NULL row; `item_null` fills its `size` child slots.
	fixed_list_null : Writer.FixedLists(w), (w -> w) -> Writer.FixedLists(w)
	fixed_list_null = |w, item_null| {
		{ size, len, child, nulls } = w
		var $c = child
		for _ in (0.U64).until(size) {
			$c = item_null($c)
		}
		{ size, len: len + 1, child: $c, nulls: nulls.append(len) }
	}

	## Export: no buffer but the bitmap, and the child that `child_finish` exports.
	## Zero copy.
	fixed_list_finish : Writer.FixedLists(w), List(U64), (w -> Host.Array) -> Host.Array
	fixed_list_finish = |w, cleared, child_finish| {
		{ len, child, nulls, .. } = w
		base = leaf(len, nulls, cleared, [])
		{ ..base, children: [child_finish(child)] }
	}

	## A Struct writer. `rows` is a hint only; each field has its own writer.
	row : U64 -> Writer.Row
	row = |_rows| { len: 0, nulls: [] }

	## One valid row. Push one value to each field writer too.
	row_push : Writer.Row -> Writer.Row
	row_push = |w| {
		{ len, nulls } = w
		{ len: len + 1, nulls }
	}

	## A NULL row. Push a value or a NULL to each field writer too.
	row_null : Writer.Row -> Writer.Row
	row_null = |w| {
		{ len, nulls } = w
		{ len: len + 1, nulls: nulls.append(len) }
	}

	## Export: the bitmap and `kids`, the exported field writers in field order.
	## Zero copy.
	row_finish : Writer.Row, List(U64), List(Host.Array) -> Host.Array
	row_finish = |w, cleared, kids| {
		base = leaf(w.len, w.nulls, cleared, [])
		{ ..base, children: kids }
	}
}

## Append `xs` to `data` in one copy, keeping `data`'s reserved capacity
## (`append_sublist` grows `data` in place; `concat` onto an empty list would
## return `xs` and drop it).
put_bytes : List(U8), List(U8) -> List(U8)
put_bytes = |data, xs| data.append_sublist(xs, { start: 0, len: xs.len() })

## Append a string's UTF-8 bytes. Strings of 23 bytes or less are copied
## byte by byte (`to_utf8` of a small string allocates); longer ones in one copy.
put_str : List(U8), Str -> List(U8)
put_str = |data, s|
	if s.count_utf8_bytes() <= 23 {
		var $d = data
		for b in s.iter_utf8() {
			$d = $d.append(b)
		}
		$d
	} else {
		put_bytes(data, s.to_utf8())
	}

pad : List(U8), U64 -> List(U8)
pad = |data, n| {
	var $d = data
	for _ in (0.U64).until(n) {
		$d = $d.append(0)
	}
	$d
}

## The host form of one column: NULL where `nulls` or `cleared` name a row.
leaf : U64, List(U64), List(U64), List(Host.Buffer) -> Host.Array
leaf = |rows, nulls, cleared, buffers| {
	count = nulls.len() + cleared.len()
	bitmap = if (count == 0) Absent else U8s(clear_bits(clear_bits(List.repeat(0xFF, (rows + 7) // 8), nulls), cleared))
	{ length: rows.to_i64_wrap(), null_count: count.to_i64_wrap(), offset: 0, buffers: [bitmap].concat(buffers), children: [], dictionary: [] }
}

clear_bits : List(U8), List(U64) -> List(U8)
clear_bits = |bits, rows| {
	var $b = bits
	for r in rows {
		mask = (1.U8).shl_wrap(r.bitwise_and(7).to_u8_wrap()).bitwise_not()
		$b = match $b.update(r.shr_zf_wrap(3), |x| x.bitwise_and(mask)) {
			Ok(next) => next
			Err(OutOfBounds) => $b
		}
	}
	$b
}

## Little-endian u32 at `at`; bytes past the end read as 0.
le_u32 : List(U8), U64 -> U32
le_u32 = |bytes, at| {
	b = |k| (bytes.get(at + k) ?? 0).to_u32()
	b(0).bitwise_or(b(1).shl_wrap(8)).bitwise_or(b(2).shl_wrap(16)).bitwise_or(b(3).shl_wrap(24))
}

expect {
	w = Writer.prim_null(Writer.prim_push(Writer.prim_push(Writer.prim(4), 7.I64), 8), 0)
	out = Writer.prim_finish(w, [0], |xs| I64s(xs))
	out.length == 3 and out.null_count == 2 and out.buffers == [U8s([0b1111_1010]), I64s([7, 8, 0])]
}

# A long first value keeps the reserved data buffer (no concat onto empty).
expect {
	w = Writer.str_push(Writer.var_null(Writer.str_push(Writer.varlen(2, 64), "a string longer than twenty-three bytes")), "hi")
	out = Writer.var_finish(w, [])
	out.length == 3 and out.null_count == 1 and out.buffers.get(1) == Ok(I32s([0, 39, 39, 41]))
}

expect {
	w = Writer.list_push(Writer.list_null(Writer.list_push(Writer.lists(Writer.varlen(2, 0)), ["a", "bc"], Writer.str_push)), [], Writer.str_push)
	out = Writer.list_finish(w, [], |c| Writer.var_finish(c, []))
	out.buffers.get(1) == Ok(I32s([0, 2, 2, 2])) and out.children.len() == 1
}

expect {
	w = Writer.views_push(Writer.views_push(Writer.views(2, 0), [1, 2, 3]), List.repeat(9, 13))
	out = Writer.views_finish(w, [])
	out.buffers == [Absent, U32s([3, 0x030201, 0, 0, 13, 0x09090909, 0, 0]), U8s(List.repeat(9, 13)), I64s([13])]
}

expect {
	w = Writer.fixed_null(Writer.fixed_push(Writer.fixed(3, 2), [1, 2]))
	out = Writer.fixed_finish(w, [])
	out.buffers == [U8s([0b1111_1101]), U8s([1, 2, 0, 0, 0, 0])]
}

expect {
	w = Writer.bools_push(Writer.bools_null(Writer.bools_push(Writer.bools(3), Bool.True)), Bool.True)
	Writer.bools_finish(w, []).buffers == [U8s([0b1111_1101]), U8s([0b101])]
}

expect {
	w = Writer.row_push(Writer.row_null(Writer.row(2)))
	out = Writer.row_finish(w, [], [])
	out.length == 2 and out.null_count == 1
}

import Array
import BinaryColumn
import DataType
import ListColumn
import PrimitiveColumn

## Export, import as `dt`, and read every row back through `BinaryColumn`.
strs_back : Host.Array, DataType -> List(Try(Str, [Null, OutOfBounds, BadUtf8]))
strs_back = |host, dt| {
	col = BinaryColumn.from_array(Array.from_host(host, dt) ?? crash "import") ?? crash "view"
	(0.U64).until(col.len()).map(|i| col.get_str(i)).collect()
}

## Export, import as a list type of Int64 items, and read every row back
## through `ListColumn` and `PrimitiveColumn`.
lists_back : Host.Array, DataType -> List(Try(List(Try(I64, [Null])), [Null, OutOfBounds]))
lists_back = |host, dt| {
	col = ListColumn.from_array(Array.from_host(host, dt) ?? crash "import") ?? crash "view"
	(0.U64).until(col.len())
		.map(|i| col.get(i).map_ok(|kid| (PrimitiveColumn.i64(kid) ?? crash "items").iter().collect()))
		.collect()
}

long : Str
long = "a string longer than twenty-three bytes"

# LargeUtf8 and LargeBinary: 64-bit offsets, NULL and cleared rows, read back.
expect {
	w = Writer.large_str_push(Writer.large_var_null(Writer.large_str_push(Writer.large_str_push(Writer.large_varlen(4, 0), long), "hi")), "")
	out = Writer.large_var_finish(w, [1])
	b = Writer.large_bytes_push(Writer.large_bytes_push(Writer.large_varlen(2, 0), [1, 2, 3]), [])
	bytes = BinaryColumn.from_array(Array.from_host(Writer.large_var_finish(b, []), LargeBinary) ?? crash "import") ?? crash "view"
	out.buffers.get(1) == Ok(I64s([0, 39, 41, 41, 41]))
		and strs_back(out, LargeUtf8) == [Ok(long), Err(Null), Err(Null), Ok("")]
		and [bytes.get_bytes(0), bytes.get_bytes(1)] == [Ok([1, 2, 3]), Ok([])]
}

# Utf8View text at every size class: inline up to 12 bytes, small strings
# over 12, and long strings. The words equal those of `views_push`.
expect {
	texts = ["", "abcde", "twelve bytes", "thirteen byte", "twenty-three bytes long", "twenty-four bytes long!!", long]
	w = texts.fold(Writer.views(8, 0), Writer.views_str_push)
	out = Writer.views_finish(Writer.views_null(w), [])
	by_bytes = Writer.views_finish(Writer.views_null(texts.fold(Writer.views(8, 0), |acc, t| Writer.views_push(acc, t.to_utf8()))), [])
	out.buffers == by_bytes.buffers and strs_back(out, Utf8View) == texts.map(|t| Ok(t)).append(Err(Null))
}

# LargeList: rows with values, a NULL row, an empty row and a cleared row.
expect {
	push = |w, x| Writer.prim_push(w, x)
	w0 = Writer.large_list_push(Writer.large_lists(Writer.prim(4)), [1.I64, 2], push)
	w1 = Writer.large_list_push(Writer.large_list_push(Writer.large_list_null(w0), [], push), [3], push)
	w2 = Writer.large_list_push(w1, [4], push)
	out = Writer.large_list_finish(w2, [3], |c| Writer.prim_finish(c, [], |xs| I64s(xs)))
	out.buffers.get(1) == Ok(I64s([0, 2, 2, 2, 3, 4]))
		and lists_back(out, LargeList(DataType.field("item", Int64, Bool.True))) == [Ok([Ok(1), Ok(2)]), Err(Null), Ok([]), Err(Null), Ok([Ok(4)])]
}

# FixedSizeList(2): a short row is padded with NULL items, a long one cut,
# and a NULL row fills its two slots.
expect {
	push = |w, x| Writer.prim_push(w, x)
	item_null = |w| Writer.prim_null(w, 0)
	w0 = Writer.fixed_list_push(Writer.fixed_lists(2, Writer.prim(8)), [1.I64, 2], push, item_null)
	w1 = Writer.fixed_list_push(Writer.fixed_list_null(w0, item_null), [3], push, item_null)
	w2 = Writer.fixed_list_push(w1, [4, 5, 6], push, item_null)
	out = Writer.fixed_list_finish(w2, [], |c| Writer.prim_finish(c, [], |xs| I64s(xs)))
	back = lists_back(out, FixedSizeList(DataType.field("item", Int64, Bool.True), 2))
	out.length == 4
		and out.null_count == 1
		and out.children.map(|c| c.length) == [8]
		and back == [Ok([Ok(1), Ok(2)]), Err(Null), Ok([Ok(3), Err(Null)]), Ok([Ok(4), Ok(5)])]
}

# Binary bytes: an empty value, a NULL row in the middle, a cleared row.
expect {
	w = Writer.bytes_push(Writer.bytes_push(Writer.var_null(Writer.bytes_push(Writer.bytes_push(Writer.varlen(5, 0), [1, 2, 3]), [])), [0xFF]), [4, 5])
	out = Writer.var_finish(w, [4])
	col = BinaryColumn.from_array(Array.from_host(out, Binary) ?? crash "import") ?? crash "view"
	out.buffers.get(1) == Ok(I32s([0, 3, 3, 3, 4, 6]))
		and (0.U64).until(5).map(|i| col.get_bytes(i)).collect() == [Ok([1, 2, 3]), Ok([]), Err(Null), Ok([0xFF]), Err(Null)]
}

# A NULL view row in the middle: four zero words, and the next long value
# still points at its own bytes.
expect {
	tail = List.repeat(7, 20)
	w = Writer.views_push(Writer.views_null(Writer.views_push(Writer.views(3, 0), [1, 2])), tail)
	out = Writer.views_finish(w, [])
	col = BinaryColumn.from_array(Array.from_host(out, BinaryView) ?? crash "import") ?? crash "view"
	words_ok = match out.buffers.get(1) {
		Ok(U32s(ws)) => ws.sublist({ start: 4, len: 4 }) == [0, 0, 0, 0]
		_ => Bool.False
	}
	out.null_count == 1
		and words_ok
		and out.buffers.get(0) == Ok(U8s([0b1111_1101]))
		and [col.get_bytes(0), col.get_bytes(1), col.get_bytes(2)] == [Ok([1, 2]), Err(Null), Ok(tail)]
}

import Utf8Column

# Rows in several scripts, an empty row and spaces at the ends.
part_rows : List(Str)
part_rows = ["  hello world  ", "", "été à Paris", "日本語 テキスト", " 🎉party🚀 ", "x", "a string longer than twenty-three bytes"]

part_src : Utf8Column
part_src = Utf8Column.from_array(Array.from_strs(part_rows)) ?? crash "view"

# Row `i` as parts: a Str, bytes, the trimmed first word in upper case, and
# the rest of the trimmed row in lower case.
parts_of : Writer.Text(w), U64 -> Writer.Text(w)
parts_of = |t, i| {
	trim = part_src.trim_ascii(i)
	word = part_src.first_word(i, trim)
	rest = { start: word.start + word.len, len: trim.len - word.len }
	t
		|> Writer.part_str("<")
		|> Writer.part_bytes([0x7C])
		|> Writer.part_upper(part_src, i, word)
		|> Writer.part_lower(part_src, i, rest)
		|> Writer.part_str("é>")
}

# What `parts_of` writes, from Str builtins.
parts_want : List(Str)
parts_want = ["<|HELLO worldé>", "<|é>", "<|éTé à parisé>", "<|日本語 テキストé>", "<|🎉PARTY🚀é>", "<|Xé>", "<|A string longer than twenty-three bytesé>"]

# Utf8: every row in parts, a NULL row between, and `part_len` per row.
expect {
	var $w = Writer.varlen(8, 0)
	var $lens = []
	for i in (0.U64).until(part_rows.len()) {
		t = parts_of(Writer.str_begin($w), i)
		$lens = $lens.append(Writer.part_len(t))
		$w = Writer.var_null(Writer.str_end(t))
	}
	out = Writer.var_finish($w, [])
	want = parts_want.join_map(|s| [Ok(s), Err(Null)])
	strs_back(out, Utf8) == want and $lens == parts_want.map(|s| s.count_utf8_bytes())
}

# LargeUtf8: the same rows; an empty row in parts.
expect {
	var $w = Writer.large_varlen(8, 0)
	for i in (0.U64).until(part_rows.len()) {
		$w = Writer.large_str_end(parts_of(Writer.large_str_begin($w), i))
	}
	$w = Writer.large_str_end(Writer.large_str_begin($w))
	strs_back(Writer.large_var_finish($w, []), LargeUtf8) == parts_want.map(|s| Ok(s)).append(Ok(""))
}

# Utf8View: a row in parts gives the views and data of `views_str_push` at
# every size class (inline, 12 bytes, small Str, long), between long rows.
expect {
	texts = ["", "abcde", "twelve bytes", "thirteen byte", "twenty-three bytes long", long, "hi", long]
	whole = texts.fold(Writer.views(8, 0), Writer.views_str_push)
	in_parts = texts.fold(
		Writer.views(8, 0),
		|w, s| {
			n = s.count_utf8_bytes()
			half = s.to_utf8().take_first(n // 2)
			Writer.views_str_end(Writer.part_str(Writer.part_bytes(Writer.views_str_begin(w), half), Str.from_utf8_lossy(s.to_utf8().drop_first(n // 2))))
		},
	)
	Writer.views_finish(in_parts, []).buffers == Writer.views_finish(whole, []).buffers
}

expect {
	var $w = Writer.views(8, 0)
	for i in (0.U64).until(part_rows.len()) {
		$w = Writer.views_null(Writer.views_str_end(parts_of(Writer.views_str_begin($w), i)))
	}
	strs_back(Writer.views_finish($w, []), Utf8View) == parts_want.join_map(|s| [Ok(s), Err(Null)])
}

# A source column cut by a host offset, read through BinaryColumn in the
# text layouts: trimmed spans in parts give the trimmed text.
expect {
	trimmed = |col| {
		var $w = Writer.varlen(8, 0)
		for i in (0.U64).until(col.len()) {
			$w = Writer.str_end(Writer.part_range(Writer.str_begin($w), col, i, col.trim_ascii(i)))
		}
		strs_back(Writer.var_finish($w, []), Utf8)
	}
	large = Writer.large_var_finish(part_rows.fold(Writer.large_varlen(8, 0), Writer.large_str_push), [])
	views = Writer.views_finish(part_rows.fold(Writer.views(8, 0), Writer.views_str_push), [])
	view_of = |host, dt| BinaryColumn.from_array((Array.from_host(host, dt) ?? crash "import").slice(2, 5)) ?? crash "view"
	want = part_rows.sublist({ start: 2, len: 5 }).map(|s| Ok(s.trim()))
	trimmed(view_of(large, LargeUtf8)) == want and trimmed(view_of(views, Utf8View)) == want and trimmed(Utf8Column.from_array(Array.from_strs(part_rows).slice(2, 5)) ?? crash "view") == want
}

# A row cut into two spans at every byte gives the row back: an end inside
# a character moves back to its first byte in both spans.
expect {
	row = "aé日🎉 x"
	col = Utf8Column.from_array(Array.from_strs([row])) ?? crash "view"
	n = row.count_utf8_bytes()
	w = (0.U64).until(n + 1).fold(
		Writer.varlen(n + 1, 0),
		|acc, k| Writer.str_end(Writer.part_range(Writer.part_range(Writer.str_begin(acc), col, 0, { start: 0, len: k }), col, 0, { start: k, len: n })),
	)
	strs_back(Writer.var_finish(w, []), Utf8) == List.repeat(Ok(row), n + 1)
}

# A text column read through BinaryColumn moves a span end inside a
# character back to its first byte; a Binary column of the same bytes does
# not, as it has no characters.
expect {
	text = Writer.large_var_finish(Writer.large_str_push(Writer.large_varlen(1, 0), "aé日"), [])
	bytes = Writer.large_var_finish(Writer.large_bytes_push(Writer.large_varlen(1, 0), "aé日".to_utf8()), [])
	col = |host, dt| BinaryColumn.from_array(Array.from_host(host, dt) ?? crash "import") ?? crash "view"
	span = |c, start, len| c.append_span(0, { start, len }, AsIs, [])
	t = col(text, LargeUtf8)
	b = col(bytes, LargeBinary)
	span(t, 2, 1) == "é".to_utf8() and span(t, 2, 3) == "é".to_utf8() and span(t, 4, 9) == "日".to_utf8() and span(b, 2, 1) == [0xA9] and span(b, 4, 2) == [0x97, 0xA5]
}
