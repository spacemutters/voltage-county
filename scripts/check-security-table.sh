#!/usr/bin/env bash
# Security table gate: every remote declared in src/shared/Net.luau (its REMOTES table) has exactly one row in the
# remote table of docs/SECURITY.md, and that table names no remote Net.luau doesn't declare. scripts/check.sh runs
# it as "== security table"; on its own: scripts/check-security-table.sh
# Fails (exit 1) with one plain line per missing, extra or doubled name. Twin: scripts/check-security-table.ps1.
set -euo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C

net="src/shared/Net.luau"
doc="docs/SECURITY.md"

# Net.luau: the names one tab in ("	Name = {") between "local REMOTES" and the table's closing brace.
declared="$(tr -d '\r' < "$net" | awk '
	/^local REMOTES[: ]/ { inside = 1; next }
	inside && /^}/ { exit }
	inside && /^\t[A-Za-z_][A-Za-z0-9_]* = [{]/ { sub(/^\t/, ""); sub(/ = [{].*$/, ""); print }
')"

# SECURITY.md: the first cell of each row ("| `Name` | ...") between the remotes:start and remotes:end markers.
documented="$(tr -d '\r' < "$doc" | awk '
	/<!-- remotes:start -->/ { inside = 1; next }
	/<!-- remotes:end -->/ { exit }
	inside
' | sed -n -E 's/^\|[[:space:]]*`([A-Za-z_][A-Za-z0-9_]*)`[[:space:]]*\|.*$/\1/p')"

problems=()
[ -n "$declared" ] || problems+=("found no remotes in $net (is the REMOTES table still there?)")
if [ -z "$documented" ] || ! grep -q '<!-- remotes:end -->' "$doc"; then
	problems+=("found no remote table in $doc (rows go between <!-- remotes:start --> and <!-- remotes:end -->)")
fi
while IFS= read -r name; do
	[ -n "$name" ] || continue
	grep -qxF "$name" <<< "$documented" || problems+=("no row in $doc for the remote $name (declared in $net)")
done <<< "$declared"
while IFS= read -r name; do
	[ -n "$name" ] || continue
	grep -qxF "$name" <<< "$declared" || problems+=("$doc has a row for $name, which $net doesn't declare")
done <<< "$documented"
while IFS= read -r name; do
	[ -n "$name" ] || continue
	problems+=("$doc has $(grep -cxF "$name" <<< "$documented") rows for $name; keep one")
done < <(sort <<< "$documented" | uniq -d)

if [ "${#problems[@]}" -gt 0 ]; then
	printf '  %s\n' "${problems[@]}" | awk '!seen[$0]++'
	exit 1
fi
echo "  all $(grep -c . <<< "$declared") remotes in $net have a row in $doc"
