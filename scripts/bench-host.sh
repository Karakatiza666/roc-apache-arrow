#!/usr/bin/env bash
# Time the trusted text path: 100k rows of 32-byte text read through
# Utf8Column, with the data buffer as U8s (Roc checks the UTF-8) and as a
# trusted Str (Roc does not). Builds tests/host/app.roc with the speed backend
# and tests/host/host.c with ARROW_HOST_BENCH, and prints ns per row.
#
#   scripts/bench-host.sh
#
# Set ROC to use a roc that is not on the PATH, CC for the C compiler (default cc).
set -euo pipefail
cd "$(dirname "$0")/.."
roc="${ROC:-roc}"
cc="${CC:-cc}"

if [[ "$(uname -s)-$(uname -m)" != Linux-x86_64 ]]; then
	echo "error: the host bench runs on Linux x86_64 only" >&2
	exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$roc" build --target=x64glibc --opt=speed --output="$work/libapp.a" tests/host/app.roc >&2
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-function -DARROW_HOST_BENCH \
	-I glue -o "$work/bench" tests/host/host.c "$work/libapp.a" 2> >(grep -v -e 'GNU-stack' -e 'NOTE: This behaviour' >&2)
"$work/bench"
