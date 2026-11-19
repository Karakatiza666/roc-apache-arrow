## Days since 1970-01-01 (Arrow Date32), proleptic Gregorian calendar.
Date32 := { days : I32 }.{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## From days since 1970-01-01. Any `I32` is accepted.
	from_days : I32 -> Date32
	from_days = |days| { days: days }

	## Fails for an invalid month or day.
	from_ymd : I32, U8, U8 -> Try(Date32, [InvalidDate])
	from_ymd = |year, month, day| {
		if month < 1 or month > 12 or day < 1 or day > days_in_month(year.to_i64(), month) {
			return Err(InvalidDate)
		}
		# Days from civil, after Howard Hinnant's algorithm.
		y = if (month <= 2) year.to_i64() - 1 else year.to_i64()
		era = y.div_floor_by(400)
		yoe = y - era * 400
		m = month.to_i64()
		doy = (153 * (if (m > 2) m - 3 else m + 9) + 2) // 5 + day.to_i64() - 1
		doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
		match (era * 146_097 + doe - 719_468).to_i32_try() {
			Ok(days) => Ok({ days: days })
			Err(_) => Err(InvalidDate)
		}
	}

	## The proleptic Gregorian year, month (1 ..= 12) and day (1 ..= 31).
	to_ymd : Date32 -> { year : I32, month : U8, day : U8 }
	to_ymd = |date| {
		z = date.days.to_i64() + 719_468
		era = z.div_floor_by(146_097)
		doe = z - era * 146_097
		yoe = (doe - doe // 1460 + doe // 36_524 - doe // 146_096) // 365
		doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
		mp = (5 * doy + 2) // 153
		d = doy - (153 * mp + 2) // 5 + 1
		m = if (mp < 10) mp + 3 else mp - 9
		y = yoe + era * 400 + (if (m <= 2) 1 else 0)
		{ year: y.to_i32_wrap(), month: m.to_u8_wrap(), day: d.to_u8_wrap() }
	}
}

days_in_month : I64, U8 -> U8
days_in_month = |year, month| match month {
	2 => if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 29 else 28
	4 | 6 | 9 | 11 => 30
	_ => 31
}

expect Date32.from_ymd(1970, 1, 1) == Ok(Date32.from_days(0))
expect Date32.from_ymd(2000, 2, 29).map_ok(|d| d.to_ymd()) == Ok({ year: 2000, month: 2, day: 29 })
expect Date32.from_days(-1).to_ymd() == { year: 1969, month: 12, day: 31 }
expect Date32.from_ymd(2023, 2, 29) == Err(InvalidDate)
