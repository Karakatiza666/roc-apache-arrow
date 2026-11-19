# The platform of the contender test (scripts/test-contender.sh). Its
# `requires` and `provides` are the ones of glue/platform.roc, so
# glue/roc_platform_abi.h is its header. It builds a static archive that the
# Rust driver in tests/contender links.
platform ""
	requires {
		run : Host.Array, Host.Schema -> Host.Array
	}
	exposes []
	packages { arrow: "../../../package/main.roc" }
	provides { "roc_run": run_for_host }
	targets: {
		inputs_dir: "targets/",
		x64glibc: {
			inputs: [app],
			output: Archive,
		},
		arm64glibc: {
			inputs: [app],
			output: Archive,
		},
	}

import arrow.Host

run_for_host : Host.Array, Host.Schema -> Host.Array
run_for_host = |a, s| run(a, s)
