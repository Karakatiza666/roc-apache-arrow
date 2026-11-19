# Must type check: the right use of an open row in each writer. The other
# files here each break one rule and must not type check (scripts/test.sh).
app [run] {
	arrow: "../../package/main.roc",
	pf: platform "../contender/platform/main.roc",
}

import arrow.Host
import arrow.Writer

run : Host.Array, Host.Schema -> Host.Array
run = |_input, _schema| {
	w = Writer.str_end(Writer.part_bytes(Writer.part_str(Writer.str_begin(Writer.varlen(1, 0)), "x"), [0x79]))
	large = Writer.large_str_end(Writer.part_str(Writer.large_str_begin(Writer.large_varlen(1, 0)), "x"))
	views = Writer.views_str_end(Writer.part_str(Writer.views_str_begin(Writer.views(1, 0)), "x"))
	_ = Writer.large_var_finish(large, [])
	_ = Writer.views_finish(views, [])
	Writer.var_finish(w, [])
}
