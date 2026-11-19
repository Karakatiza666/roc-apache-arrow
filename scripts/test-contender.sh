#!/usr/bin/env bash
# The contender test: differential tests of the package against arrow-rs
# through the Arrow C Data Interface. cargo builds tests/contender/app.roc as
# a static archive on the test platform (tests/contender/build.rs), links it
# with the Rust driver, and runs the valid corpus, the invalid corpus and the
# edge cases.
#
#   scripts/test-contender.sh                          5000 random cases per test
#   CONTENDER_CASES=100000 scripts/test-contender.sh   a long run
#   CONTENDER_SEED=<n> scripts/test-contender.sh       another base seed
#
# A failure prints the seed and the case that failed, shrunk to the fewest
# rows. Set ROC to use a roc that is not on the PATH, ROC_OPT to pick the
# backend (dev or speed; default dev).
set -euo pipefail
cd "$(dirname "$0")/.."
roc="${ROC:-roc}"

# The test platform has targets for Linux x64 and arm64 (glibc).
case "$(uname -s)-$(uname -m)" in
	Linux-x86_64 | Linux-aarch64) ;;
	*)
		echo "error: the contender test runs on Linux x86_64 and aarch64 only" >&2
		exit 1
		;;
esac

# build.rs runs in another directory, so it needs the absolute path.
if [[ "$roc" == */* ]]; then
	roc="$(cd "$(dirname "$roc")" && pwd)/$(basename "$roc")"
else
	roc="$(command -v "$roc")"
fi

"$roc" fmt --check tests/contender
"$roc" check tests/contender/app.roc

export ROC="$roc"
export CONTENDER_CASES="${CONTENDER_CASES:-5000}"
cd tests/contender
cargo test --locked --no-fail-fast -- --nocapture
