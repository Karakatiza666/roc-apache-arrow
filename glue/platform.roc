# A stub platform for `roc glue`: its `requires` names the Host types, so the
# generated glue/roc_platform_abi.h holds their C layout. Make the header
# again with scripts/glue.sh.
platform ""
	requires {
		run : Host.Array, Host.Schema -> Host.Array
	}
	exposes []
	packages { arrow: "../package/main.roc" }
	provides { "roc_run": run_for_host }
	targets: {
		inputs_dir: "targets/",
		x64glibc: {
			inputs: [app],
			output: Shared,
		},
	}

import arrow.Host

run_for_host : Host.Array, Host.Schema -> Host.Array
run_for_host = |a, s| run(a, s)
