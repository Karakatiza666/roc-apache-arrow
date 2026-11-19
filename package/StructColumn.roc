import Array
import DataType exposing [Field]
import Validity

## A zero-copy view of a Struct column: its fields and child arrays, each
## sliced to the struct's rows. A null struct row says nothing about its
## children's rows.
StructColumn :: { fields : List(Field), kids : List(Array), rows : U64, valid : Validity }.{

	## The view of a Struct array. O(1), no copy. Refuses any other type.
	from_array : Array -> Try(StructColumn, [TypeMismatch(DataType)])
	from_array = |arr| match (arr.data_type(), arr.body()) {
		(Struct(fs), Children(kids)) => Ok({ fields: fs, kids, rows: arr.len(), valid: arr.validity() })
		_ => Err(TypeMismatch(arr.data_type()))
	}

	## The row count. O(1).
	len : StructColumn -> U64
	len = |col| col.rows

	## Whether row `row` holds a value. False past the end.
	is_valid : StructColumn, U64 -> Bool
	is_valid = |col, row| row < col.rows and col.valid.is_valid(row)

	## The validity, at the column's bit offset. O(1), no copy.
	validity : StructColumn -> Validity
	validity = |col| col.valid

	## The fields, in child order.
	fields : StructColumn -> List(Field)
	fields = |col| col.fields

	## The child column with this field name.
	column : StructColumn, Str -> Try(Array, [NotFound(Str)])
	column = |col, name| {
		found = col.fields.find_first_index(|f| f.name == name).map_err(|_| NotFound(name))?
		col.kids.get(found).map_err(|_| NotFound(name))
	}

	## Child `index` (0-based), sliced to the struct's rows. `OutOfBounds` past the last
	## field.
	column_at : StructColumn, U64 -> Try(Array, [OutOfBounds])
	column_at = |col, index| col.kids.get(index)
}

import Host
import PrimitiveColumn

# A struct's offset slices its children.
expect {
	a = { length: 3, null_count: 0, offset: 0, buffers: [Absent, I32s([1, 2, 3])], children: [], dictionary: [] }
	b = { length: 3, null_count: 0, offset: 0, buffers: [Absent, F64s([0.5, 1.5, 2.5])], children: [], dictionary: [] }
	host = { length: 2, null_count: 0, offset: 1, buffers: [Absent], children: [a, b], dictionary: [] }
	dt = Struct([DataType.field("f0", Int32, Bool.False), DataType.field("f1", Float64, Bool.True)])
	arr = Array.from_host(host, dt) ?? crash "import"
	col = StructColumn.from_array(arr) ?? crash "type"
	f1 = col.column("f1") ?? crash "f1"
	PrimitiveColumn.f64(f1).map_ok(|c| c.values()) == Ok([1.5, 2.5]) and col.column("f9").is_err()
}

struct_type : DataType
struct_type = Struct([DataType.field("f0", Int32, Bool.False), DataType.field("f1", Float64, Bool.True)])

# Rows from 1: { 1, 1.5 }, NULL over { 2, 2.5 }, { 3, 3.5 }. Validity bits past
# the last row are set.
struct_host : Host.Array
struct_host = {
	length: 3,
	null_count: 1,
	offset: 1,
	buffers: [U8s([0xFB])],
	children: [
		{ length: 4, null_count: 0, offset: 0, buffers: [Absent, I32s([0, 1, 2, 3])], children: [], dictionary: [] },
		{ length: 4, null_count: 0, offset: 0, buffers: [Absent, F64s([0.5, 1.5, 2.5, 3.5])], children: [], dictionary: [] },
	],
	dictionary: [],
}

struct_col : StructColumn
struct_col = StructColumn.from_array(Array.from_host(struct_host, struct_type) ?? crash "import") ?? crash "type"

expect struct_col.len() == 3 and struct_col.fields().map(|f| f.name) == ["f0", "f1"] and Struct(struct_col.fields()) == struct_type

# A NULL struct row leaves its children's rows as they are.
expect {
	f0 = struct_col.column_at(0) ?? crash "f0"
	f1 = struct_col.column_at(1) ?? crash "f1"
	PrimitiveColumn.i32(f0).map_ok(|c| c.values()) == Ok([1, 2, 3]) and f0.is_valid(1) and PrimitiveColumn.f64(f1).map_ok(|c| c.values()) == Ok([1.5, 2.5, 3.5])
}

expect struct_col.column_at(2).is_err()

expect struct_col.is_valid(0) and !struct_col.is_valid(1) and struct_col.is_valid(2) and !struct_col.is_valid(3)

expect struct_col.validity().null_count(3) == 1 and !struct_col.validity().is_valid(1)

# A slice of a slice cuts the validity and every child.
expect {
	arr = Array.from_host(struct_host, struct_type) ?? crash "import"
	col = StructColumn.from_array(arr.slice(1, 2).slice(1, 1)) ?? crash "type"
	f0 = col.column_at(0) ?? crash "f0"
	f1 = col.column("f1") ?? crash "f1"
	col.len() == 1 and col.is_valid(0) and PrimitiveColumn.i32(f0).map_ok(|c| c.values()) == Ok([3]) and PrimitiveColumn.f64(f1).map_ok(|c| c.values()) == Ok([3.5])
}

expect {
	match StructColumn.from_array(Array.from_i32s([1])) {
		Err(TypeMismatch(Int32)) => Bool.True
		_ => Bool.False
	}
}

# A short or missing child is refused at import.
expect Array.from_host({ ..struct_host, length: 4 }, struct_type).is_err()
expect Array.from_host({ ..struct_host, children: struct_host.children.take_first(1) }, struct_type).is_err()
