import DataType

## A Decimal128 value: an unscaled I128 with its precision and scale, the
## value being `unscaled * 10^-scale`.
Decimal := { unscaled : I128, precision : U8, scale : I8 }.{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## Check that `unscaled` fits `precision` digits (1 ..= 38).
	new : I128, U8, I8 -> Try(Decimal, [OutOfRange])
	new = |unscaled, precision, scale|
		if precision < 1 or precision > 38 or unscaled.abs_diff(0) >= pow10(precision.to_u64()).to_u128_wrap() {
			Err(OutOfRange)
		} else {
			Ok({ unscaled, precision, scale })
		}

	## The column type of this value: `Decimal128(precision, scale)`.
	data_type : Decimal -> DataType
	data_type = |d| Decimal128({ precision: d.precision, scale: d.scale })

	## Exact conversion: fails when digits below 10^-18 are not zero, or the
	## value is outside Dec's range.
	to_dec : Decimal -> Try(Dec, [OutOfRange])
	to_dec = |d| Decimal.unscaled_to_dec(d.unscaled, d.scale)

	## Round to `scale` digits (half away from zero) and check `precision`.
	from_dec : Dec, U8, I8 -> Try(Decimal, [OutOfRange])
	from_dec = |value, precision, scale| {
		attos = value.to_attos()
		shift = 18 - scale.to_i64()
		unscaled =
			if shift >= 0 {
				divisor = pow10(shift.to_u64_wrap())
				q = attos // divisor
				r = attos % divisor
				if r.abs_diff(0) * 2 >= divisor.to_u128_wrap() {
					if (attos < 0) q - 1 else q + 1
				} else q
			} else {
				attos.times_try(pow10((0 - shift).to_u64_wrap())) ? |_| OutOfRange
			}
		Decimal.new(unscaled, precision, scale)
	}

	## `unscaled * 10^-scale` as a Dec, exact or `Err(OutOfRange)`.
	unscaled_to_dec : I128, I8 -> Try(Dec, [OutOfRange])
	unscaled_to_dec = |unscaled, scale| {
		shift = 18 - scale.to_i64()
		attos =
			if shift >= 0 {
				unscaled.times_try(pow10(shift.to_u64_wrap())) ? |_| OutOfRange
			} else {
				divisor = pow10((0 - shift).to_u64_wrap())
				if unscaled % divisor != 0 {
					return Err(OutOfRange)
				}
				unscaled // divisor
			}
		Ok(Dec.from_attos(attos))
	}
}

pow10 : U64 -> I128
pow10 = |n| (0.U64).until(n).fold(1.I128, |acc, _| acc * 10)

expect Decimal.unscaled_to_dec(12345, 2) == Ok(123.45)
expect Decimal.unscaled_to_dec(-5, 0) == Ok(-5)
expect Decimal.unscaled_to_dec(1, 19).is_err()
expect Decimal.unscaled_to_dec(10, 19) == Ok(Dec.from_attos(1))
expect Decimal.from_dec(1.005, 10, 2).map_ok(|d| d.unscaled) == Ok(101)
expect Decimal.from_dec(-1.005, 10, 2).map_ok(|d| d.unscaled) == Ok(-101)
expect Decimal.from_dec(123.45, 4, 2).is_err()
expect Decimal.new(99999, 5, 0).is_ok() and Decimal.new(100000, 5, 0).is_err()
expect Decimal.new(12345, 10, 2).map_ok(|d| d.data_type()) == Ok(Decimal128({ precision: 10, scale: 2 }))

# to_dec is exact, and refuses digits below 10^-18.
expect {
	a = Decimal.new(-12_345, 5, 2) ?? crash "a"
	b = Decimal.new(100, 3, 20) ?? crash "b"
	c = Decimal.new(1, 1, 20) ?? crash "c"
	a.to_dec() == Ok(-123.45) and b.to_dec() == Ok(0.000000000000000001) and c.to_dec() == Err(OutOfRange)
}
