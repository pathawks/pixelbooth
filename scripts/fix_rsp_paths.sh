#!/bin/zsh
# Fix vendored header include flags: SwiftPM resolves relative -I paths
# relative to the working directory, which is not guaranteed to be the
# package root. Rewrite the .rsp so the -I arguments are absolute.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

find "$ROOT/.build" -name "*.resp" 2>/dev/null | while read -r resp; do
  if grep -q "vendor/build" "$resp" 2>/dev/null; then
    # -I vendor/build/X pairs: make each include path absolute.
    perl -0777 -pe 's{\B-?I vendor/build/avif-install/include}{-I'"$ROOT"'/vendor/build/avif-install/include}g;
                    s{\B-?I vendor/build/aom-install/include}{-I'"$ROOT"'/vendor/build/aom-install/include}g;
                    s{\B-?I vendor/build/avif-install/include}{-I'"$ROOT"'/vendor/build/avif-install/include}g;
                    s{\B-?I vendor/build/aom-install/include}{-I'"$ROOT"'/vendor/build/aom-install/include}g;
                    s{\B-?L vendor/build/avif\b}{-L'"$ROOT"'/vendor/build/avif}g;
                    s{\B-?L vendor/build/aom\b}{-L'"$ROOT"'/vendor/build/aom}g' "$resp" > "$resp.tmp" \
      && mv "$resp" "$resp.fix" && mv "$resp.fix" "$resp"
  fi
done
