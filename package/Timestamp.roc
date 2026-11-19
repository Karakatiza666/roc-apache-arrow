import DataType
import TimeUnit

## An instant (or a wall-clock reading when `zone` is empty): a count of
## `unit` since 1970-01-01T00:00:00. The column's `DataType` carries the unit
## and zone; the codec reads the raw count as `I64`.
Timestamp := { since_epoch : I64, unit : TimeUnit, zone : Str }.{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## A raw value of a Timestamp column.
	from_raw : I64, DataType -> Try(Timestamp, [TypeMismatch(DataType)])
	from_raw = |raw, dt| match dt {
		Timestamp(unit, zone) => Ok({ since_epoch: raw, unit, zone })
		_ => Err(TypeMismatch(dt))
	}

	## The column type: `Timestamp(unit, zone)`.
	data_type : Timestamp -> DataType
	data_type = |ts| Timestamp(ts.unit, ts.zone)

	## The same instant in another unit; exact or an error.
	to_unit : Timestamp, TimeUnit -> Try(Timestamp, [Overflow, Inexact])
	to_unit = |ts, unit| {
		moved = TimeUnit.convert(ts.since_epoch, ts.unit, unit)?
		Ok({ ..ts, since_epoch: moved, unit })
	}

	## Days since the epoch (floor) and the time of day in `unit`.
	split_day : Timestamp -> { days : I64, time_of_day : I64 }
	split_day = |ts| {
		per_day = ts.unit.per_second() * 86_400
		days = ts.since_epoch.div_floor_by(per_day)
		{ days, time_of_day: ts.since_epoch - days * per_day }
	}
}

expect Timestamp.from_raw(1_500, Timestamp(Millisecond, "")).map_ok(|t| t.to_unit(Second)) == Ok(Err(Inexact))
expect Timestamp.from_raw(-1, Timestamp(Second, "+00:00")).map_ok(|t| t.split_day()) == Ok({ days: -1, time_of_day: 86_399 })
expect Timestamp.from_raw(1, Int64).is_err()
expect Timestamp.from_raw(5, Timestamp(Nanosecond, "UTC")).map_ok(|t| t.data_type()) == Ok(Timestamp(Nanosecond, "UTC"))
