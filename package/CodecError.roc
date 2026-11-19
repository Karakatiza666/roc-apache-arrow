import DataType

## Why the Arrow codec could not read or write a value. `path` names the
## position, for example `f1.f0[2]`; it is empty at the top level.
CodecError := [
	## The Roc shape asks for `expected`, the column has another physical type.
	TypeMismatch({ path : Str, expected : Str, found : DataType }),

	## A null at a position whose Roc type is not `Try(_, [Null])`.
	UnexpectedNull(Str),
	MissingField(Str),

	## A record has a field the Struct column does not have (encode).
	UnknownField(Str),
	ArityMismatch({ path : Str, expected : U64, found : U64 }),
	InvalidUtf8(Str),

	## A value does not fit the target (Decimal precision, Dec range).
	OutOfRange(Str),
	RowOutOfBounds(U64),
].{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## A one-line message that names the path, for example
	## `at 'a.b': expected Int64, found Utf8`.
	to_str : CodecError -> Str
	to_str = |err| match err {
		TypeMismatch({ path, expected, found }) => "at '${path}': expected ${expected}, found ${Str.inspect(found)}"
		UnexpectedNull(path) => "at '${path}': unexpected null"
		MissingField(name) => "missing field '${name}'"
		UnknownField(name) => "the column has no field '${name}'"
		ArityMismatch({ path, expected, found }) => "at '${path}': expected ${expected.to_str()} fields, found ${found.to_str()}"
		InvalidUtf8(path) => "at '${path}': invalid UTF-8"
		OutOfRange(path) => "at '${path}': value out of range"
		RowOutOfBounds(row) => "row ${row.to_str()} is out of bounds"
	}
}

expect CodecError.to_str(TypeMismatch({ path: "f1[0]", expected: "I64", found: Utf8 })) == "at 'f1[0]': expected I64, found Utf8"
expect CodecError.to_str(UnexpectedNull("f0")) == "at 'f0': unexpected null"
expect CodecError.to_str(MissingField("id")) == "missing field 'id'"
expect CodecError.to_str(UnknownField("id")) == "the column has no field 'id'"
expect CodecError.to_str(ArityMismatch({ path: "t", expected: 2, found: 3 })) == "at 't': expected 2 fields, found 3"
expect CodecError.to_str(InvalidUtf8("s")) == "at 's': invalid UTF-8"
expect CodecError.to_str(OutOfRange("d")) == "at 'd': value out of range"
expect CodecError.to_str(RowOutOfBounds(7)) == "row 7 is out of bounds"
