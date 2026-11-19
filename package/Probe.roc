import CodecError
import DataType
import Shape

## A format that runs a type's derived `parser_for` without data and records
## each operation it asks for, giving the type's `Shape`. A host checks it
## against a declared schema before any row arrives:
##
##     shape = Probe.shape_of(Row.parser_for(Probe.Shapes))?
##     Shape.check_input({ shape, nullable: Bool.False }, declared)?
##
## `parse_null` first answers "null" for a position it has not seen, which
## hides the value's type; the probe then reruns with that position marked,
## so the run count is the nesting depth of `Try(_, [Null])` plus one.
Probe := [Shapes].{

	## The probe state: the open containers and the nullable positions found so far.
	State := { frames : List(Probe.Frame), known : List(Str), found : List(Str) }

	## An open slot: the root, a record, a tuple or a list.
	Frame := [
		Root(Shape.Slot),
		Rec({ path : Str, names : List(Str), fields : List({ name : Str, slot : Shape.Slot }) }),
		Tup({ path : Str, slots : List(Shape.Slot) }),
		Lst({ path : Str }),
	]

	## The error of a missing field.
	missing_field : Probe, Str -> [ProbeErr(Str)]
	missing_field = |_, name| ProbeErr("missing field ${name}")

	## The error of a value no shape accepts.
	invalid_value : Probe, Probe.State -> [ProbeErr(Str)]
	invalid_value = |_, _| ProbeErr("invalid value")

	## Field names are used as written.
	rename_field : Probe, Str -> Str
	rename_field = |_, name| name

	## Skipping a field records nothing.
	skip_record_field : Probe, Probe.State -> Try(Probe.State, [ProbeErr(Str)])
	skip_record_field = |_, state| Ok(state)

	## Answers NULL at a position it has not seen, and marks it; `shape_of` then reruns
	## so the parser descends there.
	parse_null : Probe, Probe.State -> Try(Probe.State, [ProbeErr(Str)])
	parse_null = |_, state| {
		path = slot_path(state)
		if state.known.contains(path) {
			# Seen before: say "not null" so the parser descends.
			Err(ProbeErr("descend"))
		} else {
			Ok(emit({ ..state, found: state.found.append(path) }, Unknown))
		}
	}

	## Records `Scalar(Boolean)` at this slot.
	parse_bool : Probe, Probe.State -> Try({ value : Bool, rest : Probe.State }, [ProbeErr(Str)])
	parse_bool = |_, state| Ok({ value: Bool.False, rest: emit(state, Scalar(Boolean)) })

	## Records `Scalar(Int8)` at this slot.
	parse_i8 : Probe, Probe.State -> Try({ value : I8, rest : Probe.State }, [ProbeErr(Str)])
	parse_i8 = |_, state| Ok({ value: 0, rest: emit(state, Scalar(Int8)) })

	## Records `Scalar(Int16)` at this slot.
	parse_i16 : Probe, Probe.State -> Try({ value : I16, rest : Probe.State }, [ProbeErr(Str)])
	parse_i16 = |_, state| Ok({ value: 0, rest: emit(state, Scalar(Int16)) })

	## Records `Scalar(Int32)` at this slot.
	parse_i32 : Probe, Probe.State -> Try({ value : I32, rest : Probe.State }, [ProbeErr(Str)])
	parse_i32 = |_, state| Ok({ value: 0, rest: emit(state, Scalar(Int32)) })

	## Records `Scalar(Int64)` at this slot.
	parse_i64 : Probe, Probe.State -> Try({ value : I64, rest : Probe.State }, [ProbeErr(Str)])
	parse_i64 = |_, state| Ok({ value: 0, rest: emit(state, Scalar(Int64)) })

	## Records `Scalar(UInt8)` at this slot.
	parse_u8 : Probe, Probe.State -> Try({ value : U8, rest : Probe.State }, [ProbeErr(Str)])
	parse_u8 = |_, state| Ok({ value: 0, rest: emit(state, Scalar(UInt8)) })

	## Records `Scalar(UInt16)` at this slot.
	parse_u16 : Probe, Probe.State -> Try({ value : U16, rest : Probe.State }, [ProbeErr(Str)])
	parse_u16 = |_, state| Ok({ value: 0, rest: emit(state, Scalar(UInt16)) })

	## Records `Scalar(UInt32)` at this slot.
	parse_u32 : Probe, Probe.State -> Try({ value : U32, rest : Probe.State }, [ProbeErr(Str)])
	parse_u32 = |_, state| Ok({ value: 0, rest: emit(state, Scalar(UInt32)) })

	## Records `Scalar(UInt64)` at this slot.
	parse_u64 : Probe, Probe.State -> Try({ value : U64, rest : Probe.State }, [ProbeErr(Str)])
	parse_u64 = |_, state| Ok({ value: 0, rest: emit(state, Scalar(UInt64)) })

	## Records `Scalar(Decimal128(38, 0))` at this slot.
	parse_i128 : Probe, Probe.State -> Try({ value : I128, rest : Probe.State }, [ProbeErr(Str)])
	parse_i128 = |_, state| Ok({ value: 0, rest: emit(state, Scalar(Decimal128({ precision: 38, scale: 0 }))) })

	## Records `Scalar(Float32)` at this slot.
	parse_f32 : Probe, Probe.State -> Try({ value : F32, rest : Probe.State }, [ProbeErr(Str)])
	parse_f32 = |_, state| Ok({ value: 0, rest: emit(state, Scalar(Float32)) })

	## Records `Scalar(Float64)` at this slot.
	parse_f64 : Probe, Probe.State -> Try({ value : F64, rest : Probe.State }, [ProbeErr(Str)])
	parse_f64 = |_, state| Ok({ value: 0, rest: emit(state, Scalar(Float64)) })

	## Records `Dec` at this slot: it reads any Decimal column.
	parse_dec : Probe, Probe.State -> Try({ value : Dec, rest : Probe.State }, [ProbeErr(Str)])
	parse_dec = |_, state| Ok({ value: 0, rest: emit(state, Dec) })

	## Records `Scalar(Utf8)` at this slot.
	parse_str : Probe, Probe.State -> Try({ value : Str, rest : Probe.State }, [ProbeErr(Str)])
	parse_str = |_, state| Ok({ value: "", rest: emit(state, Scalar(Utf8)) })

	## Counted(1) forces exactly one descent into the item type; the list
	## frame closes when that item arrives.
	parse_list_start : Probe, Probe.State -> Try([Counted({ len : U64, rest : Probe.State }), Uncounted(Probe.State)], [ProbeErr(Str)])
	parse_list_start = |_, state| Ok(Counted({ len: 1, rest: { ..state, frames: state.frames.append(Lst({ path: "${slot_path(state)}[]" })) } }))

	## Never reached: lists are Counted. The driver still needs the methods.
	parse_list_next : Probe, Probe.State -> Try([Item(Probe.State), Done(Probe.State)], [ProbeErr(Str)])
	parse_list_next = |_, state| Ok(Done(state))

	## Never reached: lists are Counted.
	parse_list_after_item : Probe, Probe.State -> Try([Continue(Probe.State), Done(Probe.State)], [ProbeErr(Str)])
	parse_list_after_item = |_, state| Ok(Done(state))

	## Open a record slot.
	parse_record_start : Probe, Probe.State -> Try([Counted({ len : U64, rest : Probe.State }), Uncounted(Probe.State)], [ProbeErr(Str)])
	parse_record_start = |_, state| Ok(Uncounted({ ..state, frames: state.frames.append(Rec({ path: slot_path(state), names: [], fields: [] })) }))

	## Hand the derived parser the next field name and record it.
	parse_record_field : Probe,
	Encoding.FieldName.FieldNames(_shape),
	Probe.State -> Try(
		[
			Field({ field : Encoding.FieldName(_shape), rest : Probe.State }),
			TryField({ name : Str, rest : Probe.State }),
			TryFieldCaseless({ name : Str, rest : Probe.State }),
			Continue(Probe.State),
			Done(Probe.State),
		],
		[ProbeErr(Str)],
	)
	parse_record_field = |_, field_names, state| match state.frames.last() {
		Ok(Rec(frame)) => {
			names = if (frame.fields.is_empty()) field_names.iter().map(|n| n.name()).collect() else frame.names
			opened = { ..state, frames: state.frames.drop_last(1).append(Rec({ ..frame, names })) }
			match names.get(frame.fields.len()) {
				Ok(name) => Ok(TryField({ name, rest: opened }))
				Err(_) => Ok(Done(close_record(opened)))
			}
		}
		_ => Err(ProbeErr("no open record"))
	}

	## Continue until every field has a shape, then record the `Record`.
	parse_record_after_field : Probe, Probe.State -> Try([Continue(Probe.State), Done(Probe.State)], [ProbeErr(Str)])
	parse_record_after_field = |_, state| match state.frames.last() {
		Ok(Rec(frame)) => if (frame.fields.len() < frame.names.len()) Ok(Continue(state)) else Ok(Done(close_record(state)))
		_ => Err(ProbeErr("no open record"))
	}

	## Open a tuple slot.
	parse_tuple_start : Probe, Probe.State, U64 -> Try(Probe.State, [ProbeErr(Str)])
	parse_tuple_start = |_, state, _arity| Ok({ ..state, frames: state.frames.append(Tup({ path: slot_path(state), slots: [] })) })

	## Records nothing: the item's own parse fills the next slot.
	parse_tuple_next : Probe, Probe.State, U64, U64 -> Try(Probe.State, [ProbeErr(Str)])
	parse_tuple_next = |_, state, _index, _arity| Ok(state)

	## Close the tuple and record its `Tuple` shape.
	parse_tuple_end : Probe, Probe.State, U64 -> Try(Probe.State, [ProbeErr(Str)])
	parse_tuple_end = |_, state, _arity| match state.frames.last() {
		Ok(Tup({ slots, .. })) => Ok(emit({ ..state, frames: state.frames.drop_last(1) }, Tuple(slots)))
		_ => Err(ProbeErr("no open tuple"))
	}

	## The shape of the type whose probe parser this is:
	## `Probe.shape_of(Row.parser_for(Probe.Shapes))`.
	shape_of : (Probe.State -> Try({ value : a, rest : Probe.State }, [ProbeErr(Str)])) -> Try(Shape.Slot, [ProbeErr(Str)])
	shape_of = |parse| {
		var $known = []
		# Each round marks at least one more nullable position; 64 rounds is
		# far past any real nesting depth.
		for _ in (0.U64).until(64) {
			start = { frames: [Root({ shape: Unknown, nullable: Bool.False })], known: $known, found: [] }
			parsed = parse(start)?
			if parsed.rest.found.is_empty() {
				return match parsed.rest.frames {
					[Root(slot)] => Ok(slot)
					_ => Err(ProbeErr("the parser left a container open"))
				}
			}
			$known = $known.concat(parsed.rest.found)
		}
		Err(ProbeErr("nullable nesting deeper than 64"))
	}
}

## The path of the slot the next value fills.
slot_path : Probe.State -> Str
slot_path = |state| match state.frames.last() {
	Ok(Rec({ path, names, fields })) => "${path}.${names.get(fields.len()) ?? "?"}"
	Ok(Tup({ path, slots })) => "${path}.${slots.len().to_str()}"
	Ok(Lst({ path })) => path
	_ => ""
}

## Put a finished shape in the open slot, closing list frames it completes.
emit : Probe.State, Shape -> Probe.State
emit = |state, shape| {
	path = slot_path(state)
	slot = { shape, nullable: state.known.contains(path) or state.found.contains(path) }
	rest = state.frames.drop_last(1)
	match state.frames.last() {
		Ok(Root(_)) => { ..state, frames: rest.append(Root(slot)) }
		Ok(Rec(frame)) => {
			name = frame.names.get(frame.fields.len()) ?? "?"
			{ ..state, frames: rest.append(Rec({ ..frame, fields: frame.fields.append({ name, slot }) })) }
		}
		Ok(Tup(frame)) => { ..state, frames: rest.append(Tup({ ..frame, slots: frame.slots.append(slot) })) }
		Ok(Lst(_)) => emit({ ..state, frames: rest }, List(slot))
		Err(_) => state
	}
}

close_record : Probe.State -> Probe.State
close_record = |state| match state.frames.last() {
	Ok(Rec({ fields, .. })) => emit({ ..state, frames: state.frames.drop_last(1) }, Record(fields))
	_ => state
}
