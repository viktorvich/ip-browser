#!/bin/bash
# App/Resources/licenses.txt = tools/licenses-header.txt + the full license and notice texts of
# EVERY component compiled into the app: each Go module linked into LibXray (from the libXray
# work tree tools/build-libxray.sh left), the Go standard library, and each Swift package the
# app resolved (Package.resolved). Run on the Mac after tools/build-libxray.sh and a resolve.
#   tools/licenses.sh <libXray work dir> <SwiftPM checkouts dir>
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LX=$1; SPM=$2
OUT="$ROOT/App/Resources/licenses.txt"
texts() { # dir -> license, copying and notice files of that directory
  find "$1" -maxdepth 1 -type f \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' -o -iname 'PATENTS*' \) | sort
}
# A text as bundled: a person's e-mail address in a copyright line is left out (a copyright notice is
# the year and the name; the original file is at the component's source named in its heading).
show() { sed -E 's/ ?<[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+>//g' "$1"; }
{
  cat "$ROOT/tools/licenses-header.txt"
  printf '\n\nFULL TEXTS\n\n'
  cd "$LX"
  # the main module (libXray itself) has no version in the module graph: its tag stands there
  main=$(git -C "$LX" describe --tags 2>/dev/null || echo source)
  go list -deps -f '{{with .Module}}{{.Path}} {{if .Version}}{{.Version}}{{else}}MAIN{{end}} {{.Dir}}{{end}}' . ./cgo_bridge | sort -u | while read -r path version dir; do
    [ -n "$dir" ] || continue
    files=$(texts "$dir")
    [ -n "$files" ] || { echo "no license file in $path $version" >&2; exit 1; }
    [ "$version" = MAIN ] && version=$main
    printf '=== %s %s (Go module, linked into LibXray) ===\n\n' "$path" "$version"
    for f in $files; do show "$f"; printf '\n\n'; done
  done
  printf '=== Go standard library %s ===\n\n' "$(go env GOVERSION)"
  cat "$(go env GOROOT)/LICENSE"; printf '\n\n'
  [ -f "$(go env GOROOT)/PATENTS" ] && { cat "$(go env GOROOT)/PATENTS"; printf '\n\n'; }
  for dir in "$SPM"/*/; do
    name=$(basename "$dir")
    files=$(texts "$dir")
    [ -n "$files" ] || { echo "no license file in Swift package $name" >&2; exit 1; }
    printf '=== %s (Swift package) ===\n\n' "$name"
    for f in $files; do show "$f"; printf '\n\n'; done
  done
} > "$OUT.new"
mv "$OUT.new" "$OUT"
echo "$OUT: $(wc -c < "$OUT") bytes, $(grep -c '^=== ' "$OUT") components"
