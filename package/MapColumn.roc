import Array
import DataType
import ListColumn
import StructColumn

## A zero-copy view of a Map column: a list of `entries { key, value }`.
## Entries keep their stored order; this view never builds a `Dict`.
MapColumn :: { entries : ListColumn, keys : Array, items : Array }.{

	## The view of a Map array. O(1), no copy. Refuses any other type, and a Map
	## whose entries are not a Struct of two children.
	from_array : Array -> Try(MapColumn, [TypeMismatch(DataType)])
	from_array = |arr| {
		match arr.data_type() {
			Map(_, _) => {}
			_ => return Err(TypeMismatch(arr.data_type()))
		}
		entries = ListColumn.from_array(arr)?
		kv = StructColumn.from_array(entries.values())?
		key_arr = kv.column_at(0).map_err(|_| TypeMismatch(arr.data_type()))?
		item_arr = kv.column_at(1).map_err(|_| TypeMismatch(arr.data_type()))?
		Ok({ entries, keys: key_arr, items: item_arr })
	}

	## The row count. O(1).
	len : MapColumn -> U64
	len = |col| col.entries.len()

	## Whether row `row` holds a value. False past the end.
	is_valid : MapColumn, U64 -> Bool
	is_valid = |col, row| col.entries.is_valid(row)

	## All keys of all rows.
	keys : MapColumn -> Array
	keys = |col| col.keys

	## All values of all rows.
	items : MapColumn -> Array
	items = |col| col.items

	## Where row `row`'s entries sit in `keys` and `items`.
	range : MapColumn, U64 -> Try({ start : U64, len : U64 }, [Null, OutOfBounds])
	range = |col, row| col.entries.range(row)
}

import Host
import PrimitiveColumn
import Utf8Column

map_type : DataType
map_type = DataType.map_of(Utf8, Int64, Bool.True)

entries_host : Host.Array
entries_host = {
	length: 7,
	null_count: 0,
	offset: 0,
	buffers: [Absent],
	children: [
		{ length: 7, null_count: 0, offset: 0, buffers: [Absent, I32s([0, 1, 2, 3, 4, 5, 6, 7]), U8s("abcdefg".to_utf8())], children: [], dictionary: [] },
		{ length: 7, null_count: 0, offset: 0, buffers: [Absent, I64s([0, 1, 2, 3, 4, 5, 6])], children: [], dictionary: [] },
	],
	dictionary: [],
}

# Rows from 1: {b: 1, c: 2}, NULL over {d: 3}, {}, {e: 4, f: 5, g: 6}.
# Validity bits past the last row are set.
map_host : Host.Array
map_host = { length: 4, null_count: 1, offset: 1, buffers: [U8s([0xFB]), I32s([0, 1, 3, 4, 4, 7])], children: [entries_host], dictionary: [] }

map_col : MapColumn
map_col = MapColumn.from_array(Array.from_host(map_host, map_type) ?? crash "import") ?? crash "type"

ranges : MapColumn -> List(Try({ start : U64, len : U64 }, [Null, OutOfBounds]))
ranges = |col| (0.U64).until(col.len() + 1).map(|i| col.range(i)).collect()

expect map_col.len() == 4

expect ranges(map_col) == [Ok({ start: 1, len: 2 }), Err(Null), Ok({ start: 4, len: 0 }), Ok({ start: 4, len: 3 }), Err(OutOfBounds)]

expect map_col.is_valid(0) and !map_col.is_valid(1) and map_col.is_valid(2) and !map_col.is_valid(4)

# Keys and items hold every entry, in stored order.
expect {
	keys = Utf8Column.from_array(map_col.keys()) ?? crash "keys"
	items = PrimitiveColumn.i64(map_col.items()) ?? crash "items"
	keys.at(1) == "b" and keys.at(6) == "g" and keys.len() == 7 and items.values() == [0, 1, 2, 3, 4, 5, 6]
}

# A slice of a slice keeps the empty map and the last map.
expect {
	arr = Array.from_host(map_host, map_type) ?? crash "import"
	col = MapColumn.from_array(arr.slice(1, 3).slice(1, 2)) ?? crash "type"
	ranges(col) == [Ok({ start: 4, len: 0 }), Ok({ start: 4, len: 3 }), Err(OutOfBounds)] and col.keys().len() == 7
}

# A list of key-value structs is not a map.
expect {
	list_type = DataType.list_of(Struct([DataType.field("key", Utf8, Bool.False), DataType.field("value", Int64, Bool.True)]))
	arr = Array.from_host(map_host, list_type) ?? crash "import"
	match MapColumn.from_array(arr) {
		Err(TypeMismatch(List(_))) => Bool.True
		_ => Bool.False
	}
}

# Entries with one field have no items.
expect {
	one = Map(DataType.field("entries", Struct([DataType.field("key", Utf8, Bool.False)]), Bool.False), Bool.False)
	arr = Array.from_host({ ..map_host, children: [{ ..entries_host, children: entries_host.children.take_first(1) }] }, one) ?? crash "import"
	MapColumn.from_array(arr).is_err()
}

# Offsets past the entries are refused at import.
expect Array.from_host({ ..map_host, buffers: [Absent, I32s([0, 1, 3, 4, 4, 8])] }, map_type).is_err()
