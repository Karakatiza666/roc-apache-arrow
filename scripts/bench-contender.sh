#!/usr/bin/env bash
# The lineitem bench: the package against arrow-rs on a batch job over a
# table modeled on TPC-H lineitem (tests/contender/src/lineitem.rs). Each way
# of the job runs in its own process over the whole table, for each batch
# size, and checks its output against the arrow-rs row loop on every batch
# before it times. Writes a markdown report; PERFORMANCE.md explains it.
#
#   scripts/bench-contender.sh                       1M rows, 7 passes
#   LINEITEM_ROWS=6000000 scripts/bench-contender.sh
#   LINEITEM_PASSES=15 scripts/bench-contender.sh
#   BENCH_CPU=3 scripts/bench-contender.sh           pin to CPU 3 (default: the last CPU; empty: no pin)
#   BENCH_PROFILE=0 scripts/bench-contender.sh       no sampled profile (Linux x86-64 only)
#   BENCH_OUT=report.md scripts/bench-contender.sh   where the report goes
#
# Roc builds with --opt speed and Rust with --release. Set ROC to use a roc
# that is not on the PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
roc="${ROC:-roc}"

case "$(uname -s)-$(uname -m)" in
	Linux-x86_64 | Linux-aarch64) ;;
	*)
		echo "error: the bench runs on Linux x86_64 and aarch64 only" >&2
		exit 1
		;;
esac

# build.rs runs in another directory, so it needs the absolute path.
if [[ "$roc" == */* ]]; then
	roc="$(cd "$(dirname "$roc")" && pwd)/$(basename "$roc")"
else
	roc="$(command -v "$roc")"
fi

export LINEITEM_ROWS="${LINEITEM_ROWS:-1000000}"
export LINEITEM_PASSES="${LINEITEM_PASSES:-7}"
cpu="${BENCH_CPU-$(($(nproc) - 1))}"
profile="${BENCH_PROFILE:-1}"
out="${BENCH_OUT:-tests/contender/target/bench-lineitem.md}"
mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

# A target directory of its own: the tests build the app with the dev backend.
target="$PWD/tests/contender/target/bench"
(cd tests/contender && ROC="$roc" ROC_OPT=speed CARGO_TARGET_DIR="$target" \
	cargo build --locked --release --bin bench_lineitem >&2)
bench="$target/release/bench_lineitem"

pin=()
pinned="not pinned"
if [[ -n "$cpu" ]] && command -v taskset >/dev/null; then
	pin=(taskset -c "$cpu")
	pinned="CPU $cpu (taskset)"
fi

load_before="$(cut -d' ' -f1-3 /proc/loadavg)"
results="$(mktemp)"
trap 'rm -f "$results"' EXIT

run() {
	echo "bench: $*" >&2
	"${pin[@]}" "$bench" "$@" >>"$results"
}

ways=(rust-rows rust-kernels roc-checked roc-trusted roc-str-checked roc-str-trusted)
for size in 8192 65536; do
	for way in "${ways[@]}"; do
		run "$way" "$size"
	done
done
for size in 8192 65536; do
	for way in rust-rows roc-checked roc-trusted roc-str-trusted; do
		for phase in host import numeric; do
			run "$way" "$size" "$phase"
		done
	done
done
load_after="$(cut -d' ' -f1-3 /proc/loadavg)"

{
	echo "# lineitem bench"
	echo
	echo "| Item | Value |"
	echo "|---|---|"
	echo "| machine | $(uname -m), $(lscpu | sed -n 's/^Model name: *//p' | head -1), $(nproc) CPUs |"
	echo "| pinned | $pinned; one thread on each side |"
	echo "| load average (1, 5, 15 min) | before: $load_before; after: $load_after |"
	echo "| roc | $("$roc" version) (--opt speed) |"
	echo "| rustc | $(rustc --version) (--release) |"
	echo "| passes | $LINEITEM_PASSES timed, after 1 warm-up pass; median, min and max |"
	echo
	echo "## Data"
	echo
	echo "| Item | Value |"
	echo "|---|---|"
	"$bench" stats | awk -F'\t' '{ printf "| %s | %s |\n", $1, $2 }'
	echo
	echo "## Whole job"
	echo
	echo "Time per pass over all rows: import, job and export of every batch."
	echo
	echo "| Way | Batch rows | Median ms | Min ms | Max ms | Mrows/s | Input MB/s | Time vs arrow-rs rows | Peak RSS MiB | RSS growth MiB | Allocations per row |"
	echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
	awk -F'\t' '
		$3 == "full" {
			if ($1 == "arrow-rs rows") base[$2] = $7
			line[++n] = $0
		}
		END {
			for (i = 1; i <= n; i++) {
				split(line[i], f, "\t")
				printf "| %s | %d | %.1f | %.1f | %.1f | %.2f | %.0f | %.2fx | %.0f | %.1f | %.2f |\n",
					f[1], f[2], f[7] * 1000, f[8] * 1000, f[9] * 1000,
					f[4] / f[7] / 1e6, f[5] / f[7] / 1e6, f[7] / base[f[2]],
					f[11] / 1024, (f[11] - f[10]) / 1024, f[12] / f[4]
			}
		}' "$results"
	echo
	echo "## Phases"
	echo
	echo "Median ms per pass. Each phase run stops after that phase, so a phase's own"
	echo "cost is the difference to the run before it. host: the host makes its Roc"
	echo "values from the C array (Roc only). import: to the typed column views."
	echo "numeric: the filter, the prices and the totals. text and export: the rest of"
	echo "the full run."
	echo
	echo "| Way | Batch rows | host | import | numeric | text and export | full |"
	echo "|---|---:|---:|---:|---:|---:|---:|"
	awk -F'\t' '
		{ t[$1 "|" $2 "|" $3] = $7 * 1000; if (!seen[$1 "|" $2]++) order[++n] = $1 "|" $2 }
		END {
			for (i = 1; i <= n; i++) {
				k = order[i]
				if (!((k "|import") in t)) continue
				split(k, f, "|")
				h = t[k "|host"]; im = t[k "|import"]; nu = t[k "|numeric"]; fu = t[k "|full"]
				printf "| %s | %d | %.1f | %.1f | %.1f | %.1f | %.1f |\n",
					f[1], f[2], h, im - h, nu - im, fu - nu, fu
			}
		}' "$results"
} >"$out"

if [[ "$profile" == 1 && "$(uname -m)" == x86_64 ]]; then
	{
		for way in roc-trusted rust-rows; do
			echo
			echo "## Profile: $way, batch 8192"
			echo
			echo "Share of SIGPROF samples per symbol over the timed passes (top 20)."
			echo
			echo '```'
			LINEITEM_PROFILE=1 LINEITEM_PASSES=20 "${pin[@]}" "$bench" "$way" 8192 2>"$results" >/dev/null
			head -21 "$results"
			echo '```'
		done
	} >>"$out"
fi

cat "$out"
echo "bench: wrote $out" >&2
