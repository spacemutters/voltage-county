# Quality gate. Run before every commit: .\scripts\check.ps1
# Steps: --!strict on every file -> brand names -> security table -> streaming settings -> StyLua check -> Selene ->
# Rojo build.
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

# No real carmaker or model names in game code (CLAUDE.md hard rule 4), and no real building, architect, street or
# neighbourhood the city takes after. Lists: scripts/banned-names.txt, scripts/banned-city-names.txt (the second is
# not part of the AI Car Designer's brand list below).
Write-Host "== brand names" -ForegroundColor Cyan
$patterns = Get-Content scripts/banned-names.txt | Where-Object { $_.Trim() -and -not $_.StartsWith("#") }
$cityPatterns = Get-Content scripts/banned-city-names.txt | Where-Object { $_.Trim() -and -not $_.StartsWith("#") }
$allFiles = Get-ChildItem src, tests -Recurse -File | Where-Object { $_.FullName -notmatch "\\Vendor\\" }
# A name counts whole wherever it stands, also inside an identifier: "_" and "-" separate words like a space does
# (so "marine_stadium" and "ocean-drive" are caught), and a space in a pattern matches any of the three.
$joined = (@($patterns) + @($cityPatterns) | ForEach-Object { $_.Trim().Replace(" ?", "[ _-]?").Replace(" ", "[ _-]") }) -join '|'
$hits = $allFiles | Select-String -Pattern "(?<![A-Za-z0-9])($joined)(?![A-Za-z0-9])"
if ($hits) {
	$hits | ForEach-Object { Write-Host "  $($_.Path):$($_.LineNumber): $($_.Line.Trim())" }
	Fail "brand names (a real carmaker, model, building or place name in game code)"
}

# The game checks AI text against its own copy of that list (src/shared/Util/BrandNames.luau, ROT13 so the check
# above passes; CLAUDE.md hard rule 11). Every line of scripts/banned-names.txt needs a phrase there.
Write-Host "== brand list in step" -ForegroundColor Cyan
$brandModule = "src/shared/Util/BrandNames.luau"
$encoded = Select-String -Path $brandModule -Pattern '^\s*"([a-z0-9 ]+)",\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
$phrases = $encoded | ForEach-Object {
	-join ($_.ToCharArray() | ForEach-Object {
		$code = [int]$_
		if ($code -ge 97 -and $code -le 122) { [char]((($code - 97 + 13) % 26) + 97) } else { $_ }
	})
}
if (-not $phrases) { Fail "brand list in step (no phrases found in $brandModule)" }
$missing = $patterns | ForEach-Object { $_.Trim() } | Where-Object {
	$regex = '^(?:' + $_ + ')$'
	-not ($phrases | Where-Object { $_ -match $regex })
}
if ($missing) {
	$missing | ForEach-Object { Write-Host "  no phrase in $brandModule for the pattern: $_" }
	Fail "brand list in step (add the missing names to $brandModule, ROT13-encoded)"
}

# Every remote in src/shared/Net.luau has its row in docs/SECURITY.md, and no row names a remote that isn't there.
Run "security table" { & "$PSScriptRoot\check-security-table.ps1" }

# default.project.json's Workspace streaming values match Config/Perf.streaming (scripts can't read them in a place).
Run "streaming settings" { & "$PSScriptRoot\check-streaming.ps1" }

if (-not (Test-Path Packages)) { Run "wally install" { wally install } }
Run "stylua" { stylua --check src tests }
Run "selene" { selene src tests }
New-Item -ItemType Directory -Force build | Out-Null
Run "rojo build" { rojo build -o build/check.rbxl }
Write-Host "CHECK PASSED" -ForegroundColor Green
