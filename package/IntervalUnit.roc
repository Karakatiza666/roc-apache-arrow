## The physical layout of an Arrow Interval: months (i32), days and millis
## (2 x i32), or months, days and nanos (i32, i32, i64).
IntervalUnit := [YearMonth, DayTime, MonthDayNano].{

	## Derived structural equality: `==` and `!=`.
	is_eq : _
}
