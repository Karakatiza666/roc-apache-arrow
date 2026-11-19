#!/usr/bin/env bash
# The host conformance test: build tests/host/app.roc as a static archive on
# the test platform, link it with the C host tests/host/host.c under
# AddressSanitizer, and run it. Then run it once per fault the host can inject
# (ARROW_HOST_FAULT) and require each run to fail, so the checks are proven
# to catch a broken host.
#
#   scripts/test-host.sh
#
# Set ROC to use a roc that is not on the PATH, ROC_OPT to pick the backend
# (dev or speed; default dev), CC for the C compiler (default cc).
set -euo pipefail
cd "$(dirname "$0")/.."
roc="${ROC:-roc}"
opt="${ROC_OPT:-dev}"
cc="${CC:-cc}"

# The test platform has one target.
if [[ "$(uname -s)-$(uname -m)" != Linux-x86_64 ]]; then
	echo "error: the host test runs on Linux x86_64 only" >&2
	exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$roc" fmt --check tests/host
"$roc" check tests/host/app.roc
"$roc" build --target=x64glibc --opt="$opt" --output="$work/libapp.a" tests/host/app.roc
"$cc" -std=c11 -g -O1 -Wall -Wextra -Werror -fno-omit-frame-pointer \
	-fsanitize=address,undefined -fno-sanitize-recover=all \
	-I glue -o "$work/host" tests/host/host.c "$work/libapp.a"

export ASAN_OPTIONS="detect_leaks=1:abort_on_error=0"
"$work/host"

# Each fault breaks one host rule; the run must fail.
for fault in static_rc_one i64_as_u8s release_leaks i128_unaligned; do
	if ARROW_HOST_FAULT="$fault" "$work/host" > "$work/fault.log" 2>&1; then
		echo "error: the host test passed with fault '$fault'" >&2
		cat "$work/fault.log" >&2
		exit 1
	fi
	echo "fault '$fault' caught: $(grep -m 1 -E 'FAIL|ERROR' "$work/fault.log" || tail -n 1 "$work/fault.log")"
done
