#!/usr/bin/env bash
# Regenerate glue/roc_platform_abi.h with `roc glue`, and compile it with the
# C compiler so its static asserts (the layout of Host.Array, Host.Schema and
# Host.Buffer) are checked.
#
#   scripts/glue.sh            write glue/roc_platform_abi.h
#   scripts/glue.sh --check    fail when the file in git is not what roc writes
#
# The glue specs (CGlue.roc and others) are in the Roc source archive of the
# same nightly. Set ROC_GLUE_DIR to a directory that holds CGlue.roc to skip
# the download. Set ROC to use a roc that is not on the PATH, CC for the C
# compiler (default cc).
set -euo pipefail
cd "$(dirname "$0")/.."
roc="${ROC:-roc}"
tag="$(tr -d '\r\n' < .roc-version)"
stamp="${tag#nightly-}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

spec_dir="${ROC_GLUE_DIR:-}"
if [[ -z "$spec_dir" ]]; then
	url="https://github.com/roc-lang/nightlies/releases/download/$tag/roc_nightly-source-$stamp.tar.gz"
	echo "info: downloading $url" >&2
	curl --fail --location --silent --show-error --retry 3 "$url" | tar -xz -C "$work" --wildcards '*/src/glue/src/*'
	spec_dir="$(dirname "$(find "$work" -path '*/src/glue/src/CGlue.roc' | head -n 1)")"
fi
[[ -f "$spec_dir/CGlue.roc" ]] || {
	echo "error: no CGlue.roc in '$spec_dir'" >&2
	exit 1
}

"$roc" glue "$spec_dir/CGlue.roc" "$work/out" glue/platform.roc >&2
printf '#include "roc_platform_abi.h"\nint main(void) { return 0; }\n' > "$work/check.c"
"${CC:-cc}" -std=c11 -Wall -Werror -I "$work/out" -o "$work/check" "$work/check.c"

if [[ "${1:-}" == --check ]]; then
	diff -u glue/roc_platform_abi.h "$work/out/roc_platform_abi.h" || {
		echo "error: glue/roc_platform_abi.h is stale; run scripts/glue.sh" >&2
		exit 1
	}
	echo "glue/roc_platform_abi.h is current and compiles"
else
	cp "$work/out/roc_platform_abi.h" glue/roc_platform_abi.h
	echo "wrote glue/roc_platform_abi.h"
fi
