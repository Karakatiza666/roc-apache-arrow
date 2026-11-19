# Must not type check: a Utf8View row closed as a Utf8 row.
app [run] {
	arrow: "../../package/main.roc",
	pf: platform "../contender/platform/main.roc",
}

import arrow.Host
import arrow.Writer

run : Host.Array, Host.Schema -> Host.Array
run = |_input, _schema| {
	w = Writer.str_end(Writer.views_str_begin(Writer.views(1, 0)))
	Writer.var_finish(w, [])
}
