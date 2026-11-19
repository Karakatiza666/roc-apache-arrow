# Must not type check: a writer finished while a row is open.
app [run] {
	arrow: "../../package/main.roc",
	pf: platform "../contender/platform/main.roc",
}

import arrow.Host
import arrow.Writer

run : Host.Array, Host.Schema -> Host.Array
run = |_input, _schema| {
	Writer.var_finish(Writer.str_begin(Writer.varlen(1, 0)), [])
}
