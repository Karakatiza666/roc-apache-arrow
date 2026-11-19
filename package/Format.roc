import DataType
import TimeUnit
import UnionMode

## The head of a C Data Interface format string: the node kind without its
## children. Children come from the `ArrowSchema` child nodes.
Format := [
	Leaf(DataType),
	List,
	LargeList,
	ListView,
	LargeListView,
	FixedSizeList(U64),
	Struct,
	Map,
	Union(UnionMode, List(I8)),
	RunEndEncoded,
].{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## Parse the head of a C Data Interface format string.
	parse : Str -> Try(Format, [InvalidFormat(Str)])
	parse = |text| {
		bad = Err(InvalidFormat(text))
		match text {
			"n" => Ok(Leaf(Null))
			"b" => Ok(Leaf(Boolean))
			"c" => Ok(Leaf(Int8))
			"C" => Ok(Leaf(UInt8))
			"s" => Ok(Leaf(Int16))
			"S" => Ok(Leaf(UInt16))
			"i" => Ok(Leaf(Int32))
			"I" => Ok(Leaf(UInt32))
			"l" => Ok(Leaf(Int64))
			"L" => Ok(Leaf(UInt64))
			"e" => Ok(Leaf(Float16))
			"f" => Ok(Leaf(Float32))
			"g" => Ok(Leaf(Float64))
			"z" => Ok(Leaf(Binary))
			"Z" => Ok(Leaf(LargeBinary))
			"vz" => Ok(Leaf(BinaryView))
			"u" => Ok(Leaf(Utf8))
			"U" => Ok(Leaf(LargeUtf8))
			"vu" => Ok(Leaf(Utf8View))
			"tdD" => Ok(Leaf(Date32))
			"tdm" => Ok(Leaf(Date64))
			"tts" => Ok(Leaf(Time32(Second)))
			"ttm" => Ok(Leaf(Time32(Millisecond)))
			"ttu" => Ok(Leaf(Time64(Microsecond)))
			"ttn" => Ok(Leaf(Time64(Nanosecond)))
			"tDs" => Ok(Leaf(Duration(Second)))
			"tDm" => Ok(Leaf(Duration(Millisecond)))
			"tDu" => Ok(Leaf(Duration(Microsecond)))
			"tDn" => Ok(Leaf(Duration(Nanosecond)))
			"tiM" => Ok(Leaf(Interval(YearMonth)))
			"tiD" => Ok(Leaf(Interval(DayTime)))
			"tin" => Ok(Leaf(Interval(MonthDayNano)))
			"+l" => Ok(List)
			"+L" => Ok(LargeList)
			"+vl" => Ok(ListView)
			"+vL" => Ok(LargeListView)
			"+s" => Ok(Struct)
			"+m" => Ok(Map)
			"+r" => Ok(RunEndEncoded)
			_ =>
				if text.starts_with("ts") {
					unit = time_unit_of(text.drop_prefix("ts")) ? |_| InvalidFormat(text)
					zone = text.drop_prefix("ts").drop_prefix(unit_char(unit)).drop_prefix(":")
					if text.drop_prefix("ts").drop_prefix(unit_char(unit)).starts_with(":") {
						Ok(Leaf(Timestamp(unit, zone)))
					} else {
						bad
					}
				} else if text.starts_with("d:") {
					parts = text.drop_prefix("d:").split_on(",")
					parsed = match parts {
						[p, s] => decimal(p, s, "128")
						[p, s, w] => decimal(p, s, w)
						_ => Err(Bad)
					}
					parsed.map_err(|_| InvalidFormat(text))
				} else if text.starts_with("w:") {
					match U64.from_str(text.drop_prefix("w:")) {
						Ok(n) => Ok(Leaf(FixedSizeBinary(n)))
						Err(_) => bad
					}
				} else if text.starts_with("+w:") {
					match U64.from_str(text.drop_prefix("+w:")) {
						Ok(n) => Ok(FixedSizeList(n))
						Err(_) => bad
					}
				} else if text.starts_with("+ud:") or text.starts_with("+us:") {
					mode = if (text.starts_with("+ud:")) Dense else Sparse
					ids_text = text.drop_prefix("+ud:").drop_prefix("+us:")
					ids = if (ids_text.is_empty()) Ok([]) else ids_text.split_on(",").map_try(I8.from_str)
					match ids {
						Ok(type_ids) => Ok(Union(mode, type_ids))
						Err(_) => bad
					}
				} else {
					bad
				}
		}
	}

	## The C Data Interface format string of this node (children excluded).
	print : DataType -> Str
	print = |data_type| match data_type {
		Null => "n"
		Boolean => "b"
		Int8 => "c"
		UInt8 => "C"
		Int16 => "s"
		UInt16 => "S"
		Int32 => "i"
		UInt32 => "I"
		Int64 => "l"
		UInt64 => "L"
		Float16 => "e"
		Float32 => "f"
		Float64 => "g"
		Decimal32({ precision, scale }) => "d:${precision.to_str()},${scale.to_str()},32"
		Decimal64({ precision, scale }) => "d:${precision.to_str()},${scale.to_str()},64"
		Decimal128({ precision, scale }) => "d:${precision.to_str()},${scale.to_str()}"
		Decimal256({ precision, scale }) => "d:${precision.to_str()},${scale.to_str()},256"
		Date32 => "tdD"
		Date64 => "tdm"
		Time32(unit) => "tt${unit_char(unit)}"
		Time64(unit) => "tt${unit_char(unit)}"
		Timestamp(unit, zone) => "ts${unit_char(unit)}:${zone}"
		Duration(unit) => "tD${unit_char(unit)}"
		Interval(YearMonth) => "tiM"
		Interval(DayTime) => "tiD"
		Interval(MonthDayNano) => "tin"
		Binary => "z"
		LargeBinary => "Z"
		BinaryView => "vz"
		FixedSizeBinary(n) => "w:${n.to_str()}"
		Utf8 => "u"
		LargeUtf8 => "U"
		Utf8View => "vu"
		List(_) => "+l"
		LargeList(_) => "+L"
		ListView(_) => "+vl"
		LargeListView(_) => "+vL"
		FixedSizeList(_, n) => "+w:${n.to_str()}"
		Struct(_) => "+s"
		Map(_, _) => "+m"
		Union(mode, ids, _) => {
			prefix = if (mode == Dense) "+ud:" else "+us:"
			"${prefix}${Str.join_with(ids.map(I8.to_str), ",")}"
		}
		Dictionary(index, _, _) => Format.print(index)
		RunEndEncoded(_, _) => "+r"
	}

	## Rebuild a node from its format head and its children. The inverse of
	## `print` plus `children`.
	build : Format, List(DataType.Field) -> Try(DataType, [InvalidFormat(Str)])
	build = |format, kids| match (format, kids) {
		(Leaf(leaf), []) => Ok(leaf)
		(List, [item]) => Ok(List(item))
		(LargeList, [item]) => Ok(LargeList(item))
		(ListView, [item]) => Ok(ListView(item))
		(LargeListView, [item]) => Ok(LargeListView(item))
		(FixedSizeList(n), [item]) => Ok(FixedSizeList(item, n))
		(Struct, fields) => Ok(Struct(fields))
		(Map, [entries]) => Ok(Map(entries, Bool.False))
		(Union(mode, ids), fields) if ids.len() == fields.len() => Ok(Union(mode, ids, fields))
		(RunEndEncoded, [ends, values]) => Ok(RunEndEncoded(ends, values))
		_ => Err(InvalidFormat("wrong number of children for this format"))
	}
}

unit_char : TimeUnit -> Str
unit_char = |unit| match unit {
	Second => "s"
	Millisecond => "m"
	Microsecond => "u"
	Nanosecond => "n"
}

time_unit_of : Str -> Try(TimeUnit, [NoUnit])
time_unit_of = |text|
	if (text.starts_with("s")) Ok(Second)
	else if (text.starts_with("m")) Ok(Millisecond)
	else if (text.starts_with("u")) Ok(Microsecond)
	else if (text.starts_with("n")) Ok(Nanosecond)
	else Err(NoUnit)

decimal : Str, Str, Str -> Try(Format, [Bad])
decimal = |p_text, s_text, w_text| {
	precision = U8.from_str(p_text) ? |_| Bad
	scale = I8.from_str(s_text) ? |_| Bad
	ps = { precision, scale }
	match w_text {
		"32" => Ok(Leaf(Decimal32(ps)))
		"64" => Ok(Leaf(Decimal64(ps)))
		"128" => Ok(Leaf(Decimal128(ps)))
		"256" => Ok(Leaf(Decimal256(ps)))
		_ => Err(Bad)
	}
}

round_trips : Str -> Bool
round_trips = |text| match Format.parse(text) {
	Ok(Leaf(t)) => Format.print(t) == text
	_ => Bool.False
}

expect ["n", "b", "c", "C", "s", "S", "i", "I", "l", "L", "e", "f", "g", "z", "Z", "vz", "u", "U", "vu", "tdD", "tdm", "tts", "ttm", "ttu", "ttn", "tDs", "tDu", "tiM", "tiD", "tin", "w:16", "d:10,2", "d:76,5,256", "tsu:", "tsu:+00:00", "tsn:Europe/Paris"].all(round_trips)
expect Format.parse("d:10,2") == Ok(Leaf(Decimal128({ precision: 10, scale: 2 })))
expect Format.parse("tsu:+00:00") == Ok(Leaf(Timestamp(Microsecond, "+00:00")))
expect Format.parse("+w:3") == Ok(FixedSizeList(3))
expect Format.parse("+ud:0,5") == Ok(Union(Dense, [0, 5]))
expect Format.parse("q").is_err()
expect Format.parse("tsx:").is_err()
expect Format.parse("d:10").is_err()

## `print`, `parse` and `build` with the node's children give the node back.
nested_round_trips : DataType -> Bool
nested_round_trips = |data_type| {
	text = Format.print(data_type)
	match Format.parse(text) {
		Ok(head) => Format.build(head, data_type.children()) == Ok(data_type)
		Err(_) => Bool.False
	}
}

item : DataType.Field
item = DataType.field("item", Int32, Bool.True)

expect {
	text = Format.print
	[
		(List(item), "+l"),
		(LargeList(item), "+L"),
		(ListView(item), "+vl"),
		(LargeListView(item), "+vL"),
		(FixedSizeList(item, 3), "+w:3"),
		(Struct([item, DataType.field("b", Utf8, Bool.False)]), "+s"),
		(Struct([]), "+s"),
		(DataType.map_of(Utf8, Int64, Bool.True), "+m"),
		(Union(Dense, [0, 5], [item, DataType.field("s", Utf8, Bool.True)]), "+ud:0,5"),
		(Union(Sparse, [3], [item]), "+us:3"),
		(Union(Sparse, [], []), "+us:"),
		(RunEndEncoded(DataType.field("run_ends", Int32, Bool.False), item), "+r"),
	].all(|(dt, want)| text(dt) == want and nested_round_trips(dt))
}

# A list of structs of maps: each node round-trips with its own children.
expect {
	deep = DataType.list_of(Struct([DataType.field("m", DataType.map_of(Utf8, DataType.list_of(Float64), Bool.False), Bool.True)]))
	nodes = [deep].concat(deep.children().map(|f| f.data_type))
	nodes.all(nested_round_trips)
}

# A dictionary prints its index type; the values come from the dictionary node (see Schema).
expect Format.print(Dictionary(Int32, Utf8, Bool.False)) == "i"
expect Format.parse(Format.print(Dictionary(Int16, Utf8, Bool.True))) == Ok(Leaf(Int16))

# keys_sorted is a flag, not part of the format: `build` gives False.
expect Format.build(Map, [DataType.field("entries", Struct([]), Bool.False)]) == Ok(Map(DataType.field("entries", Struct([]), Bool.False), Bool.False))

# A wrong number of children is refused.
expect Format.build(List, []).is_err()
expect Format.build(FixedSizeList(2), [item, item]).is_err()
expect Format.build(Union(Dense, [0, 1]), [item]).is_err()
expect Format.build(RunEndEncoded, [item]).is_err()
expect Format.build(Leaf(Int32), [item]).is_err()

# Bad nested heads are refused.
expect ["+", "+w:", "+w:x", "+ud:a", "+uz:0", "+l2", "+vx"].all(|t| Format.parse(t).is_err())
expect Format.parse("+ud:") == Ok(Union(Dense, []))
expect Format.parse("d:5,-2") == Ok(Leaf(Decimal128({ precision: 5, scale: -2 })))
