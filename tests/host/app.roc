# The Roc side of the host conformance test (scripts/test-host.sh). The
# schema name picks the step; the schema format gives the column type.
app [run] {
	arrow: "../../package/main.roc",
	pf: platform "platform/main.roc",
}

import arrow.Array
import arrow.Host
import arrow.PrimitiveColumn
import arrow.Schema
import arrow.Utf8Column
import arrow.Writer

run : Host.Array, Host.Schema -> Host.Array
run = |input, schema| match step(input, schema) {
	Ok(out) => out
	Err(e) => crash "host test step failed: ${Str.inspect(e)}"
}

step : Host.Array, Host.Schema -> Try(Host.Array, _)
step = |input, schema| {
	name = Str.from_utf8_lossy(schema.name)
	# The input is consumed: "drop" is how the host releases a result.
	if name == "drop" {
		return Ok(Host.empty_array(0))
	}
	field = Schema.field_from_host(schema)?
	arr = Array.from_host(input, field.data_type)?
	match name {
		# Rows 1 .. end of the input, with no copy of the values.
		"pass" => Ok(arr.slice(1, arr.len()).to_host())
		"sum_i64" => {
			col = PrimitiveColumn.i64(arr)?
			var $sum = 0.I64
			for i in (0.U64).until(col.len()) {
				if col.is_valid(i) {
					$sum = $sum + col.at(i, 0)
				}
			}
			Ok(Writer.prim_finish(Writer.prim_push(Writer.prim(1), $sum), [], |xs| I64s(xs)))
		}
		"sum_i128" => {
			col = PrimitiveColumn.i128(arr)?
			var $sum = 0.I128
			for i in (0.U64).until(col.len()) {
				if col.is_valid(i) {
					$sum = $sum + col.at(i, 0)
				}
			}
			Ok(Writer.prim_finish(Writer.prim_push(Writer.prim(1), $sum), [], |xs| I128s(xs)))
		}
		"double_i64" => {
			col = PrimitiveColumn.i64(arr)?
			var $w = Writer.prim(col.len())
			for i in (0.U64).until(col.len()) {
				$w = if (col.is_valid(i)) Writer.prim_push($w, col.at(i, 0) * 2) else Writer.prim_null($w, 0)
			}
			Ok(Writer.prim_finish($w, [], |xs| I64s(xs)))
		}
		"repeat_utf8" => {
			col = Utf8Column.from_array(arr)?
			var $w = Writer.varlen(col.len(), col.data_len() * 2)
			for i in (0.U64).until(col.len()) {
				$w = if (col.is_valid(i)) Writer.str_push($w, Str.concat(col.at(i), col.at(i))) else Writer.var_null($w)
			}
			Ok(Writer.var_finish($w, []))
		}
		_ => Err(UnknownStep(name))
	}
}
