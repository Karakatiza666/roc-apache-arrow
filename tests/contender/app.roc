# The Roc side of the contender test: the Rust driver in tests/contender
# passes an arrow-rs array and a schema, and the schema name picks the entry
# point. Each entry point reads the array through the package's typed views.
#
# | Entry      | Gives                                                        |
# |------------|--------------------------------------------------------------|
# | identity   | the array, read through the views and written again by Writer |
# | digest     | a Utf8 column: one canonical text per row of the input       |
# | validate   | a Utf8 column of one row: "accept" or "refuse <error>"       |
# | drop       | an empty array; the host gives a result back to Roc this way |
#
# To add an entry point, add a branch to `run` and call it from Rust with
# `contender::call(<name>, ..)`.
app [run] {
	arrow: "../../package/main.roc",
	pf: platform "platform/main.roc",
}

import arrow.Array
import arrow.BinaryColumn
import arrow.BoolColumn
import arrow.Host
import arrow.Items
import arrow.ListColumn
import arrow.ListItems
import arrow.MapColumn
import arrow.PrimitiveColumn
import arrow.Schema
import arrow.StructColumn
import arrow.Utf8Column
import arrow.Writer

run : Host.Array, Host.Schema -> Host.Array
run = |input, schema| {
	name = Str.from_utf8_lossy(schema.name)
	match name {
		# The input is consumed: this is how the host frees a result.
		"drop" => Host.empty_array(0)
		"validate" => strs_out([validate(input, schema)])
		"identity" =>
			match import_input(input, schema) {
				Ok(arr) =>
					match rebuild(arr, (0.U64).until(arr.len()).fold([], |acc, i| acc.append(i))) {
						Ok(out) => out
						Err(e) => crash "identity: ${Str.inspect(e)}"
					}
				Err(e) => crash "identity: ${Str.inspect(e)}"
			}
		"digest" =>
			match import_input(input, schema) {
				Ok(arr) =>
					match digests(arr) {
						Ok(rows) => strs_out(rows)
						Err(e) => crash "digest: ${Str.inspect(e)}"
					}
				Err(e) => crash "digest: ${Str.inspect(e)}"
			}
		_ => crash "unknown entry point '${name}'"
	}
}

import_input : Host.Array, Host.Schema -> Try(Array, _)
import_input = |input, schema| {
	field = Schema.field_from_host(schema)?
	Array.from_host(input, field.data_type)
}

## A non-null Utf8 column of these rows.
strs_out : List(Str) -> Host.Array
strs_out = |rows| {
	var $w = Writer.varlen(rows.len(), rows.fold(0, |n, s| n + s.count_utf8_bytes()))
	for s in rows {
		$w = Writer.str_push($w, s)
	}
	Writer.var_finish($w, [])
}

# ---------------------------------------------------------------------------
# validate: import, then build the view of every node, and check the text of
# the text types as the views read it.

validate : Host.Array, Host.Schema -> Str
validate = |input, schema| match import_input(input, schema) {
	Ok(arr) =>
		match views(arr) {
			Ok({}) => "accept"
			Err(e) => "refuse ${Str.inspect(e)}"
		}
	Err(e) => "refuse ${Str.inspect(e)}"
}

views : Array -> Try({}, _)
views = |arr| match arr.data_type() {
	Utf8 => {
		col = Utf8Column.from_array(arr)?
		if (col.is_valid_utf8()) Ok({}) else Err(BadUtf8)
	}
	LargeUtf8 | Utf8View => {
		col = BinaryColumn.from_array(arr)?
		# Every row, NULL rows too: their bytes are part of the column.
		bad = (0.U64).until(col.len()).fold(0, |n, i| if (Str.from_utf8(col.bytes_at(i)).is_ok()) n else n + 1)
		if (bad == 0) Ok({}) else Err(BadUtf8)
	}
	Binary | LargeBinary | BinaryView | FixedSizeBinary(_) => BinaryColumn.from_array(arr).map_ok(|_| {})
	Boolean => BoolColumn.from_array(arr).map_ok(|_| {})
	List(_) | LargeList(_) | FixedSizeList(_, _) => {
		col = ListColumn.from_array(arr)?
		views(col.values())
	}
	Map(_, _) => {
		col = MapColumn.from_array(arr)?
		views(col.keys())?
		views(col.items())
	}
	Struct(_) => {
		col = StructColumn.from_array(arr)?
		col.fields().map_with_index(|_, k| col.column_at(k)).map_try(|c| c)?.map_try(views).map_ok(|_| {})
	}
	_ => rebuild(arr, []).map_ok(|_| {})
}

# ---------------------------------------------------------------------------
# identity: rebuild the rows `sel` of an array from its views with Writer.
# A list keeps the child rows its valid rows hold, in order.

rebuild : Array, List(U64) -> Try(Host.Array, _)
rebuild = |arr, sel| match arr.data_type() {
	Null => Ok(Array.nulls(sel.len()).to_host())
	Boolean => {
		col = BoolColumn.from_array(arr)?
		var $w = Writer.bools(sel.len())
		for i in sel {
			$w = if (col.is_valid(i)) Writer.bools_push($w, col.at(i)) else Writer.bools_null($w)
		}
		Ok(Writer.bools_finish($w, []))
	}
	Int8 => Ok(prim_out(PrimitiveColumn.i8(arr)?, sel, 0, |xs| I8s(xs)))
	Int16 => Ok(prim_out(PrimitiveColumn.i16(arr)?, sel, 0, |xs| I16s(xs)))
	Int32 | Date32 | Time32(_) | Decimal32(_) | Interval(YearMonth) => Ok(prim_out(PrimitiveColumn.i32(arr)?, sel, 0, |xs| I32s(xs)))
	Int64 | Date64 | Time64(_) | Timestamp(_, _) | Duration(_) | Decimal64(_) => Ok(prim_out(PrimitiveColumn.i64(arr)?, sel, 0, |xs| I64s(xs)))
	UInt8 => Ok(prim_out(PrimitiveColumn.u8(arr)?, sel, 0, |xs| U8s(xs)))
	UInt16 | Float16 => Ok(prim_out(PrimitiveColumn.u16(arr)?, sel, 0, |xs| U16s(xs)))
	UInt32 => Ok(prim_out(PrimitiveColumn.u32(arr)?, sel, 0, |xs| U32s(xs)))
	UInt64 => Ok(prim_out(PrimitiveColumn.u64(arr)?, sel, 0, |xs| U64s(xs)))
	Float32 => Ok(prim_out(PrimitiveColumn.f32(arr)?, sel, 0, |xs| F32s(xs)))
	Float64 => Ok(prim_out(PrimitiveColumn.f64(arr)?, sel, 0, |xs| F64s(xs)))
	Decimal128(_) => Ok(prim_out(PrimitiveColumn.i128(arr)?, sel, 0, |xs| I128s(xs)))
	Utf8 => {
		col = Utf8Column.from_array(arr)?
		var $w = Writer.varlen(sel.len(), col.data_len())
		for i in sel {
			$w = if (col.is_valid(i)) Writer.str_push($w, col.at(i)) else Writer.var_null($w)
		}
		Ok(Writer.var_finish($w, []))
	}
	Binary => {
		col = BinaryColumn.from_array(arr)?
		var $w = Writer.varlen(sel.len(), col.data_len())
		for i in sel {
			$w = if (col.is_valid(i)) Writer.bytes_push($w, col.bytes_at(i)) else Writer.var_null($w)
		}
		Ok(Writer.var_finish($w, []))
	}
	LargeUtf8 => {
		col = BinaryColumn.from_array(arr)?
		var $w = Writer.large_varlen(sel.len(), col.data_len())
		for i in sel {
			$w = match col.get_str(i) {
				Ok(s) => Writer.large_str_push($w, s)
				Err(Null) => Writer.large_var_null($w)
				# Bytes that are not UTF-8 go out as they are, and the host's check finds them.
				Err(_) => Writer.large_bytes_push($w, col.bytes_at(i))
			}
		}
		Ok(Writer.large_var_finish($w, []))
	}
	LargeBinary => {
		col = BinaryColumn.from_array(arr)?
		var $w = Writer.large_varlen(sel.len(), col.data_len())
		for i in sel {
			$w = if (col.is_valid(i)) Writer.large_bytes_push($w, col.bytes_at(i)) else Writer.large_var_null($w)
		}
		Ok(Writer.large_var_finish($w, []))
	}
	Utf8View => {
		col = BinaryColumn.from_array(arr)?
		var $w = Writer.views(sel.len(), col.data_len())
		for i in sel {
			$w = match col.get_str(i) {
				Ok(s) => Writer.views_str_push($w, s)
				Err(Null) => Writer.views_null($w)
				Err(_) => Writer.views_push($w, col.bytes_at(i))
			}
		}
		Ok(Writer.views_finish($w, []))
	}
	BinaryView => {
		col = BinaryColumn.from_array(arr)?
		var $w = Writer.views(sel.len(), col.data_len())
		for i in sel {
			$w = if (col.is_valid(i)) Writer.views_push($w, col.bytes_at(i)) else Writer.views_null($w)
		}
		Ok(Writer.views_finish($w, []))
	}
	FixedSizeBinary(width) => {
		col = BinaryColumn.from_array(arr)?
		var $w = Writer.fixed(width, sel.len())
		for i in sel {
			$w = if (col.is_valid(i)) Writer.fixed_push($w, col.bytes_at(i)) else Writer.fixed_null($w)
		}
		Ok(Writer.fixed_finish($w, []))
	}
	List(_) => {
		col = ListColumn.from_array(arr)?
		var $w = Writer.lists({})
		var $kids = []
		for i in sel {
			if col.is_valid(i) {
				r = col.range_at(i)
				before = $kids.len()
				$kids = append_range($kids, r)
				$w = Writer.list_push($w, $kids.sublist({ start: before, len: r.len }), |c, _| c)
			} else {
				$w = Writer.list_null($w)
			}
		}
		child = rebuild(col.values(), $kids)?
		Ok(Writer.list_finish($w, [], |_| child))
	}
	LargeList(_) => {
		col = ListColumn.from_array(arr)?
		var $w = Writer.large_lists({})
		var $kids = []
		for i in sel {
			if col.is_valid(i) {
				r = col.range_at(i)
				before = $kids.len()
				$kids = append_range($kids, r)
				$w = Writer.large_list_push($w, $kids.sublist({ start: before, len: r.len }), |c, _| c)
			} else {
				$w = Writer.large_list_null($w)
			}
		}
		child = rebuild(col.values(), $kids)?
		Ok(Writer.large_list_finish($w, [], |_| child))
	}
	FixedSizeList(_, size) => {
		col = ListColumn.from_array(arr)?
		var $w = Writer.fixed_lists(size, {})
		var $kids = []
		for i in sel {
			# A NULL row keeps its `size` child slots.
			r = col.range_at(i)
			before = $kids.len()
			$kids = append_range($kids, r)
			$w =
				if col.is_valid(i) {
					Writer.fixed_list_push($w, $kids.sublist({ start: before, len: r.len }), |c, _| c, |c| c)
				} else {
					Writer.fixed_list_null($w, |c| c)
				}
		}
		child = rebuild(col.values(), $kids)?
		Ok(Writer.fixed_list_finish($w, [], |_| child))
	}
	Map(_, _) => {
		col = MapColumn.from_array(arr)?
		var $w = Writer.lists({})
		var $kids = []
		for i in sel {
			match col.range(i) {
				Ok(r) => {
					before = $kids.len()
					$kids = append_range($kids, r)
					$w = Writer.list_push($w, $kids.sublist({ start: before, len: r.len }), |c, _| c)
				}
				Err(_) => {
					$w = Writer.list_null($w)
				}
			}
		}
		keys = rebuild(col.keys(), $kids)?
		items = rebuild(col.items(), $kids)?
		entries = Writer.row_finish($kids.fold(Writer.row($kids.len()), |w, _| Writer.row_push(w)), [], [keys, items])
		Ok(Writer.list_finish($w, [], |_| entries))
	}
	Struct(fields) => {
		col = StructColumn.from_array(arr)?
		var $w = Writer.row(sel.len())
		for i in sel {
			$w = if (col.is_valid(i)) Writer.row_push($w) else Writer.row_null($w)
		}
		kids = fields.map_with_index(|_, k| col.column_at(k)).map_try(|c| c)?.map_try(|kid| rebuild(kid, sel))?
		Ok(Writer.row_finish($w, [], kids))
	}
	other => Err(Unsupported(Str.inspect(other)))
}

prim_out : PrimitiveColumn(a), List(U64), a, (List(a) -> Host.Buffer) -> Host.Array
prim_out = |col, sel, zero, wrap| {
	var $w = Writer.prim(sel.len())
	for i in sel {
		$w = if (col.is_valid(i)) Writer.prim_push($w, col.at(i, zero)) else Writer.prim_null($w, zero)
	}
	Writer.prim_finish($w, [], wrap)
}

append_range : List(U64), { start : U64, len : U64 } -> List(U64)
append_range = |xs, r| {
	var $out = xs
	for j in r.start.until(r.start + r.len) {
		$out = $out.append(j)
	}
	$out
}

# ---------------------------------------------------------------------------
# digest: one text per row, read with the checked reads (`get`, `range`).
#
# | Value           | Text                                   |
# |-----------------|----------------------------------------|
# | NULL            | N                                      |
# | integer         | decimal                                |
# | Boolean         | t or f                                 |
# | float           | f and the decimal of its IEEE bits     |
# | text            | s, byte count, colon, the text         |
# | bytes           | x and lowercase hex                    |
# | list            | [a,b]                                  |
# | struct          | {a,b}                                  |
# | map             | {k=v,k=v}                              |

digests : Array -> Try(List(Str), _)
digests = |arr| match arr.data_type() {
	Null => Ok(List.repeat("N", arr.len()))
	Boolean => {
		col = BoolColumn.from_array(arr)?
		Ok(
			each(
				col.len(),
				|i| match col.get(i) {
					Ok(b) => if (b) "t" else "f"
					Err(Null) => "N"
					Err(OutOfBounds) => "!oob"
				},
			),
		)
	}
	Int8 => Ok(prim_digests(PrimitiveColumn.i8(arr)?, |x| x.to_str()))
	Int16 => Ok(prim_digests(PrimitiveColumn.i16(arr)?, |x| x.to_str()))
	Int32 | Date32 | Time32(_) | Decimal32(_) | Interval(YearMonth) => Ok(prim_digests(PrimitiveColumn.i32(arr)?, |x| x.to_str()))
	Int64 | Date64 | Time64(_) | Timestamp(_, _) | Duration(_) | Decimal64(_) => Ok(prim_digests(PrimitiveColumn.i64(arr)?, |x| x.to_str()))
	UInt8 => Ok(prim_digests(PrimitiveColumn.u8(arr)?, |x| x.to_str()))
	UInt16 | Float16 => Ok(prim_digests(PrimitiveColumn.u16(arr)?, |x| x.to_str()))
	UInt32 => Ok(prim_digests(PrimitiveColumn.u32(arr)?, |x| x.to_str()))
	UInt64 => Ok(prim_digests(PrimitiveColumn.u64(arr)?, |x| x.to_str()))
	Float32 => Ok(prim_digests(PrimitiveColumn.f32(arr)?, |x| "f${x.to_bits().to_str()}"))
	Float64 => Ok(prim_digests(PrimitiveColumn.f64(arr)?, |x| "f${x.to_bits().to_str()}"))
	Decimal128(_) => Ok(prim_digests(PrimitiveColumn.i128(arr)?, |x| x.to_str()))
	Utf8 => {
		col = Utf8Column.from_array(arr)?
		Ok(
			each(
				col.len(),
				|i| match col.get(i) {
					Ok(s) => text(s)
					Err(Null) => "N"
					Err(OutOfBounds) => "!oob"
				},
			),
		)
	}
	LargeUtf8 | Utf8View => {
		col = BinaryColumn.from_array(arr)?
		Ok(
			each(
				col.len(),
				|i| match col.get_str(i) {
					Ok(s) => text(s)
					Err(Null) => "N"
					Err(OutOfBounds) => "!oob"
					Err(BadUtf8) => "!bad"
				},
			),
		)
	}
	Binary | LargeBinary | BinaryView | FixedSizeBinary(_) => {
		col = BinaryColumn.from_array(arr)?
		Ok(
			each(
				col.len(),
				|i| match col.get_bytes(i) {
					Ok(bytes) => "x${hex(bytes)}"
					Err(Null) => "N"
					Err(OutOfBounds) => "!oob"
				},
			),
		)
	}
	List(_) | LargeList(_) | FixedSizeList(_, _) => {
		col = ListColumn.from_array(arr)?
		src = ListItems.wrap(digests(col.values())?)
		Ok(
			each(
				col.len(),
				|i| match col.range(i) {
					Ok(r) => "[${joined(Items.view(src, r.start, r.len))}]"
					Err(Null) => "N"
					Err(OutOfBounds) => "!oob"
				},
			),
		)
	}
	Map(_, _) => {
		col = MapColumn.from_array(arr)?
		keys = digests(col.keys())?
		items = digests(col.items())?
		pairs = List.map2(keys, items, |k, v| "${k}=${v}")
		src = ListItems.wrap(pairs)
		Ok(
			each(
				col.len(),
				|i| match col.range(i) {
					Ok(r) => "{${joined(Items.view(src, r.start, r.len))}}"
					Err(Null) => "N"
					Err(OutOfBounds) => "!oob"
				},
			),
		)
	}
	Struct(fields) => {
		col = StructColumn.from_array(arr)?
		kids = fields.map_with_index(|_, k| col.column_at(k)).map_try(|c| c)?.map_try(digests)?
		Ok(
			each(
				col.len(),
				|i|
					if col.is_valid(i) {
						"{${Str.join_with(kids.map(|kid| kid.get(i) ?? "!oob"), ",")}}"
					} else {
						"N"
					},
			),
		)
	}
	other => Err(Unsupported(Str.inspect(other)))
}

prim_digests : PrimitiveColumn(a), (a -> Str) -> List(Str)
prim_digests = |col, show| each(
	col.len(),
	|i| match col.get(i) {
		Ok(x) => show(x)
		Err(Null) => "N"
		Err(OutOfBounds) => "!oob"
	},
)

each : U64, (U64 -> Str) -> List(Str)
each = |n, f| {
	var $out = List.with_capacity(n)
	for i in (0.U64).until(n) {
		$out = $out.append(f(i))
	}
	$out
}

joined : Items(Str, ListItems(Str)) -> Str
joined = |items| Str.join_with(items.iter().fold([], |acc, s| acc.append(s)), ",")

text : Str -> Str
text = |s| "s${s.count_utf8_bytes().to_str()}:${s}"

hex : List(U8) -> Str
hex = |bytes| {
	digit = |n| if (n < 10) n + 48 else n + 87
	Str.from_utf8_lossy(bytes.fold([], |acc, b| acc.append(digit(b.shr_zf_wrap(4))).append(digit(b.bitwise_and(15)))))
}
