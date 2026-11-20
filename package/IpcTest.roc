import Array
import BinaryColumn
import BoolColumn
import DataType
import Ipc
import ListColumn
import MapColumn
import PrimitiveColumn
import Schema
import StructColumn
import Utf8Column
import "../tests/ipc/probe3.arrow" as probe3 : List(U8)
import "../tests/ipc/sums.arrow" as sums : List(U8)
import "../tests/ipc/empty.arrow" as empty : List(U8)
import "../tests/ipc/zero_columns.arrow" as zero_columns : List(U8)
import "../tests/ipc/zero_rows.arrow" as zero_rows : List(U8)
import "../tests/ipc/v4.arrow" as v4 : List(U8)
import "../tests/ipc/depth64.arrow" as depth64 : List(U8)
import "../tests/ipc/depth65.arrow" as depth65 : List(U8)
import "../tests/ipc/fan_out.arrow" as fan_out : List(U8)
import "../tests/ipc/shared_text.arrow" as shared_text : List(U8)
import "../tests/ipc/time_unit.arrow" as time_unit : List(U8)
import "../tests/ipc/type_id.arrow" as type_id : List(U8)
import "../tests/ipc/long_vector.arrow" as long_vector : List(U8)
import "../tests/ipc/long_buffers.arrow" as long_buffers : List(U8)
import "../tests/ipc/extra_node.arrow" as extra_node : List(U8)
import "../tests/ipc/extra_buffer.arrow" as extra_buffer : List(U8)
import "../tests/ipc/short_column.arrow" as short_column : List(U8)
import "../tests/ipc/bad_offsets.arrow" as bad_offsets : List(U8)
import "../tests/ipc/old_version.arrow" as old_version : List(U8)

## Tests of `Ipc` (tests/ipc/README.md says how each file was made): streams
## that a real server wrote, arrow-rs 59 through DataFusion's stream writer,
## and small crafted streams for what no usual writer sends.
IpcTest :: [].{}

# Column `i` of a batch: a batch is a Struct array, its children are the columns.
column : Array, U64 -> Array
column = |batch, i| batch.children().get(i) ?? Array.nulls(0)

first_batch : List(U8) -> Array
first_batch = |bytes|
	match Ipc.read_stream(bytes) {
		Ok({ batches: [batch, ..], .. }) => batch
		_ => Array.nulls(0)
	}

# The schema: names, types and nullability of every column, nested ones included.
expect {
	schema = Ipc.read_stream(probe3).map_ok(|r| r.schema) ?? Schema.new([])
	schema.fields.map(|f| f.name) == ["id", "small", "tiny", "ratio", "amount", "name", "flag", "ts", "d", "t", "tags", "attrs", "bin", "v", "pair"]
		and schema.fields.map(|f| f.nullable) == [Bool.False, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True]
		and schema.fields.map(|f| f.data_type) == [
			Int64,
			Int32,
			Int8,
			Float64,
			Decimal128({ precision: 10, scale: 2 }),
			Utf8,
			Boolean,
			Timestamp(Microsecond, ""),
			Date32,
			Time64(Nanosecond),
			LargeList(DataType.field("item", Utf8, Bool.True)),
			Map(DataType.field("entries", Struct([DataType.field("key", Utf8, Bool.False), DataType.field("value", Int32, Bool.True)]), Bool.False), Bool.False),
			LargeBinary,
			Utf8,
			Struct([DataType.field("a", Int32, Bool.False), DataType.field("b", Utf8, Bool.False)]),
		]
}

# Fixed-width columns of the one batch.
expect {
	batch = first_batch(probe3)
	ids = PrimitiveColumn.i64(column(batch, 0)).map_ok(|c| c.values())
	small = PrimitiveColumn.i32(column(batch, 1)).map_ok(|c| c.values())
	tiny = PrimitiveColumn.i8(column(batch, 2)).map_ok(|c| c.values())
	ratio = PrimitiveColumn.f64(column(batch, 3)).map_ok(|c| c.values())
	amount = PrimitiveColumn.i128(column(batch, 4)).map_ok(|c| c.values())
	ts = PrimitiveColumn.i64(column(batch, 7)).map_ok(|c| c.values())
	day = PrimitiveColumn.i32(column(batch, 8)).map_ok(|c| c.values())
	time = PrimitiveColumn.i64(column(batch, 9)).map_ok(|c| c.values())
	batch.len() == 3 and batch.children().len() == 15 and batch.null_count() == 0
		and ids == Ok([0, 1, 2]) and small == Ok([0, 1, 2]) and tiny == Ok([0, 1, 2]) and ratio == Ok([0.0, 1.0, 2.0])
		and amount == Ok([0, 100, 200]) and ts == Ok([0, 1000, 2000]) and day == Ok([0, 1, 2]) and time == Ok([0, 1_000_000, 2_000_000])
}

# Text, booleans, binary, and a column that is all null.
expect {
	batch = first_batch(probe3)
	names = Utf8Column.from_array(column(batch, 5)).map_ok(|c| [c.at(0), c.at(1), c.at(2)])
	flags = BoolColumn.from_array(column(batch, 6)).map_ok(|c| [c.at(0), c.at(1), c.at(2)])
	bins = BinaryColumn.from_array(column(batch, 12)).map_ok(|c| [c.bytes_at(0), c.bytes_at(1), c.bytes_at(2)])
	variant = column(batch, 13)
	names == Ok(["0", "1", "2"]) and flags == Ok([Bool.False, Bool.True, Bool.False]) and bins == Ok([[], [0], [0, 1]])
		and variant.null_count() == 3 and column(batch, 5).null_count() == 0
}

# Nested columns: a list of text, an empty map, a struct.
expect {
	batch = first_batch(probe3)
	tags =
		match ListColumn.from_array(column(batch, 10)) {
			Ok(lists) =>
				match Utf8Column.from_array(lists.values()) {
					Ok(items) => [0, 1, 2].map(
						|row| {
							range = lists.range_at(row)
							List.repeat(0.U8, range.len).map_with_index(|_, i| items.at(range.start + i))
						},
					)
					Err(_) => []
				}
			Err(_) => []
		}
	attrs = MapColumn.from_array(column(batch, 11)).map_ok(|m| [m.range(0), m.range(1), m.range(2)])
	pair =
		match StructColumn.from_array(column(batch, 14)) {
			Ok(s) => (s.column("a").map_ok(|a| PrimitiveColumn.i32(a).map_ok(|c| c.values())), s.column("b").map_ok(|b| Utf8Column.from_array(b).map_ok(|c| c.at(2))))
			Err(_) => (Err(NotFound("")), Err(NotFound("")))
		}
	tags == [[], ["0"], ["0", "1"]]
		and attrs == Ok([Ok({ start: 0, len: 0 }), Ok({ start: 0, len: 0 }), Ok({ start: 0, len: 0 })])
		and pair == (Ok(Ok([0, 1, 2])), Ok(Ok("2")))
}

# A second stream: a wide decimal, a Null column, a non-null count.
expect {
	schema = Ipc.read_stream(sums).map_ok(|r| r.schema) ?? Schema.new([])
	batch = first_batch(sums)
	schema.fields.map(|f| f.data_type) == [Boolean, Int64, Decimal128({ precision: 38, scale: 2 }), Float64, Timestamp(Microsecond, ""), Null, Int64]
		and batch.children().len() == 7 and batch.len() > 0
		and column(batch, 5).null_count() == batch.len()
		and PrimitiveColumn.i64(column(batch, 6)).map_ok(|c| c.at(0, 0)) == Ok(batch.len().to_i64_wrap())
}

# A result with no rows is a schema and no batch.
expect {
	match Ipc.read_stream(empty) {
		Ok({ schema, batches }) => schema.fields.len() == 15 and batches.is_empty()
		Err(_) => Bool.False
	}
}

# A stream that arrives in pieces gives the same batches, wherever it is cut.
expect {
	whole = first_batch(probe3)
	ids = PrimitiveColumn.i64(column(whole, 0)).map_ok(|c| c.values())
	[1, 4, 7, 8, 9, 600, 1151, 1152, 1153, 1160, 2400, 3839, 3840, 3847].all(
		|cut| {
			head = Ipc.reader.feed(probe3.take_first(cut))
			match head {
				Ok(first) =>
					match first.reader.feed(probe3.drop_first(cut)) {
						Ok(second) => {
							batches = first.batches.concat(second.batches)
							got = batches.first().map_ok(|b| PrimitiveColumn.i64(column(b, 0)).map_ok(|c| c.values()))
							batches.len() == 1 and got == Ok(ids) and second.reader.is_ended() and second.reader.finish().is_ok()
						}
						Err(_) => Bool.False
					}
				Err(_) => Bool.False
			}
		},
	)
}

# What a `Try` of the reader says.
say : Try(a, Ipc.Err) -> Str
say = |result|
	match result {
		Ok(_) => "no error"
		Err(InvalidIpc(why)) => "invalid: ${why}"
		Err(Unsupported(what)) => "unsupported: ${what}"
	}

problem : List(U8) -> Str
problem = |bytes| say(Ipc.read_stream(bytes))

# The input fed one byte at a time, then finished: what the first error says,
# how many bytes were fed when it came, and the batches before it.
trickle : List(U8) -> { said : Str, fed : U64, batches : U64 }
trickle = |bytes| {
	var $reader = Ipc.reader
	var $said = "no error"
	var $fed = 0.U64
	var $batches = 0.U64
	for byte in bytes {
		if $said == "no error" {
			$fed = $fed + 1
			match $reader.feed([byte]) {
				Ok(next) => {
					$reader = next.reader
					$batches = $batches + next.batches.len()
				}
				Err(e) => {
					$said = say(Err(e))
				}
			}
		}
	}
	if $said == "no error" {
		$said = say($reader.finish())
	}
	{ said: $said, fed: $fed, batches: $batches }
}

# Byte by byte, and bytes after the end marker are ignored.
expect trickle(sums.concat([1, 2, 3])) == { said: "no error", fed: sums.len() + 3, batches: 1 }

# Byte by byte and in pieces of 7 bytes, the values are those of the whole stream.
expect {
	ids = |batches| batches.first().map_ok(|b| PrimitiveColumn.i64(column(b, 0)).map_ok(|c| c.values()))
	start = { reader: Ipc.reader, batches: [], failed: Bool.False }
	step = |acc, piece|
		match acc.reader.feed(piece) {
			Ok(next) => { reader: next.reader, batches: acc.batches.concat(next.batches), failed: acc.failed }
			Err(_) => { ..acc, failed: Bool.True }
		}
	single = probe3.fold(start, |acc, byte| step(acc, [byte]))
	sevens = probe3.chunks_of(7).fold(start, step)
	!single.failed and !sevens.failed and single.batches.len() == 1 and sevens.batches.len() == 1
		and ids(single.batches) == Ok(Ok([0, 1, 2])) and ids(sevens.batches) == Ok(Ok([0, 1, 2]))
		and single.reader.is_ended() and sevens.reader.finish().is_ok()
}

# The reader: no schema at the start; the schema once its message is in;
# the end only with the end marker; a feed after the end does nothing.
expect {
	at_start = Ipc.reader.schema() == Err(NoSchema) and !Ipc.reader.is_ended()
	after_schema =
		match Ipc.reader.feed(empty.drop_last(8)) {
			Ok(fed) => fed.reader.schema().map_ok(|s| s.fields.len()) == Ok(15) and !fed.reader.is_ended() and fed.reader.finish().map_ok(|s| s.fields.len()) == Ok(15)
			Err(_) => Bool.False
		}
	after_end =
		match Ipc.reader.feed(sums) {
			Ok(fed) =>
				match fed.reader.feed(sums) {
					Ok(again) => fed.batches.len() == 1 and fed.reader.is_ended() and again.batches.is_empty() and again.reader.is_ended() and again.reader.finish().is_ok()
					Err(_) => Bool.False
				}
			Err(_) => Bool.False
		}
	at_start and after_schema and after_end
}

# finish: the input may stop after a whole message, not inside one, and not before the schema.
expect say(Ipc.reader.finish()) == "invalid: the stream has no schema message"
expect say(Ipc.reader.feed([255, 255, 255, 255, 0, 0, 0, 0]).map_ok(|fed| fed.reader.finish())) == "no error"
expect problem([255, 255, 255, 255, 0, 0, 0, 0]) == "invalid: the stream has no schema message"
expect problem([]) == "invalid: the stream has no schema message"
expect problem(probe3.take_first(2000)) == "invalid: the stream ends inside a message"
expect problem(probe3.take_first(3)) == "invalid: the stream ends inside a message"
expect problem(probe3.drop_first(1152)) == "invalid: a record batch came before the schema"
expect problem(probe3.drop_last(8)) == "no error"

expect {
	# The body of the batch is cut short: no batch yet, and the input may not end here.
	short = probe3.take_first(1152 + 8 + 1208 + 100)
	match Ipc.reader.feed(short) {
		Ok(fed) => fed.batches.is_empty() and say(fed.reader.finish()) == "invalid: the stream ends inside a message"
		Err(_) => Bool.False
	}
}

expect {
	# Random bytes after a valid schema.
	noise = probe3.take_first(1152).concat([255, 255, 255, 255, 16, 0, 0, 0, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9])
	problem(noise) == "invalid: a 32-bit value lies outside the metadata"
}

# A table whose vtable lies before the buffer is an error, not a crash.
expect say(Ipc.reader.feed([255, 255, 255, 255, 8, 0, 0, 0, 4, 0, 0, 0, 5, 0, 0, 0])) == "invalid: the vtable of a table lies outside the metadata"

# What is not a stream is refused as soon as the first bytes tell: the file
# format at its magic, anything else at the first byte that is not the marker.
file_start : List(U8)
file_start = "ARROW1".to_utf8().concat([0, 0, 255, 255, 255, 255, 16, 0, 0, 0])

json_text : List(U8)
json_text = "{\"error\":\"no such table\"}".to_utf8()

expect problem(file_start) == "unsupported: the Arrow file format (this reads the streaming format)"
expect trickle(file_start) == { said: "unsupported: the Arrow file format (this reads the streaming format)", fed: 6, batches: 0 }
expect problem(json_text) == "invalid: not an Arrow IPC stream"
expect trickle(json_text) == { said: "invalid: not an Arrow IPC stream", fed: 1, batches: 0 }
expect trickle("ARROW2".to_utf8()) == { said: "invalid: not an Arrow IPC stream", fed: 6, batches: 0 }
expect trickle("ARR".to_utf8()) == { said: "invalid: the stream ends inside a message", fed: 3, batches: 0 }
expect trickle([255, 255, 0, 0, 0, 0, 0, 0]) == { said: "invalid: not an Arrow IPC stream", fed: 3, batches: 0 }

# The framing of Arrow before 0.15 (a length with no marker before it) is not read.
expect problem(probe3.drop_first(4)) == "invalid: not an Arrow IPC stream"
expect problem(probe3.take_first(1152).concat(probe3.drop_first(1156))) == "invalid: a message does not start with the continuation marker"

# Metadata V4 with the marker reads as V5 does.
expect {
	match Ipc.read_stream(v4) {
		Ok({ schema, batches: [batch] }) => schema.fields.map(|f| f.name) == ["id"] and PrimitiveColumn.i64(column(batch, 0)).map_ok(|c| c.values()) == Ok([7, 8])
		_ => Bool.False
	}
}

# An older version is refused when the metadata is in, before the body is.
expect say(Ipc.reader.feed(old_version)) == "unsupported: metadata version V3 (V4 and V5 are read)"

# A batch is a non-null Struct array of the schema's fields: columns by name.
expect {
	batch = first_batch(probe3)
	by_name =
		match StructColumn.from_array(batch) {
			Ok(columns) => (columns.column("id").map_ok(|a| PrimitiveColumn.i64(a).map_ok(|c| c.values())), columns.column("nope").is_err(), columns.len())
			Err(_) => (Err(NotFound("")), Bool.False, 0)
		}
	fields = Ipc.read_stream(probe3).map_ok(|r| r.schema.fields) ?? []
	batch.data_type() == Struct(fields) and by_name == (Ok(Ok([0, 1, 2])), Bool.True, 3)
}

# A batch of no columns keeps its row count; a batch of no rows keeps its columns.
expect {
	match Ipc.read_stream(zero_columns) {
		Ok({ schema, batches: [batch] }) => schema.fields.is_empty() and batch.len() == 5 and batch.children().is_empty() and batch.data_type() == Struct([])
		_ => Bool.False
	}
}

expect {
	match Ipc.read_stream(zero_rows) {
		Ok({ schema, batches: [batch] }) =>
			schema.fields.map(|f| f.data_type) == [Int64, Utf8] and batch.len() == 0 and batch.children().map(|c| c.len()) == [0, 0]
				and PrimitiveColumn.i64(column(batch, 0)).map_ok(|c| c.values()) == Ok([])
				and Utf8Column.from_array(column(batch, 1)).map_ok(|c| c.len()) == Ok(0)
		_ => Bool.False
	}
}

# The schema's limits. Fields nest 64 levels deep, not 65.
depth_of : DataType -> U64
depth_of = |data_type| 1 + data_type.children().fold(0, |deepest, f| deepest.max(depth_of(f.data_type)))

expect Ipc.read_stream(depth64).map_ok(|r| r.schema.fields.map(|f| depth_of(f.data_type))) == Ok([64])
expect problem(depth65) == "invalid: the schema nests fields deeper than 64 levels"

# Tables and strings that are shared: 1 KB that names 10^10 fields, and 1 KB
# that holds the same 100 bytes of metadata 200 times.
expect problem(fan_out) == "invalid: the schema has more than 100000 fields"
expect problem(shared_text) == "invalid: the names and metadata of the schema are larger than 4 times its message"

# A vector that is longer than the metadata: the fields of a schema, the buffers of a batch.
expect problem(long_vector) == "invalid: a vector of 4294967295 elements lies outside the metadata"
expect problem(long_buffers) == "invalid: a vector of 4294967295 elements lies outside the metadata"

expect problem(probe3.take_first(1152).concat(probe3)) == "invalid: a second schema message"

# Field nodes and buffers that no column uses; a column of another length than its batch.
expect problem(extra_node) == "invalid: the record batch names 2 field nodes; its columns have 1"
expect problem(extra_buffer) == "invalid: the record batch names 3 buffers; its columns have 2"
expect problem(short_column) == "invalid: column 'id' has 2 rows, the batch has 3"

# An error of a column's buffers names the batch and the column.
expect problem(bad_offsets) == "invalid: record batch 0, column 'name': offsets decrease at row 1"

# An error of the schema names the field.
expect problem(time_unit) == "invalid: unknown time unit 7 in field 'ts'"
expect problem(type_id) == "invalid: unknown type id 30 in field 'x'"
