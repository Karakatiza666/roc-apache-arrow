# Must not type check: a Utf8 row closed as a LargeUtf8 row.
app [run] {
	arrow: "../../package/main.roc",
	pf: platform "../contender/platform/main.roc",
}

import arrow.Host
import arrow.Writer

run : Host.Array, Host.Schema -> Host.Array
run = |_input, _schema| {
	w = Writer.large_str_end(Writer.str_begin(Writer.varlen(1, 0)))
	Writer.large_var_finish(w, [])
}
