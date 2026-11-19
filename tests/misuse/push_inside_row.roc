# Must not type check: a whole value pushed while a row is open.
app [run] {
	arrow: "../../package/main.roc",
	pf: platform "../contender/platform/main.roc",
}

import arrow.Host
import arrow.Writer

run : Host.Array, Host.Schema -> Host.Array
run = |_input, _schema| {
	t = Writer.str_push(Writer.str_begin(Writer.varlen(1, 0)), "x")
	Writer.var_finish(Writer.str_end(t), [])
}
