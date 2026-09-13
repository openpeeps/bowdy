#!/usr/bin/env bash
# Head-to-head: sassc vs bro vs bro --strict vs dart-sass, all via CLI.
#
#   benchmarks/bench.sh                     # all three suites
#   benchmarks/bench.sh --warmup=2 --runs=5
#   benchmarks/bench.sh --big-count=500     # smaller Suite C
#
# Suites: A) same input (bin/bootstrap.css, valid for every compiler),
# B) equivalent features pair, C) generated scale pair (gen_big.py).
# dart-sass (benchmarks/dart-sass/sass, gitignored) runs when present.
set -euo pipefail

cd "$(dirname "$0")/.."

WARMUP=3
RUNS=10
BIG_COUNT=2000
VS_DIR="benchmarks/vs_sassc"
DARTSASS="benchmarks/dart-sass/sass"
BOOTSTRAP="bin/bootstrap.css"

for arg in "$@"; do
  case "$arg" in
    --warmup=*) WARMUP="${arg#*=}" ;;
    --runs=*) RUNS="${arg#*=}" ;;
    --big-count=*) BIG_COUNT="${arg#*=}" ;;
    --help|-h) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

for cmd in sassc hyperfine python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing: $cmd" >&2; exit 1; }
done
if [ ! -x bin/bro ]; then
  echo "building bro (release)..."
  clue build --release
fi

HAS_DART=0
[ -x "$DARTSASS" ] && HAS_DART=1

# $1=report $2=tag $3=scss-input $4=bass-input
suite() {
  local report="$1" tag="$2" scss="$3" bass="$4"
  local cmd=(hyperfine --warmup "$WARMUP" --runs "$RUNS" --export-markdown "$report")
  cmd+=(--command-name "sassc" "sassc -t compressed $scss /tmp/bench-$tag-sassc.css")
  cmd+=(--command-name "bro" "./bin/bro c $bass -o:/tmp/bench-$tag-bro.css")
  cmd+=(--command-name "bro --strict" "./bin/bro c --strict $bass -o:/tmp/bench-$tag-strict.css")
  if [ "$HAS_DART" = 1 ]; then
    cmd+=(--command-name "dart-sass" "$DARTSASS --style=compressed $scss /tmp/bench-$tag-dart.css 2>/dev/null")
  fi
  "${cmd[@]}"
  wc -c /tmp/bench-$tag-*.css
}

echo "━━━ A: same input ($BOOTSTRAP) ━━━"
suite bin/bench-a.md a "$BOOTSTRAP" "$BOOTSTRAP"

echo "━━━ B: features pair ━━━"
suite bin/bench-b.md b "$VS_DIR/features.scss" "$VS_DIR/features.bass"

echo "━━━ C: scale pair ($BIG_COUNT rules) ━━━"
python3 "$VS_DIR/gen_big.py" --count "$BIG_COUNT" --out "$VS_DIR"
suite bin/bench-c.md c "$VS_DIR/big.scss" "$VS_DIR/big.bass"

echo "reports: bin/bench-a.md bin/bench-b.md bin/bench-c.md"
