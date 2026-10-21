#!/usr/bin/env bash
# Streaming settings gate: the Workspace streaming values in default.project.json (Workspace "$properties") match the
# `streaming` block of src/shared/Config/Perf.luau. Four of the five aren't scriptable, so no script, test or plugin
# (Rojo's included) can set or read them in a place: they are set by hand in Studio's Properties panel
# (docs/LAUNCH.md step 10). This keeps the project file (what `rojo build` writes) and the config saying the same thing.
# scripts/check.sh runs it as "== streaming settings"; on its own: scripts/check-streaming.sh
# Fails (exit 1) with one plain line per value that differs or is missing. Twin: scripts/check-streaming.ps1.
set -euo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C

perf="src/shared/Config/Perf.luau"
project="default.project.json"

# Config/Perf: "key=value" for the "key = value," lines two tabs in, between "	streaming = {" and its closing "	},".
config="$(tr -d '\r' < "$perf" | awk '
	/^\tstreaming = [{]/ { inside = 1; next }
	inside && /^\t[}]/ { exit }
	inside && /^\t\t[A-Za-z]+ = / {
		line = $0
		sub(/^\t\t/, "", line)
		key = line; sub(/ = .*$/, "", key)
		value = line; sub(/^[A-Za-z]+ = /, "", value); sub(/,.*$/, "", value); gsub(/"/, "", value)
		print key "=" value
	}
')"

# default.project.json: "Name=value" for the Workspace streaming properties (their names appear nowhere else).
project_values="$(tr -d '\r' < "$project" | sed -n -E \
	's/^[[:space:]]*"(StreamingEnabled|StreamingMinRadius|StreamingTargetRadius|StreamOutBehavior|StreamingIntegrityMode)"[[:space:]]*:[[:space:]]*"?([^",]*)"?,?[[:space:]]*$/\1=\2/p')"

lookup() { # lookup <name> <lines>: the value after "name=", or nothing
	sed -n "s/^$1=//p" <<< "$2" | head -n 1
}

problems=()
[ -n "$config" ] || problems+=("found no streaming block in $perf")
for pair in StreamingEnabled:enabled StreamingMinRadius:minRadius StreamingTargetRadius:targetRadius \
	StreamOutBehavior:outBehavior StreamingIntegrityMode:integrityMode; do
	property="${pair%%:*}"
	key="${pair##*:}"
	want="$(lookup "$key" "$config")"
	have="$(lookup "$property" "$project_values")"
	if [ -z "$want" ]; then
		problems+=("$perf streaming has no $key (for Workspace.$property)")
	elif [ -z "$have" ]; then
		problems+=("$project Workspace \$properties has no $property (Config/Perf streaming.$key is $want)")
	elif [ "$have" != "$want" ]; then
		problems+=("$project Workspace $property is $have, but Config/Perf streaming.$key is $want")
	fi
done

if [ "${#problems[@]}" -gt 0 ]; then
	printf '  %s\n' "${problems[@]}"
	exit 1
fi
echo "  $project Workspace streaming matches Config/Perf (5 values)"
