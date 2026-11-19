# Must not type check: a part with no open row.
app [run] {
	arrow: "../../package/main.roc",
	pf: platform "../contender/platform/main.roc",
}

import arrow.Host
import arrow.Writer

run : Host.Array, Host.Schema -> Host.Array
run = |_input, _schema| {
	w = Writer.part_str(Writer.varlen(1, 0), "x")
	Writer.var_finish(w, [])
}
