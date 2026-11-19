#!/usr/bin/env bash
# Every check of the source tree: format, type check, every expect, the
# misuse files that must not type check, the examples, and the glue header.
#
#   scripts/test.sh
#
# Set ROC to use a roc that is not on the PATH, ROC_OPT to pick the backend
# (default dev), and SKIP_GLUE=1 where the glue sources are not at hand.
set -euo pipefail
cd "$(dirname "$0")/.."
roc="${ROC:-roc}"
opt="${ROC_OPT:-dev}"

"$roc" version
"$roc" fmt --check package examples glue tests/misuse
"$roc" check package/main.roc
"$roc" check package/tests.roc
# tests.roc exposes every module and every test module, so this one run covers
# all the expects of the package.
"$roc" test --opt="$opt" package/tests.roc
# An open row of a writer: tests/misuse/ok.roc uses it right and must type
# check; each other file there breaks one rule and must fail with one type
# mismatch.
"$roc" check tests/misuse/ok.roc
for f in tests/misuse/*.roc; do
	[[ "$f" == */ok.roc ]] && continue
	if out="$("$roc" check "$f" 2>&1)"; then
		echo "error: $f type checks, but it misuses an open row" >&2
		exit 1
	fi
	grep -q "type mismatch" <<<"$out" && grep -q "^── 1 error and" <<<"$out" || {
		echo "error: $f fails for another reason:" >&2
		echo "$out" >&2
		exit 1
	}
done
for app in examples/*.roc; do
	"$roc" check "$app"
	"$roc" --opt="$opt" "$app"
done
[[ "${SKIP_GLUE:-}" == 1 ]] || scripts/glue.sh --check
