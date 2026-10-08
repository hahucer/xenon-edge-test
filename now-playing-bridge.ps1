param([string]$DataDirectory = (Join-Path $PSScriptRoot 'data'))

$ErrorActionPreference = 'Stop'
$Port = 47831
$MaxBodyBytes = 131072
$MaxHeaderBytes = 16384
$MaxRecords = 1000
$WidgetKeys = @('memo', 'focus', 'countdown', 'calculator', 'calendar')
$Utf8 = [Text.UTF8Encoding]::new($false, $true)
$AllowedOrigins = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
[void]$AllowedOrigins.Add('https://hahucer.github.io')
[void]$AllowedOrigins.Add("http://127.0.0.1:$Port")
[void]$AllowedOrigins.Add("http://localhost:$Port")
$AllowedHosts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void]$AllowedHosts.Add("127.0.0.1:$Port")
[void]$AllowedHosts.Add("localhost:$Port")
$DataDirectory = [IO.Path]::GetFullPath($DataDirectory)
$StatePath = Join-Path $DataDirectory 'dashboard-state.json'
$MediaAvailable = $true
try { Add-Type -AssemblyName System.Runtime.WindowsRuntime } catch { $MediaAvailable = $false }
$script:MediaResponse = @{ bridge = $true; available = $false; playing = $false }
$script:MediaResponseAt = [DateTime]::MinValue
$script:NextMediaQueryAt = [DateTime]::MinValue
$script:WeatherState = @{ available = $false; stale = $true; error = $null; status = 'loading'; updatedAt = $null; location = 'Edmonton'; timezone = 'America/Edmonton'; current = $null; today = $null; units = @{ temperature = 'C'; humidity = '%'; wind = 'km/h'; precipitation = 'mm' } }
$script:WeatherHttpClient = $null
$script:WeatherTask = $null
$script:WeatherCancellation = $null
$script:WeatherTimedOut = $false
$script:NextWeatherQueryAt = [DateTime]::MinValue

function Wait-WinRtOperation($Operation, [DateTime]$Deadline) {
    while ($Operation.Status.ToString() -eq 'Started') {
        $remaining = [int]($Deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0) { break }
        Start-Sleep -Milliseconds ([Math]::Min(20, $remaining))
    }
    if ($Operation.Status.ToString() -ne 'Completed' -or [DateTime]::UtcNow -gt $Deadline) {
        try { [void]$Operation.Cancel() } catch {}
        return $null
    }
    try { return $Operation.GetResults() } catch { return $null }
}
function Recent-MediaResponse {
    if ([DateTime]::UtcNow -le $script:MediaResponseAt.AddSeconds(15)) { return $script:MediaResponse }
    return @{ bridge = $true; available = $false; playing = $false }
}
function Remember-MediaResponse($Response) {
    $script:MediaResponse = $Response
    $script:MediaResponseAt = [DateTime]::UtcNow
    return $Response
}
function Get-LegacyNowPlaying {
    $now = [DateTime]::UtcNow
    if ($now -lt $script:NextMediaQueryAt) { return (Recent-MediaResponse) }
    $script:NextMediaQueryAt = $now.AddSeconds(3)
    if (-not $MediaAvailable) { return (Remember-MediaResponse @{ bridge = $true; available = $false; playing = $false }) }
    # Both asynchronous WinRT stages share one budget; dashboard requests do not wait twice.
    $deadline = $now.AddMilliseconds(600)
    try {
        $manager = Wait-WinRtOperation ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]::RequestAsync()) $deadline
        if ($null -eq $manager) { return (Recent-MediaResponse) }
        $session = $manager.GetCurrentSession()
        if ($null -eq $session) { return (Remember-MediaResponse @{ bridge = $true; available = $false; playing = $false }) }
        if ([DateTime]::UtcNow -ge $deadline) { return (Recent-MediaResponse) }
        $properties = Wait-WinRtOperation ($session.TryGetMediaPropertiesAsync()) $deadline
        if ($null -eq $properties) { return (Recent-MediaResponse) }
        $playback = $session.GetPlaybackInfo()
        $status = if ($null -ne $playback) { $playback.PlaybackStatus.ToString() } else { 'Unknown' }
        $source = ''
        try { $source = [string]$session.SourceAppUserModelId } catch {}
        return (Remember-MediaResponse @{ bridge = $true; available = $true; playing = ($status -eq 'Playing'); status = $status; title = [string]$properties.Title; artist = [string]$properties.Artist; album = [string]$properties.AlbumTitle; source = [string]$source })
    } catch { return (Recent-MediaResponse) }
}
function Invalid-Data([string]$Message) { throw [ArgumentException]::new($Message) }
function Property-Value($Object, [string]$Name) {
    if ($Object -is [Collections.IDictionary]) { return ,$Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}
function Require-Object($Value) {
    if ($null -eq $Value -or ($Value -isnot [Collections.IDictionary] -and $Value -isnot [Management.Automation.PSCustomObject])) { Invalid-Data 'object_required' }
}
function Valid-String($Value, [int]$Maximum, [bool]$AllowEmpty = $false) {
    if ($Value -isnot [string]) { Invalid-Data 'string_required' }
    $value = $Value.Trim()
    if ($value.Length -gt $Maximum -or (-not $AllowEmpty -and $value.Length -eq 0) -or $value -match '[\x00-\x1F\x7F]') { Invalid-Data 'invalid_string' }
    return $value
}
function Valid-Id($Value) { return (Valid-String $Value 80) }
function Valid-Task($Value) {
    Require-Object $Value
    $done = Property-Value $Value 'done'
    if ($done -isnot [bool]) { Invalid-Data 'done_must_be_boolean' }
    return @{ id = Valid-Id (Property-Value $Value 'id'); text = Valid-String (Property-Value $Value 'text') 160; done = $done }
}
function Valid-Event($Value) {
    Require-Object $Value
    $date = Valid-String (Property-Value $Value 'date') 10
    $time = Valid-String (Property-Value $Value 'time') 5 $true
    $parsed = [DateTime]::MinValue
    if ($date -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' -or -not [DateTime]::TryParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { Invalid-Data 'invalid_date' }
    if ($time -ne '' -and $time -cnotmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$') { Invalid-Data 'invalid_time' }
    return @{ id = Valid-Id (Property-Value $Value 'id'); name = Valid-String (Property-Value $Value 'name') 120; date = $date; time = $time }
}
function Valid-Records($Value, [string]$Kind) {
    if ($Value -isnot [Array] -or $Value.Count -gt $MaxRecords) { Invalid-Data 'invalid_record_array' }
    $items = [Collections.Generic.List[object]]::new()
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Value) {
        $record = if ($Kind -ceq 'task') { Valid-Task $item } else { Valid-Event $item }
        if (-not $ids.Add($record.id)) { Invalid-Data 'duplicate_record_id' }
        $items.Add($record)
    }
    return ,($items.ToArray())
}
function Has-Property($Object, [string]$Name) {
    if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
    return ($null -ne $Object.PSObject.Properties[$Name])
}
function Object-Keys($Object) {
    if ($Object -is [Collections.IDictionary]) { return ,@($Object.Keys) }
    return ,@($Object.PSObject.Properties.Name)
}
function Valid-Integer($Value, [long]$Minimum, [long]$Maximum) {
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt $Minimum -or $Value -gt $Maximum) { Invalid-Data 'invalid_integer' }
    return [long]$Value
}
function Valid-Number($Value, [double]$Minimum, [double]$Maximum) {
    if ($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [double] -and $Value -isnot [decimal]) { Invalid-Data 'number_required' }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $Minimum -or $number -gt $Maximum) { Invalid-Data 'invalid_number' }
    return $number
}
function Valid-WidgetText($Value, [int]$Maximum, [bool]$Multiline = $false) {
    if ($Value -isnot [string] -or $Value.Length -gt $Maximum) { Invalid-Data 'invalid_widget_text' }
    $forbidden = if ($Multiline) { '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]' } else { '[\x00-\x1F\x7F]' }
    if ($Value -match $forbidden) { Invalid-Data 'invalid_widget_text' }
    return $Value
}
function Default-Widgets {
    try { $edmonton = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'Mountain Standard Time') }
    catch { try { $edmonton = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'America/Edmonton') } catch { $edmonton = [DateTime]::UtcNow } }
    return [ordered]@{
        memo = [ordered]@{ text = '' }
        focus = [ordered]@{ durationSeconds = [long]300; remainingSeconds = [double]300; running = $false; endAt = $null }
        countdown = [ordered]@{ durationSeconds = [long]600; remainingSeconds = [double]600; running = $false; endAt = $null }
        calculator = [ordered]@{ expression = ''; result = '0'; history = @(); entry = '0'; accumulator = $null; lastOperand = $null; operation = $null; lastOperation = $null; waiting = $false; finished = $false; error = $false }
        calendar = [ordered]@{ year = [long][Math]::Min(2100, [Math]::Max(2000, $edmonton.Year)); month = [long]($edmonton.Month - 1) }
    }
}
function Valid-WidgetValue([string]$Key, $Value) {
    Require-Object $Value
    switch -CaseSensitive ($Key) {
        'memo' { return [ordered]@{ text = Valid-WidgetText (Property-Value $Value 'text') 10000 $true } }
        { $_ -ceq 'focus' -or $_ -ceq 'countdown' } {
            $running = Property-Value $Value 'running'
            if ($running -isnot [bool]) { Invalid-Data 'running_must_be_boolean' }
            $endAt = Property-Value $Value 'endAt'
            if ($null -ne $endAt) { $endAt = Valid-Integer $endAt 1 253402300799999 }
            if ($running -and $null -eq $endAt) { Invalid-Data 'running_timer_requires_end_at' }
            return [ordered]@{
                durationSeconds = Valid-Integer (Property-Value $Value 'durationSeconds') 1 86400
                remainingSeconds = Valid-Number (Property-Value $Value 'remainingSeconds') 0 86400
                running = $running
                endAt = $endAt
            }
        }
        'calculator' {
            $history = Property-Value $Value 'history'
            if ($history -isnot [Array] -or $history.Count -gt 20) { Invalid-Data 'invalid_calculator_history' }
            $items = [Collections.Generic.List[object]]::new()
            foreach ($entry in $history) {
                Require-Object $entry
                $record = [ordered]@{ expression = Valid-WidgetText (Property-Value $entry 'expression') 200; result = Valid-WidgetText (Property-Value $entry 'result') 200 }
                if (Has-Property $entry 'at') {
                    $record.at = Valid-Integer (Property-Value $entry 'at') 0 253402300799999
                }
                $items.Add($record)
            }
            $calculator = [ordered]@{ expression = Valid-WidgetText (Property-Value $Value 'expression') 200; result = Valid-WidgetText (Property-Value $Value 'result') 200; history = $items.ToArray() }
            $calculator.entry = if (Has-Property $Value 'entry') { Valid-WidgetText (Property-Value $Value 'entry') 200 } else { $calculator.result }
            foreach ($key in @('accumulator', 'lastOperand')) {
                $number = if (Has-Property $Value $key) { Property-Value $Value $key } else { $null }
                if ($null -ne $number) { $number = Valid-Number $number (-[double]::MaxValue) ([double]::MaxValue) }
                $calculator[$key] = $number
            }
            foreach ($key in @('operation', 'lastOperation')) {
                $operator = if (Has-Property $Value $key) { Property-Value $Value $key } else { $null }
                if ($null -ne $operator -and ($operator -isnot [string] -or $operator -cnotin @('+', '-', '*', '/'))) { Invalid-Data 'invalid_calculator_operator' }
                $calculator[$key] = $operator
            }
            foreach ($key in @('waiting', 'finished', 'error')) {
                $flag = if (Has-Property $Value $key) { Property-Value $Value $key } else { $false }
                if ($flag -isnot [bool]) { Invalid-Data 'calculator_flag_must_be_boolean' }
                $calculator[$key] = $flag
            }
            return $calculator
        }
        'calendar' { return [ordered]@{ year = Valid-Integer (Property-Value $Value 'year') 2000 2100; month = Valid-Integer (Property-Value $Value 'month') 0 11 } }
        default { Invalid-Data 'unsupported_widget' }
    }
}
function Valid-Widgets($Value) {
    $widgets = Default-Widgets
    if ($null -eq $Value) { return $widgets }
    Require-Object $Value
    foreach ($key in (Object-Keys $Value)) { if ($key -cnotin $WidgetKeys) { Invalid-Data 'unsupported_widget' } }
    foreach ($key in $WidgetKeys) { if (Has-Property $Value $key) { $widgets[$key] = Valid-WidgetValue $key (Property-Value $Value $key) } }
    return $widgets
}
function Valid-WidgetRevisions($Value) {
    $revisions = [ordered]@{ memo = [long]0; focus = [long]0; countdown = [long]0; calculator = [long]0; calendar = [long]0 }
    if ($null -eq $Value) { return $revisions }
    Require-Object $Value
    foreach ($key in (Object-Keys $Value)) { if ($key -cnotin $WidgetKeys) { Invalid-Data 'unsupported_widget' } }
    foreach ($key in $WidgetKeys) { if (Has-Property $Value $key) { $revisions[$key] = Valid-Integer (Property-Value $Value $key) 0 ([long]::MaxValue - 1) } }
    return $revisions
}
function Set-WeatherFailure([string]$Reason) {
    $script:WeatherState.stale = $true
    $script:WeatherState.error = $Reason
    $script:WeatherState.status = if ($script:WeatherState.available) { 'stale' } else { 'error' }
    $script:NextWeatherQueryAt = [DateTime]::UtcNow.AddSeconds(30)
}
function Weather-Snapshot($Data) {
    Require-Object $Data
    $current = Property-Value $Data 'current'
    $daily = Property-Value $Data 'daily'
    Require-Object $current
    Require-Object $daily
    $minimums = Property-Value $daily 'temperature_2m_min'
    $maximums = Property-Value $daily 'temperature_2m_max'
    if ($minimums -isnot [Array] -or $maximums -isnot [Array] -or $minimums.Count -eq 0 -or $maximums.Count -eq 0) { Invalid-Data 'invalid_weather_daily' }
    $minimum = Valid-Number $minimums[0] -100 100
    $maximum = Valid-Number $maximums[0] -100 100
    if ($minimum -gt $maximum) { Invalid-Data 'invalid_weather_daily' }
    $time = Property-Value $current 'time'
    if ($time -is [DateTime]) { $time = $time.ToString('yyyy-MM-ddTHH:mm', [Globalization.CultureInfo]::InvariantCulture) }
    $time = Valid-WidgetText $time 40
    return @{
        available = $true; stale = $false; error = $null; status = 'ready'
        updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        location = 'Edmonton'; timezone = 'America/Edmonton'
        units = @{ temperature = 'C'; humidity = '%'; wind = 'km/h'; precipitation = 'mm' }
        current = @{
            temperature_2m = Valid-Number (Property-Value $current 'temperature_2m') -100 100
            apparent_temperature = Valid-Number (Property-Value $current 'apparent_temperature') -150 150
            relative_humidity_2m = Valid-Number (Property-Value $current 'relative_humidity_2m') 0 100
            weather_code = Valid-Integer (Property-Value $current 'weather_code') 0 99
            wind_speed_10m = Valid-Number (Property-Value $current 'wind_speed_10m') 0 500
            precipitation = Valid-Number (Property-Value $current 'precipitation') 0 1000
            is_day = Valid-Integer (Property-Value $current 'is_day') 0 1
            time = $time
        }
        today = @{ temperature_2m_min = $minimum; temperature_2m_max = $maximum }
    }
}
function Advance-Weather {
    # HttpClient runs its request asynchronously. No dashboard handler waits for DNS or weather.
    if ($null -ne $script:WeatherTask) {
        if ($script:WeatherTask.IsCompleted) {
            $response = $null
            try {
                $response = $script:WeatherTask.GetAwaiter().GetResult()
                if (-not $script:WeatherTimedOut) {
                    [void]$response.EnsureSuccessStatusCode()
                    $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    $script:WeatherState = Weather-Snapshot (ConvertFrom-Json -InputObject $json -ErrorAction Stop)
                    $script:NextWeatherQueryAt = [DateTime]::UtcNow.AddMinutes(10)
                }
            } catch { if (-not $script:WeatherTimedOut) { Set-WeatherFailure 'weather_unavailable' } }
            finally {
                if ($null -ne $response) { $response.Dispose() }
                $script:WeatherTask.Dispose()
                $script:WeatherTask = $null
                if ($null -ne $script:WeatherCancellation) { $script:WeatherCancellation.Dispose(); $script:WeatherCancellation = $null }
            }
        } elseif (-not $script:WeatherTimedOut -and [DateTime]::UtcNow -ge $script:WeatherDeadline) {
            $script:WeatherTimedOut = $true
            $script:WeatherCancellation.Cancel()
            Set-WeatherFailure 'weather_timeout'
        }
    }
    if ($null -ne $script:WeatherTask -or [DateTime]::UtcNow -lt $script:NextWeatherQueryAt) { return }
    try {
        if ($null -eq $script:WeatherHttpClient) {
            Add-Type -AssemblyName System.Net.Http
            $script:WeatherHttpClient = [Net.Http.HttpClient]::new()
            $script:WeatherHttpClient.Timeout = [TimeSpan]::FromSeconds(2)
            $script:WeatherHttpClient.MaxResponseContentBufferSize = 1048576
        }
        $script:WeatherCancellation = [Threading.CancellationTokenSource]::new(2000)
        $script:WeatherTimedOut = $false
        $script:WeatherDeadline = [DateTime]::UtcNow.AddSeconds(2)
        $script:NextWeatherQueryAt = [DateTime]::UtcNow.AddMinutes(10)
        $uri = 'https://api.open-meteo.com/v1/forecast?latitude=53.5461&longitude=-113.4938&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,precipitation,is_day&daily=temperature_2m_min,temperature_2m_max&timezone=America%2FEdmonton&forecast_days=1'
        $script:WeatherTask = $script:WeatherHttpClient.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseContentRead, $script:WeatherCancellation.Token)
    } catch {
        if ($null -ne $script:WeatherCancellation) { $script:WeatherCancellation.Dispose(); $script:WeatherCancellation = $null }
        Set-WeatherFailure 'weather_unavailable'
    }
}
function Empty-MediaSnapshot([string]$Reason, [bool]$Helper = $false, [bool]$Stale = $false) {
    return @{ schema = 1; updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); bridge = $true; helper = $Helper; available = $false; playing = $false; status = 'Stopped'; title = ''; artist = ''; album = ''; source = ''; positionSeconds = [double]0; durationSeconds = [double]0; reason = $Reason; stale = $Stale; artworkVersion = ''; artworkMime = ''; artworkBytes = [long]0 }
}
function Read-BoundedLocalFile([string]$Path, [int]$Maximum) {
    $file = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $file = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        if ($file.Length -le 0 -or $file.Length -gt $Maximum) { Invalid-Data 'invalid_local_file_size' }
        $bytes = [byte[]]::new([int]$file.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $file.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { Invalid-Data 'truncated_local_file' }
            $offset += $read
        }
        return ,$bytes
    } finally { if ($null -ne $file) { $file.Dispose() } }
}
function Normalize-MediaSnapshot($Value) {
    Require-Object $Value
    if ((Valid-Integer (Property-Value $Value 'schema') 1 1) -ne 1) { Invalid-Data 'invalid_media_schema' }
    $snapshot = Empty-MediaSnapshot '' $true
    foreach ($key in @('bridge', 'helper', 'available', 'playing', 'stale')) {
        $flag = Property-Value $Value $key
        if ($flag -isnot [bool]) { Invalid-Data 'invalid_media_flag' }
        $snapshot[$key] = $flag
    }
    foreach ($key in @('status', 'title', 'artist', 'album', 'source', 'reason')) { $snapshot[$key] = Valid-WidgetText (Property-Value $Value $key) 1024 $true }
    $snapshot.updatedAt = Valid-Integer (Property-Value $Value 'updatedAt') 0 253402300799999
    $snapshot.positionSeconds = Valid-Number (Property-Value $Value 'positionSeconds') 0 31536000
    $snapshot.durationSeconds = Valid-Number (Property-Value $Value 'durationSeconds') 0 31536000
    $snapshot.artworkBytes = Valid-Integer (Property-Value $Value 'artworkBytes') 0 2097152
    $snapshot.artworkVersion = Valid-WidgetText (Property-Value $Value 'artworkVersion') 64
    $snapshot.artworkMime = Valid-WidgetText (Property-Value $Value 'artworkMime') 32
    if ($snapshot.artworkBytes -gt 0) {
        if ($snapshot.artworkVersion -cnotmatch '^[a-f0-9]{64}$' -or $snapshot.artworkMime -cnotin @('image/png', 'image/jpeg', 'image/gif', 'image/webp')) { Invalid-Data 'invalid_media_artwork' }
    } elseif ($snapshot.artworkVersion -ne '' -or $snapshot.artworkMime -ne '') { Invalid-Data 'invalid_media_artwork' }
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $snapshot.updatedAt
    if ($age -lt -10000) { Invalid-Data 'invalid_media_timestamp' }
    if ($age -gt 15000) { $snapshot.stale = $true; $snapshot.playing = $false; $snapshot.reason = 'helper_snapshot_stale' }
    return $snapshot
}
function Get-NowPlaying {
    $path = Join-Path $DataDirectory 'media-state.json'
    if ([IO.File]::Exists($path)) {
        try { return (Normalize-MediaSnapshot (ConvertFrom-Json -InputObject ($Utf8.GetString((Read-BoundedLocalFile $path 65536))) -ErrorAction Stop)) }
        catch { return (Empty-MediaSnapshot 'helper_snapshot_invalid' $true $true) }
    }
    $legacy = Get-LegacyNowPlaying
    $reason = if ($legacy.available) { 'legacy_media_helper_missing' } elseif (-not $MediaAvailable) { 'helper_missing_runtime_unavailable' } else { 'helper_missing' }
    $snapshot = Empty-MediaSnapshot $reason
    $snapshot.available = [bool]$legacy.available
    $snapshot.playing = [bool]$legacy.playing
    foreach ($key in @('status', 'title', 'artist', 'album', 'source')) { if ($legacy.ContainsKey($key)) { $snapshot[$key] = [string]$legacy[$key] } }
    return $snapshot
}
function Artwork-Mime([byte[]]$Bytes) {
    if ($Bytes.Length -ge 8 -and $Bytes[0] -eq 137 -and $Bytes[1] -eq 80 -and $Bytes[2] -eq 78 -and $Bytes[3] -eq 71 -and $Bytes[4] -eq 13 -and $Bytes[5] -eq 10 -and $Bytes[6] -eq 26 -and $Bytes[7] -eq 10) { return 'image/png' }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 216 -and $Bytes[2] -eq 255) { return 'image/jpeg' }
    if ($Bytes.Length -ge 6 -and [Text.Encoding]::ASCII.GetString($Bytes, 0, 6) -cin @('GIF87a', 'GIF89a')) { return 'image/gif' }
    if ($Bytes.Length -ge 12 -and [Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ceq 'RIFF' -and [Text.Encoding]::ASCII.GetString($Bytes, 8, 4) -ceq 'WEBP') { return 'image/webp' }
    return ''
}
function Valid-State($Value) {
    Require-Object $Value
    $schema = Property-Value $Value 'schema'
    if (($schema -isnot [int] -and $schema -isnot [long]) -or $schema -ne 1) { Invalid-Data 'invalid_schema' }
    $storeId = Valid-String (Property-Value $Value 'storeId') 80
    $uuid = [Guid]::Empty
    if (-not [Guid]::TryParse($storeId, [ref]$uuid) -or $uuid -eq [Guid]::Empty) { Invalid-Data 'invalid_store_id' }
    $revision = Property-Value $Value 'revision'
    if (($revision -isnot [int] -and $revision -isnot [long]) -or $revision -lt 0 -or $revision -ge [long]::MaxValue) { Invalid-Data 'invalid_revision' }
    if (Has-Property $Value 'widgets') { if ($null -eq (Property-Value $Value 'widgets')) { Invalid-Data 'invalid_widgets' } }
    if (Has-Property $Value 'widgetRevisions') { if ($null -eq (Property-Value $Value 'widgetRevisions')) { Invalid-Data 'invalid_widget_revisions' } }
    $opIds = Property-Value $Value 'processedOpIds'
    if ($opIds -isnot [Array] -or $opIds.Count -gt 512) { Invalid-Data 'invalid_operation_history' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $history = [Collections.Generic.List[string]]::new()
    foreach ($id in $opIds) {
        $id = Valid-Id $id
        if (-not $seen.Add($id)) { Invalid-Data 'duplicate_operation_id' }
        $history.Add($id)
    }
    return @{ schema = 1; storeId = $storeId; revision = [long]$revision; tasks = (Valid-Records (Property-Value $Value 'tasks') 'task'); events = (Valid-Records (Property-Value $Value 'events') 'event'); widgets = (Valid-Widgets (Property-Value $Value 'widgets')); widgetRevisions = (Valid-WidgetRevisions (Property-Value $Value 'widgetRevisions')); processedOpIds = $history.ToArray() }
}
function Save-State($State) {
    [void][IO.Directory]::CreateDirectory($DataDirectory)
    if ([IO.File]::Exists($StatePath)) {
        try {
            if ([IO.FileInfo]::new($StatePath).Length -gt 2097152) { throw 'state_file_too_large' }
            $saved = Valid-State (ConvertFrom-Json -InputObject ($Utf8.GetString([IO.File]::ReadAllBytes($StatePath))) -ErrorAction Stop)
        } catch { throw [IO.IOException]::new('The saved dashboard file cannot be read. It was not overwritten; restore a valid backup.') }
        if ($null -ne $script:DashboardState -and ($saved.storeId -cne $script:DashboardState.storeId -or $saved.revision -ne $script:DashboardState.revision)) {
            throw [IO.IOException]::new('The saved dashboard file changed outside this process. It was not overwritten; restart the bridge.')
        }
    }
    $temporary = Join-Path $DataDirectory ('.dashboard-state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $bytes = $Utf8.GetBytes(($State | ConvertTo-Json -Depth 10 -Compress))
    $file = $null
    try {
        $file = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $file.Write($bytes, 0, $bytes.Length)
        $file.Flush($true)
        $file.Dispose(); $file = $null
        if ([IO.File]::Exists($StatePath)) { [IO.File]::Replace($temporary, $StatePath, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $StatePath) }
    } finally {
        if ($null -ne $file) { $file.Dispose() }
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
function Load-State {
    if (-not [IO.File]::Exists($StatePath)) {
        $state = @{ schema = 1; storeId = [Guid]::NewGuid().ToString(); revision = [long]0; tasks = @(); events = @(); widgets = (Default-Widgets); widgetRevisions = (Valid-WidgetRevisions $null); processedOpIds = @() }
        Save-State $state
        return $state
    }
    try {
        if ([IO.FileInfo]::new($StatePath).Length -gt 2097152) { throw 'state_file_too_large' }
        $json = $Utf8.GetString([IO.File]::ReadAllBytes($StatePath))
        return (Valid-State (ConvertFrom-Json -InputObject $json -ErrorAction Stop))
    } catch {
        throw "Dashboard data cannot be read. The existing file was not changed: $StatePath. Restore a valid backup or select a separate DataDirectory."
    }
}
function Public-State($State) {
    return @{ schema = 1; storeId = $State.storeId; revision = $State.revision; serverNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); tasks = @($State.tasks); events = @($State.events); widgets = $State.widgets; widgetRevisions = $State.widgetRevisions; live = @{ weather = $script:WeatherState; media = (Get-NowPlaying) } }
}
function Valid-Batch($Body) {
    Require-Object $Body
    $inputOperations = Property-Value $Body 'operations'
    if ($inputOperations -isnot [Array] -or $inputOperations.Count -gt 100) { Invalid-Data 'invalid_operation_batch' }
    $operations = [Collections.Generic.List[object]]::new()
    foreach ($operation in $inputOperations) {
        Require-Object $operation
        $normalized = @{ opId = Valid-Id (Property-Value $operation 'opId'); kind = Valid-String (Property-Value $operation 'kind') 32 }
        switch -CaseSensitive ($normalized.kind) {
            'task.add' { $normalized.item = Valid-Task (Property-Value $operation 'item') }
            'task.set' {
                $normalized.id = Valid-Id (Property-Value $operation 'id')
                $normalized.done = Property-Value $operation 'done'
                if ($normalized.done -isnot [bool]) { Invalid-Data 'done_must_be_boolean' }
            }
            'task.remove' { $normalized.id = Valid-Id (Property-Value $operation 'id') }
            'event.add' { $normalized.item = Valid-Event (Property-Value $operation 'item') }
            'event.remove' { $normalized.id = Valid-Id (Property-Value $operation 'id') }
            { $_ -ceq 'widget.set' -or $_ -ceq 'widget.import' } {
                $normalized.key = Valid-String (Property-Value $operation 'key') 32
                if ($normalized.key -cnotin $WidgetKeys) { Invalid-Data 'unsupported_widget' }
                $normalized.value = Valid-WidgetValue $normalized.key (Property-Value $operation 'value')
            }
            'import' {
                $normalized.tasks = Valid-Records (Property-Value $operation 'tasks') 'task'
                $normalized.events = Valid-Records (Property-Value $operation 'events') 'event'
            }
            default { Invalid-Data 'unsupported_operation' }
        }
        $operations.Add($normalized)
    }
    return ,($operations.ToArray())
}
function Apply-Batch($Operations) {
    # Detached records become live only after successful atomic persistence.
    $next = @{ schema = 1; storeId = $script:DashboardState.storeId; revision = $script:DashboardState.revision; tasks = @(); events = @(); widgets = (Valid-Widgets $script:DashboardState.widgets); widgetRevisions = (Valid-WidgetRevisions $script:DashboardState.widgetRevisions); processedOpIds = @() }
    $tasks = [Collections.Generic.List[object]]::new()
    $events = [Collections.Generic.List[object]]::new()
    $history = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($task in $script:DashboardState.tasks) { $tasks.Add(@{ id = $task.id; text = $task.text; done = $task.done }) }
    foreach ($event in $script:DashboardState.events) { $events.Add(@{ id = $event.id; name = $event.name; date = $event.date; time = $event.time }) }
    foreach ($id in $script:DashboardState.processedOpIds) { $history.Add($id); [void]$seen.Add($id) }
    $changed = $false
    $newOperations = $false
    foreach ($operation in $Operations) {
        if ($seen.Contains($operation.opId)) { continue }
        switch -CaseSensitive ($operation.kind) {
            'task.add' {
                $exists = $false
                foreach ($task in $tasks) { if ($task.id -ceq $operation.item.id) { $exists = $true; break } }
                if (-not $exists) { $tasks.Add($operation.item); $changed = $true }
            }
            'task.set' { foreach ($task in $tasks) { if ($task.id -ceq $operation.id -and $task.done -ne $operation.done) { $task.done = $operation.done; $changed = $true; break } } }
            'task.remove' { for ($i = $tasks.Count - 1; $i -ge 0; $i--) { if ($tasks[$i].id -ceq $operation.id) { $tasks.RemoveAt($i); $changed = $true } } }
            'event.add' {
                $exists = $false
                foreach ($event in $events) { if ($event.id -ceq $operation.item.id) { $exists = $true; break } }
                if (-not $exists) { $events.Add($operation.item); $changed = $true }
            }
            'event.remove' { for ($i = $events.Count - 1; $i -ge 0; $i--) { if ($events[$i].id -ceq $operation.id) { $events.RemoveAt($i); $changed = $true } } }
            { $_ -ceq 'widget.set' -or $_ -ceq 'widget.import' } {
                $key = $operation.key
                $widgetRevision = $next.widgetRevisions[$key]
                if ($operation.kind -ceq 'widget.set' -or $widgetRevision -eq 0) {
                    $before = $next.widgets[$key] | ConvertTo-Json -Depth 10 -Compress
                    $after = $operation.value | ConvertTo-Json -Depth 10 -Compress
                    if ($before -cne $after -or $widgetRevision -eq 0) {
                        if ($widgetRevision -ge ([long]::MaxValue - 1)) { Invalid-Data 'widget_revision_limit' }
                        $next.widgets[$key] = $operation.value
                        $next.widgetRevisions[$key] = [long]$widgetRevision + 1
                        $changed = $true
                    }
                }
            }
            'import' {
                foreach ($item in $operation.tasks) {
                    $exists = $false
                    foreach ($task in $tasks) { if ($task.id -ceq $item.id -or $task.text -ceq $item.text) { $exists = $true; break } }
                    if (-not $exists) { $tasks.Add($item); $changed = $true }
                }
                foreach ($item in $operation.events) {
                    $exists = $false
                    foreach ($event in $events) { if ($event.id -ceq $item.id -or ($event.name -ceq $item.name -and $event.date -ceq $item.date -and $event.time -ceq $item.time)) { $exists = $true; break } }
                    if (-not $exists) { $events.Add($item); $changed = $true }
                }
            }
        }
        if ($tasks.Count -gt $MaxRecords -or $events.Count -gt $MaxRecords) { Invalid-Data 'too_many_records' }
        [void]$seen.Add($operation.opId)
        $history.Add($operation.opId)
        if ($history.Count -gt 512) { $history.RemoveAt(0) }
        $newOperations = $true
    }
    if (-not $newOperations) { return (Public-State $script:DashboardState) }
    if ($changed) {
        if ($next.revision -ge ([long]::MaxValue - 1)) { Invalid-Data 'revision_limit' }
        $next.revision = [long]$next.revision + 1
    }
    $next.tasks = $tasks.ToArray(); $next.events = $events.ToArray(); $next.processedOpIds = $history.ToArray()
    Save-State $next
    $script:DashboardState = $next
    return (Public-State $next)
}
function Read-HttpRequest($Stream) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $header = [Collections.Generic.List[byte]]::new()
    while ($true) {
        $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0) { throw [TimeoutException]::new('request_timeout') }
        $Stream.ReadTimeout = $remaining
        $nextByte = $Stream.ReadByte()
        if ($nextByte -lt 0) { Invalid-Data 'truncated_headers' }
        $header.Add([byte]$nextByte)
        if ($header.Count -gt $MaxHeaderBytes) { Invalid-Data 'headers_too_large' }
        $n = $header.Count
        if ($n -ge 4 -and $header[$n - 4] -eq 13 -and $header[$n - 3] -eq 10 -and $header[$n - 2] -eq 13 -and $header[$n - 1] -eq 10) { break }
    }
    foreach ($byte in $header) { if ($byte -gt 126 -or ($byte -lt 32 -and $byte -notin @(9, 10, 13))) { Invalid-Data 'invalid_header_bytes' } }
    $lines = [Text.Encoding]::ASCII.GetString($header.ToArray()).Split(@("`r`n"), [StringSplitOptions]::None)
    if ($lines[0] -cnotmatch '^([A-Z]+) (/[^ \r\n#]*) HTTP/1\.[01]$') { Invalid-Data 'invalid_request_line' }
    $method = $Matches[1]; $target = $Matches[2]
    $headers = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($i = 1; $i -lt ($lines.Length - 2); $i++) {
        $line = $lines[$i]
        $separator = $line.IndexOf(':')
        if ($separator -le 0) { Invalid-Data 'invalid_header' }
        $name = $line.Substring(0, $separator)
        if ($name -cnotmatch '^[!#$%&''*+.^_`|~0-9A-Za-z-]+$' -or $headers.ContainsKey($name) -or $headers.Count -ge 64) { Invalid-Data 'invalid_or_duplicate_header' }
        $headers.Add($name, $line.Substring($separator + 1).Trim())
    }
    if ($headers.ContainsKey('Transfer-Encoding')) { Invalid-Data 'transfer_encoding_not_supported' }
    $length = [long]0
    if ($headers.ContainsKey('Content-Length')) {
        if ($headers['Content-Length'] -cnotmatch '^[0-9]+$' -or -not [long]::TryParse($headers['Content-Length'], [ref]$length) -or $length -gt $MaxBodyBytes) { Invalid-Data 'invalid_content_length' }
    } elseif ($method -ceq 'POST') { Invalid-Data 'content_length_required' }
    $bytes = [byte[]]::new([int]$length)
    $offset = 0
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($offset -lt $bytes.Length) {
        $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0) { throw [TimeoutException]::new('request_timeout') }
        $Stream.ReadTimeout = $remaining
        $read = $Stream.Read($bytes, $offset, $bytes.Length - $offset)
        if ($read -le 0) { Invalid-Data 'truncated_body' }
        $offset += $read
    }
    return @{ method = $method; path = $target.Split('?')[0]; headers = $headers; bytes = $bytes }
}
function Write-HttpResponse($Stream, [int]$Status, [string]$Reason, [byte[]]$Bytes, [string]$ContentType, [string]$Origin = '', [bool]$Preflight = $false) {
    $headers = [Collections.Generic.List[string]]::new()
    $headers.Add("HTTP/1.1 $Status $Reason")
    $headers.Add("Content-Type: $ContentType")
    if ($Status -ne 204) { $headers.Add("Content-Length: $($Bytes.Length)") }
    $headers.Add('Cache-Control: no-store, max-age=0')
    $headers.Add('X-Content-Type-Options: nosniff')
    $headers.Add('Connection: close')
    if ($AllowedOrigins.Contains($Origin)) {
        $headers.Add("Access-Control-Allow-Origin: $Origin")
        $headers.Add('Vary: Origin')
        if ($Preflight) {
            $headers.Add('Access-Control-Allow-Methods: GET, POST, OPTIONS')
            $headers.Add('Access-Control-Allow-Headers: Content-Type, X-Edge-Request')
            $headers.Add('Access-Control-Allow-Private-Network: true')
            $headers.Add('Access-Control-Max-Age: 600')
        }
    }
    $head = [Text.Encoding]::ASCII.GetBytes(($headers -join "`r`n") + "`r`n`r`n")
    $Stream.Write($head, 0, $head.Length)
    if ($Bytes.Length -gt 0) { $Stream.Write($Bytes, 0, $Bytes.Length) }
}
function Write-JsonResponse($Stream, [int]$Status, [string]$Reason, $Value, [string]$Origin = '') {
    $bytes = $Utf8.GetBytes(($Value | ConvertTo-Json -Depth 10 -Compress))
    Write-HttpResponse $Stream $Status $Reason $bytes 'application/json; charset=utf-8' $Origin
}
function Write-EventStreamHeaders($Stream, [string]$Origin) {
    $headers = [Collections.Generic.List[string]]::new()
    $headers.Add('HTTP/1.1 200 OK')
    $headers.Add('Content-Type: text/event-stream; charset=utf-8')
    $headers.Add('Cache-Control: no-store, max-age=0')
    $headers.Add('X-Content-Type-Options: nosniff')
    $headers.Add('X-Accel-Buffering: no')
    $headers.Add('Connection: keep-alive')
    $headers.Add('Transfer-Encoding: chunked')
    if ($AllowedOrigins.Contains($Origin)) {
        $headers.Add("Access-Control-Allow-Origin: $Origin")
        $headers.Add('Vary: Origin')
    }
    $bytes = [Text.Encoding]::ASCII.GetBytes(($headers -join "`r`n") + "`r`n`r`n")
    $Stream.Write($bytes, 0, $bytes.Length)
}
function Dashboard-EventBytes {
    $json = (Public-State $script:DashboardState) | ConvertTo-Json -Depth 10 -Compress
    return ,($Utf8.GetBytes("event: dashboard`ndata: $json`n`n"))
}
function Write-EventStreamChunk($Stream, [byte[]]$Payload) {
    # One complete HTTP chunk per write; SSE receives the unchunked UTF-8 event.
    $prefix = [Text.Encoding]::ASCII.GetBytes(('{0:X}' -f $Payload.Length) + "`r`n")
    $bytes = [byte[]]::new($prefix.Length + $Payload.Length + 2)
    [Buffer]::BlockCopy($prefix, 0, $bytes, 0, $prefix.Length)
    [Buffer]::BlockCopy($Payload, 0, $bytes, $prefix.Length, $Payload.Length)
    $bytes[$bytes.Length - 2] = 13
    $bytes[$bytes.Length - 1] = 10
    $Stream.Write($bytes, 0, $bytes.Length)
}
function Remove-DashboardSubscriber([int]$Index) {
    $subscriber = $script:DashboardSubscribers[$Index]
    try { $subscriber.stream.Dispose() } catch {}
    try { $subscriber.client.Close() } catch {}
    $script:DashboardSubscribers.RemoveAt($Index)
}
function Test-DashboardSubscriber($Subscriber) {
    try {
        if (-not $Subscriber.client.Connected) { return $false }
        if ($Subscriber.client.Client.Poll(0, [Net.Sockets.SelectMode]::SelectRead) -and $Subscriber.client.Available -eq 0) { return $false }
        return $true
    } catch { return $false }
}
function Prune-DashboardSubscribers {
    for ($i = $script:DashboardSubscribers.Count - 1; $i -ge 0; $i--) {
        if (-not (Test-DashboardSubscriber $script:DashboardSubscribers[$i])) { Remove-DashboardSubscriber $i }
    }
}
function Broadcast-Dashboard {
    if ($script:DashboardSubscribers.Count -eq 0) { return }
    $bytes = Dashboard-EventBytes
    for ($i = $script:DashboardSubscribers.Count - 1; $i -ge 0; $i--) {
        $subscriber = $script:DashboardSubscribers[$i]
        if (-not (Test-DashboardSubscriber $subscriber)) { Remove-DashboardSubscriber $i; continue }
        try { Write-EventStreamChunk $subscriber.stream $bytes }
        catch { Remove-DashboardSubscriber $i }
    }
}
function Is-RequestTimeout($Exception) {
    while ($null -ne $Exception) {
        if ($Exception -is [TimeoutException]) { return $true }
        if ($Exception -is [Net.Sockets.SocketException] -and $Exception.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) { return $true }
        $Exception = $Exception.InnerException
    }
    return $false
}

$script:DashboardSubscribers = [Collections.Generic.List[object]]::new()
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$listener.Start()
try {
    # Only the process that owns the loopback listener may initialize the store.
    $script:DashboardState = Load-State
    Write-Output "Xenon Edge dashboard bridge: http://127.0.0.1:$Port (loopback only)"
    $nextHeartbeat = [DateTime]::UtcNow.AddSeconds(3)
    while ($true) {
        Advance-Weather
        if ([DateTime]::UtcNow -ge $nextHeartbeat) {
            Broadcast-Dashboard
            $nextHeartbeat = [DateTime]::UtcNow.AddSeconds(3)
        }
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
        $client = $listener.AcceptTcpClient()
        $stream = $null
        $origin = ''
        $persistent = $false
        $eventStreamStarted = $false
        try {
            # Browsers may open idle preconnections. Do not let one block ready requests.
            if (-not $client.Client.Poll(200000, [Net.Sockets.SelectMode]::SelectRead) -or $client.Available -eq 0) {
                continue
            }
            $stream = $client.GetStream()
            $stream.WriteTimeout = 5000
            $request = Read-HttpRequest $stream
            $headers = $request.headers
            $origin = [string]$headers['Origin']
            if (-not $AllowedHosts.Contains([string]$headers['Host'])) { Write-JsonResponse $stream 403 'Forbidden' @{ error = 'host_not_allowed' }; continue }
            if ($headers.ContainsKey('Origin') -and -not $AllowedOrigins.Contains($origin)) { Write-JsonResponse $stream 403 'Forbidden' @{ error = 'origin_not_allowed' }; continue }
            $knownPath = $request.path -cin @('/', '/index.html', '/game.html', '/dashboard', '/dashboard/events', '/now-playing', '/media-art')
            if (-not $knownPath) { Write-JsonResponse $stream 404 'Not Found' @{ error = 'not_found' } $origin; continue }
            if ($request.method -ceq 'OPTIONS') {
                if (-not $AllowedOrigins.Contains($origin)) { Write-JsonResponse $stream 403 'Forbidden' @{ error = 'origin_required' }; continue }
                $requestedMethod = [string]$headers['Access-Control-Request-Method']
                if ($requestedMethod -cne 'GET' -and ($requestedMethod -cne 'POST' -or $request.path -cne '/dashboard')) { Write-JsonResponse $stream 403 'Forbidden' @{ error = 'method_not_allowed' } $origin; continue }
                $allowedHeaders = @('content-type', 'x-edge-request')
                $invalidHeader = $false
                if ($headers.ContainsKey('Access-Control-Request-Headers')) {
                    foreach ($name in $headers['Access-Control-Request-Headers'].Split(',')) { if ($name.Trim().ToLowerInvariant() -notin $allowedHeaders) { $invalidHeader = $true } }
                }
                if ($invalidHeader) { Write-JsonResponse $stream 403 'Forbidden' @{ error = 'header_not_allowed' } $origin; continue }
                Write-HttpResponse $stream 204 'No Content' ([byte[]]@()) 'application/json; charset=utf-8' $origin $true
                continue
            }
            if ($request.method -ceq 'POST' -and $request.path -ceq '/dashboard') {
                if (-not $AllowedOrigins.Contains($origin) -or $headers['X-Edge-Request'] -cne '1') { Write-JsonResponse $stream 403 'Forbidden' @{ error = 'mutation_origin_or_header_required' } $origin; continue }
                if ([string]$headers['Content-Type'] -inotmatch '^application/json(?:\s*;\s*charset\s*=\s*utf-8)?\s*$') { Write-JsonResponse $stream 415 'Unsupported Media Type' @{ error = 'json_required' } $origin; continue }
                try { $body = ConvertFrom-Json -InputObject ($Utf8.GetString($request.bytes)) -ErrorAction Stop } catch { Invalid-Data 'invalid_json_or_utf8' }
                $operations = Valid-Batch $body
                $result = Apply-Batch $operations
                Broadcast-Dashboard
                Write-JsonResponse $stream 200 'OK' $result $origin
                continue
            }
            if ($request.method -cne 'GET') { Write-JsonResponse $stream 405 'Method Not Allowed' @{ error = 'method_not_allowed' } $origin; continue }
            switch -CaseSensitive ($request.path) {
                '/dashboard/events' {
                    Prune-DashboardSubscribers
                    if ($script:DashboardSubscribers.Count -ge 16) {
                        Write-JsonResponse $stream 503 'Service Unavailable' @{ error = 'event_stream_limit' } $origin
                    } else {
                        $client.NoDelay = $true
                        $stream.WriteTimeout = 100
                        $eventStreamStarted = $true
                        Write-EventStreamHeaders $stream $origin
                        Write-EventStreamChunk $stream (Dashboard-EventBytes)
                        $script:DashboardSubscribers.Add(@{ client = $client; stream = $stream })
                        $persistent = $true
                    }
                }
                '/dashboard' { Write-JsonResponse $stream 200 'OK' (Public-State $script:DashboardState) $origin }
                '/now-playing' { Write-JsonResponse $stream 200 'OK' (Get-NowPlaying) $origin }
                '/media-art' {
                    $media = Get-NowPlaying
                    $artPath = Join-Path $DataDirectory 'media-art.bin'
                    if (-not $media.available -or $media.stale -or $media.artworkBytes -le 0 -or -not [IO.File]::Exists($artPath)) {
                        Write-JsonResponse $stream 404 'Not Found' @{ error = 'artwork_unavailable' } $origin
                    } else {
                        try {
                            $art = Read-BoundedLocalFile $artPath 2097152
                            $mime = Artwork-Mime $art
                            if ($mime -ceq '' -or $mime -cne $media.artworkMime -or $art.Length -ne $media.artworkBytes) { Invalid-Data 'invalid_media_artwork' }
                            Write-HttpResponse $stream 200 'OK' $art $mime $origin
                        } catch { Write-JsonResponse $stream 404 'Not Found' @{ error = 'artwork_unavailable' } $origin }
                    }
                }
                default {
                    $name = if ($request.path -ceq '/game.html') { 'game.html' } else { 'index.html' }
                    $path = Join-Path $PSScriptRoot $name
                    if (-not [IO.File]::Exists($path)) { Write-JsonResponse $stream 404 'Not Found' @{ error = 'page_not_found' } $origin }
                    else { Write-HttpResponse $stream 200 'OK' ([IO.File]::ReadAllBytes($path)) 'text/html; charset=utf-8' $origin }
                }
            }
        } catch {
            if ($null -ne $stream -and -not $eventStreamStarted) {
                try {
                    if ($_.Exception -is [ArgumentException]) { Write-JsonResponse $stream 400 'Bad Request' @{ error = $_.Exception.Message } $origin }
                    elseif (Is-RequestTimeout $_.Exception) { Write-JsonResponse $stream 408 'Request Timeout' @{ error = 'request_timeout' } $origin }
                    else { Write-JsonResponse $stream 500 'Internal Server Error' @{ error = 'request_failed'; message = 'Reload /dashboard to check the current saved state.' } $origin }
                } catch {}
            }
        } finally {
            if (-not $persistent) {
                if ($null -ne $stream) { $stream.Dispose() }
                $client.Close()
            }
        }
    }
} finally {
    for ($i = $script:DashboardSubscribers.Count - 1; $i -ge 0; $i--) { Remove-DashboardSubscriber $i }
    if ($null -ne $script:WeatherCancellation) { $script:WeatherCancellation.Cancel(); $script:WeatherCancellation.Dispose() }
    if ($null -ne $script:WeatherHttpClient) { $script:WeatherHttpClient.Dispose() }
    $listener.Stop()
}
