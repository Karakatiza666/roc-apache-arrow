app [main!] {
	arrow: "../package/main.roc",
}

import arrow.Array
import arrow.DataType
import arrow.Host
import arrow.Items
import arrow.ListColumn
import arrow.PrimitiveColumn
import arrow.Writer

# A List(Int64) column from a host: rows [1, 2, 3], [], NULL, [4, 5]. The
# offsets give each row's range in the child; validity bits 0b1011 make
# row 2 NULL.
child : Host.Array
child = { length: 5, null_count: 0, offset: 0, buffers: [Absent, I64s([1, 2, 3, 4, 5])], children: [], dictionary: [] }

lists : Host.Array
lists = { length: 4, null_count: 1, offset: 0, buffers: [U8s([0b1011]), I32s([0, 3, 3, 3, 5])], children: [child], dictionary: [] }

# An `Items` source over the child column. `iter_range` returns a slice
# iterator of the values list, so a row's items are read with no copy.
Ints := { col : PrimitiveColumn(I64) }.{
	item_at : Ints, U64 -> I64
	item_at = |src, j| src.col.at(j, 0)

	iter_range : Ints, U64, U64 -> Iter(I64)
	iter_range = |src, start, count| src.col.values().sublist({ start, len: count }).iter()
}

# The sum of each row, NULL for a NULL row.
row_sums : Host.Array -> Try(Host.Array, _)
row_sums = |host| {
	col = ListColumn.from_array(Array.from_host(host, DataType.list_of(Int64))?)?
	src : Ints
	src = { col: PrimitiveColumn.i64(col.values())? }
	rows = col.len()
	var $w = Writer.prim(rows)
	for i in (0.U64).until(rows) {
		$w =
			if col.is_valid(i) {
				r = col.range_at(i)
				items = Items.view(src, r.start, r.len)
				# `fold` reads every item with no early exit; see the README on loops.
				Writer.prim_push($w, items.iter().fold(0, |acc, x| acc + x))
			} else {
				Writer.prim_null($w, 0)
			}
	}
	Ok(Writer.prim_finish($w, [], |xs| I64s(xs)))
}

main! = |_args| {
	out = row_sums(lists)?
	sums : List(Try(I64, [Null]))
	sums = PrimitiveColumn.i64(Array.from_host(out, Int64)?)?.iter().collect()
	echo!("row sums: ${Str.inspect(sums)}\n")
	# CI runs the examples, so a wrong result fails the run.
	if (sums == [Ok(6), Ok(0), Err(Null), Ok(9)]) Ok({}) else Err(WrongResult)
}
