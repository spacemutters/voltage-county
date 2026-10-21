# Security table gate: every remote declared in src/shared/Net.luau (its REMOTES table) has exactly one row in the
# remote table of docs/SECURITY.md, and that table names no remote Net.luau doesn't declare. scripts/check.ps1 runs
# it as "== security table"; on its own: .\scripts\check-security-table.ps1
# Fails (exit 1) with one plain line per missing, extra or doubled name. Twin: scripts/check-security-table.sh.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

$netPath = "src/shared/Net.luau"
$docPath = "docs/SECURITY.md"

# Net.luau: the names one tab in ("	Name = {") between "local REMOTES" and the table's closing brace.
$declared = @()
$inside = $false
foreach ($line in Get-Content $netPath) {
	if (-not $inside) {
		if ($line -match '^local REMOTES\b') { $inside = $true }
		continue
	}
	if ($line -match '^}') { break }
	if ($line -cmatch '^\t([A-Za-z_][A-Za-z0-9_]*) = \{') { $declared += $Matches[1] }
}

# SECURITY.md: the first cell of each row ("| `Name` | ...") between the remotes:start and remotes:end markers.
$documented = @()
$inside = $false
$sawEnd = $false
foreach ($line in Get-Content $docPath -Encoding UTF8) {
	if ($line -match '<!-- remotes:start -->') { $inside = $true; continue }
	if ($line -match '<!-- remotes:end -->') { $sawEnd = $true; break }
	if ($inside -and $line -cmatch '^\|\s*`([A-Za-z_][A-Za-z0-9_]*)`\s*\|') { $documented += $Matches[1] }
}

$problems = @()
if ($declared.Count -eq 0) { $problems += "found no remotes in $netPath (is the REMOTES table still there?)" }
if (-not $sawEnd -or $documented.Count -eq 0) {
	$problems += "found no remote table in $docPath (rows go between <!-- remotes:start --> and <!-- remotes:end -->)"
}
foreach ($name in $declared) {
	if ($documented -cnotcontains $name) { $problems += "no row in ${docPath} for the remote $name (declared in $netPath)" }
}
foreach ($name in $documented) {
	if ($declared -cnotcontains $name) { $problems += "$docPath has a row for $name, which $netPath doesn't declare" }
}
$documented | Group-Object -CaseSensitive | Where-Object { $_.Count -gt 1 } | ForEach-Object {
	$problems += "$docPath has $($_.Count) rows for $($_.Name); keep one"
}

if ($problems.Count -gt 0) {
	$problems | Select-Object -Unique | ForEach-Object { Write-Host "  $_" }
	exit 1
}
Write-Host "  all $($declared.Count) remotes in $netPath have a row in $docPath"
exit 0
