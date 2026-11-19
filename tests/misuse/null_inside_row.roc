# Must not type check: a NULL row while a row is open.
app [run] {
	arrow: "../../package/main.roc",
	pf: platform "../contender/platform/main.roc",
}

import arrow.Host
import arrow.Writer

run : Host.Array, Host.Schema -> Host.Array
run = |_input, _schema| {
	t = Writer.var_null(Writer.str_begin(Writer.varlen(1, 0)))
	Writer.var_finish(Writer.str_end(t), [])
}
