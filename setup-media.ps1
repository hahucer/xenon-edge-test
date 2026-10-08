$ErrorActionPreference = 'Stop'
$runtimeDirectory = Join-Path $PSScriptRoot '.media-runtime'
$bundledPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$python = if (Test-Path -LiteralPath $bundledPython) { $bundledPython } else { (Get-Command python -ErrorAction Stop).Source }
New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
$requirements = Join-Path $PSScriptRoot 'media-requirements.txt'
& $python -m pip install --target $runtimeDirectory --upgrade --requirement $requirements --disable-pip-version-check
if ($LASTEXITCODE -ne 0) { throw '음악 연동 모듈을 설치하지 못했습니다.' }
[IO.File]::WriteAllText((Join-Path $runtimeDirectory 'python.txt'), $python)
Write-Host '음악 연동 준비가 끝났습니다. Edge Desk 공유 시작을 다시 실행해 주세요.'
