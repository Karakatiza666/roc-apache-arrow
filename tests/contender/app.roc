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
# | lineitem   | one batch of the lineitem table: the rows shipped in a date range with their prices, and the totals per group |
# | lineitem_str | the same job with a `Str` per text read and per text written |
# | parts      | a text or binary column: reads and writes of each row with the byte reads and the writer's parts |
#
# `lineitem_import` and `lineitem_numeric` (and the same for `lineitem_str`)
# stop after the import and after the numeric work: the bench subtracts them
# to time each phase.
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
		"lineitem" => lineitem(input, schema, Full, Parts)
		"lineitem_numeric" => lineitem(input, schema, Numeric, Parts)
		"lineitem_import" => lineitem(input, schema, ImportOnly, Parts)
		"lineitem_str" => lineitem(input, schema, Full, Strs)
		"lineitem_str_numeric" => lineitem(input, schema, Numeric, Strs)
		"lineitem_str_import" => lineitem(input, schema, ImportOnly, Strs)
		"parts" | "parts_bin" =>
			match import_input(input, schema) {
				Ok(arr) =>
					match parts(arr, name == "parts_bin") {
						Ok(out) => out
						Err(e) => crash "parts: ${Str.inspect(e)}"
					}
				Err(e) => crash "parts: ${Str.inspect(e)}"
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

# ---------------------------------------------------------------------------
# lineitem: a batch of the lineitem table (a Struct) in, one Struct row out:
#
# | Field  | Value                                                              |
# |--------|--------------------------------------------------------------------|
# | rows   | the rows with ship_from <= shipdate < ship_until: orderkey, disc_price = extendedprice * (1 - discount), charge = disc_price * (1 + tax), comment_norm, comment_len |
# | groups | per (returnflag, linestatus) with rows, in key order: the row count and the sums of quantity, extendedprice, disc_price and charge |
#
# A NULL operand makes a price NULL; a sum skips NULL prices. comment_norm is
# the trimmed comment with its first word in ASCII uppercase.
#
# Two styles of the same job: `Parts` reads the flags and the comment with
# the byte reads and writes comment_norm in parts, with no `Str` per row;
# `Strs` reads a `Str` per flag and comment and writes a `Str`.

## 1994-01-01 and 1997-03-01 as days since 1970-01-01.
ship_from : I32
ship_from = 8766

ship_until : I32
ship_until = 9921

Totals : { count : I64, qty : I128, base : I128, disc : I128, charge : I128 }

lineitem : Host.Array, Host.Schema, [Full, Numeric, ImportOnly], [Parts, Strs] -> Host.Array
lineitem = |input, schema, phase, style| match lineitem_batch(input, schema, phase, style) {
	Ok(out) => out
	Err(e) => crash "lineitem: ${Str.inspect(e)}"
}

lineitem_batch : Host.Array, Host.Schema, [Full, Numeric, ImportOnly], [Parts, Strs] -> Try(Host.Array, _)
lineitem_batch = |input, schema, phase, style| {
	table = StructColumn.from_array(import_input(input, schema)?)?
	column = |name| table.column(name)
	orderkey = PrimitiveColumn.i64(column("orderkey")?)?
	quantity = PrimitiveColumn.i128(column("quantity")?)?
	price = PrimitiveColumn.i128(column("extendedprice")?)?
	discount = PrimitiveColumn.i128(column("discount")?)?
	tax = PrimitiveColumn.i128(column("tax")?)?
	flag = Utf8Column.from_array(column("returnflag")?)?
	status = Utf8Column.from_array(column("linestatus")?)?
	shipdate = PrimitiveColumn.i32(column("shipdate")?)?
	comment = Utf8Column.from_array(column("comment")?)?
	if phase == ImportOnly {
		return Ok(Host.empty_array(0))
	}
	n = table.len()
	var $rows = Writer.row(n)
	var $keys = Writer.prim(n)
	var $disc = Writer.prim(n)
	var $charge = Writer.prim(n)
	var $text = Writer.varlen(n, comment.data_len())
	var $lens = Writer.prim(n)
	var $totals = List.repeat({ count: 0, qty: 0, base: 0, disc: 0, charge: 0 }, 6)
	for i in (0.U64).until(n) {
		day = shipdate.at(i, 0)
		if shipdate.is_valid(i) and day >= ship_from and day < ship_until {
			base = price.at(i, 0)
			disc = if (discount.is_valid(i)) Ok(base * (100 - discount.at(i, 0))) else Err(Null)
			charge = match disc {
				Ok(d) if tax.is_valid(i) => Ok(d * (100 + tax.at(i, 0)))
				_ => Err(Null)
			}
			$rows = Writer.row_push($rows)
			$keys = Writer.prim_push($keys, orderkey.at(i, 0))
			$disc = match disc {
				Ok(d) => Writer.prim_push($disc, d)
				Err(_) => Writer.prim_null($disc, 0)
			}
			$charge = match charge {
				Ok(c) => Writer.prim_push($charge, c)
				Err(_) => Writer.prim_null($charge, 0)
			}
			if phase == Full {
				if !comment.is_valid(i) {
					$text = Writer.var_null($text)
					$lens = Writer.prim_null($lens, 0)
				} else if style == Parts {
					(norm, len) = normalize_into($text, comment, i)
					$text = norm
					$lens = Writer.prim_push($lens, len.to_i32_wrap())
				} else {
					norm = normalize(comment.at(i))
					$text = Writer.str_push($text, norm)
					$lens = Writer.prim_push($lens, norm.count_utf8_bytes().to_i32_wrap())
				}
			}
			g = if (style == Parts) group_at(flag, status, i)? else group_of(flag.at(i), status.at(i))?
			add = |t| { count: t.count + 1, qty: t.qty + quantity.at(i, 0), base: t.base + base, disc: t.disc + (disc ?? 0), charge: t.charge + (charge ?? 0) }
			$totals = match $totals.update(g, add) {
				Ok(ts) => ts
				Err(OutOfBounds) => return Err(OutOfBounds)
			}
		}
	}
	if phase == Numeric {
		return Ok(Host.empty_array(0))
	}
	kept = $rows.len
	rows = Writer.row_finish(
		$rows,
		[],
		[
			Writer.prim_finish($keys, [], |xs| I64s(xs)),
			Writer.prim_finish($disc, [], |xs| I128s(xs)),
			Writer.prim_finish($charge, [], |xs| I128s(xs)),
			Writer.var_finish($text, []),
			Writer.prim_finish($lens, [], |xs| I32s(xs)),
		],
	)
	one_list = |child, len| Writer.list_finish(Writer.list_push(Writer.lists({}), List.repeat({}, len), |c, _| c), [], |_| child)
	groups = totals_out($totals)
	Ok(Writer.row_finish(Writer.row_push(Writer.row(1)), [], [one_list(rows, kept), one_list(groups.array, groups.len)]))
}

## The group of a (returnflag, linestatus) pair: A, N, R times F, O.
group_of : Str, Str -> Try(U64, [UnknownGroup(Str, Str)])
group_of = |flag, status| {
	f = match flag {
		"A" => 0
		"N" => 1
		"R" => 2
		_ => return Err(UnknownGroup(flag, status))
	}
	s = match status {
		"F" => 0
		"O" => 1
		_ => return Err(UnknownGroup(flag, status))
	}
	Ok(f * 2 + s)
}

## The group of row `i` from one byte of returnflag and of linestatus: no
## `Str` per row.
group_at : Utf8Column, Utf8Column, U64 -> Try(U64, [UnknownGroup(Str, Str)])
group_at = |flag, status, i| {
	f = match (flag.byte_len(i), flag.byte_at(i, 0)) {
		(1, Ok('A')) => 0
		(1, Ok('N')) => 1
		(1, Ok('R')) => 2
		_ => return Err(UnknownGroup(flag.at(i), status.at(i)))
	}
	s = match (status.byte_len(i), status.byte_at(i, 0)) {
		(1, Ok('F')) => 0
		(1, Ok('O')) => 1
		_ => return Err(UnknownGroup(flag.at(i), status.at(i)))
	}
	Ok(f * 2 + s)
}

## `normalize` of row `i`, written in parts: the first word of the trimmed
## row in ASCII uppercase, then the rest of it, each byte copied once. Gives
## the row's byte length too.
normalize_into : Writer.Var, Utf8Column, U64 -> (Writer.Var, U64)
normalize_into = |w, comment, i| {
	trim = comment.trim_ascii(i)
	if may_end_in_unicode_space(comment, i, trim) {
		norm = normalize(comment.at(i))
		return (Writer.str_push(w, norm), norm.count_utf8_bytes())
	}
	open = Writer.str_begin(w)
	row = match comment.find_byte(i, trim, ' ') {
		Ok(k) => {
			word = { start: trim.start, len: k - trim.start }
			rest = { start: k, len: trim.start + trim.len - k }
			open |> Writer.part_upper(comment, i, word) |> Writer.part_range(comment, i, rest)
		}
		Err(NotFound) => Writer.part_upper(open, comment, i, trim)
	}
	len = Writer.part_len(row)
	(Writer.str_end(row), len)
}

## `trim` also removes Unicode white space, which `trim_ascii` keeps. Each
## such character starts with 0xC2, 0xE1, 0xE2 or 0xE3, so a span with none
## of those at its ends trims the same; any other row takes the `Str` path.
may_end_in_unicode_space : Utf8Column, U64, { start : U64, len : U64 } -> Bool
may_end_in_unicode_space = |col, i, span| {
	lead = |b| b == 0xC2 or (b >= 0xE1 and b <= 0xE3)
	end = span.start + span.len
	span.len > 0
		and (lead(col.byte_at(i, span.start) ?? 0)
			or lead(col.byte_at(i, end.minus_saturated(2)) ?? 0)
			or lead(col.byte_at(i, end.minus_saturated(3)) ?? 0))
}

## The trimmed text with its first word in ASCII uppercase.
normalize : Str -> Str
normalize = |raw| {
	trimmed = raw.trim()
	match trimmed.split_first(" ") {
		Ok({ before, after }) => "${before.with_ascii_uppercased()} ${after}"
		Err(NotFound) => trimmed.with_ascii_uppercased()
	}
}

## The groups with rows, in key order, as a Struct.
totals_out : List(Totals) -> { array : Host.Array, len : U64 }
totals_out = |totals| {
	var $flags = Writer.varlen(6, 6)
	var $statuses = Writer.varlen(6, 6)
	var $count = Writer.prim(6)
	var $qty = Writer.prim(6)
	var $base = Writer.prim(6)
	var $disc = Writer.prim(6)
	var $charge = Writer.prim(6)
	var $rows = Writer.row(6)
	for g in (0.U64).until(6) {
		t = totals.get(g) ?? { count: 0, qty: 0, base: 0, disc: 0, charge: 0 }
		if t.count > 0 {
			$flags = Writer.str_push($flags, ["A", "N", "R"].get(g // 2) ?? "")
			$statuses = Writer.str_push($statuses, ["F", "O"].get(g % 2) ?? "")
			$count = Writer.prim_push($count, t.count)
			$qty = Writer.prim_push($qty, t.qty)
			$base = Writer.prim_push($base, t.base)
			$disc = Writer.prim_push($disc, t.disc)
			$charge = Writer.prim_push($charge, t.charge)
			$rows = Writer.row_push($rows)
		}
	}
	len = $rows.len
	array = Writer.row_finish(
		$rows,
		[],
		[
			Writer.var_finish($flags, []),
			Writer.var_finish($statuses, []),
			Writer.prim_finish($count, [], |xs| I64s(xs)),
			Writer.prim_finish($qty, [], |xs| I128s(xs)),
			Writer.prim_finish($base, [], |xs| I128s(xs)),
			Writer.prim_finish($disc, [], |xs| I128s(xs)),
			Writer.prim_finish($charge, [], |xs| I128s(xs)),
		],
	)
	{ array, len }
}

# ---------------------------------------------------------------------------
# parts: a text or binary column in, a Struct of one row per input row out.
# Each field reads the row with the byte reads (`byte_len`, `byte_at`,
# `eq_bytes`, `eq_str`, `trim_ascii`, `first_word`, `find_byte`) or writes it
# again in parts, into a writer of the input's type. `parts_bin` reads Utf8
# through `BinaryColumn`, `parts` through `Utf8Column`.
#
# | Field     | Value (row bytes b; NULL rows NULL in the text fields)          |
# |-----------|------------------------------------------------------------------|
# | same      | b in three spans, cut at a third and two thirds of its length     |
# | upper     | b with ASCII letters in upper case                                |
# | lower     | b with ASCII letters in lower case                                |
# | trim      | b with ASCII white space trimmed at both ends                     |
# | word      | the trimmed b up to its first ASCII white space                   |
# | mixed     | "<", the byte 0x7C, b, "é>"                                       |
# | mixed_len | the byte length of mixed, from `part_len`, after a first row      |
# | len       | the byte length of b                                              |
# | first     | the first byte of b, or -1                                        |
# | last      | the last byte of b, or -1                                         |
# | past      | the byte after b: always -1                                       |
# | space     | the index of the first space in b, or -1                          |
# | space_in_trim | the index in b of the first space inside the trimmed b, or -1 |
# | eq_prev   | b equals the bytes of the row before (none before row 0)          |
# | eq_prev_str | b equals the text of the row before, decoded with replacement characters |

parts : Array, Bool -> Try(Host.Array, _)
parts = |arr, as_bin| match arr.data_type() {
	Utf8 if !as_bin => Ok(parts_of(Utf8Column.from_array(arr)?, var_kit))
	Utf8 | Binary => Ok(parts_of(BinaryColumn.from_array(arr)?, var_kit))
	LargeUtf8 | LargeBinary => Ok(parts_of(BinaryColumn.from_array(arr)?, large_kit))
	Utf8View | BinaryView => Ok(parts_of(BinaryColumn.from_array(arr)?, views_kit))
	other => Err(Unsupported(Str.inspect(other)))
}

var_kit = {
	new: |n| Writer.varlen(n, 0),
	begin: Writer.str_begin,
	end: Writer.str_end,
	null: Writer.var_null,
	finish: |w| Writer.var_finish(w, []),
}

large_kit = {
	new: |n| Writer.large_varlen(n, 0),
	begin: Writer.large_str_begin,
	end: Writer.large_str_end,
	null: Writer.large_var_null,
	finish: |w| Writer.large_var_finish(w, []),
}

views_kit = {
	new: |n| Writer.views(n, 0),
	begin: Writer.views_str_begin,
	end: Writer.views_str_end,
	null: Writer.views_null,
	finish: |w| Writer.views_finish(w, []),
}

## One text field: `row` writes the parts of each valid row.
text_field = |col, kit, row| {
	var $w = (kit.new)(col.len())
	for i in (0.U64).until(col.len()) {
		$w = if (col.is_valid(i)) (kit.end)(row((kit.begin)($w), i)) else (kit.null)($w)
	}
	(kit.finish)($w)
}

## One Int64 field.
i64_field = |n, f| {
	var $w = Writer.prim(n)
	for i in (0.U64).until(n) {
		$w = Writer.prim_push($w, f(i))
	}
	Writer.prim_finish($w, [], |xs| I64s(xs))
}

## One Int32 field.
i32_field = |n, f| {
	var $w = Writer.prim(n)
	for i in (0.U64).until(n) {
		$w = Writer.prim_push($w, f(i))
	}
	Writer.prim_finish($w, [], |xs| I32s(xs))
}

## One Boolean field.
bool_field = |n, f| {
	var $w = Writer.bools(n)
	for i in (0.U64).until(n) {
		$w = Writer.bools_push($w, f(i))
	}
	Writer.bools_finish($w, [])
}

parts_of = |col, kit| {
	n = col.len()
	all = { start: 0, len: U64.highest }
	byte = |i, k| match col.byte_at(i, k) {
		Ok(b) => b.to_i32()
		Err(OutOfBounds) => -1
	}
	prev = |i| if (i == 0) [] else col.append_span(i - 1, all, AsIs, [])
	# A writer with one long row, so an open row does not start at 0.
	after_one_row = (kit.end)(Writer.part_str((kit.begin)((kit.new)(2)), "a first row of more than twelve bytes"))
	mixed = |t, i| t |> Writer.part_str("<") |> Writer.part_bytes([0x7C]) |> Writer.part_range(col, i, all) |> Writer.part_str("é>")
	fields = [
		text_field(
			col,
			kit,
			|t, i| {
				size = col.byte_len(i)
				a = size // 3
				b = (2 * size) // 3
				t |> Writer.part_range(col, i, { start: 0, len: a }) |> Writer.part_range(col, i, { start: a, len: b - a }) |> Writer.part_range(col, i, { start: b, len: size - b })
			},
		),
		text_field(col, kit, |t, i| Writer.part_upper(t, col, i, all)),
		text_field(col, kit, |t, i| Writer.part_lower(t, col, i, all)),
		text_field(col, kit, |t, i| Writer.part_range(t, col, i, col.trim_ascii(i))),
		text_field(col, kit, |t, i| Writer.part_range(t, col, i, col.first_word(i, col.trim_ascii(i)))),
		text_field(col, kit, mixed),
		i64_field(n, |i| Writer.part_len(mixed((kit.begin)(after_one_row), i)).to_i64_wrap()),
		i64_field(n, |i| col.byte_len(i).to_i64_wrap()),
		i32_field(n, |i| byte(i, 0)),
		i32_field(n, |i| if (col.byte_len(i) == 0) -1 else byte(i, col.byte_len(i) - 1)),
		i32_field(n, |i| byte(i, col.byte_len(i))),
		i64_field(
			n,
			|i| match col.find_byte(i, all, ' ') {
				Ok(k) => k.to_i64_wrap()
				Err(NotFound) => -1
			},
		),
		i64_field(
			n,
			|i| match col.find_byte(i, col.trim_ascii(i), ' ') {
				Ok(k) => k.to_i64_wrap()
				Err(NotFound) => -1
			},
		),
		bool_field(n, |i| col.eq_bytes(i, prev(i))),
		bool_field(n, |i| col.eq_str(i, Str.from_utf8_lossy(prev(i)))),
	]
	Writer.row_finish((0.U64).until(n).fold(Writer.row(n), |w, _| Writer.row_push(w)), [], fields)
}
