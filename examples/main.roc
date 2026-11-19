app [main!] {
	arrow: "../package/main.roc",
}

import arrow.Array
import arrow.ArrowEncoding
import arrow.DataType
import arrow.Host
import arrow.PrimitiveColumn
import arrow.Schema
import arrow.Utf8Column
import arrow.Writer

# A host gives Roc each column as a `Host.Array`. Here Roc builds them, so the
# example runs with no host: an Int64 column with a NULL in row 1 (validity
# bits 0b101), and a Utf8 column.
ints : Host.Array
ints = { length: 3, null_count: 1, offset: 0, buffers: [U8s([0b101]), I64s([10, 0, 30])], children: [], dictionary: [] }

words : Host.Array
words = Array.from_strs(["a", "bb", "ccc"]).to_host()

# Primary path: zero-copy views in, one typed writer out.
add_lengths : Host.Array, Host.Array -> Try(Host.Array, _)
add_lengths = |a, b| {
	nums = PrimitiveColumn.i64(Array.from_host(a, Int64)?)?
	text = Utf8Column.from_array(Array.from_host(b, Utf8)?)?
	rows = nums.len()
	var $w = Writer.prim(rows)
	for i in (0.U64).until(rows) {
		$w =
			if nums.is_valid(i) {
				Writer.prim_push($w, nums.at(i, 0) + text.at(i).count_utf8_bytes().to_i64_wrap())
			} else {
				Writer.prim_null($w, 0)
			}
	}
	Ok(Writer.prim_finish($w, [], |xs| I64s(xs)))
}

# Dynamic path: decode one row of a Struct into a Roc record. It copies, so it
# is for code that knows its types only at run time.
Row : { n : Try(I64, [Null]), s : Str }

first_row : Host.Array, Host.Array -> Try(Row, _)
first_row = |a, b| {
	schema = Schema.new([DataType.field("n", Int64, Bool.True), DataType.field("s", Utf8, Bool.False)])
	batch = Array.from_columns(schema, [Array.from_host(a, Int64)?, Array.from_host(b, Utf8)?])?
	ArrowEncoding.decode_row(batch, 0)
}

main! = |_args| {
	out = add_lengths(ints, words)?
	sums : List(Try(I64, [Null]))
	sums = PrimitiveColumn.i64(Array.from_host(out, Int64)?)?.iter().collect()
	echo!("add_lengths: ${Str.inspect(sums)}\n")
	row = first_row(ints, words)?
	echo!("first row: ${Str.inspect(row)}\n")
	Ok({})
}
