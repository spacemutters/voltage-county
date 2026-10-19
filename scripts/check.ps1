# Quality gate. Run before every commit: .\scripts\check.ps1
# Steps: --!strict on every file -> brand names -> StyLua check -> Selene -> Rojo build.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)
$env:PATH = "$HOME\.rokit\bin;$env:PATH"

function Fail($message) {
	Write-Host "FAILED: $message" -ForegroundColor Red
	exit 1
}

function Run($name, [scriptblock]$command) {
	Write-Host "== $name" -ForegroundColor Cyan
	& $command
	if ($LASTEXITCODE -ne 0) { Fail $name }
}

$luauFiles = Get-ChildItem src, tests -Recurse -File -Filter *.luau | Where-Object { $_.FullName -notmatch "\\Vendor\\" }

# Every Luau file we own starts with --!strict (CLAUDE.md, Stack).
Write-Host "== strict mode" -ForegroundColor Cyan
$notStrict = $luauFiles | Where-Object { (Get-Content $_.FullName -TotalCount 1) -ne "--!strict" }
if ($notStrict) {
	$notStrict | ForEach-Object { Write-Host "  missing --!strict: $($_.FullName)" }
	Fail "strict mode"
}

# No real carmaker or model names in game code (CLAUDE.md hard rule 4). List: scripts/banned-names.txt.
Write-Host "== brand names" -ForegroundColor Cyan
$patterns = Get-Content scripts/banned-names.txt | Where-Object { $_.Trim() -and -not $_.StartsWith("#") }
$allFiles = Get-ChildItem src, tests -Recurse -File | Where-Object { $_.FullName -notmatch "\\Vendor\\" }
$hits = $allFiles | Select-String -Pattern "\b($($patterns -join '|'))\b"
if ($hits) {
	$hits | ForEach-Object { Write-Host "  $($_.Path):$($_.LineNumber): $($_.Line.Trim())" }
	Fail "brand names (real carmaker or model name in game code)"
}

if (-not (Test-Path Packages)) { Run "wally install" { wally install } }
Run "stylua" { stylua --check src tests }
Run "selene" { selene src tests }
New-Item -ItemType Directory -Force build | Out-Null
Run "rojo build" { rojo build -o build/check.rbxl }
Write-Host "CHECK PASSED" -ForegroundColor Green
