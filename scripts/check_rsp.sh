#!/bin/zsh
# Sandbox-safe check: verify what include path the rsp actually has now,
# after SwiftPM regenerated it. Then probe the include resolution by
# copying the pinned headers into the package's public headers directory.
set -euo pipefail
cd "$(dirname "$0")/.."
grep -o "\-I[^ ]*vendor[^ ]*" ".build/out/Intermediates.noindex/PixelBooth.build/Debug/PixelBoothCAvifShim-t.build/Objects-normal/arm64/7187679823f38a2a940e0043cdf9d637-common-args.resp" || echo "no vendor path found in rsp"
