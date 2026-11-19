## One host round trip, the way a host function library uses the package: bind (schema
## in, probe, check), then call (arrays in, zero-copy views, one typed writer,
## exported with zero copy). Run: roc test package/tests.roc
FlowTest :: []

import Array
import DataType
import Host
import PrimitiveColumn
import Probe
import Schema
import Shape
import Utf8Column
import Writer

Args : { f0 : Try(I64, [Null]), f1 : Str }

Out : Try(I64, [Null])

# What the host passes: one `+s` schema with a child per parameter.
host_args_schema : Host.Schema
host_args_schema = {
	format: "+s".to_utf8(),
	name: [],
	metadata: [],
	flags: 0,
	children: [
		{ format: "l".to_utf8(), name: "f0".to_utf8(), metadata: [], flags: Host.flag_nullable, children: [], dictionary: [] },
		{ format: "u".to_utf8(), name: "f1".to_utf8(), metadata: [], flags: 0, children: [], dictionary: [] },
	],
	dictionary: [],
}

result_field : DataType.Field
result_field = DataType.field("result", Int64, Bool.True)

bind : Host.Schema -> Try(Schema, _)
bind = |args_schema| {
	schema = Schema.from_host(args_schema)?
	args_shape = Probe.shape_of(Args.parser_for(Probe.Shapes))?
	Shape.check_input(args_shape, DataType.field("args", schema.to_data_type(), Bool.False))?
	out_shape = Probe.shape_of(Out.parser_for(Probe.Shapes))?
	Shape.check_output(out_shape, result_field)?
	Ok(schema)
}

# The function: string length plus f0, null when f0 is null. Each row is
# read from the views on demand and written once into the result buffer.
call : Schema, List(Host.Array) -> Try(Host.Array, _)
call = |schema, args| {
	cols = List.map2(schema.fields, args, |f, a| Array.from_host(a, f.data_type)).map_try(|r| r)?
	f0 = PrimitiveColumn.i64(cols.get(0)?)?
	f1 = Utf8Column.from_array(cols.get(1)?)?
	rows = f0.len()
	var $w = Writer.prim(rows)
	for i in (0.U64).until(rows) {
		$w =
			if f0.is_valid(i) {
				Writer.prim_push($w, f0.at(i, 0) + f1.at(i).count_utf8_bytes().to_i64_wrap())
			} else {
				Writer.prim_null($w, 0)
			}
	}
	Ok(Writer.prim_finish($w, [], |xs| I64s(xs)))
}

expect {
	schema = bind(host_args_schema) ?? crash "bind"
	f0 = { length: 3, null_count: 1, offset: 0, buffers: [U8s([0b101]), I64s([10, 0, 30])], children: [], dictionary: [] }
	f1 = Array.from_strs(["a", "bb", "ccc"]).to_host()
	out = call(schema, [f0, f1]) ?? crash "call"
	back = Array.from_host(out, Int64) ?? crash "export"
	PrimitiveColumn.i64(back).map_ok(|c| c.iter().collect()) == Ok([Ok(11), Err(Null), Ok(33)])
}

# Bind refuses a Roc type that cannot read the declared column.
expect {
	wrong = { ..host_args_schema, children: host_args_schema.children.map(|c| { ..c, format: "i".to_utf8() }) }
	bind(wrong).is_err()
}
