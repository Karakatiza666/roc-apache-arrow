#!/usr/bin/env bash
# Install the Roc nightly named in .roc-version (or in $1) and print the path
# of its roc binary. In a GitHub Actions job it also puts roc on the PATH.
#
#   scripts/install-roc.sh                      the pinned nightly
#   scripts/install-roc.sh nightly-2026-11-18-a520eed
#
# The install goes to $ROC_HOME/<tag> (default: ~/.cache/roc-nightlies). A
# second run finds it and downloads nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:-$(tr -d '\r\n' < .roc-version)}"
if [[ ! "$tag" =~ ^nightly-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{7,40}$ ]]; then
	echo "error: '$tag' is not a Roc nightly tag" >&2
	exit 1
fi
stamp="${tag#nightly-}"

case "$(uname -s)-$(uname -m)" in
	Linux-x86_64) asset=linux_x86_64 ;;
	Linux-aarch64 | Linux-arm64) asset=linux_arm64 ;;
	Darwin-arm64) asset=macos_apple_silicon ;;
	Darwin-x86_64) asset=macos_x86_64 ;;
	*)
		echo "error: no Roc nightly for $(uname -s) $(uname -m)" >&2
		exit 1
		;;
esac

dest="${ROC_HOME:-$HOME/.cache/roc-nightlies}/$tag"
if [[ ! -x "$dest/roc" ]]; then
	url="https://github.com/roc-lang/nightlies/releases/download/$tag/roc_nightly-$asset-$stamp.tar.gz"
	echo "info: downloading $url" >&2
	mkdir -p "$dest"
	curl --fail --location --silent --show-error --retry 3 "$url" | tar -xz --strip-components=1 -C "$dest"
fi
[[ -x "$dest/roc" ]] || {
	echo "error: no roc binary in $dest" >&2
	exit 1
}

[[ -z "${GITHUB_PATH:-}" ]] || echo "$dest" >> "$GITHUB_PATH"
echo "$dest/roc"
