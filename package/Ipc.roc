import Array
import DataType exposing [Field]
import Host
import Metadata
import Schema
import TimeUnit

## The Arrow IPC streaming format, read side: the bytes that a server sends
## for a query result (a schema message, then record batches, then an end
## marker) become a `Schema` and one `Array` per record batch.
##
## ```roc
## result = Ipc.read_stream(bytes)?
## batch = result.batches.first()?
## ids = PrimitiveColumn.i64(StructColumn.from_array(batch)?.column("id")?)?
## ```
##
## A batch is a non-null Struct array whose children are the columns, in the
## order of `result.schema.fields`: `batch.len()` is its row count,
## `batch.children()` its columns, and `StructColumn.from_array(batch)` finds
## a column by name (`column("id")`) or by position (`column_at(0)`).
## `ArrowEncoding.decode_row(batch, i)` reads row `i` into a record.
##
## A stream that arrives in pieces (HTTP chunks, WebSocket frames) goes
## through an `Ipc.Reader`. A piece may end anywhere, also inside a message:
##
## ```roc
## fed = reader.feed(piece)?      # start with Ipc.reader
## # fed.batches: the batches this piece completed; go on with fed.reader
## schema = fed.reader.finish()?  # when the input ends
## ```
##
## After an `Err` the stream is broken: do not feed the reader again. Feeding
## after the end marker does nothing.
##
## Validity bitmaps, Boolean bits, text and binary data, FixedSizeBinary
## values and the data buffers of view columns are slices of the fed bytes,
## with no copy. The numeric values, the offsets and the views are decoded
## into typed lists (one copy). So a batch keeps the bytes of its message
## alive (and the pieces fed with them) for as long as one of its arrays
## lives.
##
## What it reads: the streaming format with metadata versions V4 and V5,
## little-endian, uncompressed, every type that `Array.from_host` takes. What
## it does not read, and gives as `Unsupported` or `InvalidIpc`, never as a
## wrong value: the file format (`ARROW1`), compressed bodies, dictionary
## batches and dictionary-encoded fields, unions, run-end encoded and
## list-view types, big-endian streams, and the framing of Arrow before 0.15
## (a message without the continuation marker). It does not write.
Ipc :: [].{

	## `InvalidIpc`: the bytes are not a valid stream. `Unsupported`: a valid
	## Arrow feature that this reader does not have.
	Err : [InvalidIpc(Str), Unsupported(Str)]

	## The state of a stream that is read in pieces. Opaque: `Ipc.reader` is the
	## start, `feed` gives the next state.
	Reader :: {
		got : Try(Schema, [NoSchema]),
		ended : Bool,
		messages : U64,
		batch_count : U64,
		pieces : List(List(U8)),
		held : U64,
		need : U64,
	}.{

		## The schema, once its message has arrived.
		schema : Ipc.Reader -> Try(Schema, [NoSchema])
		schema = |r| r.got

		## Whether the end marker has arrived. A stream may also just stop
		## after a whole message; `finish` tells.
		is_ended : Ipc.Reader -> Bool
		is_ended = |r| r.ended

		## The next piece of the stream: the reader afterwards and the batches
		## this piece completed, each a non-null Struct array of the schema's
		## fields. A piece may end anywhere. Bytes after the end marker are
		## ignored. After an `Err`, do not use the reader further.
		feed : Ipc.Reader, List(U8) -> Try({ reader : Ipc.Reader, batches : List(Array) }, Ipc.Err)
		feed = |start, piece| {
			if start.ended {
				return Ok({ reader: start, batches: [] })
			}
			held = start.held + piece.len()
			if held < start.need {
				# The message is not complete: keep the piece, and join once when it is.
				return Ok({ reader: { ..start, pieces: stack(start.pieces, piece), held }, batches: [] })
			}
			buf = if (start.pieces.is_empty()) piece else start.pieces.append(piece).join()
			var $pos = 0.U64
			var $got = start.got
			var $ended = Bool.False
			var $messages = start.messages
			var $count = start.batch_count
			var $batches = []
			var $need = 0.U64
			var $more = Bool.True
			while $more {
				left = buf.len() - $pos
				begins(buf.sublist({ start: $pos, len: 6 }), $messages == 0)?
				if left < 8 {
					# Look again at the next byte: what is not a stream is refused early.
					$need = left + 1
					$more = Bool.False
				} else {
					meta_len = u32_at(buf, $pos + 4)?
					if meta_len == 0 {
						$ended = Bool.True
						$more = Bool.False
					} else if meta_len > 0x7FFF_FFFF {
						return Err(InvalidIpc("a message has a negative metadata length"))
					} else if left < 8 + meta_len {
						$need = 8 + meta_len
						$more = Bool.False
					} else {
						meta = buf.sublist({ start: $pos + 8, len: meta_len })
						message = table_at(meta, u32_at(meta, 0)?)?
						version = i16_field(message, 0, 0)?
						if version != 3 and version != 4 {
							return Err(Unsupported("metadata version ${version_name(version)} (V4 and V5 are read)"))
						}
						kind = u8_field(message, 1, 0)?
						if kind == 2 {
							return Err(Unsupported("dictionary batches"))
						}
						body_len = i64_field(message, 3, 0)?
						if body_len < 0 {
							return Err(InvalidIpc("a message has a negative body length"))
						}
						total = 8 + meta_len + body_len.to_u64_wrap()
						if left < total {
							$need = total
							$more = Bool.False
						} else {
							if (kind == 1 or kind == 3) and !present(message, 2) {
								return Err(InvalidIpc("a message has no header"))
							}
							header = child(message, 2)?
							if kind == 1 {
								match $got {
									Ok(_) => return Err(InvalidIpc("a second schema message"))
									Err(NoSchema) => {
										$got = Ok(schema_of(header)?)
									}
								}
							} else if kind == 3 {
								match $got {
									Ok(known) => {
										body = buf.sublist({ start: $pos + 8 + meta_len, len: body_len.to_u64_wrap() })
										$batches = $batches.append(batch_of(known, header, body, $count)?)
										$count = $count + 1
									}
									Err(NoSchema) => return Err(InvalidIpc("a record batch came before the schema"))
								}
							} else {
								{}
							}
							$messages = $messages + 1
							$pos = $pos + total
						}
					}
				}
			}
			rest = if ($ended) [] else buf.drop_first($pos)
			after = {
				got: $got,
				ended: $ended,
				messages: $messages,
				batch_count: $count,
				pieces: if (rest.is_empty()) [] else [rest],
				held: rest.len(),
				need: $need,
			}
			Ok({ reader: after, batches: $batches })
		}

		## The end of the input: the schema of the stream. The end marker may be
		## missing; half a message, or no schema message, is `InvalidIpc`.
		finish : Ipc.Reader -> Try(Schema, Ipc.Err)
		finish = |r|
			if r.held > 0 {
				Err(InvalidIpc("the stream ends inside a message"))
			} else {
				match r.got {
					Ok(known) => Ok(known)
					Err(NoSchema) => Err(InvalidIpc("the stream has no schema message"))
				}
			}
	}

	## A reader at the start of a stream.
	reader : Ipc.Reader
	reader = { got: Err(NoSchema), ended: Bool.False, messages: 0, batch_count: 0, pieces: [], held: 0, need: 0 }

	## A whole stream: its schema and one Struct array per record batch. The
	## end marker may be missing; half a message may not.
	read_stream : List(U8) -> Try({ schema : Schema, batches : List(Array) }, Ipc.Err)
	read_stream = |bytes| {
		fed = Ipc.Reader.feed(Ipc.reader, bytes)?
		known = Ipc.Reader.finish(fed.reader)?
		Ok({ schema: known, batches: fed.batches })
	}
}

# ---------------------------------------------------------------- framing

file_magic : List(U8)
file_magic = ['A', 'R', 'R', 'O', 'W', '1']

# The first bytes of a message (6 at most, fewer when no more have arrived):
# they must be, or may still become, the continuation marker 0xFFFFFFFF. The
# first message of the input also tells what else the input is.
begins : List(U8), Bool -> Try({}, Ipc.Err)
begins = |head, first|
	if head.take_first(4).all(|b| b == 255) {
		Ok({})
	} else if !first {
		Err(InvalidIpc("a message does not start with the continuation marker"))
	} else if head == file_magic {
		Err(Unsupported("the Arrow file format (this reads the streaming format)"))
	} else if file_magic.starts_with(head) {
		# Fewer than 6 bytes of the file magic: wait for the rest.
		Ok({})
	} else {
		Err(InvalidIpc("not an Arrow IPC stream"))
	}

# The pieces of an incomplete message with one more. A piece joins the one
# before it while that one is not longer, so there are few pieces and each
# byte is copied O(log n) times, however small the pieces are.
stack : List(List(U8)), List(U8) -> List(List(U8))
stack = |pieces, piece| {
	if piece.is_empty() {
		return pieces
	}
	var $top = piece
	var $below = pieces
	var $more = Bool.True
	while $more {
		match $below.last() {
			Ok(prev) if prev.len() <= $top.len() => {
				$top = prev.concat($top)
				$below = $below.drop_last(1)
			}
			_ => {
				$more = Bool.False
			}
		}
	}
	$below.append($top)
}

version_name : I64 -> Str
version_name = |version| if (version >= 0 and version <= 2) "V${(version + 1).to_str()}" else "number ${version.to_str()}"

# ---------------------------------------------------------------- little-endian reads

# Every read is checked: a position outside the buffer is `InvalidIpc`.

outside : Str -> Try(a, Ipc.Err)
outside = |what| Err(InvalidIpc("${what} lies outside the metadata"))

# Whether `n` bytes at `at` are in the buffer, with no sum that can overflow.
inside : List(U8), U64, U64 -> Bool
inside = |b, at, n| at <= b.len() and b.len() - at >= n

u8_at : List(U8), U64 -> Try(U64, Ipc.Err)
u8_at = |b, at|
	match b.get(at) {
		Ok(x) => Ok(x.to_u64())
		Err(_) => outside("a byte")
	}

u16_at : List(U8), U64 -> Try(U64, Ipc.Err)
u16_at = |b, at|
	match U16.from_le_bytes(b, at) {
		Ok(x) => Ok(x.to_u64())
		Err(_) => outside("a 16-bit value")
	}

u32_at : List(U8), U64 -> Try(U64, Ipc.Err)
u32_at = |b, at|
	match U32.from_le_bytes(b, at) {
		Ok(x) => Ok(x.to_u64())
		Err(_) => outside("a 32-bit value")
	}

i16_at : List(U8), U64 -> Try(I64, Ipc.Err)
i16_at = |b, at|
	match I16.from_le_bytes(b, at) {
		Ok(x) => Ok(x.to_i64())
		Err(_) => outside("a 16-bit value")
	}

i32_at : List(U8), U64 -> Try(I64, Ipc.Err)
i32_at = |b, at|
	match I32.from_le_bytes(b, at) {
		Ok(x) => Ok(x.to_i64())
		Err(_) => outside("a 32-bit value")
	}

i64_at : List(U8), U64 -> Try(I64, Ipc.Err)
i64_at = |b, at|
	match I64.from_le_bytes(b, at) {
		Ok(x) => Ok(x)
		Err(_) => outside("a 64-bit value")
	}

# What the offset at `at` points to. Offsets are unsigned and point forwards.
target : List(U8), U64 -> Try(U64, Ipc.Err)
target = |b, at| Ok(at.plus_saturated(u32_at(b, at)?))

# ---------------------------------------------------------------- FlatBuffers tables

# A table of a FlatBuffer: the buffer, the table's position, and its vtable,
# which `table_at` has checked to lie in the buffer. `vsize` 0 is no table:
# every field of it is absent.
Table : { buf : List(U8), pos : U64, vtable : U64, vsize : U64 }

no_table : Table
no_table = { buf: [], pos: 0, vtable: 0, vsize: 0 }

table_at : List(U8), U64 -> Try(Table, Ipc.Err)
table_at = |buf, pos| {
	# A buffer is far smaller than 2^62 bytes, so these do not overflow.
	back = i32_at(buf, pos)?
	start = pos.to_i64_wrap() - back
	if start < 0 {
		return outside("the vtable of a table")
	}
	vtable = start.to_u64_wrap()
	vsize = match u16_at(buf, vtable) {
		Ok(n) => n
		Err(_) => return outside("the vtable of a table")
	}
	if vsize < 4 or !inside(buf, vtable, vsize) {
		outside("the vtable of a table")
	} else {
		Ok({ buf, pos, vtable, vsize })
	}
}

# The position of field `k`, or 0 when the table does not have it.
field_pos : Table, U64 -> U64
field_pos = |t, k| {
	slot = 4 + 2 * k
	if slot + 2 > t.vsize {
		0
	} else {
		# The slot is inside the vtable, which is inside the buffer.
		match u16_at(t.buf, t.vtable + slot) {
			Ok(0) | Err(_) => 0
			Ok(at) => t.pos + at
		}
	}
}

present : Table, U64 -> Bool
present = |t, k| field_pos(t, k) != 0

u8_field : Table, U64, U64 -> Try(U64, Ipc.Err)
u8_field = |t, k, default| {
	at = field_pos(t, k)
	if (at == 0) Ok(default) else u8_at(t.buf, at)
}

bool_field : Table, U64 -> Try(Bool, Ipc.Err)
bool_field = |t, k| Ok(u8_field(t, k, 0)? != 0)

i16_field : Table, U64, I64 -> Try(I64, Ipc.Err)
i16_field = |t, k, default| {
	at = field_pos(t, k)
	if (at == 0) Ok(default) else i16_at(t.buf, at)
}

i32_field : Table, U64, I64 -> Try(I64, Ipc.Err)
i32_field = |t, k, default| {
	at = field_pos(t, k)
	if (at == 0) Ok(default) else i32_at(t.buf, at)
}

i64_field : Table, U64, I64 -> Try(I64, Ipc.Err)
i64_field = |t, k, default| {
	at = field_pos(t, k)
	if (at == 0) Ok(default) else i64_at(t.buf, at)
}

# The table that field `k` points to; `no_table` when the field is absent.
child : Table, U64 -> Try(Table, Ipc.Err)
child = |t, k| {
	at = field_pos(t, k)
	if (at == 0) Ok(no_table) else table_at(t.buf, target(t.buf, at)?)
}

# A vector field of elements of `size` bytes: where its elements start and
# how many there are. All of them lie in the buffer.
vector : Table, U64, U64 -> Try({ start : U64, len : U64 }, Ipc.Err)
vector = |t, k, size| {
	at = field_pos(t, k)
	if at == 0 {
		return Ok({ start: 0, len: 0 })
	}
	head = target(t.buf, at)?
	len = u32_at(t.buf, head)?
	# `len` is below 2^32 and `size` is 16 at most.
	if inside(t.buf, head + 4, len * size) {
		Ok({ start: head + 4, len })
	} else {
		outside("a vector of ${len.to_str()} elements")
	}
}

# Table `i` of a vector of tables.
table_in : Table, { start : U64, len : U64 }, U64 -> Try(Table, Ipc.Err)
table_in = |t, v, i| table_at(t.buf, target(t.buf, v.start + 4 * i)?)

str_field : Table, U64 -> Try(Str, Ipc.Err)
str_field = |t, k| {
	v = vector(t, k, 1)?
	Ok(Str.from_utf8_lossy(t.buf.sublist(v)))
}

# ---------------------------------------------------------------- the schema message

max_depth : U64
max_depth = 64

max_fields : U64
max_fields = 100_000

# What a schema may still use. FlatBuffers tables and strings can be shared,
# so a small message can name the same fields and text many times over; the
# budget bounds what is built from it: the count of fields, and the bytes of
# names, metadata and time zones (4 times the size of the message).
Budget : { fields : U64, text : U64 }

spend_text : Budget, U64 -> Try(Budget, Ipc.Err)
spend_text = |budget, n|
	if n > budget.text {
		Err(InvalidIpc("the names and metadata of the schema are larger than 4 times its message"))
	} else {
		Ok({ ..budget, text: budget.text - n })
	}

schema_of : Table -> Try(Schema, Ipc.Err)
schema_of = |t| {
	if i16_field(t, 0, 0)? != 0 {
		return Err(Unsupported("a big-endian stream"))
	}
	top = fields_of(t, 1, 1, { fields: max_fields, text: t.buf.len().times_saturated(4) })?
	meta = metadata_of(t, 2, top.budget)?
	Ok({ fields: top.fields, metadata: meta.metadata })
}

# The fields of the vector in field `k`, which are at nesting level `depth`.
fields_of : Table, U64, U64, Budget -> Try({ fields : List(Field), budget : Budget }, Ipc.Err)
fields_of = |t, k, depth, budget| {
	v = vector(t, k, 4)?
	if v.len == 0 {
		return Ok({ fields: [], budget })
	}
	if depth > max_depth {
		return Err(InvalidIpc("the schema nests fields deeper than ${max_depth.to_str()} levels"))
	}
	if v.len > budget.fields {
		return Err(InvalidIpc("the schema has more than ${max_fields.to_str()} fields"))
	}
	var $budget = { ..budget, fields: budget.fields - v.len }
	var $fields = List.with_capacity(v.len)
	var $i = 0.U64
	while $i < v.len {
		got = field_of(table_in(t, v, $i)?, depth, $budget)?
		$fields = $fields.append(got.field)
		$budget = got.budget
		$i = $i + 1
	}
	Ok({ fields: $fields, budget: $budget })
}

metadata_of : Table, U64, Budget -> Try({ metadata : Metadata, budget : Budget }, Ipc.Err)
metadata_of = |t, k, budget| {
	v = vector(t, k, 4)?
	var $budget = spend_text(budget, v.len.times_saturated(8))?
	var $pairs = List.with_capacity(v.len)
	var $i = 0.U64
	while $i < v.len {
		pair = table_in(t, v, $i)?
		key = text_field(pair, 0, $budget)?
		value = text_field(pair, 1, key.budget)?
		$pairs = $pairs.append({ key: key.text, value: value.text })
		$budget = value.budget
		$i = $i + 1
	}
	Ok({ metadata: Metadata.from_pairs($pairs), budget: $budget })
}

# A string field, paid from the budget before it is copied.
text_field : Table, U64, Budget -> Try({ text : Str, budget : Budget }, Ipc.Err)
text_field = |t, k, budget| {
	v = vector(t, k, 1)?
	after = spend_text(budget, v.len)?
	Ok({ text: Str.from_utf8_lossy(t.buf.sublist(v)), budget: after })
}

field_of : Table, U64, Budget -> Try({ field : Field, budget : Budget }, Ipc.Err)
field_of = |t, depth, budget| {
	named = text_field(t, 0, budget)?
	name = named.text
	if present(t, 4) {
		return Err(Unsupported("the dictionary-encoded field '${name}'"))
	}
	kids = fields_of(t, 5, depth + 1, named.budget)?
	data_type = type_of(name, u8_field(t, 2, 0)?, child(t, 3)?, kids.fields)?
	zone_len = match data_type {
		Timestamp(_, zone) => zone.count_utf8_bytes()
		_ => 0
	}
	meta = metadata_of(t, 6, spend_text(kids.budget, zone_len)?)?
	Ok({ field: { name, data_type, nullable: bool_field(t, 1)?, metadata: meta.metadata }, budget: meta.budget })
}

unit_of : Str, I64 -> Try(TimeUnit, Ipc.Err)
unit_of = |name, n|
	match n {
		0 => Ok(Second)
		1 => Ok(Millisecond)
		2 => Ok(Microsecond)
		3 => Ok(Nanosecond)
		_ => Err(InvalidIpc("unknown time unit ${n.to_str()} in field '${name}'"))
	}

one_child : Str, List(Field) -> Try(Field, Ipc.Err)
one_child = |name, kids|
	match kids {
		[only] => Ok(only)
		_ => Err(InvalidIpc("the field '${name}' needs exactly one child, it has ${kids.len().to_str()}"))
	}

# The `Type` union of Schema.fbs: its tag, its table, and the field's children.
type_of : Str, U64, Table, List(Field) -> Try(DataType, Ipc.Err)
type_of = |name, tag, t, kids|
	match tag {
		1 => Ok(Null)
		2 => {
			signed = bool_field(t, 1)?
			match i32_field(t, 0, 0)? {
				8 => Ok(if (signed) Int8 else UInt8)
				16 => Ok(if (signed) Int16 else UInt16)
				32 => Ok(if (signed) Int32 else UInt32)
				64 => Ok(if (signed) Int64 else UInt64)
				other => Err(InvalidIpc("an integer of ${other.to_str()} bits in field '${name}'"))
			}
		}
		3 =>
			match i16_field(t, 0, 0)? {
				0 => Ok(Float16)
				1 => Ok(Float32)
				2 => Ok(Float64)
				other => Err(InvalidIpc("unknown float precision ${other.to_str()} in field '${name}'"))
			}
		4 => Ok(Binary)
		5 => Ok(Utf8)
		6 => Ok(Boolean)
		7 => {
			precision = i32_field(t, 0, 0)?
			scale = i32_field(t, 1, 0)?
			if precision < 1 or precision > 76 or scale < -128 or scale > 127 {
				return Err(InvalidIpc("decimal(${precision.to_str()}, ${scale.to_str()}) in field '${name}'"))
			}
			spec = { precision: precision.to_u8_wrap(), scale: scale.to_i8_wrap() }
			match i32_field(t, 2, 128)? {
				32 => Ok(Decimal32(spec))
				64 => Ok(Decimal64(spec))
				128 => Ok(Decimal128(spec))
				256 => Ok(Decimal256(spec))
				other => Err(InvalidIpc("a decimal of ${other.to_str()} bits in field '${name}'"))
			}
		}
		8 =>
			match i16_field(t, 0, 1)? {
				0 => Ok(Date32)
				1 => Ok(Date64)
				other => Err(InvalidIpc("unknown date unit ${other.to_str()} in field '${name}'"))
			}
		9 => {
			unit = unit_of(name, i16_field(t, 0, 1)?)?
			match i32_field(t, 1, 32)? {
				32 => Ok(Time32(unit))
				64 => Ok(Time64(unit))
				other => Err(InvalidIpc("a time of ${other.to_str()} bits in field '${name}'"))
			}
		}
		10 => Ok(Timestamp(unit_of(name, i16_field(t, 0, 0)?)?, str_field(t, 1)?))
		11 =>
			match i16_field(t, 0, 0)? {
				0 => Ok(Interval(YearMonth))
				1 => Ok(Interval(DayTime))
				2 => Ok(Interval(MonthDayNano))
				other => Err(InvalidIpc("unknown interval unit ${other.to_str()} in field '${name}'"))
			}
		12 => Ok(List(one_child(name, kids)?))
		13 => Ok(Struct(kids))
		14 => Err(Unsupported("the union field '${name}'"))
		15 => {
			width = i32_field(t, 0, 0)?
			if (width < 0) Err(InvalidIpc("a negative byte width in field '${name}'")) else Ok(FixedSizeBinary(width.to_u64_wrap()))
		}
		16 => {
			size = i32_field(t, 0, 0)?
			if (size < 0) Err(InvalidIpc("a negative list size in field '${name}'")) else Ok(FixedSizeList(one_child(name, kids)?, size.to_u64_wrap()))
		}
		17 => Ok(Map(one_child(name, kids)?, bool_field(t, 0)?))
		18 => Ok(Duration(unit_of(name, i16_field(t, 0, 1)?)?))
		19 => Ok(LargeBinary)
		20 => Ok(LargeUtf8)
		21 => Ok(LargeList(one_child(name, kids)?))
		22 => Err(Unsupported("the run-end encoded field '${name}'"))
		23 => Ok(BinaryView)
		24 => Ok(Utf8View)
		25 | 26 => Err(Unsupported("the list-view field '${name}'"))
		other => Err(InvalidIpc("unknown type id ${other.to_str()} in field '${name}'"))
	}

# ---------------------------------------------------------------- the record batch message

# Where the reader is in the batch's flat lists: field nodes, buffers, and the
# counts of data buffers of view columns. They are in depth-first order.
Cursor : { node : U64, buffer : U64, variadic : U64 }

Layout : { body : List(U8), nodes : { start : U64, len : U64 }, buffers : { start : U64, len : U64 }, variadic : { start : U64, len : U64 }, meta : List(U8) }

# A record batch as a non-null Struct array of the schema's fields. `index`
# counts the batches of the stream from 0, for the error messages.
batch_of : Schema, Table, List(U8), U64 -> Try(Array, Ipc.Err)
batch_of = |known, t, body, index| {
	if present(t, 3) {
		return Err(Unsupported("a compressed record batch"))
	}
	rows = i64_field(t, 0, 0)?
	if rows < 0 {
		return Err(InvalidIpc("a record batch has a negative length"))
	}
	layout = { body, nodes: vector(t, 1, 16)?, buffers: vector(t, 2, 16)?, variadic: vector(t, 4, 8)?, meta: t.buf }
	start = { hosts: [], cursor: { node: 0, buffer: 0, variadic: 0 } }
	done = known.fields.fold_try(
		start,
		|acc, field| {
			got = host_of(layout, field, acc.cursor)?
			if got.host.length != rows {
				Err(InvalidIpc("column '${field.name}' has ${got.host.length.to_str()} rows, the batch has ${rows.to_str()}"))
			} else {
				Ok({ hosts: acc.hosts.append(got.host), cursor: got.cursor })
			}
		},
	)?
	if done.cursor.node != layout.nodes.len {
		return Err(InvalidIpc("the record batch names ${layout.nodes.len.to_str()} field nodes; its columns have ${done.cursor.node.to_str()}"))
	}
	if done.cursor.buffer != layout.buffers.len {
		return Err(InvalidIpc("the record batch names ${layout.buffers.len.to_str()} buffers; its columns have ${done.cursor.buffer.to_str()}"))
	}
	match Array.from_host(host_array(rows, 0, [Absent], done.hosts), Struct(known.fields)) {
		Ok(batch) => Ok(batch)
		Err(e) => {
			# Which column? Import each alone; the first that fails gives the message.
			at = "record batch ${index.to_str()}"
			_ = List.map2(known.fields, done.hosts, |field, host| { field, host }).fold_try(
				{},
				|_, column|
					match Array.from_host(column.host, column.field.data_type) {
						Ok(_) => Ok({})
						Err(inner) => Err(blame("${at}, column '${column.field.name}'", inner))
					},
			)?
			Err(blame(at, e))
		}
	}
}

blame : Str, [InvalidArray(Str), Unsupported(Str)] -> Ipc.Err
blame = |at, e|
	match e {
		InvalidArray(why) => InvalidIpc("${at}: ${why}")
		Unsupported(what) => Unsupported("${at}: ${what}")
	}

# The next buffer of the batch as bytes of the body. An empty one is absent.
buffer_of : Layout, U64 -> Try(Host.Buffer, Ipc.Err)
buffer_of = |layout, i| {
	if i >= layout.buffers.len {
		return Err(InvalidIpc("the record batch names ${layout.buffers.len.to_str()} buffers; its columns need more"))
	}
	at = layout.buffers.start + 16 * i
	offset = i64_at(layout.meta, at)?
	len = i64_at(layout.meta, at + 8)?
	if offset < 0 or len < 0 or offset.to_u64_wrap().plus_saturated(len.to_u64_wrap()) > layout.body.len() {
		Err(InvalidIpc("buffer ${i.to_str()} lies outside the message body"))
	} else if len == 0 {
		Ok(Absent)
	} else {
		Ok(U8s(layout.body.sublist({ start: offset.to_u64_wrap(), len: len.to_u64_wrap() })))
	}
}

# `count` buffers from buffer `first` on. The count is checked first, so a
# count from the stream cannot make a long list.
buffers_of : Layout, U64, U64 -> Try(List(Host.Buffer), Ipc.Err)
buffers_of = |layout, first, count| {
	if first > layout.buffers.len or count > layout.buffers.len - first {
		return Err(InvalidIpc("the record batch names ${layout.buffers.len.to_str()} buffers; its columns need more"))
	}
	var $out = List.with_capacity(count)
	var $i = 0.U64
	while $i < count {
		$out = $out.append(buffer_of(layout, first + $i)?)
		$i = $i + 1
	}
	Ok($out)
}

host_array : I64, I64, List(Host.Buffer), List(Host.Array) -> Host.Array
host_array = |length, null_count, buffers, children| { length, null_count, offset: 0, buffers, children, dictionary: [] }

# One column (or child column) as a host array tree, and the cursor after it.
# The schema is no deeper than `max_depth`, and so is this recursion.
host_of : Layout, Field, Cursor -> Try({ host : Host.Array, cursor : Cursor }, Ipc.Err)
host_of = |layout, field, cursor| {
	if cursor.node >= layout.nodes.len {
		return Err(InvalidIpc("the record batch names ${layout.nodes.len.to_str()} field nodes; its columns need more"))
	}
	at = layout.nodes.start + 16 * cursor.node
	length = i64_at(layout.meta, at)?
	null_count = i64_at(layout.meta, at + 8)?
	if length < 0 or null_count < 0 {
		return Err(InvalidIpc("field '${field.name}' has a negative length"))
	}
	after_node = { ..cursor, node: cursor.node + 1 }
	leaf = |count| {
		buffers = buffers_of(layout, cursor.buffer, count)?
		Ok({ host: host_array(length, null_count, buffers, []), cursor: { ..after_node, buffer: cursor.buffer + count } })
	}
	nested = |count, kids| {
		buffers = buffers_of(layout, cursor.buffer, count)?
		start = { children: [], cursor: { ..after_node, buffer: cursor.buffer + count } }
		done = kids.fold_try(
			start,
			|acc, kid| {
				got = host_of(layout, kid, acc.cursor)?
				Ok({ children: acc.children.append(got.host), cursor: got.cursor })
			},
		)?
		Ok({ host: host_array(length, null_count, buffers, done.children), cursor: done.cursor })
	}
	match field.data_type {
		Null => leaf(0)
		Binary | Utf8 | LargeBinary | LargeUtf8 => leaf(3)
		BinaryView | Utf8View => {
			if cursor.variadic >= layout.variadic.len {
				return Err(InvalidIpc("field '${field.name}' is a view column, and the batch does not say how many data buffers it has"))
			}
			count = i64_at(layout.meta, layout.variadic.start + 8 * cursor.variadic)?
			if count < 0 or count.to_u64_wrap() > layout.buffers.len {
				return Err(InvalidIpc("field '${field.name}' names ${count.to_str()} data buffers"))
			}
			buffers = buffers_of(layout, cursor.buffer, 2 + count.to_u64_wrap())?
			# The C Data Interface ends a view array with the sizes of its data buffers.
			sizes = buffers.drop_first(2).map(|b| Host.Buffer.len(b).to_i64_wrap())
			Ok({
				host: host_array(length, null_count, buffers.append(I64s(sizes)), []),
				cursor: { node: after_node.node, buffer: cursor.buffer + 2 + count.to_u64_wrap(), variadic: cursor.variadic + 1 },
			})
		}
		List(kid) | LargeList(kid) | Map(kid, _) => nested(2, [kid])
		FixedSizeList(kid, _) => nested(1, [kid])
		Struct(kids) => nested(1, kids)
		ListView(_) | LargeListView(_) | Union(_, _, _) | Dictionary(_, _, _) | RunEndEncoded(_, _) => Err(Unsupported("the type of field '${field.name}'"))
		_ => leaf(2)
	}
}
