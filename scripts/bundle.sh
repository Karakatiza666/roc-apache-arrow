#!/usr/bin/env bash
# Bundle the package into <out>/<hash>.tar.zst and check that the bundle holds
# every module of package/main.roc. Prints the bundle's file name.
#
#   scripts/bundle.sh [out-dir]        default: dist
#
# Set ROC to use a roc that is not on the PATH. In a GitHub Actions job it also
# writes `archive=<file name>` to GITHUB_OUTPUT.
set -euo pipefail
cd "$(dirname "$0")/.."
roc="${ROC:-roc}"
case "$roc" in */*) roc="$(cd "$(dirname "$roc")" && pwd)/$(basename "$roc")" ;; esac
out="${1:-dist}"

rm -rf "$out"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

# roc bundles main.roc and every module it imports; the test modules and
# tests.roc are not imported, so they stay out.
(cd package && "$roc" bundle --output-dir "$out" main.roc) >&2

archive="$(find "$out" -maxdepth 1 -name '*.tar.zst' | head -n 1)"
[[ -n "$archive" ]] || {
	echo "error: roc bundle wrote no .tar.zst" >&2
	exit 1
}

# roc unbundle extracts into <hash>/ in the current directory.
listing="$(mktemp -d)"
trap 'rm -rf "$listing"' EXIT
(cd "$listing" && "$roc" unbundle "$archive" > /dev/null)
files="$(cd "$listing"/* && ls)"

# Every module main.roc exposes must be in the bundle; no test module may be.
missing=0
for name in $(sed -n 's/^package \[\(.*\)\].*/\1/p' package/main.roc | tr -d ' ' | tr ',' ' ') main; do
	grep -qx "$name.roc" <<< "$files" || {
		echo "error: the bundle is missing $name.roc" >&2
		missing=1
	}
done
if grep -qE 'Test\.roc$|^tests\.roc$' <<< "$files"; then
	echo "error: the bundle holds test files" >&2
	missing=1
fi
[[ "$missing" -eq 0 ]] || exit 1

[[ -z "${GITHUB_OUTPUT:-}" ]] || echo "archive=$(basename "$archive")" >> "$GITHUB_OUTPUT"
echo "$(basename "$archive")"
