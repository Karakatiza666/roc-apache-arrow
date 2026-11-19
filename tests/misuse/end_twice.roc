# Must not type check: a row closed twice.
app [run] {
	arrow: "../../package/main.roc",
	pf: platform "../contender/platform/main.roc",
}

import arrow.Host
import arrow.Writer

run : Host.Array, Host.Schema -> Host.Array
run = |_input, _schema| {
	w = Writer.str_end(Writer.str_end(Writer.str_begin(Writer.varlen(1, 0))))
	Writer.var_finish(w, [])
}
