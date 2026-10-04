#!/usr/bin/env bash
# Writes App/Resources/Legal/Acknowledgements.txt: the licenses of everything compiled into the embedded go2rtc
# (go2rtc itself, the Go modules its packages pull in and the Go standard library). Run after ./GoMobile/build.sh
# whenever go2rtc or its modules change; the app shows the file in «О приложении → Лицензии».
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SRC="$HERE/build/go2rtc"
OUT="$ROOT/App/Resources/Legal/Acknowledgements.txt"
[ -d "$SRC/mobile" ] || { echo "Run ./GoMobile/build.sh first"; exit 1; }

cd "$SRC"
# Modules that actually end up in the binary (not tests, not tools).
# golang.org/x/mobile: the bind runtime gomobile links into the framework.
MODULES=$( (GOOS=ios GOARCH=arm64 CGO_ENABLED=1 go list -deps -f '{{with .Module}}{{if not .Main}}{{.Path}}{{end}}{{end}}' ./mobile; echo golang.org/x/mobile) | sort -u)

license_file() {
  for name in LICENSE LICENSE.md LICENSE.txt LICENCE COPYING LICENSE-MIT; do
    [ -f "$1/$name" ] && { echo "$1/$name"; return; }
  done
}

{
  echo "Waiting Paws includes the following open-source software."
  echo
  echo "================================================================================"
  echo "go2rtc $(git -C "$SRC" describe --tags 2>/dev/null || echo) — https://github.com/AlexxIT/go2rtc"
  echo "(modified for Waiting Paws: see GoMobile/build.sh)"
  echo "================================================================================"
  echo
  cat "$SRC/LICENSE"
  for module in $MODULES; do
    dir=$(go list -m -f '{{.Dir}}' "$module")
    version=$(go list -m -f '{{.Version}}' "$module")
    file=$(license_file "$dir")
    [ -n "$file" ] || { echo "no license file for $module" >&2; exit 1; }
    echo
    echo "================================================================================"
    echo "$module $version"
    echo "================================================================================"
    echo
    cat "$file"
  done
  echo
  echo "================================================================================"
  echo "The Go programming language $(go env GOVERSION) — https://go.dev"
  echo "================================================================================"
  echo
  GOROOT_DIR="$(go env GOROOT)"
  cat "$(license_file "$GOROOT_DIR" || true)" 2>/dev/null || cat "$(license_file "$GOROOT_DIR/..")"
} > "$OUT"
echo "Wrote $OUT ($(echo "$MODULES" | wc -l | tr -d ' ') modules)"
