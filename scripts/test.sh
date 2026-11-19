#!/usr/bin/env bash
# Every check of the source tree: format, type check, every expect, the
# examples, and the glue header.
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
"$roc" fmt --check package examples glue
"$roc" check package/main.roc
"$roc" check package/tests.roc
# tests.roc exposes every module and every test module, so this one run covers
# all the expects of the package.
"$roc" test --opt="$opt" package/tests.roc
for app in examples/*.roc; do
	"$roc" check "$app"
	"$roc" --opt="$opt" "$app"
done
[[ "${SKIP_GLUE:-}" == 1 ]] || scripts/glue.sh --check
