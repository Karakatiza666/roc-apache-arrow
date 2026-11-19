## The host-facing ABI: what a C Data Interface host (Rust, Zig, C) fills in
## to hand Roc an Arrow tree, and what Roc hands back.
##
## Every buffer is a Roc list. A host wraps a foreign buffer with zero copy by
## pointing the list's allocation word at a static refcount word (refcount 0),
## so Roc never frees or mutates it. The records use declared-order layout
## (the unnamed `_ : {}` field), so a host can mirror them as plain C structs.
## The glue header that `roc glue` writes for a platform gives the exact offsets.
Host :: [].{

	## One Arrow buffer. The host picks the typed variant from the buffer's role
	## in the format string; `U8s` is always accepted and Roc copies it into
	## the typed form (the pure-Roc and unaligned path). `Absent` is a NULL
	## buffer pointer. Tags are numbered alphabetically: Absent = 0 ... U8s = 11,
	## Utf8 = 12.
	##
	## `Utf8` is the trusted text path: the data buffer of a Utf8 or LargeUtf8
	## array as a `Str`, so Roc does not check its UTF-8. The host promises that
	## the bytes are valid UTF-8. Roc does not check this, and invalid bytes
	## break the invariants of `Str`. A host that cannot promise it passes `U8s`.
	Buffer := [
		Absent,
		F32s(List(F32)),
		F64s(List(F64)),
		I128s(List(I128)),
		I16s(List(I16)),
		I32s(List(I32)),
		I64s(List(I64)),
		I8s(List(I8)),
		U16s(List(U16)),
		U32s(List(U32)),
		U64s(List(U64)),
		U8s(List(U8)),
		Utf8(Str),
	].{
		is_eq : _

		## The number of elements, not bytes. Bytes for `Utf8`.
		len : Host.Buffer -> U64
		len = |buffer| match buffer {
			Absent => 0
			F32s(xs) => xs.len()
			F64s(xs) => xs.len()
			I128s(xs) => xs.len()
			I16s(xs) => xs.len()
			I32s(xs) => xs.len()
			I64s(xs) => xs.len()
			I8s(xs) => xs.len()
			U16s(xs) => xs.len()
			U32s(xs) => xs.len()
			U64s(xs) => xs.len()
			U8s(xs) => xs.len()
			Utf8(text) => text.count_utf8_bytes()
		}
	}

	## Mirrors `struct ArrowArray` without the callbacks. `dictionary` holds
	## zero or one array. `null_count` is -1 when unknown.
	Array := {
		length : I64,
		null_count : I64,
		offset : I64,
		buffers : List(Host.Buffer),
		children : List(Host.Array),
		dictionary : List(Host.Array),
		_ : {},
	}

	## Mirrors `struct ArrowSchema`. Text fields are UTF-8 bytes without the
	## trailing NUL; `metadata` is the C binary encoding (empty for NULL).
	## `flags` uses the C values: 1 dictionary ordered, 2 nullable, 4 map keys
	## sorted. `dictionary` holds zero or one schema.
	Schema := {
		format : List(U8),
		name : List(U8),
		metadata : List(U8),
		flags : I64,
		children : List(Host.Schema),
		dictionary : List(Host.Schema),
		_ : {},
	}

	## The C flag `ARROW_FLAG_DICTIONARY_ORDERED` (1).
	flag_dictionary_ordered : I64
	flag_dictionary_ordered = 1

	## The C flag `ARROW_FLAG_NULLABLE` (2).
	flag_nullable : I64
	flag_nullable = 2

	## The C flag `ARROW_FLAG_MAP_KEYS_SORTED` (4).
	flag_map_keys_sorted : I64
	flag_map_keys_sorted = 4

	## An array with no buffers or children, for building trees in Roc.
	empty_array : I64 -> Host.Array
	empty_array = |length| { length, null_count: 0, offset: 0, buffers: [], children: [], dictionary: [] }
}

expect Host.Buffer.len(I64s([1, 2, 3])) == 3
expect Host.Buffer.len(Utf8("aé")) == 3
expect Host.empty_array(4).length == 4

# The flags hold the values of the C Data Interface.
expect Host.flag_dictionary_ordered == 1 and Host.flag_nullable == 2 and Host.flag_map_keys_sorted == 4
