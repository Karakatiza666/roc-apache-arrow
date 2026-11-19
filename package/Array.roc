import DataType
import Schema
import Host
import Validity

## A validated, immutable Arrow array: a data type, a row count, a validity
## and typed buffers. Opaque, so every `Array` passed `from_host` checks and
## later reads need no bounds checks against bad input.
##
## Row 0 is always the first logical row: the Arrow `offset` is applied once
## at import by slicing, which is zero-copy for every buffer kind.
##
## `text` keeps the data buffer of a Utf8 or LargeUtf8 array when the host
## passed it as a `Str` (`Host.Buffer.Utf8`), so a view need not check it.
Array :: { dt : DataType, rows : U64, valid : Validity, buffers : Array.Body, text : Try(Str, [NoText]) }.{

	## The typed buffers of an array, by physical layout. Readable by anyone;
	## only this module builds an `Array` around one.
	Body := [
		NoBuffers,

		## Bit-packed booleans with a bit offset.
		BoolBits(List(U8), U64),
		I8s(List(I8)),
		I16s(List(I16)),
		I32s(List(I32)),
		I64s(List(I64)),
		U8s(List(U8)),
		U16s(List(U16)),
		U32s(List(U32)),
		U64s(List(U64)),
		F32s(List(F32)),
		F64s(List(F64)),
		I128s(List(I128)),

		## Offsets (rows + 1, absolute into data), data.
		Var32(List(I32), List(U8)),
		Var64(List(I64), List(U8)),

		## Four u32 words per row (length, prefix, buffer index, offset), data buffers.
		Views(List(U32), List(List(U8))),

		## Byte width, bytes.
		Fixed(U64, List(U8)),

		## Offsets (rows + 1, absolute into the child), child.
		List32(List(I32), Array),
		List64(List(I64), Array),

		## List size, child already sliced to this array's rows.
		FixedList(U64, Array),

		## Children already sliced to this array's rows.
		Children(List(Array)),
	]

	## Import a host array of the given type. Validates buffer kinds, sizes,
	## offsets and views once. An `Absent` (NULL) buffer is an empty one, and
	## an array of no rows may have an empty offsets buffer. Typed host buffers are wrapped with zero copy; `U8s`
	## buffers for typed data are decoded (one copy). The data buffer of a
	## binary or text type may be `Utf8(str)`: Roc takes the bytes of the `Str`
	## with zero copy and does not check them. For Utf8 and LargeUtf8 the array
	## keeps the `Str` (see `trusted_text`).
	from_host : Host.Array, DataType -> Try(Array, [InvalidArray(Str), Unsupported(Str)])
	from_host = |host, dt| {
		rows = to_u64(host.length, "length")?
		offset = to_u64(host.offset, "offset")?
		# Saturating, so a hostile length or offset fails a size check, not a crash.
		end = offset.plus_saturated(rows)
		has_validity = match dt {
			Null | Union(_, _, _) | RunEndEncoded(_, _) => Bool.False
			_ => Bool.True
		}
		valid0 : Validity
		valid0 =
			if has_validity {
				match host.buffers.first() {
					Ok(U8s(bits)) if host.null_count != 0 =>
						if bits.len() * 8 < end {
							return Err(InvalidArray("validity bitmap shorter than offset + length"))
						} else {
							Bits(bits, 0)
						}
					Ok(U8s(_)) | Ok(Absent) => AllValid
					Ok(_) => return Err(InvalidArray("validity bitmap must be a U8s buffer"))
					Err(_) => return Err(InvalidArray("missing validity buffer"))
				}
			} else {
				AllValid
			}
		valid = valid0.skip(offset)
		buf = |i| host.buffers.get(i) ?? Absent
		kid = |i, child_dt| match host.children.get(i) {
			Ok(child) => Array.from_host(child, child_dt)
			Err(_) => Err(InvalidArray("missing child ${i.to_str()}"))
		}
		fixed = |w| {
			bytes = typed_u8s(buf(1))?
			if bytes.len() < end.times_saturated(w) {
				Err(InvalidArray("value buffer shorter than offset + length"))
			} else {
				Ok(Fixed(w, bytes.sublist({ start: offset * w, len: rows * w })))
			}
		}
		text = match (dt, buf(2)) {
			(Utf8, Utf8(str)) => Ok(str)
			(LargeUtf8, Utf8(str)) => Ok(str)
			_ => Err(NoText)
		}
		b = match dt {
			Null => Ok(NoBuffers)
			Boolean => {
				bits = typed_u8s(buf(1))?
				if bits.len() * 8 < end {
					Err(InvalidArray("boolean buffer shorter than offset + length"))
				} else {
					Ok(BoolBits(bits, offset))
				}
			}
			Int8 => prim(typed_i8s(buf(1))?, offset, rows, |xs| I8s(xs))
			Int16 => prim(typed_i16s(buf(1))?, offset, rows, |xs| I16s(xs))
			Int32 | Date32 | Time32(_) | Interval(YearMonth) | Decimal32(_) => prim(typed_i32s(buf(1))?, offset, rows, |xs| I32s(xs))
			Int64 | Date64 | Time64(_) | Timestamp(_, _) | Duration(_) | Decimal64(_) => prim(typed_i64s(buf(1))?, offset, rows, |xs| I64s(xs))
			UInt8 => prim(typed_u8s(buf(1))?, offset, rows, |xs| U8s(xs))
			UInt16 | Float16 => prim(typed_u16s(buf(1))?, offset, rows, |xs| U16s(xs))
			UInt32 => prim(typed_u32s(buf(1))?, offset, rows, |xs| U32s(xs))
			UInt64 => prim(typed_u64s(buf(1))?, offset, rows, |xs| U64s(xs))
			Float32 => prim(typed_f32s(buf(1))?, offset, rows, |xs| F32s(xs))
			Float64 => prim(typed_f64s(buf(1))?, offset, rows, |xs| F64s(xs))
			Decimal128(_) => prim(typed_i128s(buf(1))?, offset, rows, |xs| I128s(xs))
			Decimal256(_) => fixed(32)
			Interval(DayTime) => fixed(8)
			Interval(MonthDayNano) => fixed(16)
			FixedSizeBinary(w) => fixed(w)
			Binary | Utf8 => {
				data = typed_data(buf(2))?
				Ok(Var32(row_offsets(typed_i32s(buf(1))?, offset, rows, data.len(), |o| o.to_i64(), 0)?, data))
			}
			LargeBinary | LargeUtf8 => {
				data = typed_data(buf(2))?
				Ok(Var64(row_offsets(typed_i64s(buf(1))?, offset, rows, data.len(), |o| o, 0)?, data))
			}
			BinaryView | Utf8View => {
				words = typed_u32s(buf(1))?
				if words.len() < end.times_saturated(4) {
					return Err(InvalidArray("view buffer shorter than offset + length"))
				}
				# Buffers 2 .. n-1 hold data; the last is the i64 sizes buffer.
				n_data = host.buffers.len().minus_saturated(3)
				datas = host.buffers.sublist({ start: 2, len: n_data }).map_try(typed_u8s)?
				mine = words.sublist({ start: offset * 4, len: rows * 4 })
				check_views(mine, datas)?
				Ok(Views(mine, datas))
			}
			List(f) | Map(f, _) => {
				child = kid(0, f.data_type)?
				Ok(List32(row_offsets(typed_i32s(buf(1))?, offset, rows, child.len(), |o| o.to_i64(), 0)?, child))
			}
			LargeList(f) => {
				child = kid(0, f.data_type)?
				Ok(List64(row_offsets(typed_i64s(buf(1))?, offset, rows, child.len(), |o| o, 0)?, child))
			}
			FixedSizeList(f, size) => {
				child = kid(0, f.data_type)?
				if child.len() < end.times_saturated(size) {
					Err(InvalidArray("fixed-size list child shorter than offset + length"))
				} else {
					Ok(FixedList(size, child.slice(offset * size, rows * size)))
				}
			}
			Struct(fields) => {
				kids = fields.map_with_index(|f, i| kid(i, f.data_type)).map_try(|r| r)?
				if kids.any(|c| c.len() < end) {
					Err(InvalidArray("struct child shorter than offset + length"))
				} else {
					Ok(Children(kids.map(|c| c.slice(offset, rows))))
				}
			}
			ListView(_) | LargeListView(_) | Union(_, _, _) | Dictionary(_, _, _) | RunEndEncoded(_, _) =>
				Err(Unsupported(unsupported_name(dt)))
		}
		Ok({ dt, rows, valid, buffers: b?, text })
	}

	## Export to the host form: offset 0, typed buffers, Roc-owned or static
	## lists as they are. The host keeps static (borrowed) buffers alive. A
	## text buffer that came in as `Utf8(str)` goes out as `U8s` over the same
	## bytes, so an export never holds a `Utf8` buffer.
	to_host : Array -> Host.Array
	to_host = |arr| {
		bitmap = match arr.valid.to_bitmap(arr.rows) {
			Ok(bits) => U8s(bits)
			Err(AllValid) => Absent
		}
		null_rows = arr.valid.null_count(arr.rows).to_i64_wrap()
		base = { length: arr.rows.to_i64_wrap(), null_count: null_rows, offset: 0, buffers: [], children: [], dictionary: [] }
		match arr.buffers {
			NoBuffers => { ..base, null_count: arr.rows.to_i64_wrap() }
			BoolBits(bits, offset) => { ..base, buffers: [bitmap, U8s(Validity.realign_bits(bits, offset, arr.rows))] }
			I8s(xs) => { ..base, buffers: [bitmap, I8s(xs)] }
			I16s(xs) => { ..base, buffers: [bitmap, I16s(xs)] }
			I32s(xs) => { ..base, buffers: [bitmap, I32s(xs)] }
			I64s(xs) => { ..base, buffers: [bitmap, I64s(xs)] }
			U8s(xs) => { ..base, buffers: [bitmap, U8s(xs)] }
			U16s(xs) => { ..base, buffers: [bitmap, U16s(xs)] }
			U32s(xs) => { ..base, buffers: [bitmap, U32s(xs)] }
			U64s(xs) => { ..base, buffers: [bitmap, U64s(xs)] }
			F32s(xs) => { ..base, buffers: [bitmap, F32s(xs)] }
			F64s(xs) => { ..base, buffers: [bitmap, F64s(xs)] }
			I128s(xs) => { ..base, buffers: [bitmap, I128s(xs)] }
			Var32(offs, data) => { ..base, buffers: [bitmap, I32s(offs), U8s(data)] }
			Var64(offs, data) => { ..base, buffers: [bitmap, I64s(offs), U8s(data)] }
			Views(words, datas) => {
				sizes = I64s(datas.map(|d| d.len().to_i64_wrap()))
				{ ..base, buffers: [bitmap, U32s(words)].concat(datas.map(|d| U8s(d))).append(sizes) }
			}
			Fixed(_, bytes) => { ..base, buffers: [bitmap, U8s(bytes)] }
			List32(offs, child) => { ..base, buffers: [bitmap, I32s(offs)], children: [child.to_host()] }
			List64(offs, child) => { ..base, buffers: [bitmap, I64s(offs)], children: [child.to_host()] }
			FixedList(_, child) => { ..base, buffers: [bitmap], children: [child.to_host()] }
			Children(kids) => { ..base, buffers: [bitmap], children: kids.map(Array.to_host) }
		}
	}

	## The logical type. O(1).
	data_type : Array -> DataType
	data_type = |arr| arr.dt

	## The row count, after any slice. O(1).
	len : Array -> U64
	len = |arr| arr.rows

	## The validity, at this array's bit offset. O(1), no copy.
	validity : Array -> Validity
	validity = |arr| arr.valid

	## The typed buffers, sliced to this array's rows. O(1), no copy.
	body : Array -> Array.Body
	body = |arr| arr.buffers

	## The data buffer of a Utf8 or LargeUtf8 array as the `Str` the host
	## passed (`Host.Buffer.Utf8`), not checked by Roc. It is the whole buffer,
	## not cut to the rows: cut it at the offsets of `body`. `Err(NoText)` when
	## the host passed bytes. O(1), no copy.
	trusted_text : Array -> Try(Str, [NoText])
	trusted_text = |arr| arr.text

	## Whether row `row` holds a value. False past the end, and for every row of a Null array.
	is_valid : Array, U64 -> Bool
	is_valid = |arr, row| row < arr.rows and arr.valid.is_valid(row) and arr.dt != Null

	## The NULL rows, counted from the bitmap in O(rows). A Null array is all NULL.
	## `from_host` keeps no bitmap when the host's `null_count` is 0.
	null_count : Array -> U64
	null_count = |arr| match arr.dt {
		Null => arr.rows
		_ => arr.valid.null_count(arr.rows)
	}

	## The child arrays (struct fields, list values), sliced to this array's
	## rows for Struct and FixedSizeList.
	children : Array -> List(Array)
	children = |arr| match arr.buffers {
		List32(_, c) | List64(_, c) | FixedList(_, c) => [c]
		Children(kids) => kids
		_ => []
	}

	## Rows `start .. start + count`, clamped to the array. Zero copy.
	slice : Array, U64, U64 -> Array
	slice = |arr, start0, count0| {
		start = start0.min(arr.rows)
		count = count0.min(arr.rows - start)
		cut = |xs| xs.sublist({ start, len: count })
		b = match arr.buffers {
			NoBuffers => NoBuffers
			BoolBits(bits, offset) => BoolBits(bits, offset + start)
			I8s(xs) => I8s(cut(xs))
			I16s(xs) => I16s(cut(xs))
			I32s(xs) => I32s(cut(xs))
			I64s(xs) => I64s(cut(xs))
			U8s(xs) => U8s(cut(xs))
			U16s(xs) => U16s(cut(xs))
			U32s(xs) => U32s(cut(xs))
			U64s(xs) => U64s(cut(xs))
			F32s(xs) => F32s(cut(xs))
			F64s(xs) => F64s(cut(xs))
			I128s(xs) => I128s(cut(xs))
			Var32(offs, data) => Var32(offs.sublist({ start, len: count + 1 }), data)
			Var64(offs, data) => Var64(offs.sublist({ start, len: count + 1 }), data)
			Views(words, datas) => Views(words.sublist({ start: start * 4, len: count * 4 }), datas)
			Fixed(w, bytes) => Fixed(w, bytes.sublist({ start: start * w, len: count * w }))
			List32(offs, child) => List32(offs.sublist({ start, len: count + 1 }), child)
			List64(offs, child) => List64(offs.sublist({ start, len: count + 1 }), child)
			FixedList(size, child) => FixedList(size, child.slice(start * size, count * size))
			Children(kids) => Children(kids.map(|c| c.slice(start, count)))
		}
		{ dt: arr.dt, rows: count, valid: arr.valid.skip(start), buffers: b, text: arr.text }
	}

	## Wrap a typed list as a primitive array with zero copy. The list's
	## element type must match the data type's physical type.
	from_body : DataType, U64, Validity, Array.Body -> Try(Array, [InvalidArray(Str), Unsupported(Str)])
	from_body = |dt, rows, valid, b| {
		# Validate by round-tripping through the host form, which checks sizes.
		host = Array.to_host({ dt, rows, valid, buffers: b, text: Err(NoText) })
		Array.from_host(host, dt)
	}

	## A non-null UInt8 array over these bytes, zero copy.
	from_u8s : List(U8) -> Array
	from_u8s = |xs| { dt: UInt8, rows: xs.len(), valid: AllValid, buffers: U8s(xs), text: Err(NoText) }

	## A non-null Int64 array, zero copy.
	from_i64s : List(I64) -> Array
	from_i64s = |xs| { dt: Int64, rows: xs.len(), valid: AllValid, buffers: I64s(xs), text: Err(NoText) }

	## A non-null Int32 array, zero copy.
	from_i32s : List(I32) -> Array
	from_i32s = |xs| { dt: Int32, rows: xs.len(), valid: AllValid, buffers: I32s(xs), text: Err(NoText) }

	## A non-null Float64 array, zero copy.
	from_f64s : List(F64) -> Array
	from_f64s = |xs| { dt: Float64, rows: xs.len(), valid: AllValid, buffers: F64s(xs), text: Err(NoText) }

	## A Utf8 array (one copy of the text).
	from_strs : List(Str) -> Array
	from_strs = |xs| {
		start = { offs: List.with_capacity(xs.len() + 1).append(0.I32), data: [] }
		built = xs.fold(
			start,
			|acc, s| {
				data = acc.data.concat(s.to_utf8())
				{ offs: acc.offs.append(data.len().to_i32_wrap()), data }
			},
		)
		{ dt: Utf8, rows: xs.len(), valid: AllValid, buffers: Var32(built.offs, built.data), text: Err(NoText) }
	}

	## The same buffers under another type of the same physical layout, for
	## example Int64 to Timestamp. Zero copy.
	reinterpret : Array, DataType -> Try(Array, [InvalidArray(Str), Unsupported(Str)])
	reinterpret = |arr, dt| Array.from_host(arr.to_host(), dt)

	## The same rows with this validity (nulls added or removed). Zero copy.
	with_validity : Array, Validity -> Array
	with_validity = |arr, v| { ..arr, valid: v }

	## A non-null Struct array from one column per schema field (a record
	## batch). Columns must have the fields' types and equal lengths.
	from_columns : Schema, List(Array) -> Try(Array, [InvalidArray(Str), Unsupported(Str)])
	from_columns = |schema, cols| {
		rows = cols.first().map_ok(Array.len) ?? 0
		if cols.len() != schema.fields.len() or cols.any(|c| c.len() != rows) {
			return Err(InvalidArray("a record batch needs one column per field, all of one length"))
		}
		if List.map2(schema.fields, cols, |f, c| f.data_type == c.dt).any(|same| !same) {
			return Err(InvalidArray("a column's type differs from its field"))
		}
		Ok({ dt: Struct(schema.fields), rows, valid: AllValid, buffers: Children(cols), text: Err(NoText) })
	}

	## An all-null array of the Null type.
	nulls : U64 -> Array
	nulls = |rows| { dt: Null, rows, valid: AllValid, buffers: NoBuffers, text: Err(NoText) }
}

unsupported_name : DataType -> Str
unsupported_name = |dt| match dt {
	ListView(_) => "ListView"
	LargeListView(_) => "LargeListView"
	Union(_, _, _) => "Union"
	Dictionary(_, _, _) => "Dictionary"
	RunEndEncoded(_, _) => "RunEndEncoded"
	_ => "this type"
}

prim : List(a), U64, U64, (List(a) -> Array.Body) -> Try(Array.Body, [InvalidArray(Str), Unsupported(Str)])
prim = |xs, offset, rows, wrap|
	if xs.len() < offset + rows {
		Err(InvalidArray("value buffer shorter than offset + length"))
	} else {
		Ok(wrap(xs.sublist({ start: offset, len: rows })))
	}

to_u64 : I64, Str -> Try(U64, [InvalidArray(Str)])
to_u64 = |n, what| n.to_u64_try().map_err(|_| InvalidArray("negative ${what}"))

## The checked offsets of rows `offset ..< offset + rows`. Arrow allows an
## empty offsets buffer for an array of no rows; it reads as one offset of 0.
row_offsets : List(a), U64, U64, U64, (a -> I64), a -> Try(List(a), [InvalidArray(Str), Unsupported(Str)])
row_offsets = |offs, offset, rows, limit, wide, zero|
	if rows == 0 and offs.is_empty() {
		Ok([zero])
	} else {
		check_offsets(offs, offset, rows, limit, wide)?
		Ok(offs.sublist({ start: offset, len: rows + 1 }))
	}

## Offsets rows [offset, offset + rows] must exist, be non-negative,
## non-decreasing and end within `limit`. `wide` reads one offset as I64, so
## 32-bit offsets are checked in place, with no converted copy.
check_offsets : List(a), U64, U64, U64, (a -> I64) -> Try({}, [InvalidArray(Str), Unsupported(Str)])
check_offsets = |offs, offset, rows, limit, wide| {
	if offs.len() < offset + rows + 1 {
		return Err(InvalidArray("offsets buffer shorter than offset + length + 1"))
	}
	var $prev = offs.get(offset).map_ok(wide) ?? 0
	if $prev < 0 {
		return Err(InvalidArray("negative offset"))
	}
	for i in (offset + 1).until(offset + rows + 1) {
		o = offs.get(i).map_ok(wide) ?? 0
		if o < $prev {
			return Err(InvalidArray("offsets decrease at row ${(i - offset - 1).to_str()}"))
		}
		$prev = o
	}
	if $prev.to_u64_wrap() > limit {
		Err(InvalidArray("offsets end past the data"))
	} else {
		Ok({})
	}
}

## Each view of 12 bytes or less has zero bytes after its value. Each longer
## view lies in its data buffer, and its prefix is the first 4 bytes there.
check_views : List(U32), List(List(U8)) -> Try({}, [InvalidArray(Str), Unsupported(Str)])
check_views = |words, datas| {
	var $i = 0
	while $i + 3 < words.len() {
		size = words.get($i) ?? 0
		prefix = words.get($i + 1) ?? 0
		if size > 12 {
			index = words.get($i + 2) ?? 0
			start = words.get($i + 3) ?? 0
			match datas.get(index.to_u64()) {
				Ok(data) if start.to_u64() + size.to_u64() <= data.len() =>
					if le_u32(data, start.to_u64()) != prefix {
						return Err(InvalidArray("view ${($i // 4).to_str()} has a prefix that is not the start of its value"))
					}
				_ => return Err(InvalidArray("view ${($i // 4).to_str()} points outside its data buffer"))
			}
		} else {
			# The value fills the 12 bytes after the length from the low byte up.
			padded = [prefix, words.get($i + 2) ?? 0, words.get($i + 3) ?? 0].map_with_index(|w, k| w.bitwise_and(after_value(size, k)))
			if padded != [0, 0, 0] {
				return Err(InvalidArray("view ${($i // 4).to_str()} has bytes after its value"))
			}
		}
		$i = $i + 4
	}
	Ok({})
}

## The bits of inline word `k` (bytes 4k ..< 4k + 4 of the value) that lie
## after a value of `size` bytes.
after_value : U32, U64 -> U32
after_value = |size, k| {
	used = size.to_u64().minus_saturated(4 * k).min(4)
	if (used == 4) 0 else (0xFFFFFFFF.U32).shl_wrap((8 * used).to_u8_wrap())
}

## The little-endian U32 at byte `at`; the data is known to hold it.
le_u32 : List(U8), U64 -> U32
le_u32 = |data, at| (0.U64).until(4).fold(0, |acc, k| acc.bitwise_or((data.get(at + k) ?? 0).to_u32().shl_wrap((8 * k).to_u8_wrap())))

wrong : Str -> Try(a, [InvalidArray(Str), Unsupported(Str)])
wrong = |want| Err(InvalidArray("expected a ${want} buffer"))

typed_u8s : Host.Buffer -> Try(List(U8), [InvalidArray(Str), Unsupported(Str)])
typed_u8s = |b| match b {
	U8s(xs) => Ok(xs)
	Absent => Ok([])
	_ => wrong("U8s")
}

## The data buffer of a binary or text type: bytes, or the bytes of a trusted
## `Str` with zero copy.
typed_data : Host.Buffer -> Try(List(U8), [InvalidArray(Str), Unsupported(Str)])
typed_data = |b| match b {
	Utf8(str) => Ok(str.to_utf8())
	_ => typed_u8s(b)
}

typed_i8s : Host.Buffer -> Try(List(I8), [InvalidArray(Str), Unsupported(Str)])
typed_i8s = |b| match b {
	I8s(xs) => Ok(xs)
	U8s(bytes) => Ok(bytes.map(|x| x.to_i8_wrap()))
	Absent => Ok([])
	_ => wrong("I8s")
}

## Decode little-endian bytes into `n`-byte values: the pure-Roc copy path.
decode_le : List(U8), U64, (List(U8), U64 -> Try(a, [OutOfBounds])) -> List(a)
decode_le = |bytes, width, read| {
	count = bytes.len() // width
	var $out = List.with_capacity(count)
	for i in (0.U64).until(count) {
		match read(bytes, i * width) {
			Ok(x) => {
				$out = $out.append(x)
			}
			Err(_) => {}
		}
	}
	$out
}

typed_i16s : Host.Buffer -> Try(List(I16), [InvalidArray(Str), Unsupported(Str)])
typed_i16s = |b| match b {
	I16s(xs) => Ok(xs)
	U8s(bytes) => Ok(decode_le(bytes, 2, I16.from_le_bytes))
	Absent => Ok([])
	_ => wrong("I16s")
}

typed_i32s : Host.Buffer -> Try(List(I32), [InvalidArray(Str), Unsupported(Str)])
typed_i32s = |b| match b {
	I32s(xs) => Ok(xs)
	U8s(bytes) => Ok(decode_le(bytes, 4, I32.from_le_bytes))
	Absent => Ok([])
	_ => wrong("I32s")
}

typed_i64s : Host.Buffer -> Try(List(I64), [InvalidArray(Str), Unsupported(Str)])
typed_i64s = |b| match b {
	I64s(xs) => Ok(xs)
	U8s(bytes) => Ok(decode_le(bytes, 8, I64.from_le_bytes))
	Absent => Ok([])
	_ => wrong("I64s")
}

typed_u16s : Host.Buffer -> Try(List(U16), [InvalidArray(Str), Unsupported(Str)])
typed_u16s = |b| match b {
	U16s(xs) => Ok(xs)
	U8s(bytes) => Ok(decode_le(bytes, 2, U16.from_le_bytes))
	Absent => Ok([])
	_ => wrong("U16s")
}

typed_u32s : Host.Buffer -> Try(List(U32), [InvalidArray(Str), Unsupported(Str)])
typed_u32s = |b| match b {
	U32s(xs) => Ok(xs)
	U8s(bytes) => Ok(decode_le(bytes, 4, U32.from_le_bytes))
	Absent => Ok([])
	_ => wrong("U32s")
}

typed_u64s : Host.Buffer -> Try(List(U64), [InvalidArray(Str), Unsupported(Str)])
typed_u64s = |b| match b {
	U64s(xs) => Ok(xs)
	U8s(bytes) => Ok(decode_le(bytes, 8, U64.from_le_bytes))
	Absent => Ok([])
	_ => wrong("U64s")
}

typed_f32s : Host.Buffer -> Try(List(F32), [InvalidArray(Str), Unsupported(Str)])
typed_f32s = |b| match b {
	F32s(xs) => Ok(xs)
	U8s(bytes) => Ok(decode_le(bytes, 4, U32.from_le_bytes).map(F32.from_bits))
	Absent => Ok([])
	_ => wrong("F32s")
}

typed_f64s : Host.Buffer -> Try(List(F64), [InvalidArray(Str), Unsupported(Str)])
typed_f64s = |b| match b {
	F64s(xs) => Ok(xs)
	U8s(bytes) => Ok(decode_le(bytes, 8, U64.from_le_bytes).map(F64.from_bits))
	Absent => Ok([])
	_ => wrong("F64s")
}

typed_i128s : Host.Buffer -> Try(List(I128), [InvalidArray(Str), Unsupported(Str)])
typed_i128s = |b| match b {
	I128s(xs) => Ok(xs)
	U8s(bytes) => Ok(decode_le(bytes, 16, I128.from_le_bytes))
	Absent => Ok([])
	_ => wrong("I128s")
}

# from_body wraps a typed buffer that fits the rows and keeps the validity.
expect {
	match Array.from_body(Int64, 2, Validity.from_bools([Bool.False, Bool.True]), I64s([7, 8])) {
		Ok(arr) =>
			match arr.body() {
				I64s(xs) => xs == [7, 8] and arr.data_type() == Int64 and !arr.is_valid(0) and arr.is_valid(1) and arr.null_count() == 1
				_ => Bool.False
			}
		Err(_) => Bool.False
	}
}

# from_body refuses a buffer shorter than the rows, or of the wrong kind.
expect Array.from_body(Int64, 3, AllValid, I64s([1, 2])).is_err()
expect Array.from_body(Int64, 1, AllValid, I32s([1])).is_err()

expect {
	arr = Array.from_i32s([1, -2])
	match arr.body() {
		I32s(xs) => xs == [1, -2] and arr.data_type() == Int32 and arr.len() == 2 and arr.null_count() == 0
		_ => Bool.False
	}
}

expect {
	arr = Array.from_f64s([0.25])
	match arr.body() {
		F64s(xs) => xs == [0.25] and arr.data_type() == Float64 and arr.len() == 1 and arr.is_valid(0)
		_ => Bool.False
	}
}

expect {
	arr = Array.from_u8s([3, 4, 5])
	match arr.body() {
		U8s(xs) => xs == [3, 4, 5] and arr.data_type() == UInt8 and arr.len() == 3 and arr.null_count() == 0
		_ => Bool.False
	}
}

# reinterpret keeps the values and validity under a type of the same layout.
expect {
	arr = Array.from_i64s([10, 20]).with_validity(Validity.from_bools([Bool.True, Bool.False]))
	match arr.reinterpret(Timestamp(Microsecond, "UTC")) {
		Ok(ts) =>
			match ts.body() {
				I64s(xs) => xs == [10, 20] and ts.data_type() == Timestamp(Microsecond, "UTC") and ts.is_valid(0) and !ts.is_valid(1)
				_ => Bool.False
			}
		Err(_) => Bool.False
	}
}

# reinterpret refuses a type of another layout.
expect Array.from_i64s([10, 20]).reinterpret(Utf8).is_err()

schema_ab : Schema
schema_ab = Schema.new([DataType.field("a", Int64, Bool.False), DataType.field("b", Utf8, Bool.True)])

# from_columns makes a Struct array of the schema's fields.
expect {
	match Array.from_columns(schema_ab, [Array.from_i64s([1, 2]), Array.from_strs(["x", "y"])]) {
		Ok(batch) => batch.data_type() == Struct(schema_ab.fields) and batch.len() == 2 and batch.children().map(Array.len) == [2, 2] and batch.null_count() == 0
		Err(_) => Bool.False
	}
}

# from_columns refuses a wrong column count, a wrong length, and a wrong type.
expect Array.from_columns(schema_ab, [Array.from_i64s([1, 2])]).is_err()
expect Array.from_columns(schema_ab, [Array.from_i64s([1]), Array.from_strs(["x", "y"])]).is_err()
expect Array.from_columns(schema_ab, [Array.from_i32s([1, 2]), Array.from_strs(["x", "y"])]).is_err()

# nulls has no valid row, and its export says every row is null.
expect {
	arr = Array.nulls(3)
	arr.len() == 3 and arr.null_count() == 3 and !arr.is_valid(0) and arr.data_type() == Null and arr.to_host().null_count == 3
}

# children: the list values, the struct fields sliced to the rows, none for a primitive.
expect {
	host = { length: 2, null_count: 0, offset: 0, buffers: [Absent, I32s([0, 1, 3])], children: [{ length: 3, null_count: 0, offset: 0, buffers: [Absent, I64s([1, 2, 3])], children: [], dictionary: [] }], dictionary: [] }
	list = Array.from_host(host, DataType.list_of(Int64)) ?? crash "import"
	batch = Array.from_columns(schema_ab, [Array.from_i64s([1, 2, 3]), Array.from_strs(["x", "y", "z"])]) ?? crash "batch"
	list.children().map(Array.len) == [3] and batch.slice(1, 2).children().map(Array.len) == [2, 2] and Array.from_i64s([1]).children().is_empty()
}

# Utf8 and LargeUtf8 keep a trusted Str through slice and with_validity; a
# Binary array and a U8s data buffer have none.
expect {
	text = "a trusted text of more than 23 bytes"
	host = |offs| { length: 1, null_count: 0, offset: 0, buffers: [Absent, offs, Utf8(text)], children: [], dictionary: [] }
	utf8 = Array.from_host(host(I32s([0, 3])), Utf8) ?? crash "utf8"
	large = Array.from_host(host(I64s([0, 3])), LargeUtf8) ?? crash "large"
	binary = Array.from_host(host(I32s([0, 3])), Binary) ?? crash "binary"
	bytes = Array.from_host({ length: 1, null_count: 0, offset: 0, buffers: [Absent, I32s([0, 3]), U8s(text.to_utf8())], children: [], dictionary: [] }, Utf8) ?? crash "bytes"
	same = |arr| arr.trusted_text() == Ok(text)
	same(utf8) and same(utf8.slice(1, 0)) and same(utf8.with_validity(AllValid)) and same(large) and binary.trusted_text() == Err(NoText) and bytes.trusted_text() == Err(NoText)
}

# A trusted Str is the data buffer: its bytes, checked against the offsets.
expect {
	host = |offs| { length: 2, null_count: 0, offset: 0, buffers: [Absent, I32s(offs), Utf8("aé")], children: [], dictionary: [] }
	ok = match Array.from_host(host([0, 1, 3]), Binary) {
		Ok(arr) =>
			match arr.body() {
				Var32(_, data) => data == "aé".to_utf8()
				_ => Bool.False
			}
		Err(_) => Bool.False
	}
	ok and Array.from_host(host([0, 1, 4]), Utf8).is_err()
}

# A trusted Str exports as U8s over the same bytes.
expect {
	host = { length: 1, null_count: 0, offset: 0, buffers: [Absent, I64s([0, 2]), Utf8("hé")], children: [], dictionary: [] }
	out = (Array.from_host(host, LargeUtf8) ?? crash "import").to_host()
	out.buffers.get(2) == Ok(U8s("hé".to_utf8()))
}

# Arrow allows an empty offsets buffer, or none, for an array of no rows.
expect {
	none = |dt, offs| Array.from_host({ length: 0, null_count: 0, offset: 0, buffers: [Absent, offs, U8s([])], children: [], dictionary: [] }, dt)
	list = |dt, offs| Array.from_host({ length: 0, null_count: 0, offset: 0, buffers: [Absent, offs], children: [Host.empty_array(0)], dictionary: [] }, dt)
	all_ok = [none(Utf8, I32s([])), none(Binary, Absent), none(LargeUtf8, I64s([])), list(DataType.list_of(Null), I32s([])), list(LargeList(DataType.field("item", Null, Bool.True)), Absent)].all(|r| r.is_ok())
	all_ok and none(Utf8, I32s([])).map_ok(|a| a.to_host().buffers.get(1)) == Ok(Ok(I32s([0])))
}

# An empty offsets buffer is still refused when the array has rows.
expect Array.from_host({ length: 1, null_count: 0, offset: 0, buffers: [Absent, I32s([]), U8s([])], children: [], dictionary: [] }, Utf8).is_err()

# A NULL values buffer (Absent) is an empty one: fine for no rows, refused for one.
expect {
	host = |rows| { length: rows, null_count: 0, offset: 0, buffers: [Absent, Absent], children: [], dictionary: [] }
	[Int8, Int16, UInt16, UInt32, UInt64, Float32, Float64, Decimal128({ precision: 38, scale: 0 })].all(|dt| Array.from_host(host(0), dt).is_ok() and Array.from_host(host(1), dt).is_err())
}
