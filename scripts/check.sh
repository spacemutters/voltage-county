#!/usr/bin/env bash
# Quality gate. Run before every commit: scripts/check.sh
# Steps: --!strict on every file -> brand names -> StyLua check -> Selene -> Rojo build.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.rokit/bin:$PATH"

fail() { echo "FAILED: $1"; exit 1; }

# Every Luau file we own starts with --!strict (CLAUDE.md, Stack).
echo "== strict mode"
bad=0
while IFS= read -r -d '' file; do
	if [ "$(head -n 1 "$file" | tr -d '\r')" != "--!strict" ]; then
		echo "  missing --!strict: $file"
		bad=1
	fi
done < <(find src tests -name '*.luau' -not -path '*/Vendor/*' -print0)
[ "$bad" -eq 0 ] || fail "strict mode"

# No real carmaker or model names in game code (CLAUDE.md hard rule 4). List: scripts/banned-names.txt.
echo "== brand names"
pattern="$(grep -v '^#' scripts/banned-names.txt | grep -v '^[[:space:]]*$' | tr -d '\r' | paste -sd '|' -)"
if grep -rniE --exclude-dir=Vendor "\b(${pattern})\b" src tests; then
	fail "brand names (real carmaker or model name in game code)"
fi

[ -d Packages ] || wally install
echo "== stylua"; stylua --check src tests || fail "stylua"
echo "== selene"; selene src tests || fail "selene"
mkdir -p build
echo "== rojo build"; rojo build -o build/check.rbxl || fail "rojo build"
echo "CHECK PASSED"
