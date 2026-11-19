import Array
import CodecError
import DataType
import Decimal
import Host
import Validity

## Builds one Arrow array row by row, for any supported data type. Buffers
## are Roc lists grown with `append`, so a unique builder grows in place;
## `finish_host` hands them to a host with zero copy.
##
## Validity is lazy: no bitmap exists until the first null.
Builder :: { dt : DataType, rows : U64, bits : List(U8), nulls : U64, data : Builder.Data }.{

	## The typed buffers a builder grows, one variant per physical layout.
	Data := [
		NullD,
		BoolD(List(U8)),
		I8D(List(I8)),
		I16D(List(I16)),
		I32D(List(I32)),
		I64D(List(I64)),
		U8D(List(U8)),
		U16D(List(U16)),
		U32D(List(U32)),
		U64D(List(U64)),
		F32D(List(F32)),
		F64D(List(F64)),
		I128D(List(I128)),
		VarD(List(I32), List(U8)),
		LargeVarD(List(I64), List(U8)),
		FixedD(U64, List(U8)),
		ViewD(List(U32), List(U8)),
		ListD(List(I32), Builder),
		LargeListD(List(I64), Builder),
		FixedListD(U64, Builder),
		StructD(List(Builder)),
	]

	## A builder with room for `capacity` rows (and, for nested types,
	## `capacity` child rows).
	new : DataType, U64 -> Try(Builder, [Unsupported(Str)])
	new = |dt, capacity| {
		cap = |_| List.with_capacity(capacity)
		offsets32 = List.with_capacity(capacity + 1).append(0.I32)
		offsets64 = List.with_capacity(capacity + 1).append(0.I64)
		d = match dt {
			Null => NullD
			Boolean => BoolD(List.with_capacity((capacity + 7) // 8))
			Int8 => I8D(cap({}))
			Int16 => I16D(cap({}))
			Int32 | Date32 | Time32(_) | Interval(YearMonth) | Decimal32(_) => I32D(cap({}))
			Int64 | Date64 | Time64(_) | Timestamp(_, _) | Duration(_) | Decimal64(_) => I64D(cap({}))
			UInt8 => U8D(cap({}))
			UInt16 | Float16 => U16D(cap({}))
			UInt32 => U32D(cap({}))
			UInt64 => U64D(cap({}))
			Float32 => F32D(cap({}))
			Float64 => F64D(cap({}))
			Decimal128(_) => I128D(cap({}))
			Binary | Utf8 => VarD(offsets32, List.with_capacity(capacity * 8))
			LargeBinary | LargeUtf8 => LargeVarD(offsets64, List.with_capacity(capacity * 8))
			FixedSizeBinary(w) => FixedD(w, List.with_capacity(capacity * w))
			BinaryView | Utf8View => ViewD(List.with_capacity(capacity * 4), List.with_capacity(capacity * 8))
			Decimal256(_) => FixedD(32, List.with_capacity(capacity * 32))
			Interval(DayTime) => FixedD(8, List.with_capacity(capacity * 8))
			Interval(MonthDayNano) => FixedD(16, List.with_capacity(capacity * 16))
			List(f) | Map(f, _) => ListD(offsets32, Builder.new(f.data_type, capacity)?)
			LargeList(f) => LargeListD(offsets64, Builder.new(f.data_type, capacity)?)
			FixedSizeList(f, size) => FixedListD(size, Builder.new(f.data_type, capacity * size)?)
			Struct(fs) => StructD(fs.map_try(|f| Builder.new(f.data_type, capacity))?)
			_ => return Err(Unsupported(Str.inspect(dt)))
		}
		Ok({ dt, rows: 0, bits: [], nulls: 0, data: d })
	}

	## The type given to `new`.
	data_type : Builder -> DataType
	data_type = |b| b.dt

	## The rows appended so far, NULL rows included.
	len : Builder -> U64
	len = |b| b.rows

	## A NULL row. A fixed-width slot gets 0; a FixedSizeList or Struct row gets a
	## NULL in each child slot.
	append_null : Builder -> Try(Builder, [ArrowErr(CodecError)])
	append_null = |b0| {
		{ dt, rows: rows0, bits, nulls, data } = b0
		b = mark({ dt, rows: rows0, bits, nulls, data: NullD }, Bool.False)
		d = match data {
			NullD => NullD
			BoolD(xs) => BoolD(push_bit(xs, rows0, Bool.False))
			I8D(xs) => I8D(xs.append(0))
			I16D(xs) => I16D(xs.append(0))
			I32D(xs) => I32D(xs.append(0))
			I64D(xs) => I64D(xs.append(0))
			U8D(xs) => U8D(xs.append(0))
			U16D(xs) => U16D(xs.append(0))
			U32D(xs) => U32D(xs.append(0))
			U64D(xs) => U64D(xs.append(0))
			F32D(xs) => F32D(xs.append(0))
			F64D(xs) => F64D(xs.append(0))
			I128D(xs) => I128D(xs.append(0))
			VarD(offs, bytes) => VarD(offs.append(bytes.len().to_i32_wrap()), bytes)
			LargeVarD(offs, bytes) => LargeVarD(offs.append(bytes.len().to_i64_wrap()), bytes)
			FixedD(w, bytes) => FixedD(w, bytes.concat(List.repeat(0, w)))
			ViewD(words, bytes) => ViewD(words.append(0).append(0).append(0).append(0), bytes)
			ListD(offs, child) => ListD(offs.append(child.len().to_i32_wrap()), child)
			LargeListD(offs, child) => LargeListD(offs.append(child.len().to_i64_wrap()), child)
			FixedListD(size, child) => FixedListD(size, repeat_null(child, size)?)
			StructD(kids) => StructD(kids.map_try(Builder.append_null)?)
		}
		Ok({ ..b, data: d })
	}

	## One Boolean value. Refuses any other column (`TypeMismatch`).
	append_bool : Builder, Bool -> Try(Builder, [ArrowErr(CodecError)])
	append_bool = |b, x| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			BoolD(xs) => Ok({ ..mark(shell, Bool.True), data: BoolD(push_bit(xs, rows, x)) })
			_ => wrong(shell, "Boolean")
		}
	}

	## One value into an Int8 column.
	## Refuses any other column (`TypeMismatch`).
	append_i8 : Builder, I8 -> Try(Builder, [ArrowErr(CodecError)])
	append_i8 = |b, x| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			I8D(xs) => Ok({ ..mark(shell, Bool.True), data: I8D(xs.append(x)) })
			_ => wrong(shell, "Int8")
		}
	}

	## One value into an Int16 column.
	## Refuses any other column (`TypeMismatch`).
	append_i16 : Builder, I16 -> Try(Builder, [ArrowErr(CodecError)])
	append_i16 = |b, x| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			I16D(xs) => Ok({ ..mark(shell, Bool.True), data: I16D(xs.append(x)) })
			_ => wrong(shell, "Int16")
		}
	}

	## One value into an Int32, Date32, Time32, Interval(YearMonth) or Decimal32
	## (unscaled) column. Refuses any other column (`TypeMismatch`).
	append_i32 : Builder, I32 -> Try(Builder, [ArrowErr(CodecError)])
	append_i32 = |b, x| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			I32D(xs) => Ok({ ..mark(shell, Bool.True), data: I32D(xs.append(x)) })
			_ => wrong(shell, "Int32")
		}
	}

	## One value into an Int64, Date64, Time64, Timestamp, Duration or Decimal64
	## (unscaled) column. Refuses any other column (`TypeMismatch`).
	append_i64 : Builder, I64 -> Try(Builder, [ArrowErr(CodecError)])
	append_i64 = |b, x| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			I64D(xs) => Ok({ ..mark(shell, Bool.True), data: I64D(xs.append(x)) })
			_ => wrong(shell, "Int64")
		}
	}

	## One value into a UInt8 column.
	## Refuses any other column (`TypeMismatch`).
	append_u8 : Builder, U8 -> Try(Builder, [ArrowErr(CodecError)])
	append_u8 = |b, x| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			U8D(xs) => Ok({ ..mark(shell, Bool.True), data: U8D(xs.append(x)) })
			_ => wrong(shell, "UInt8")
		}
	}

	## One value into a UInt16 column; a Float16 column is refused.
	## Refuses any other column (`TypeMismatch`).
	append_u16 : Builder, U16 -> Try(Builder, [ArrowErr(CodecError)])
	append_u16 = |b, x| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			U16D(xs) if dt != Float16 => Ok({ ..mark(shell, Bool.True), data: U16D(xs.append(x)) })
			_ => wrong(shell, "UInt16")
		}
	}

	## One value into a UInt32 column.
	## Refuses any other column (`TypeMismatch`).
	append_u32 : Builder, U32 -> Try(Builder, [ArrowErr(CodecError)])
	append_u32 = |b, x| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			U32D(xs) => Ok({ ..mark(shell, Bool.True), data: U32D(xs.append(x)) })
			_ => wrong(shell, "UInt32")
		}
	}

	## One value into a UInt64 column.
	## Refuses any other column (`TypeMismatch`).
	append_u64 : Builder, U64 -> Try(Builder, [ArrowErr(CodecError)])
	append_u64 = |b, x| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			U64D(xs) => Ok({ ..mark(shell, Bool.True), data: U64D(xs.append(x)) })
			_ => wrong(shell, "UInt64")
		}
	}

	## One value into a Float32 column.
	## Refuses any other column (`TypeMismatch`).
	append_f32 : Builder, F32 -> Try(Builder, [ArrowErr(CodecError)])
	append_f32 = |b, x| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			F32D(xs) => Ok({ ..mark(shell, Bool.True), data: F32D(xs.append(x)) })
			_ => wrong(shell, "Float32")
		}
	}

	## One value into a Float64 column.
	## Refuses any other column (`TypeMismatch`).
	append_f64 : Builder, F64 -> Try(Builder, [ArrowErr(CodecError)])
	append_f64 = |b, x| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			F64D(xs) => Ok({ ..mark(shell, Bool.True), data: F64D(xs.append(x)) })
			_ => wrong(shell, "Float64")
		}
	}

	## A Decimal128 unscaled value.
	append_i128 : Builder, I128 -> Try(Builder, [ArrowErr(CodecError)])
	append_i128 = |b, x| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			I128D(xs) => Ok({ ..mark(shell, Bool.True), data: I128D(xs.append(x)) })
			_ => wrong(shell, "Decimal128")
		}
	}

	## A Dec rounded to the column's scale (Decimal32, Decimal64 or
	## Decimal128); fails past its precision or its storage width.
	append_dec : Builder, Dec -> Try(Builder, [ArrowErr(CodecError)])
	append_dec = |b, x| match b.dt {
		Decimal32({ precision, scale }) => {
			unscaled = rescale(x, precision, scale)?
			Builder.append_i32(b, unscaled.to_i32_try() ? |_| ArrowErr(OutOfRange("")))
		}
		Decimal64({ precision, scale }) => {
			unscaled = rescale(x, precision, scale)?
			Builder.append_i64(b, unscaled.to_i64_try() ? |_| ArrowErr(OutOfRange("")))
		}
		Decimal128({ precision, scale }) => Builder.append_i128(b, rescale(x, precision, scale)?)
		_ => wrong(b, "Decimal")
	}

	## One string into a Utf8, LargeUtf8 or Utf8View column; copies its bytes.
	## Refuses any other column (`TypeMismatch`).
	append_str : Builder, Str -> Try(Builder, [ArrowErr(CodecError)])
	append_str = |b, s| match b.dt {
		Utf8 | LargeUtf8 | Utf8View => append_var(b, s.to_utf8())
		_ => wrong(b, "Utf8")
	}

	## Binary, LargeBinary, BinaryView, or FixedSizeBinary of exactly this
	## length.
	append_bytes : Builder, List(U8) -> Try(Builder, [ArrowErr(CodecError)])
	append_bytes = |b, bytes| {
		# Take the data out first: a list read from a builder that stays alive
		# is shared, and the append would copy the whole column.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			FixedD(w, held) => if (bytes.len() == w) Ok({ ..mark(shell, Bool.True), data: FixedD(w, held.concat(bytes)) }) else Err(ArrowErr(OutOfRange("")))
			_ =>
				match dt {
					Binary | LargeBinary | BinaryView => append_var({ ..shell, data }, bytes)
					_ => wrong(shell, "Binary")
				}
		}
	}

	## Run `fill` on child `index` (a struct field, or a list's values),
	## keeping the child unique so it grows in place.
	update_child : Builder, U64, (Builder -> Try(Builder, [ArrowErr(CodecError)])) -> Try(Builder, [ArrowErr(CodecError)])
	update_child = |b, index, fill| {
		# Take the data out first: a child read from a builder that stays
		# alive is shared, and its next append would copy it.
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			ListD(offs, child) => Ok({ ..shell, data: ListD(offs, fill(child)?) })
			LargeListD(offs, child) => Ok({ ..shell, data: LargeListD(offs, fill(child)?) })
			FixedListD(size, child) => Ok({ ..shell, data: FixedListD(size, fill(child)?) })
			StructD(kids) =>
				match kids.replace(index, placeholder) {
					Ok({ list, prev }) => {
						filled = fill(prev)?
						Ok({ ..shell, data: StructD(list.set(index, filled) ?? list) })
					}
					Err(_) => wrong(shell, "a child ${index.to_str()}")
				}
			_ => wrong(shell, "a nested type")
		}
	}

	## Close a list row whose values `update_child` appended.
	end_list : Builder -> Try(Builder, [ArrowErr(CodecError)])
	end_list = |b| {
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			ListD(offs, child) => {
				end = child.len().to_i32_wrap()
				Ok({ ..mark(shell, Bool.True), data: ListD(offs.append(end), child) })
			}
			LargeListD(offs, child) => {
				end = child.len().to_i64_wrap()
				Ok({ ..mark(shell, Bool.True), data: LargeListD(offs.append(end), child) })
			}
			FixedListD(size, child) => {
				held = child.len()
				if held == (rows + 1) * size {
					Ok({ ..mark(shell, Bool.True), data: FixedListD(size, child) })
				} else {
					Err(ArrowErr(ArityMismatch({ path: "", expected: size, found: held - rows * size })))
				}
			}
			_ => wrong(shell, "List")
		}
	}

	## Close a struct row: a child that got no value this row gets a null.
	end_struct : Builder -> Try(Builder, [ArrowErr(CodecError)])
	end_struct = |b| {
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			StructD(kids) => {
				# Swap each short child out so it stays unique while it pads.
				var $kids = kids
				for index in (0.U64).until($kids.len()) {
					short = $kids.get(index).map_ok(|k| k.len() <= rows) ?? Bool.False
					if short {
						match $kids.replace(index, placeholder) {
							Ok({ list, prev }) => {
								padded = Builder.append_null(prev)?
								$kids = list.set(index, padded) ?? list
							}
							Err(_) => {}
						}
					}
				}
				Ok({ ..mark(shell, Bool.True), data: StructD($kids) })
			}
			_ => wrong(shell, "Struct")
		}
	}

	## Detach the children (struct fields, or a list's values) so a caller
	## can fill them while each stays unique. `put_children` reattaches.
	take_children : Builder -> { shell : Builder, kids : List(Builder) }
	take_children = |b| {
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match data {
			ListD(offs, child) => { shell: { ..shell, data: ListD(offs, placeholder) }, kids: [child] }
			LargeListD(offs, child) => { shell: { ..shell, data: LargeListD(offs, placeholder) }, kids: [child] }
			FixedListD(size, child) => { shell: { ..shell, data: FixedListD(size, placeholder) }, kids: [child] }
			StructD(kids) => { shell: { ..shell, data: StructD([]) }, kids }
			other => { shell: { ..shell, data: other }, kids: [] }
		}
	}

	## Reattach the children that `take_children` detached. A list takes one child,
	## a struct one per field.
	put_children : Builder, List(Builder) -> Builder
	put_children = |b, kids| {
		{ dt, rows, bits, nulls, data } = b
		shell = { dt, rows, bits, nulls, data: NullD }
		match (data, kids) {
			(ListD(offs, _), [child]) => { ..shell, data: ListD(offs, child) }
			(LargeListD(offs, _), [child]) => { ..shell, data: LargeListD(offs, child) }
			(FixedListD(size, _), [child]) => { ..shell, data: FixedListD(size, child) }
			(StructD(_), _) => { ..shell, data: StructD(kids) }
			(other, _) => { ..shell, data: other }
		}
	}

	## The child count of a struct, the value count of a list.
	child_len : Builder, U64 -> U64
	child_len = |b, index| match b.data {
		ListD(_, c) | LargeListD(_, c) | FixedListD(_, c) => c.len()
		StructD(kids) => kids.get(index).map_ok(Builder.len) ?? 0
		_ => 0
	}

	## The finished buffers in host form, offset 0, zero copy.
	finish_host : Builder -> Host.Array
	finish_host = |b| {
		bitmap = if (b.nulls == 0) Absent else U8s(b.bits)
		base = { length: b.rows.to_i64_wrap(), null_count: b.nulls.to_i64_wrap(), offset: 0, buffers: [], children: [], dictionary: [] }
		match b.data {
			NullD => { ..base, null_count: b.rows.to_i64_wrap() }
			BoolD(xs) => { ..base, buffers: [bitmap, U8s(xs)] }
			I8D(xs) => { ..base, buffers: [bitmap, I8s(xs)] }
			I16D(xs) => { ..base, buffers: [bitmap, I16s(xs)] }
			I32D(xs) => { ..base, buffers: [bitmap, I32s(xs)] }
			I64D(xs) => { ..base, buffers: [bitmap, I64s(xs)] }
			U8D(xs) => { ..base, buffers: [bitmap, U8s(xs)] }
			U16D(xs) => { ..base, buffers: [bitmap, U16s(xs)] }
			U32D(xs) => { ..base, buffers: [bitmap, U32s(xs)] }
			U64D(xs) => { ..base, buffers: [bitmap, U64s(xs)] }
			F32D(xs) => { ..base, buffers: [bitmap, F32s(xs)] }
			F64D(xs) => { ..base, buffers: [bitmap, F64s(xs)] }
			I128D(xs) => { ..base, buffers: [bitmap, I128s(xs)] }
			VarD(offs, bytes) => { ..base, buffers: [bitmap, I32s(offs), U8s(bytes)] }
			LargeVarD(offs, bytes) => { ..base, buffers: [bitmap, I64s(offs), U8s(bytes)] }
			FixedD(_, bytes) => { ..base, buffers: [bitmap, U8s(bytes)] }
			ViewD(words, bytes) => { ..base, buffers: [bitmap, U32s(words), U8s(bytes), I64s([bytes.len().to_i64_wrap()])] }
			ListD(offs, child) => { ..base, buffers: [bitmap, I32s(offs)], children: [child.finish_host()] }
			LargeListD(offs, child) => { ..base, buffers: [bitmap, I64s(offs)], children: [child.finish_host()] }
			FixedListD(_, child) => { ..base, buffers: [bitmap], children: [child.finish_host()] }
			StructD(kids) => { ..base, buffers: [bitmap], children: kids.map(Builder.finish_host) }
		}
	}

	## The finished, validated array.
	finish : Builder -> Try(Array, [InvalidArray(Str), Unsupported(Str)])
	finish = |b| Array.from_host(b.finish_host(), b.dt)
}

## Count one row and its validity bit; the bitmap appears at the first null.
mark : Builder, Bool -> Builder
mark = |b, valid| {
	# Take the fields apart so `bits` is the only reference and updates in place.
	{ dt, rows, bits, nulls, data } = b
	next_bits =
		if nulls == 0 and valid {
			bits
		} else if nulls == 0 {
			push_bit(Validity.pack(List.repeat(Bool.True, rows)), rows, valid)
		} else {
			push_bit(bits, rows, valid)
		}
	{ dt, rows: rows + 1, nulls: if (valid) nulls else nulls + 1, bits: next_bits, data }
}

push_bit : List(U8), U64, Bool -> List(U8)
push_bit = |bits, index, x| {
	byte = index.shr_zf_wrap(3)
	mask = if (x) (1.U8).shl_wrap(index.bitwise_and(7).to_u8_wrap()) else 0
	if byte >= bits.len() {
		# A new byte holds the bit from the start.
		bits.append(mask)
	} else {
		# `byte` is in range here, so `update` cannot fail.
		bits.update(byte, |v| v.bitwise_or(mask)) ?? []
	}
}

append_var : Builder, List(U8) -> Try(Builder, [ArrowErr(CodecError)])
append_var = |b, bytes| {
	# Take the data out first: a list read from a builder that stays alive is
	# shared, and every append would copy it.
	{ dt, rows, bits, nulls, data } = b
	shell = mark({ dt, rows, bits, nulls, data: NullD }, Bool.True)
	match data {
		VarD(offs, held) => {
			grown = held.concat(bytes)
			Ok({ ..shell, data: VarD(offs.append(grown.len().to_i32_wrap()), grown) })
		}
		LargeVarD(offs, held) => {
			grown = held.concat(bytes)
			Ok({ ..shell, data: LargeVarD(offs.append(grown.len().to_i64_wrap()), grown) })
		}
		ViewD(words, held) => {
			# A view holds up to 12 bytes inline; a longer value keeps its
			# first 4 bytes in the view and the rest in data buffer 0.
			size = bytes.len()
			head = le_u32(bytes, 0)
			if size <= 12 {
				Ok({ ..shell, data: ViewD(words.append(size.to_u32_wrap()).append(head).append(le_u32(bytes, 4)).append(le_u32(bytes, 8)), held) })
			} else {
				at = held.len().to_u32_wrap()
				grown = held.append_sublist(bytes, { start: 0, len: size })
				Ok({ ..shell, data: ViewD(words.append(size.to_u32_wrap()).append(head).append(0).append(at), grown) })
			}
		}
		_ => wrong({ dt, rows, bits, nulls, data }, "Binary or Utf8")
	}
}

## The unscaled value of `x` at `scale`, or `OutOfRange` past `precision`.
rescale : Dec, U8, I8 -> Try(I128, [ArrowErr(CodecError)])
rescale = |x, precision, scale| match Decimal.from_dec(x, precision, scale) {
	Ok(d) => Ok(d.unscaled)
	Err(OutOfRange) => Err(ArrowErr(OutOfRange("")))
}

## Four little-endian bytes from `at`, zero past the end.
le_u32 : List(U8), U64 -> U32
le_u32 = |xs, at| (0.U64).until(4).fold(0.U32, |acc, k| acc.bitwise_or((xs.get(at + k) ?? 0).to_u32().shl_wrap((k * 8).to_u8_wrap())))

repeat_null : Builder, U64 -> Try(Builder, [ArrowErr(CodecError)])
repeat_null = |b, n| {
	var $out = b
	for _ in (0.U64).until(n) {
		$out = Builder.append_null($out)?
	}
	Ok($out)
}

## Holds a child's place while the child is out being filled.
placeholder : Builder
placeholder = { dt: Null, rows: 0, bits: [], nulls: 0, data: NullD }

wrong : Builder, Str -> Try(a, [ArrowErr(CodecError)])
wrong = |b, expected| Err(ArrowErr(TypeMismatch({ path: "", expected, found: b.dt })))
