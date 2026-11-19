## Which rows of an array hold a value. `Bits` is an Arrow LSB bitmap with a
## bit offset; the offset stays a bit offset so slicing never copies.
Validity := [AllValid, Bits(List(U8), U64)].{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## Whether row `i` holds a value. Rows past the bitmap read as null.
	is_valid : Validity, U64 -> Bool
	is_valid = |v, i| match v {
		AllValid => Bool.True
		Bits(bits, offset) => bit_at(bits, offset + i)
	}

	## Null rows among the first `n` rows.
	null_count : Validity, U64 -> U64
	null_count = |v, n| match v {
		AllValid => 0
		Bits(bits, offset) => (0.U64).until(n).fold(0, |acc, i| if (bit_at(bits, offset + i)) acc else acc + 1)
	}

	## Drop the first `start` rows.
	skip : Validity, U64 -> Validity
	skip = |v, start| match v {
		AllValid => AllValid
		Bits(bits, offset) => Bits(bits, offset + start)
	}

	## A bitmap from booleans, `True` = valid.
	from_bools : List(Bool) -> Validity
	from_bools = |flags| if (flags.all(|f| f)) AllValid else Bits(pack_bits(flags), 0)

	## The bitmap of the first `n` rows with bit offset 0, as an Arrow buffer
	## wants it. Zero copy when the offset is a multiple of 8.
	to_bitmap : Validity, U64 -> Try(List(U8), [AllValid])
	to_bitmap = |v, n| match v {
		AllValid => Err(AllValid)
		Bits(bits, offset) => Ok(realign(bits, offset, n))
	}

	## Bit `i` of an LSB bitmap; out of range reads as 0.
	bit : List(U8), U64 -> Bool
	bit = |bits, i| bit_at(bits, i)

	## Pack booleans into an LSB bitmap.
	pack : List(Bool) -> List(U8)
	pack = |flags| pack_bits(flags)

	## The first `n` bits from bit `offset`, moved to offset 0.
	realign_bits : List(U8), U64, U64 -> List(U8)
	realign_bits = |bits, offset, n| realign(bits, offset, n)
}

bit_at : List(U8), U64 -> Bool
bit_at = |bits, i| match bits.get(i.shr_zf_wrap(3)) {
	Ok(byte) => byte.shr_zf_wrap(i.bitwise_and(7).to_u8_wrap()).bitwise_and(1) == 1
	Err(_) => Bool.False
}

pack_bits : List(Bool) -> List(U8)
pack_bits = |flags| {
	var $out = List.with_capacity((flags.len() + 7) // 8)
	var $byte = 0.U8
	var $i = 0.U64
	for f in flags {
		if f {
			$byte = $byte.bitwise_or((1.U8).shl_wrap($i.bitwise_and(7).to_u8_wrap()))
		}
		$i = $i + 1
		if $i.bitwise_and(7) == 0 {
			$out = $out.append($byte)
			$byte = 0
		}
	}
	if $i.bitwise_and(7) != 0 {
		$out = $out.append($byte)
	}
	$out
}

realign : List(U8), U64, U64 -> List(U8)
realign = |bits, offset, n|
	if offset.bitwise_and(7) == 0 {
		bits.sublist({ start: offset.shr_zf_wrap(3), len: (n + 7) // 8 })
	} else {
		pack_bits((0.U64).until(n).map(|i| bit_at(bits, offset + i)).collect())
	}

expect Validity.pack([Bool.True, Bool.False, Bool.True]) == [5]
expect Validity.is_valid(Bits([0b0000_0101], 0), 2)
expect !Validity.is_valid(Bits([0b0000_0101], 1), 0)
expect Validity.null_count(Bits([0b0000_0101], 0), 3) == 1
expect Validity.realign_bits([0b1010_1010, 0b0000_0001], 1, 8) == [0b1101_0101]

# from_bools: all valid needs no bitmap; a null packs LSB first across bytes.
expect Validity.from_bools([Bool.True, Bool.True]) == AllValid
expect Validity.from_bools([]) == AllValid
expect Validity.from_bools([Bool.True, Bool.False, Bool.True]) == Bits([0b0000_0101], 0)
expect Validity.from_bools([Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.False]) == Bits([0b1111_1111, 0], 0)
