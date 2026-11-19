## Key-value metadata of a field or schema, in insertion order.
##
## The C Data Interface encodes it as `n : i32`, then per entry
## `klen : i32, key, vlen : i32, value`, native byte order (little-endian on
## every target this package supports).
Metadata := { entries : List({ key : Str, value : Str }) }.{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## No entries; encodes to an empty buffer.
	empty : Metadata
	empty = { entries: [] }

	## The entries in this order. Duplicate keys are kept as given.
	from_pairs : List({ key : Str, value : Str }) -> Metadata
	from_pairs = |pairs| { entries: pairs }

	## The entries in order.
	to_pairs : Metadata -> List({ key : Str, value : Str })
	to_pairs = |metadata| metadata.entries

	## The value of the first entry with this key.
	get : Metadata, Str -> Try(Str, [NotFound])
	get = |metadata, key| match metadata.to_pairs().find_first(|entry| entry.key == key) {
		Ok(entry) => Ok(entry.value)
		Err(_) => Err(NotFound)
	}

	## Replace the value of `key`, or append the entry when the key is new.
	insert : Metadata, Str, Str -> Metadata
	insert = |metadata, key, value| {
		pairs = metadata.to_pairs()
		if pairs.any(|entry| entry.key == key) {
			{ entries: pairs.map(|entry| if (entry.key == key) { key, value } else entry) }
		} else {
			{ entries: pairs.append({ key, value }) }
		}
	}

	## Decode the C Data Interface binary form. An empty buffer is no metadata.
	decode : List(U8) -> Try(Metadata, [InvalidMetadata(Str)])
	decode = |bytes| {
		if bytes.is_empty() {
			return Ok(Metadata.empty)
		}
		count = read_len(bytes, 0)?
		var $at = 4
		var $pairs = List.with_capacity(count)
		for _ in (0.U64).until(count) {
			key = read_str(bytes, $at)?
			value = read_str(bytes, key.next)?
			$pairs = $pairs.append({ key: key.text, value: value.text })
			$at = value.next
		}
		Ok({ entries: $pairs })
	}

	## Encode to the C Data Interface binary form. No entries encode to an
	## empty buffer, which a host passes as a NULL `metadata` pointer.
	encode : Metadata -> List(U8)
	encode = |metadata| {
		pairs = metadata.to_pairs()
		if pairs.is_empty() {
			return []
		}
		pairs.fold(
			le_i32(pairs.len()),
			|out, entry| {
				key = entry.key.to_utf8()
				value = entry.value.to_utf8()
				out.concat(le_i32(key.len())).concat(key).concat(le_i32(value.len())).concat(value)
			},
		)
	}
}

le_i32 : U64 -> List(U8)
le_i32 = |n| {
	x = n.to_u32_wrap()
	[x.to_u8_wrap(), x.shr_zf_wrap(8).to_u8_wrap(), x.shr_zf_wrap(16).to_u8_wrap(), x.shr_zf_wrap(24).to_u8_wrap()]
}

read_len : List(U8), U64 -> Try(U64, [InvalidMetadata(Str)])
read_len = |bytes, at| match I32.from_le_bytes(bytes, at) {
	Ok(n) if n >= 0 => Ok(n.to_u64_wrap())
	_ => Err(InvalidMetadata("bad length at byte ${at.to_str()}"))
}

read_str : List(U8), U64 -> Try({ text : Str, next : U64 }, [InvalidMetadata(Str)])
read_str = |bytes, at| {
	len = read_len(bytes, at)?
	start = at + 4
	if start + len > bytes.len() {
		return Err(InvalidMetadata("entry past the end at byte ${at.to_str()}"))
	}
	match Str.from_utf8(bytes.sublist({ start, len })) {
		Ok(text) => Ok({ text, next: start + len })
		Err(_) => Err(InvalidMetadata("invalid UTF-8 at byte ${start.to_str()}"))
	}
}

expect {
	m = Metadata.from_pairs([{ key: "k", value: "vv" }, { key: "a", value: "" }])
	Metadata.decode(m.encode()) == Ok(m)
}

expect Metadata.decode([]) == Ok(Metadata.empty)
expect Metadata.decode([1, 0, 0, 0, 9, 0, 0, 0]).is_err()

# get finds the first entry with the key, NotFound for a missing key.
expect {
	m = Metadata.from_pairs([{ key: "k", value: "1" }, { key: "k", value: "2" }])
	m.get("k") == Ok("1") and m.get("x") == Err(NotFound) and Metadata.empty.get("k") == Err(NotFound)
}

# insert replaces in place and appends a new key at the end.
expect {
	m = Metadata.empty.insert("a", "1").insert("b", "2").insert("a", "3")
	m.to_pairs() == [{ key: "a", value: "3" }, { key: "b", value: "2" }]
}

expect Metadata.empty.to_pairs() == []
