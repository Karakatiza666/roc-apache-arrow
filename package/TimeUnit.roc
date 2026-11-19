## The resolution of a time, timestamp or duration value.
TimeUnit := [Second, Millisecond, Microsecond, Nanosecond].{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## How many of this unit make one second.
	per_second : TimeUnit -> I64
	per_second = |unit| match unit {
		Second => 1
		Millisecond => 1_000
		Microsecond => 1_000_000
		Nanosecond => 1_000_000_000
	}

	## Convert a count of `from` units to `to` units. Exact or an error: a
	## coarser unit with a remainder is `Inexact`.
	convert : I64, TimeUnit, TimeUnit -> Try(I64, [Overflow, Inexact])
	convert = |value, from, to| {
		f = from.per_second()
		t = to.per_second()
		if t >= f {
			value.times_try(t // f).map_err(|_| Overflow)
		} else if value % (f // t) != 0 {
			Err(Inexact)
		} else {
			Ok(value // (f // t))
		}
	}
}

expect TimeUnit.convert(3, Second, Millisecond) == Ok(3000)
expect TimeUnit.convert(1_500, Microsecond, Millisecond) == Err(Inexact)
expect TimeUnit.convert(2_000, Microsecond, Millisecond) == Ok(2)
expect TimeUnit.convert(I64.highest, Second, Nanosecond) == Err(Overflow)
