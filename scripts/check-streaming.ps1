# Streaming settings gate: the Workspace streaming values in default.project.json (Workspace "$properties") match the
# `streaming` block of src/shared/Config/Perf.luau. Four of the five aren't scriptable, so no script, test or plugin
# (Rojo's included) can set or read them in a place: they are set by hand in Studio's Properties panel
# (docs/LAUNCH.md step 10). This keeps the project file (what `rojo build` writes) and the config saying the same thing.
# scripts/check.ps1 runs it as "== streaming settings"; on its own: .\scripts\check-streaming.ps1
# Fails (exit 1) with one plain line per value that differs or is missing. Twin: scripts/check-streaming.sh.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

$perfPath = "src/shared/Config/Perf.luau"
$projectPath = "default.project.json"

# Config/Perf: the "key = value," lines two tabs in, between "	streaming = {" and its closing "	},".
$config = @{}
$inside = $false
foreach ($line in Get-Content $perfPath) {
	if (-not $inside) {
		if ($line -cmatch '^\tstreaming = \{') { $inside = $true }
		continue
	}
	if ($line -cmatch '^\t\}') { break }
	if ($line -cmatch '^\t\t([A-Za-z]+) = ("[^"]*"|[^,\s]+),') { $config[$Matches[1]] = $Matches[2].Trim('"') }
}

# default.project.json is only read here, never written.
$properties = (Get-Content $projectPath -Raw | ConvertFrom-Json).tree.Workspace.'$properties'

# Workspace property -> Config/Perf streaming key.
$pairs = [ordered]@{
	StreamingEnabled = "enabled"
	StreamingMinRadius = "minRadius"
	StreamingTargetRadius = "targetRadius"
	StreamOutBehavior = "outBehavior"
	StreamingIntegrityMode = "integrityMode"
}

$problems = @()
if ($config.Count -eq 0) { $problems += "found no streaming block in $perfPath" }
if ($null -eq $properties) { $problems += "found no Workspace `$properties in $projectPath" }
foreach ($property in $pairs.Keys) {
	$key = $pairs[$property]
	$want = $config[$key]
	if ($null -eq $want) {
		$problems += "$perfPath streaming has no $key (for Workspace.$property)"
		continue
	}
	$have = if ($null -ne $properties) { $properties.$property } else { $null }
	if ($null -eq $have) {
		$problems += "$projectPath Workspace `$properties has no $property (Config/Perf streaming.$key is $want)"
		continue
	}
	$haveText = if ($have -is [bool]) { $have.ToString().ToLower() } else { [string]$have }
	if ($haveText -cne $want) {
		$problems += "$projectPath Workspace $property is $haveText, but Config/Perf streaming.$key is $want"
	}
}

if ($problems.Count -gt 0) {
	$problems | ForEach-Object { Write-Host "  $_" }
	exit 1
}
Write-Host "  $projectPath Workspace streaming matches Config/Perf ($($pairs.Count) values)"
exit 0
