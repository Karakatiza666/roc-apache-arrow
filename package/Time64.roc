import TimeUnit

## A time of day (Arrow Time64): microseconds or nanoseconds since midnight.
Time64 := { since_midnight : I64, unit : TimeUnit }.{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## Fails outside one day or for a unit coarser than microseconds.
	new : I64, TimeUnit -> Try(Time64, [OutOfRange])
	new = |since_midnight, unit| {
		day = unit.per_second() * 86_400
		if unit.per_second() < 1_000_000 or since_midnight < 0 or since_midnight >= day {
			Err(OutOfRange)
		} else {
			Ok({ since_midnight, unit })
		}
	}

	## Hours, minutes, seconds and the sub-second part in this time's unit.
	parts : Time64 -> { hour : U8, minute : U8, second : U8, fraction : I64 }
	parts = |t| {
		per = t.unit.per_second()
		secs = t.since_midnight // per
		{
			hour: (secs // 3600).to_u8_wrap(),
			minute: ((secs % 3600) // 60).to_u8_wrap(),
			second: (secs % 60).to_u8_wrap(),
			fraction: t.since_midnight % per,
		}
	}
}

expect Time64.new(3_723_000_000_005, Nanosecond).map_ok(|t| t.parts()) == Ok({ hour: 1, minute: 2, second: 3, fraction: 5 })
expect Time64.new(-1, Microsecond).is_err()
