import Array
import Builder
import CodecError
import DataType
import Decimal
import Validity

## The Arrow format for derived codecs. Any type whose `parser_for` the
## compiler derives can be read from a row of an `Array`:
##
## | Roc shape             | Arrow column (physical match)                         |
## |-----------------------|-------------------------------------------------------|
## | `Try(a, [Null])`      | any column; a null row gives `Err(Null)`              |
## | `I8` .. `I64`, `U8` .. `U64` | the same width and sign (logical types included) |
## | `I128`                | Decimal128 (unscaled)                                 |
## | `F32`, `F64`          | Float32, Float64                                      |
## | `Dec`                 | Decimal32/64/128 with scale <= 18                     |
## | `Bool`                | Boolean                                               |
## | `Str`                 | Utf8, LargeUtf8, Utf8View                             |
## | `List(U8)`            | Binary, LargeBinary, BinaryView, FixedSizeBinary, or a list of UInt8 |
## | `List(a)`             | List, LargeList, FixedSizeList, Map (entries)          |
## | record                | Struct, fields by name                                |
## | tuple                 | Struct, fields by position                            |
ArrowEncoding := [Arrow].{

	## Read cursor: a column, a row, and the containers open above it.
	State := { col : Array, row : U64, stack : List(ArrowEncoding.Frame) }

	## An open container: a record, a tuple, or a list with its next item.
	Frame := [
		Rec({ parent : Array, row : U64, next : U64, names : List(Str), kids : List(Array) }),
		Tup({ parent : Array, row : U64, kids : List(Array) }),
		Lst({ parent : Array, row : U64, child : Array, pos : U64, end : U64 }),
	]

	## The error of a record field the Struct column does not have.
	missing_field : ArrowEncoding, Str -> [ArrowErr(CodecError)]
	missing_field = |_, name| ArrowErr(MissingField(name))

	## Called by derived tuple parsers for a value no shape accepts.
	invalid_value : ArrowEncoding, ArrowEncoding.State -> [ArrowErr(CodecError)]
	invalid_value = |_, state| mismatch(state, "a valid value")

	## Field names are used as written.
	rename_field : ArrowEncoding, Str -> Str
	rename_field = |_, name| name

	## A column the record does not name costs nothing to skip: rows are random access.
	skip_record_field : ArrowEncoding, ArrowEncoding.State -> Try(ArrowEncoding.State, [ArrowErr(CodecError)])
	skip_record_field = |_, state| Ok(state)

	## Succeeds at a NULL row; at a valid row gives `UnexpectedNull`, so the derived
	## parser reads the value.
	parse_null : ArrowEncoding, ArrowEncoding.State -> Try(ArrowEncoding.State, [ArrowErr(CodecError)])
	parse_null = |_, state|
		if state.row < state.col.len() and !state.col.is_valid(state.row) {
			Ok(state)
		} else {
			Err(ArrowErr(UnexpectedNull(path_of(state))))
		}

	## One Boolean value. `UnexpectedNull` at a NULL row;
	## `TypeMismatch`, with the path, for another physical type.
	parse_bool : ArrowEncoding, ArrowEncoding.State -> Try({ value : Bool, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_bool = |_, state| scalar(
		state,
		"Boolean",
		|b, row| match b {
			BoolBits(bits, offset) => Ok(Validity.bit(bits, offset + row))
			_ => Err(Wrong)
		},
	)

	## One Int8 value. `UnexpectedNull` at a NULL row;
	## `TypeMismatch`, with the path, for another physical type.
	parse_i8 : ArrowEncoding, ArrowEncoding.State -> Try({ value : I8, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_i8 = |_, state| scalar(
		state,
		"Int8",
		|b, row| match b {
			I8s(xs) => xs.get(row).map_err(|_| Wrong)
			_ => Err(Wrong)
		},
	)

	## One Int16 value. `UnexpectedNull` at a NULL row;
	## `TypeMismatch`, with the path, for another physical type.
	parse_i16 : ArrowEncoding, ArrowEncoding.State -> Try({ value : I16, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_i16 = |_, state| scalar(
		state,
		"Int16",
		|b, row| match b {
			I16s(xs) => xs.get(row).map_err(|_| Wrong)
			_ => Err(Wrong)
		},
	)

	## One Int32 (or Date32, Time32, ...) value. `UnexpectedNull` at a NULL row;
	## `TypeMismatch`, with the path, for another physical type.
	parse_i32 : ArrowEncoding, ArrowEncoding.State -> Try({ value : I32, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_i32 = |_, state| scalar(
		state,
		"Int32",
		|b, row| match b {
			I32s(xs) => xs.get(row).map_err(|_| Wrong)
			_ => Err(Wrong)
		},
	)

	## One Int64 (or Timestamp, Date64, ...) value. `UnexpectedNull` at a NULL row;
	## `TypeMismatch`, with the path, for another physical type.
	parse_i64 : ArrowEncoding, ArrowEncoding.State -> Try({ value : I64, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_i64 = |_, state| scalar(
		state,
		"Int64",
		|b, row| match b {
			I64s(xs) => xs.get(row).map_err(|_| Wrong)
			_ => Err(Wrong)
		},
	)

	## One UInt8 value. `UnexpectedNull` at a NULL row;
	## `TypeMismatch`, with the path, for another physical type.
	parse_u8 : ArrowEncoding, ArrowEncoding.State -> Try({ value : U8, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_u8 = |_, state| scalar(
		state,
		"UInt8",
		|b, row| match b {
			U8s(xs) => xs.get(row).map_err(|_| Wrong)
			_ => Err(Wrong)
		},
	)

	## One UInt16 (Float16 refused) value. `UnexpectedNull` at a NULL row;
	## `TypeMismatch`, with the path, for another physical type.
	parse_u16 : ArrowEncoding, ArrowEncoding.State -> Try({ value : U16, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_u16 = |_, state|
		if state.col.data_type() == Float16 {
			Err(mismatch(state, "UInt16"))
		} else {
			scalar(
				state,
				"UInt16",
				|b, row| match b {
					U16s(xs) => xs.get(row).map_err(|_| Wrong)
					_ => Err(Wrong)
				},
			)
		}

	## One UInt32 value. `UnexpectedNull` at a NULL row;
	## `TypeMismatch`, with the path, for another physical type.
	parse_u32 : ArrowEncoding, ArrowEncoding.State -> Try({ value : U32, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_u32 = |_, state| scalar(
		state,
		"UInt32",
		|b, row| match b {
			U32s(xs) => xs.get(row).map_err(|_| Wrong)
			_ => Err(Wrong)
		},
	)

	## One UInt64 value. `UnexpectedNull` at a NULL row;
	## `TypeMismatch`, with the path, for another physical type.
	parse_u64 : ArrowEncoding, ArrowEncoding.State -> Try({ value : U64, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_u64 = |_, state| scalar(
		state,
		"UInt64",
		|b, row| match b {
			U64s(xs) => xs.get(row).map_err(|_| Wrong)
			_ => Err(Wrong)
		},
	)

	## Decimal128's unscaled value.
	parse_i128 : ArrowEncoding, ArrowEncoding.State -> Try({ value : I128, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_i128 = |_, state| scalar(
		state,
		"Decimal128",
		|b, row| match b {
			I128s(xs) => xs.get(row).map_err(|_| Wrong)
			_ => Err(Wrong)
		},
	)

	## One Float32 value. `UnexpectedNull` at a NULL row;
	## `TypeMismatch`, with the path, for another physical type.
	parse_f32 : ArrowEncoding, ArrowEncoding.State -> Try({ value : F32, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_f32 = |_, state| scalar(
		state,
		"Float32",
		|b, row| match b {
			F32s(xs) => xs.get(row).map_err(|_| Wrong)
			_ => Err(Wrong)
		},
	)

	## One Float64 value. `UnexpectedNull` at a NULL row;
	## `TypeMismatch`, with the path, for another physical type.
	parse_f64 : ArrowEncoding, ArrowEncoding.State -> Try({ value : F64, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_f64 = |_, state| scalar(
		state,
		"Float64",
		|b, row| match b {
			F64s(xs) => xs.get(row).map_err(|_| Wrong)
			_ => Err(Wrong)
		},
	)

	## A Decimal column converted to `Dec`; fails when the scale exceeds 18
	## and dropped digits are not zero, or the value exceeds Dec's range.
	parse_dec : ArrowEncoding, ArrowEncoding.State -> Try({ value : Dec, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_dec = |_, state| {
		scale = match state.col.data_type() {
			Decimal32({ scale: s, .. }) | Decimal64({ scale: s, .. }) | Decimal128({ scale: s, .. }) => s
			_ => return Err(mismatch(state, "Decimal"))
		}
		unscaled = scalar(
			state,
			"Decimal",
			|b, row| match b {
				I32s(xs) => xs.get(row).map_ok(|x| x.to_i128()).map_err(|_| Wrong)
				I64s(xs) => xs.get(row).map_ok(|x| x.to_i128()).map_err(|_| Wrong)
				I128s(xs) => xs.get(row).map_err(|_| Wrong)
				_ => Err(Wrong)
			},
		)?
		match Decimal.unscaled_to_dec(unscaled.value, scale) {
			Ok(value) => Ok({ value, rest: state })
			Err(_) => Err(ArrowErr(OutOfRange(path_of(state))))
		}
	}

	## Validates UTF-8; zero copy for values over 23 bytes.
	parse_str : ArrowEncoding, ArrowEncoding.State -> Try({ value : Str, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
	parse_str = |_, state| {
		match state.col.data_type() {
			Utf8 | LargeUtf8 | Utf8View => {}
			_ => return Err(mismatch(state, "Utf8"))
		}
		bytes = scalar(state, "Utf8", |b, row| Ok(bytes_at(b, row)))?
		match Str.from_utf8(bytes.value) {
			Ok(value) => Ok({ value, rest: state })
			Err(_) => Err(ArrowErr(InvalidUtf8(path_of(state))))
		}
	}

	## Open the list value at the focused row (List, LargeList, FixedSizeList, Map;
	## Binary layouts for `List(U8)`).
	parse_list_start : ArrowEncoding, ArrowEncoding.State -> Try([Counted({ len : U64, rest : ArrowEncoding.State }), Uncounted(ArrowEncoding.State)], [ArrowErr(CodecError)])
	parse_list_start = |_, state| {
		live_row(state)?
		# Uncounted: a Counted driver calls nothing between or after items, so
		# a nested container could not restore this list's focus.
		frame = |child, start, n| Ok(Uncounted({ ..state, stack: state.stack.append(Lst({ parent: state.col, row: state.row, child, pos: start, end: start + n })) }))
		match state.col.body() {
			List32(offs, child) => {
				start = (offs.get(state.row) ?? 0).to_u64_wrap()
				frame(child, start, (offs.get(state.row + 1) ?? 0).to_u64_wrap() - start)
			}
			List64(offs, child) => {
				start = (offs.get(state.row) ?? 0).to_u64_wrap()
				frame(child, start, (offs.get(state.row + 1) ?? 0).to_u64_wrap() - start)
			}
			FixedList(size, child) => frame(child, state.row * size, size)
			Var32(_, _) | Var64(_, _) | Views(_, _) | Fixed(_, _) => {
				# Bytes read as List(U8): a zero-copy UInt8 column over the value.
				bytes = Array.from_u8s(bytes_at(state.col.body(), state.row))
				frame(bytes, 0, bytes.len())
			}
			_ => Err(mismatch(state, "List or Binary"))
		}
	}

	## Focus the next item, or close the list when none is left.
	parse_list_next : ArrowEncoding, ArrowEncoding.State -> Try([Item(ArrowEncoding.State), Done(ArrowEncoding.State)], [ArrowErr(CodecError)])
	parse_list_next = |_, state| match state.stack.last() {
		Ok(Lst({ parent, row, child, pos, end })) =>
			if pos < end {
				Ok(Item({ ..state, col: child, row: pos }))
			} else {
				Ok(Done({ col: parent, row, stack: state.stack.drop_last(1) }))
			}
		_ => Err(ArrowErr(TypeMismatch({ path: path_of(state), expected: "an open list", found: state.col.data_type() })))
	}

	## Move past the item just read.
	parse_list_after_item : ArrowEncoding, ArrowEncoding.State -> Try([Continue(ArrowEncoding.State), Done(ArrowEncoding.State)], [ArrowErr(CodecError)])
	parse_list_after_item = |_, state| match state.stack.last() {
		Ok(Lst(frame)) => {
			moved = Lst({ ..frame, pos: frame.pos + 1 })
			Ok(Continue({ col: frame.parent, row: frame.row, stack: state.stack.drop_last(1).append(moved) }))
		}
		_ => Err(ArrowErr(TypeMismatch({ path: path_of(state), expected: "an open list", found: state.col.data_type() })))
	}

	## Open the Struct value at the focused row. Refuses a non-Struct column.
	parse_record_start : ArrowEncoding, ArrowEncoding.State -> Try([Counted({ len : U64, rest : ArrowEncoding.State }), Uncounted(ArrowEncoding.State)], [ArrowErr(CodecError)])
	parse_record_start = |_, state| {
		live_row(state)?
		match (state.col.data_type(), state.col.body()) {
			(Struct(fs), Children(kids)) =>
			# Uncounted, so the format restores the parent after each field.
				Ok(Uncounted({ ..state, stack: state.stack.append(Rec({ parent: state.col, row: state.row, next: 0, names: fs.map(|f| f.name), kids })) }))
			_ => Err(mismatch(state, "Struct"))
		}
	}

	## Struct children are positional; hand the derived parser each child's name.
	parse_record_field : ArrowEncoding,
	Encoding.FieldName.FieldNames(_shape),
	ArrowEncoding.State -> Try(
		[
			Field({ field : Encoding.FieldName(_shape), rest : ArrowEncoding.State }),
			TryField({ name : Str, rest : ArrowEncoding.State }),
			TryFieldCaseless({ name : Str, rest : ArrowEncoding.State }),
			Continue(ArrowEncoding.State),
			Done(ArrowEncoding.State),
		],
		[ArrowErr(CodecError)],
	)
	parse_record_field = |_, _names, state| match state.stack.last() {
		Ok(Rec({ parent, row, next, names, kids })) =>
			match (names.get(next), kids.get(next)) {
				(Ok(name), Ok(child)) => Ok(TryField({ name, rest: { ..state, col: child, row } }))
				_ => Ok(Done({ col: parent, row, stack: state.stack.drop_last(1) }))
			}
		_ => Err(mismatch(state, "an open struct"))
	}

	## Move to the next child, or close the record after the last one.
	parse_record_after_field : ArrowEncoding, ArrowEncoding.State -> Try([Continue(ArrowEncoding.State), Done(ArrowEncoding.State)], [ArrowErr(CodecError)])
	parse_record_after_field = |_, state| match state.stack.last() {
		Ok(Rec(frame)) => {
			moved = { ..frame, next: frame.next + 1 }
			if moved.next < frame.kids.len() {
				Ok(Continue({ col: frame.parent, row: frame.row, stack: state.stack.drop_last(1).append(Rec(moved)) }))
			} else {
				Ok(Done({ col: frame.parent, row: frame.row, stack: state.stack.drop_last(1) }))
			}
		}
		_ => Err(mismatch(state, "an open struct"))
	}

	## Open the Struct value at the focused row as a tuple. `ArityMismatch` when the
	## child count is not `arity`.
	parse_tuple_start : ArrowEncoding, ArrowEncoding.State, U64 -> Try(ArrowEncoding.State, [ArrowErr(CodecError)])
	parse_tuple_start = |_, state, arity| {
		live_row(state)?
		match state.col.body() {
			Children(kids) =>
				if kids.len() != arity {
					Err(ArrowErr(ArityMismatch({ path: path_of(state), expected: arity, found: kids.len() })))
				} else {
					first = kids.first() ?? state.col
					Ok({ col: first, row: state.row, stack: state.stack.append(Tup({ parent: state.col, row: state.row, kids })) })
				}
			_ => Err(mismatch(state, "Struct"))
		}
	}

	## Focus child `index`.
	parse_tuple_next : ArrowEncoding, ArrowEncoding.State, U64, U64 -> Try(ArrowEncoding.State, [ArrowErr(CodecError)])
	parse_tuple_next = |_, state, index, _arity| match state.stack.last() {
		Ok(Tup({ row, kids, .. })) =>
			match kids.get(index) {
				Ok(child) => Ok({ ..state, col: child, row })
				Err(_) => Err(ArrowErr(ArityMismatch({ path: path_of(state), expected: index + 1, found: kids.len() })))
			}
		_ => Err(mismatch(state, "an open struct"))
	}

	## Close the tuple and focus its parent again.
	parse_tuple_end : ArrowEncoding, ArrowEncoding.State, U64 -> Try(ArrowEncoding.State, [ArrowErr(CodecError)])
	parse_tuple_end = |_, state, _arity| match state.stack.last() {
		Ok(Tup({ parent, row, .. })) => Ok({ col: parent, row, stack: state.stack.drop_last(1) })
		_ => Err(mismatch(state, "an open struct"))
	}

	## Write cursor: the builder the next value goes to.
	Out := { b : Builder }

	## A container being written: its builder with the children detached.
	Fill := { shell : Builder, kids : List(Builder), names : List(Str), next : U64 }

	## Append a NULL row.
	encode_null : ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_null = |out| Ok({ b: out.b.append_null()? })

	## Append one value to a Boolean column, through the matching `Builder` append.
	encode_bool : Bool, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_bool = |x, out| Ok({ b: out.b.append_bool(x)? })

	## Append one value to an Int8 column, through the matching `Builder` append.
	encode_i8 : I8, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_i8 = |x, out| Ok({ b: out.b.append_i8(x)? })

	## Append one value to an Int16 column, through the matching `Builder` append.
	encode_i16 : I16, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_i16 = |x, out| Ok({ b: out.b.append_i16(x)? })

	## Append one value to an Int32 column, through the matching `Builder` append.
	encode_i32 : I32, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_i32 = |x, out| Ok({ b: out.b.append_i32(x)? })

	## Append one value to an Int64 column, through the matching `Builder` append.
	encode_i64 : I64, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_i64 = |x, out| Ok({ b: out.b.append_i64(x)? })

	## Append one value to a UInt8 column, through the matching `Builder` append.
	encode_u8 : U8, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_u8 = |x, out| Ok({ b: out.b.append_u8(x)? })

	## Append one value to a UInt16 column, through the matching `Builder` append.
	encode_u16 : U16, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_u16 = |x, out| Ok({ b: out.b.append_u16(x)? })

	## Append one value to a UInt32 column, through the matching `Builder` append.
	encode_u32 : U32, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_u32 = |x, out| Ok({ b: out.b.append_u32(x)? })

	## Append one value to a UInt64 column, through the matching `Builder` append.
	encode_u64 : U64, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_u64 = |x, out| Ok({ b: out.b.append_u64(x)? })

	## Append one unscaled value to a Decimal128 column, through `Builder.append_i128`.
	encode_i128 : I128, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_i128 = |x, out| Ok({ b: out.b.append_i128(x)? })

	## Append one value to a Float32 column, through the matching `Builder` append.
	encode_f32 : F32, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_f32 = |x, out| Ok({ b: out.b.append_f32(x)? })

	## Append one value to a Float64 column, through the matching `Builder` append.
	encode_f64 : F64, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_f64 = |x, out| Ok({ b: out.b.append_f64(x)? })

	## Append a `Dec` to a Decimal32, Decimal64 or Decimal128 column; `OutOfRange` past
	## its precision.
	encode_dec : Dec, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_dec = |x, out| Ok({ b: out.b.append_dec(x)? })

	## Append a string to a Utf8, LargeUtf8 or Utf8View column; copies its bytes.
	encode_str : Str, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_str = |x, out| Ok({ b: out.b.append_str(x)? })

	## A list into List, LargeList or FixedSizeList; a `List(U8)` also into
	## Binary, LargeBinary or FixedSizeBinary.
	encode_list : ArrowEncoding.Out, U64, (ArrowEncoding.Fill, (ArrowEncoding.Fill, (ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])) -> Try(ArrowEncoding.Fill, [ArrowErr(CodecError)])) -> Try(ArrowEncoding.Fill, [ArrowErr(CodecError)])) -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_list = |out, count, write_items| {
		write_item = |fill, writer| {
			# Take the fill apart and swap the child out, so it stays unique.
			{ shell, kids, names, next } = fill
			match kids.replace(0, shell) {
				Ok({ list, prev }) => {
					written = writer({ b: prev }).map_err(|e| under(e, "[${next.to_str()}]"))?
					Ok({ shell, kids: list.set(0, written.b) ?? list, names, next: next + 1 })
				}
				Err(_) => Ok({ shell, kids, names, next: next + 1 })
			}
		}
		match out.b.data_type() {
			Binary | LargeBinary | FixedSizeBinary(_) => {
				bytes0 = Builder.new(UInt8, count).map_err(|_| ArrowErr(TypeMismatch({ path: "", expected: "UInt8", found: UInt8 })))?
				filled = write_items({ shell: bytes0, kids: [bytes0], names: [], next: 0 }, write_item)?
				gathered = (filled.kids.first() ?? bytes0).finish_host()
				bytes = match gathered.buffers.get(1) {
					Ok(U8s(xs)) => xs
					_ => []
				}
				Ok({ b: out.b.append_bytes(bytes)? })
			}
			_ => {
				{ shell: top, kids: top_kids } = out.b.take_children()
				{ shell: done, kids: done_kids, names: _, next: _ } = write_items({ shell: top, kids: top_kids, names: [], next: 0 }, write_item)?
				Ok({ b: done.put_children(done_kids).end_list()? })
			}
		}
	}

	## A record into a Struct, fields by name; a Struct field the record
	## lacks gets a null.
	encode_record : ArrowEncoding.Out, U64, (ArrowEncoding.Fill, (ArrowEncoding.Fill, Str, (ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])) -> Try(ArrowEncoding.Fill, [ArrowErr(CodecError)])) -> Try(ArrowEncoding.Fill, [ArrowErr(CodecError)])) -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_record = |out, _count, write_fields| {
		names = match out.b.data_type() {
			Struct(fs) => fs.map(|f| f.name)
			other => return Err(ArrowErr(TypeMismatch({ path: "", expected: "Struct", found: other })))
		}
		{ shell: top, kids: top_kids } = out.b.take_children()
		write_field = |fill, name, writer| {
			# Take the fill apart so the swapped-out child stays unique.
			{ shell, kids, names: known, next } = fill
			index = known.find_first_index(|n| n == name).map_err(|_| ArrowErr(UnknownField(name)))?
			swapped = kids.replace(index, shell).map_err(|_| ArrowErr(UnknownField(name)))?
			written = writer({ b: swapped.prev }).map_err(|e| under(e, name))?
			Ok({ shell, kids: swapped.list.set(index, written.b) ?? swapped.list, names: known, next })
		}
		{ shell: done, kids: done_kids, names: _, next: _ } = write_fields({ shell: top, kids: top_kids, names, next: 0 }, write_field)?
		Ok({ b: done.put_children(done_kids).end_struct()? })
	}

	## A tuple into a Struct, fields by position.
	encode_tuple : ArrowEncoding.Out, U64, (ArrowEncoding.Fill, (ArrowEncoding.Fill, (ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])) -> Try(ArrowEncoding.Fill, [ArrowErr(CodecError)])) -> Try(ArrowEncoding.Fill, [ArrowErr(CodecError)])) -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])
	encode_tuple = |out, count, write_items| {
		{ shell: top, kids: top_kids } = out.b.take_children()
		found = top_kids.len()
		if found != count {
			return Err(ArrowErr(ArityMismatch({ path: "", expected: count, found })))
		}
		write_item = |fill, writer| {
			# Take the fill apart so the swapped-out child stays unique.
			{ shell, kids, names, next } = fill
			swapped = kids.replace(next, shell).map_err(|_| ArrowErr(ArityMismatch({ path: "", expected: count, found: next })))?
			written = writer({ b: swapped.prev })?
			Ok({ shell, kids: swapped.list.set(next, written.b) ?? swapped.list, names, next: next + 1 })
		}
		{ shell: done, kids: done_kids, names: _, next: _ } = write_items({ shell: top, kids: top_kids, names: [], next: 0 }, write_item)?
		Ok({ b: done.put_children(done_kids).end_struct()? })
	}

	## Names the requirement that a value can be written to an Arrow builder.
	a.Encodable :
		where [
			a.encoder_for : ArrowEncoding -> (a, ArrowEncoding.Out -> Try(ArrowEncoding.Out, [ArrowErr(CodecError)])),
		]

	## Append one row.
	encode_row : Builder, a -> Try(Builder, [ArrowErr(CodecError)]) where [a.Encodable]
	encode_row = |b, value| {
		Shape : a
		write = Shape.encoder_for(Arrow)
		written = write(value, { b: b })?
		Ok(written.b)
	}

	## Names the requirement that a value can be read from an Arrow row.
	a.Decodable :
		where [
			a.parser_for : ArrowEncoding -> (ArrowEncoding.State -> Try({ value : a, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])),
		]

	## Read row `row` of `array` as an `a`.
	decode_row : Array, U64 -> Try(a, [ArrowErr(CodecError)]) where [a.Decodable]
	decode_row = |array, row| {
		Shape : a
		parse_shape = Shape.parser_for(Arrow)
		if row >= array.len() {
			return Err(ArrowErr(RowOutOfBounds(row)))
		}
		parsed = parse_shape({ col: array, row, stack: [] })?
		Ok(parsed.value)
	}
}

scalar : ArrowEncoding.State, Str, (Array.Body, U64 -> Try(a, [Wrong])) -> Try({ value : a, rest : ArrowEncoding.State }, [ArrowErr(CodecError)])
scalar = |state, expected, read| {
	live_row(state)?
	match read(state.col.body(), state.row) {
		Ok(value) => Ok({ value, rest: state })
		Err(Wrong) => Err(mismatch(state, expected))
	}
}

## The focused row exists and is not null.
live_row : ArrowEncoding.State -> Try({}, [ArrowErr(CodecError)])
live_row = |state|
	if state.row >= state.col.len() {
		Err(ArrowErr(RowOutOfBounds(state.row)))
	} else if !state.col.is_valid(state.row) {
		Err(ArrowErr(UnexpectedNull(path_of(state))))
	} else {
		Ok({})
	}

## Put `step` (a field name or `[i]`) in front of an error's path, the way
## decode paths read: `f1.f0[2]`.
under : [ArrowErr(CodecError)], Str -> [ArrowErr(CodecError)]
under = |ArrowErr(err), step| {
	at = |path| if (path.is_empty()) step else if (path.starts_with("[")) "${step}${path}" else "${step}.${path}"
	ArrowErr(
		match err {
			TypeMismatch({ path, expected, found }) => TypeMismatch({ path: at(path), expected, found })
			ArityMismatch({ path, expected, found }) => ArityMismatch({ path: at(path), expected, found })
			UnexpectedNull(path) => UnexpectedNull(at(path))
			InvalidUtf8(path) => InvalidUtf8(at(path))
			OutOfRange(path) => OutOfRange(at(path))
			MissingField(_) | UnknownField(_) | RowOutOfBounds(_) => err
		},
	)
}

mismatch : ArrowEncoding.State, Str -> [ArrowErr(CodecError)]
mismatch = |state, expected| ArrowErr(TypeMismatch({ path: path_of(state), expected, found: state.col.data_type() }))

## `f1.f0[2]` from the open containers.
path_of : ArrowEncoding.State -> Str
path_of = |state| state.stack.fold(
	"",
	|acc, frame| match frame {
		Rec({ next, names, .. }) => {
			name = names.get(next) ?? "?"
			if (acc.is_empty()) name else "${acc}.${name}"
		}
		Tup({ .. }) => acc
		Lst({ pos, .. }) => "${acc}[${pos.to_str()}]"
	},
)

bytes_at : Array.Body, U64 -> List(U8)
bytes_at = |b, row| match b {
	Var32(offs, data) => {
		start = (offs.get(row) ?? 0).to_u64_wrap()
		data.sublist({ start, len: (offs.get(row + 1) ?? 0).to_u64_wrap() - start })
	}
	Var64(offs, data) => {
		start = (offs.get(row) ?? 0).to_u64_wrap()
		data.sublist({ start, len: (offs.get(row + 1) ?? 0).to_u64_wrap() - start })
	}
	Views(words, datas) => {
		size = (words.get(row * 4) ?? 0).to_u64()
		if size <= 12 {
			[words.get(row * 4 + 1) ?? 0, words.get(row * 4 + 2) ?? 0, words.get(row * 4 + 3) ?? 0]
				.join_map(|x| [x.to_u8_wrap(), x.shr_zf_wrap(8).to_u8_wrap(), x.shr_zf_wrap(16).to_u8_wrap(), x.shr_zf_wrap(24).to_u8_wrap()])
				.take_first(size)
		} else {
			index = (words.get(row * 4 + 2) ?? 0).to_u64()
			start = (words.get(row * 4 + 3) ?? 0).to_u64()
			(datas.get(index) ?? []).sublist({ start, len: size })
		}
	}
	Fixed(w, bytes) => bytes.sublist({ start: row * w, len: w })
	_ => []
}
