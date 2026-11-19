import TimeUnit

## An elapsed time (Arrow Duration): a signed count of `unit`.
Duration := { count : I64, unit : TimeUnit }.{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## A count of `unit`. Any `I64` is accepted.
	new : I64, TimeUnit -> Duration
	new = |count, unit| { count, unit }

	## The same length in another unit; exact or an error.
	to_unit : Duration, TimeUnit -> Try(Duration, [Overflow, Inexact])
	to_unit = |d, unit| {
		moved = TimeUnit.convert(d.count, d.unit, unit)?
		Ok({ count: moved, unit })
	}
}

expect Duration.new(90, Second).to_unit(Microsecond) == Ok(Duration.new(90_000_000, Microsecond))
