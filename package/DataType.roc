import Metadata
import TimeUnit
import IntervalUnit
import UnionMode

## The Arrow logical type of a column. A nested type holds its children as
## `DataType.Field`s, so names, nullability and metadata stay with the child.
##
## `Timestamp`'s `Str` is the time zone; `""` means none (the C format
## `tsu:` with nothing after the colon).
DataType := [
	Null,
	Boolean,
	Int8,
	Int16,
	Int32,
	Int64,
	UInt8,
	UInt16,
	UInt32,
	UInt64,
	Float16,
	Float32,
	Float64,
	Decimal32({ precision : U8, scale : I8 }),
	Decimal64({ precision : U8, scale : I8 }),
	Decimal128({ precision : U8, scale : I8 }),
	Decimal256({ precision : U8, scale : I8 }),
	Date32,
	Date64,
	Time32(TimeUnit),
	Time64(TimeUnit),
	Timestamp(TimeUnit, Str),
	Duration(TimeUnit),
	Interval(IntervalUnit),
	Binary,
	LargeBinary,
	BinaryView,
	FixedSizeBinary(U64),
	Utf8,
	LargeUtf8,
	Utf8View,
	List(DataType.Field),
	LargeList(DataType.Field),
	ListView(DataType.Field),
	LargeListView(DataType.Field),
	FixedSizeList(DataType.Field, U64),
	Struct(List(DataType.Field)),

	## The entries field (a non-null Struct of key and value) and keys_sorted.
	Map(DataType.Field, Bool),
	Union(UnionMode, List(I8), List(DataType.Field)),

	## Index type, value type, ordered.
	Dictionary(DataType, DataType, Bool),

	## Run ends field, values field.
	RunEndEncoded(DataType.Field, DataType.Field),
].{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## A child of a nested type. A structural record, so it compares with `==`.
	Field : { name : Str, data_type : DataType, nullable : Bool, metadata : Metadata }

	## A field with no metadata.
	field : Str, DataType, Bool -> DataType.Field
	field = |name, data_type, nullable| { name, data_type, nullable, metadata: Metadata.empty }

	## A list of `item : child`, nullable items.
	list_of : DataType -> DataType
	list_of = |child| List(DataType.field("item", child, Bool.True))

	## `Map` with the canonical `entries { key, value }` layout.
	map_of : DataType, DataType, Bool -> DataType
	map_of = |key, value, value_nullable| {
		entries = Struct([DataType.field("key", key, Bool.False), DataType.field("value", value, value_nullable)])
		Map(DataType.field("entries", entries, Bool.False), Bool.False)
	}

	## The child fields in C Data Interface child order.
	children : DataType -> List(DataType.Field)
	children = |data_type| match data_type {
		List(f) | LargeList(f) | ListView(f) | LargeListView(f) | FixedSizeList(f, _) | Map(f, _) => [f]
		Struct(fs) | Union(_, _, fs) => fs
		RunEndEncoded(ends, values) => [ends, values]
		_ => []
	}

	## Byte width of one value for fixed-width types, `Err(NotFixedWidth)`
	## otherwise. Boolean is bit-packed and so not fixed-width here.
	byte_width : DataType -> Try(U64, [NotFixedWidth])
	byte_width = |data_type| match data_type {
		Int8 | UInt8 => Ok(1)
		Int16 | UInt16 | Float16 => Ok(2)
		Int32 | UInt32 | Float32 | Date32 | Time32(_) | Decimal32(_) => Ok(4)
		Interval(YearMonth) => Ok(4)
		Int64 | UInt64 | Float64 | Date64 | Time64(_) | Timestamp(_, _) | Duration(_) | Decimal64(_) => Ok(8)
		Interval(DayTime) => Ok(8)
		Decimal128(_) | Interval(MonthDayNano) => Ok(16)
		Decimal256(_) => Ok(32)
		FixedSizeBinary(n) => Ok(n)
		_ => Err(NotFixedWidth)
	}
}

# byte_width of each fixed layout; bit-packed and variable layouts have none.
expect [Int8, UInt8, Int16, Float16, Int32, Date32, Time32(Second), Decimal32({ precision: 9, scale: 0 }), Interval(YearMonth)].map(DataType.byte_width) == [Ok(1), Ok(1), Ok(2), Ok(2), Ok(4), Ok(4), Ok(4), Ok(4), Ok(4)]
expect [Int64, Float64, Timestamp(Second, ""), Duration(Second), Decimal64({ precision: 18, scale: 0 }), Interval(DayTime)].map(DataType.byte_width) == [Ok(8), Ok(8), Ok(8), Ok(8), Ok(8), Ok(8)]
expect [Decimal128({ precision: 38, scale: 0 }), Interval(MonthDayNano), Decimal256({ precision: 76, scale: 0 }), FixedSizeBinary(5)].map(DataType.byte_width) == [Ok(16), Ok(16), Ok(32), Ok(5)]
expect [Boolean, Null, Utf8, Binary, DataType.list_of(Int8), Struct([])].map(DataType.byte_width) == [Err(NotFixedWidth), Err(NotFixedWidth), Err(NotFixedWidth), Err(NotFixedWidth), Err(NotFixedWidth), Err(NotFixedWidth)]
