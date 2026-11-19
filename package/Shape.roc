import DataType exposing [Field]

## The Arrow-relevant shape of a Roc type, as `Probe` derives it from the
## type's `parser_for`. A slot is nullable when the Roc type there is
## `Try(_, [Null])`.
Shape := [
	## The canonical type of a scalar parse op (`parse_i64` gives Int64).
	Scalar(DataType),

	## `Dec`: reads any Decimal column.
	Dec,
	List(Shape.Slot),
	Record(List({ name : Str, slot : Shape.Slot })),
	Tuple(List(Shape.Slot)),

	## Never descended into. Only seen when a probe stops early.
	Unknown,
].{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## A shape and whether the Roc type there is `Try(_, [Null])`.
	Slot : { shape : Shape, nullable : Bool }

	## The Arrow type a writer of this shape produces by default:
	## `List(U8)` gives Binary, `Dec` gives Decimal128(38, 18), a tuple gives a
	## Struct of `f0`, `f1`, ... fields.
	to_data_type : Shape -> DataType
	to_data_type = |shape| match shape {
		Scalar(dt) => dt
		Dec => Decimal128({ precision: 38, scale: 18 })
		List({ shape: Scalar(UInt8), nullable: Bool.False }) => Binary
		List(slot) => List(DataType.field("item", slot.shape.to_data_type(), slot.nullable))
		Record(fields) => Struct(fields.map(|f| DataType.field(f.name, f.slot.shape.to_data_type(), f.slot.nullable)))
		Tuple(slots) => Struct(slots.map_with_index(|s, i| DataType.field("f${i.to_str()}", s.shape.to_data_type(), s.nullable)))
		Unknown => Null
	}

	## Can a Roc value of this shape read every value of this column?
	## A nullable column needs a nullable slot.
	check_input : Shape.Slot, Field -> Try({}, [ShapeMismatch(Str)])
	check_input = |slot, field| check(Input, slot, field, field.name)

	## Can this column hold every value of this shape? A nullable slot needs a
	## nullable column; a Struct field the record lacks must be nullable.
	check_output : Shape.Slot, Field -> Try({}, [ShapeMismatch(Str)])
	check_output = |slot, field| check(Output, slot, field, field.name)
}

check : [Input, Output], Shape.Slot, Field, Str -> Try({}, [ShapeMismatch(Str)])
check = |dir, slot, field, path| {
	fail = |why| Err(ShapeMismatch("at '${path}': ${why}"))
	match dir {
		Input if field.nullable and !slot.nullable => return fail("the column is nullable, the Roc type is not Try(_, [Null])")
		Output if slot.nullable and !field.nullable => return fail("the Roc type can be null, the column is NOT NULL")
		_ => {}
	}
	dt = field.data_type
	match slot.shape {
		Unknown => Ok({})
		Dec =>
			match dt {
				Decimal32(_) | Decimal64(_) | Decimal128(_) => Ok({})
				_ => fail("Dec needs a Decimal column, found ${Str.inspect(dt)}")
			}
		Scalar(want) => if (physical(want) == physical(dt)) Ok({}) else fail("${physical(want)} does not match ${Str.inspect(dt)}")
		List(item) =>
			if item.shape == Scalar(UInt8) and !item.nullable and is_binary(dt) {
				Ok({})
			} else {
				match dt {
					List(child) | LargeList(child) | FixedSizeList(child, _) | Map(child, _) => check(dir, item, child, "${path}[]")
					_ => fail("a list does not match ${Str.inspect(dt)}")
				}
			}
		Record(fields) =>
			match dt {
				Struct(columns) => {
					for f in fields {
						match columns.find_first(|c| c.name == f.name) {
							Ok(column) => check(dir, f.slot, column, "${path}.${f.name}")?
							Err(_) => return fail("no column '${f.name}'")
						}
					}
					if dir == Output {
						for c in columns {
							if !c.nullable and !fields.any(|f| f.name == c.name) {
								return fail("the record has no field for NOT NULL column '${c.name}'")
							}
						}
					}
					Ok({})
				}
				_ => fail("a record needs a Struct column, found ${Str.inspect(dt)}")
			}
		Tuple(slots) =>
			match dt {
				Struct(columns) if columns.len() == slots.len() => {
					for i in (0.U64).until(slots.len()) {
						s = slots.get(i) ?? { shape: Unknown, nullable: Bool.True }
						c = columns.get(i) ?? field
						check(dir, s, c, "${path}.${i.to_str()}")?
					}
					Ok({})
				}
				_ => fail("a ${slots.len().to_str()}-tuple needs a Struct of ${slots.len().to_str()} columns")
			}
	}
}

is_binary : DataType -> Bool
is_binary = |dt| match dt {
	Binary | LargeBinary | BinaryView | FixedSizeBinary(_) => Bool.True
	_ => Bool.False
}

## The physical layout class: types with one class share a Roc parse op.
physical : DataType -> Str
physical = |dt| match dt {
	Int32 | Date32 | Time32(_) | Interval(YearMonth) | Decimal32(_) => "i32"
	Int64 | Date64 | Time64(_) | Timestamp(_, _) | Duration(_) | Decimal64(_) => "i64"
	Utf8 | LargeUtf8 | Utf8View => "utf8"
	Decimal128(_) => "i128"
	other => Str.inspect(other)
}
