#!/usr/bin/env bash
# Run the examples against a bundle instead of the source tree, two ways:
#
#   1. by path: unbundle it and point the app at the unbundled main.roc;
#   2. by URL: serve it on 127.0.0.1 (roc allows plain http to localhost) and
#      swap the dependency with --replace-dep, so roc downloads it and checks
#      its hash the way a user's roc does.
#
#   scripts/test_bundle.sh [dist/<hash>.tar.zst | https://.../<hash>.tar.zst]
#
# Set ROC to use a roc that is not on the PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
roc="${ROC:-roc}"
case "$roc" in */*) roc="$(cd "$(dirname "$roc")" && pwd)/$(basename "$roc")" ;; esac
target="${1:-$(echo dist/*.tar.zst)}"

if [[ "$target" != https://* ]]; then
	[[ -f "$target" ]] || {
		echo "error: no bundle at $target; run scripts/bundle.sh first" >&2
		exit 1
	}
	work="$(mktemp -d)"
	trap 'rm -rf "$work"; [[ -z "${server:-}" ]] || kill "$server"' EXIT
	archive="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
	(cd "$work" && "$roc" unbundle "$archive" > /dev/null)
	unbundled="$(echo "$work"/*/main.roc)"
	for app in examples/*.roc; do
		copy="$work/$(basename "$app")"
		sed "s|\"../package/main.roc\"|\"$unbundled\"|" "$app" > "$copy"
		grep -q "$unbundled" "$copy"
		"$roc" check "$copy"
		"$roc" build --opt=dev --output="$work/app" "$copy"
		"$work/app"
	done

	port="${PORT:-8765}"
	url="http://127.0.0.1:$port/$(basename "$target")"
	python3 -m http.server "$port" --bind 127.0.0.1 --directory "$(dirname "$archive")" > /dev/null 2>&1 &
	server=$!
	for _ in $(seq 50); do
		(: > "/dev/tcp/127.0.0.1/$port") 2> /dev/null && break
		sleep 0.1
	done
else
	url="$target"
fi

for app in examples/*.roc; do
	"$roc" check "$app" --replace-dep ./package/main.roc "$url"
	"$roc" "$app" --replace-dep ./package/main.roc "$url"
done
