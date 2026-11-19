## A calendar interval in whole months (Arrow Interval(YearMonth), one i32).
IntervalYearMonth := { months : I32 }.{

	## Derived structural equality: `==` and `!=`.
	is_eq : _

	## From a signed month count.
	from_months : I32 -> IntervalYearMonth
	from_months = |months| { months: months }

	## Years and the remaining months, both with the interval's sign.
	parts : IntervalYearMonth -> { years : I32, months : I32 }
	parts = |i| { years: i.months // 12, months: i.months % 12 }
}

expect IntervalYearMonth.from_months(-14).parts() == { years: -1, months: -2 }
