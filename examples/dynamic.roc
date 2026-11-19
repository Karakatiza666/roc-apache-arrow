app [main!] {
	arrow: "../package/main.roc",
}

import arrow.ArrowEncoding
import arrow.Builder
import arrow.CodecError
import arrow.DataType
import arrow.PrimitiveColumn

# The dynamic API: a column type known only at run time. Each value is
# copied, so this path is for tools and tests, not for a batch loop.

Row : { id : I64, name : Str, score : Try(I64, [Null]), tags : List(Str) }

# The same record with numbers where the column holds text.
BadRow : { id : I64, name : Str, score : Try(I64, [Null]), tags : List(I64) }

row_type : DataType
row_type = Struct([
	DataType.field("id", Int64, Bool.False),
	DataType.field("name", Utf8, Bool.False),
	DataType.field("score", Int64, Bool.True),
	DataType.field("tags", DataType.list_of(Utf8), Bool.False),
])

# Encode Roc records into a Struct builder, then decode them back.
round_trip : List(Row) -> Try(List(Row), _)
round_trip = |rows| {
	var $b = Builder.new(row_type, rows.len())?
	for r in rows {
		$b = ArrowEncoding.encode_row($b, r)?
	}
	batch = $b.finish()?
	var $out : List(Row)
	var $out = List.with_capacity(batch.len())
	for i in (0.U64).until(batch.len()) {
		$out = $out.append(ArrowEncoding.decode_row(batch, i)?)
	}
	Ok($out)
}

# One typed append per value: a Dec rounds to the column's scale.
prices : List(Dec) -> Try(List(I64), _)
prices = |values| {
	var $b = Builder.new(Decimal64({ precision: 10, scale: 2 }), values.len())?
	for v in values {
		$b = $b.append_dec(v)?
	}
	Ok(PrimitiveColumn.i64($b.finish()?)?.values())
}

main! = |_args| {
	rows : List(Row)
	rows = [{ id: 1, name: "a", score: Ok(10), tags: ["x", "y"] }, { id: 2, name: "b", score: Err(Null), tags: [] }]
	back = round_trip(rows)?
	echo!("decoded: ${Str.inspect(back)}\n")
	cents = prices([1.25, 0.5, 3.999])?
	echo!("Decimal64(10, 2) unscaled: ${Str.inspect(cents)}\n")
	# A wrong type is refused with the path of the value.
	wrong : BadRow
	wrong = { id: 1, name: "c", score: Ok(1), tags: [7] }
	bad = ArrowEncoding.encode_row(Builder.new(row_type, 1)?, wrong)
	msg = match bad {
		Err(ArrowErr(e)) => CodecError.to_str(e)
		Ok(_) => "no error"
	}
	echo!("encode error: ${msg}\n")
	# CI runs the examples, so a wrong result fails the run.
	if (back == rows and cents == [125, 50, 400] and msg == "at 'tags[0]': expected Int64, found Utf8") Ok({}) else Err(WrongResult)
}
