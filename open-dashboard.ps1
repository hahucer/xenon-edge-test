param([switch]$NoBrowser, [switch]$Restart, [switch]$StopOnly)
$ErrorActionPreference = 'Stop'
$baseUrl = 'http://127.0.0.1:47831'
$dataDirectory = Join-Path $PSScriptRoot 'data'

function Test-DashboardBridge {
    try {
        $result = Invoke-RestMethod -Uri "$baseUrl/dashboard" -TimeoutSec 1
        return ($result.schema -eq 1 -and [string]$result.storeId -ne '')
    } catch { return $false }
}

try {
    if ($Restart -or $StopOnly) {
        $pidFile = Join-Path $dataDirectory 'bridge.pid'
        if (Test-Path -LiteralPath $pidFile) {
            $oldId = 0
            if (-not [int]::TryParse([IO.File]::ReadAllText($pidFile).Trim(), [ref]$oldId)) { throw '공유 프로그램 실행 기록을 확인할 수 없습니다.' }
            $oldProcess = Get-Process -Id $oldId -ErrorAction SilentlyContinue
            if ($oldProcess) {
                $expectedEngine = (Get-Process -Id $PID).Path
                $recordedAt = (Get-Item -LiteralPath $pidFile).LastWriteTimeUtc
                if ($oldProcess.Path -ine $expectedEngine -or [Math]::Abs(($recordedAt - $oldProcess.StartTime.ToUniversalTime()).TotalSeconds) -gt 60) {
                    throw '실행 기록과 현재 프로그램이 일치하지 않아 자동으로 종료하지 않았습니다.'
                }
                Stop-Process -Id $oldProcess.Id -ErrorAction Stop
                [void]$oldProcess.WaitForExit(3000)
            }
        } elseif (Test-DashboardBridge) {
            throw '기존 공유 프로그램을 먼저 종료한 뒤 다시 시작해 주세요.'
        }
    }
    if ($StopOnly) { exit 0 }
    if (-not (Test-DashboardBridge)) {
        New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
        $engine = (Get-Process -Id $PID).Path
        $bridge = Join-Path $PSScriptRoot 'now-playing-bridge.ps1'
        $arguments = '-NoProfile -WindowStyle Hidden -File "' + $bridge + '"'
        $process = Start-Process -FilePath $engine -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $dataDirectory 'bridge-output.log') -RedirectStandardError (Join-Path $dataDirectory 'bridge-error.log')
        $ready = $false
        for ($attempt = 0; $attempt -lt 24; $attempt++) {
            if (Test-DashboardBridge) { $ready = $true; break }
            if ($process.HasExited) { break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $ready) {
            $details = Get-Content -LiteralPath (Join-Path $dataDirectory 'bridge-error.log') -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -First 1
            throw ('PC 공유 프로그램을 시작하지 못했습니다. ' + [string]$details)
        }
        [IO.File]::WriteAllText((Join-Path $dataDirectory 'bridge.pid'), [string]$process.Id)
    }
    if (-not $NoBrowser) { Start-Process -FilePath "$baseUrl/?page=today" }
} catch {
    if ($NoBrowser) { throw }
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show([string]$_.Exception.Message, 'Edge Desk', 'OK', 'Warning') | Out-Null
    exit 1
}
