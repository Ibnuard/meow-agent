#!/usr/bin/env bash
# Mac/Linux equivalent of fetch-proot.ps1.
# Fetches proot + libtalloc and places them in jniLibs.

set -euo pipefail

PROOT_VERSION="5.1.107.77"
TALLOC_VERSION="2.4.3"
ARCH="aarch64"
JNI_ARCH="arm64-v8a"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JNI_DIR="$REPO_ROOT/android/app/src/main/jniLibs/$JNI_ARCH"
mkdir -p "$JNI_DIR"

fetch_one() {
  local url="$1" binary="$2" out_name="$3"
  local out_path="$JNI_DIR/$out_name"
  if [[ -f "$out_path" ]]; then
    echo "[skip] $out_name already present"
    return
  fi

  local tmp
  tmp="$(mktemp -d -t meow_fetch.XXXXXX)"
  trap "rm -rf '$tmp'" RETURN

  echo "Downloading $binary from Termux..."
  curl -fsSL -o "$tmp/pkg.deb" "$url"

  cd "$tmp"
  ar x "pkg.deb"
  mkdir -p extracted
  tar -xf data.tar.* -C extracted

  local src
  src="$(find extracted -type f -name "$binary*" | sort -r | head -n1)"
  if [[ -z "$src" ]]; then
    echo "Error: $binary not found" >&2
    exit 1
  fi
  cp "$src" "$out_path"
  chmod +x "$out_path"
  echo "[OK] $out_name ($(wc -c < "$out_path") bytes)"
}

fetch_one \
  "https://packages.termux.dev/apt/termux-main/pool/main/p/proot/proot_${PROOT_VERSION}_${ARCH}.deb" \
  "proot" \
  "libproot.so"

fetch_one \
  "https://packages.termux.dev/apt/termux-main/pool/main/libt/libtalloc/libtalloc_${TALLOC_VERSION}_${ARCH}.deb" \
  "libtalloc.so.2" \
  "libtalloc.so"

echo
echo "Done. Run: flutter run"
