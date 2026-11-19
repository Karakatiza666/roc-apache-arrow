import DataType exposing [Field]
import Format
import Host
import Metadata

## A record batch's schema: the top-level fields and schema-level metadata.
## On the C Data Interface it is a `+s` ArrowSchema whose children are the
## fields.
Schema := { fields : List(Field), metadata : Metadata }.{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## A schema of these fields, with no metadata.
	new : List(Field) -> Schema
	new = |fields| { fields, metadata: Metadata.empty }

	## The field with this name.
	find : Schema, Str -> Try(Field, [NotFound(Str)])
	find = |schema, name| schema.fields.find_first(|f| f.name == name).map_err(|_| NotFound(name))

	## The schema as one Struct data type, as the C Data Interface carries it.
	to_data_type : Schema -> DataType
	to_data_type = |schema| Struct(schema.fields)

	## Read a schema from a `+s` host schema tree.
	from_host : Host.Schema -> Try(Schema, [InvalidSchema(Str)])
	from_host = |root| {
		top = Schema.field_from_host(root)?
		match top.data_type {
			Struct(fields) => Ok({ fields, metadata: top.metadata })
			_ => Err(InvalidSchema("a schema root must have format +s"))
		}
	}

	## Write the schema as a `+s` host schema whose children are the fields.
	to_host : Schema -> Host.Schema
	to_host = |schema| Schema.field_to_host({ name: "", data_type: Struct(schema.fields), nullable: Bool.False, metadata: schema.metadata })

	## Read one field (and its subtree) from a host schema node.
	field_from_host : Host.Schema -> Try(Field, [InvalidSchema(Str)])
	field_from_host = |node| {
		format_text = utf8(node.format, "format")?
		name = utf8(node.name, "name")?
		metadata = Metadata.decode(node.metadata) ? |InvalidMetadata(why)| InvalidSchema("field '${name}': ${why}")
		head = Format.parse(format_text) ? |InvalidFormat(f)| InvalidSchema("field '${name}': unknown format '${f}'")
		kids = node.children.map_try(Schema.field_from_host)?
		built = Format.build(head, kids) ? |InvalidFormat(why)| InvalidSchema("field '${name}': ${why}")
		with_flags = match built {
			Map(entries, _) => Map(entries, node.flags.bitwise_and(Host.flag_map_keys_sorted) != 0)
			other => other
		}
		data_type = match node.dictionary {
			[] => with_flags
			[values] => {
				value_field = Schema.field_from_host(values)?
				Dictionary(with_flags, value_field.data_type, node.flags.bitwise_and(Host.flag_dictionary_ordered) != 0)
			}
			_ => return Err(InvalidSchema("field '${name}': more than one dictionary"))
		}
		Ok({ name, data_type, nullable: node.flags.bitwise_and(Host.flag_nullable) != 0, metadata })
	}

	## Write one field and its subtree as a host schema node.
	field_to_host : Field -> Host.Schema
	field_to_host = |field| {
		nullable = if (field.nullable) Host.flag_nullable else 0
		extra = match field.data_type {
			Map(_, Bool.True) => Host.flag_map_keys_sorted
			Dictionary(_, _, Bool.True) => Host.flag_dictionary_ordered
			_ => 0
		}
		dictionary = match field.data_type {
			Dictionary(_, values, _) => [Schema.field_to_host(DataType.field("", values, Bool.True))]
			_ => []
		}
		{
			format: Format.print(field.data_type).to_utf8(),
			name: field.name.to_utf8(),
			metadata: field.metadata.encode(),
			flags: nullable.bitwise_or(extra),
			children: field.data_type.children().map(Schema.field_to_host),
			dictionary,
		}
	}
}

utf8 : List(U8), Str -> Try(Str, [InvalidSchema(Str)])
utf8 = |bytes, what| Str.from_utf8(bytes).map_err(|_| InvalidSchema("${what} is not UTF-8"))

sample : Schema
sample = Schema.new([
	DataType.field("f0", Int64, Bool.False),
	DataType.field("f1", DataType.list_of(Utf8), Bool.True),
	DataType.field("f2", DataType.map_of(Utf8, Decimal128({ precision: 10, scale: 2 }), Bool.True), Bool.True),
	DataType.field("f3", Timestamp(Microsecond, "+00:00"), Bool.True),
	DataType.field("f4", Struct([DataType.field("metadata", BinaryView, Bool.False), DataType.field("value", BinaryView, Bool.False)]), Bool.True),
	DataType.field("f5", Dictionary(Int32, Utf8, Bool.False), Bool.True),
])

expect Schema.from_host(sample.to_host()) == Ok(sample)
expect Schema.to_host(sample).children.len() == 6
expect Schema.from_host({ format: "l".to_utf8(), name: [], metadata: [], flags: 0, children: [], dictionary: [] }).is_err()

# find gives the field by name, NotFound with the name otherwise.
expect sample.find("f3").map_ok(|f| f.data_type) == Ok(Timestamp(Microsecond, "+00:00"))
expect sample.find("f9") == Err(NotFound("f9"))
