## Tests for Probe and Shape. Run: roc test package/tests.roc
ProbeTest :: []

import DataType
import Probe
import Shape

Row : { f0 : I64, f1 : Try(Str, [Null]), f2 : List(Try(F64, [Null])), f3 : { a : Bool, b : List(U8) }, f4 : (I32, Dec) }

row_shape : Try(Shape.Slot, _)
row_shape = Probe.shape_of(Row.parser_for(Probe.Shapes))

# The probe finds every field, nested nullability, lists and tuples.
expect {
	slot = row_shape ?? crash "probe"
	slot.shape.to_data_type()
		== Struct([
			DataType.field("f0", Int64, Bool.False),
			DataType.field("f1", Utf8, Bool.True),
			DataType.field("f2", DataType.list_of(Float64), Bool.False),
			DataType.field("f3", Struct([DataType.field("a", Boolean, Bool.False), DataType.field("b", Binary, Bool.False)]), Bool.False),
			DataType.field("f4", Struct([DataType.field("f0", Int32, Bool.False), DataType.field("f1", Decimal128({ precision: 38, scale: 18 }), Bool.False)]), Bool.False),
		])
}

# A nullable inside a nullable takes one more probe round.
expect {
	Deep : Try(List(Try(List(Try(I64, [Null])), [Null])), [Null])
	got = Probe.shape_of(Deep.parser_for(Probe.Shapes))
	got.map_ok(|s| s.shape.to_data_type())
		== Ok(List(DataType.field("item", List(DataType.field("item", Int64, Bool.True)), Bool.True)))
		and got.map_ok(|s| s.nullable) == Ok(Bool.True)
}

declared : DataType.Field
declared = DataType.field(
	"args",
	Struct([
		DataType.field("f0", Timestamp(Microsecond, ""), Bool.False),
		DataType.field("f1", Utf8View, Bool.True),
		DataType.field("f2", DataType.list_of(Float64), Bool.False),
		DataType.field("f3", Struct([DataType.field("a", Boolean, Bool.False), DataType.field("b", FixedSizeBinary(16), Bool.False)]), Bool.False),
		DataType.field("f4", Struct([DataType.field("x", Int32, Bool.False), DataType.field("y", Decimal128({ precision: 10, scale: 2 }), Bool.False)]), Bool.False),
		DataType.field("extra", Int8, Bool.True),
	]),
	Bool.False,
)

# Physical matching: I64 reads Timestamp, Str reads Utf8View, List(U8) reads
# FixedSizeBinary, Dec reads Decimal128(10, 2), a tuple reads by position.
expect {
	slot = row_shape ?? crash "probe"
	Shape.check_input(slot, declared) == Ok({})
}

# An extra NOT NULL column is fine for reading, not for writing.
expect {
	slot = row_shape ?? crash "probe"
	strict = { ..declared, data_type: Struct(DataType.children(declared.data_type).append(DataType.field("must", Int8, Bool.False))) }
	Shape.check_input(slot, strict).is_ok() and Shape.check_output(slot, strict).is_err()
}

# A nullable column needs a Try(_, [Null]) slot to be read.
expect {
	got = Probe.shape_of(I64.parser_for(Probe.Shapes)) ?? crash "probe"
	Shape.check_input(got, DataType.field("x", Int64, Bool.True)) == Err(ShapeMismatch("at 'x': the column is nullable, the Roc type is not Try(_, [Null])"))
}

expect {
	got = Probe.shape_of(I64.parser_for(Probe.Shapes)) ?? crash "probe"
	Shape.check_input(got, DataType.field("x", Int32, Bool.False)).is_err()
}

# Every scalar width gets its own Arrow type.
expect {
	Widths : { a : I8, b : I16, c : U16, d : U32, e : U64, g : I128, h : F32 }
	got = Probe.shape_of(Widths.parser_for(Probe.Shapes)) ?? crash "probe"
	got.shape.to_data_type()
		== Struct([
			DataType.field("a", Int8, Bool.False),
			DataType.field("b", Int16, Bool.False),
			DataType.field("c", UInt16, Bool.False),
			DataType.field("d", UInt32, Bool.False),
			DataType.field("e", UInt64, Bool.False),
			DataType.field("g", Decimal128({ precision: 38, scale: 0 }), Bool.False),
			DataType.field("h", Float32, Bool.False),
		])
}
