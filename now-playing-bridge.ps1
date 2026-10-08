param([string]$DataDirectory = (Join-Path $PSScriptRoot 'data'))

$ErrorActionPreference = 'Stop'
$Port = 47831
$MaxBodyBytes = 131072
$MaxHeaderBytes = 16384
$MaxRecords = 1000
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
function Get-NowPlaying {
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
function Valid-State($Value) {
    Require-Object $Value
    $schema = Property-Value $Value 'schema'
    if (($schema -isnot [int] -and $schema -isnot [long]) -or $schema -ne 1) { Invalid-Data 'invalid_schema' }
    $storeId = Valid-String (Property-Value $Value 'storeId') 80
    $uuid = [Guid]::Empty
    if (-not [Guid]::TryParse($storeId, [ref]$uuid) -or $uuid -eq [Guid]::Empty) { Invalid-Data 'invalid_store_id' }
    $revision = Property-Value $Value 'revision'
    if (($revision -isnot [int] -and $revision -isnot [long]) -or $revision -lt 0 -or $revision -ge [long]::MaxValue) { Invalid-Data 'invalid_revision' }
    $opIds = Property-Value $Value 'processedOpIds'
    if ($opIds -isnot [Array] -or $opIds.Count -gt 512) { Invalid-Data 'invalid_operation_history' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $history = [Collections.Generic.List[string]]::new()
    foreach ($id in $opIds) {
        $id = Valid-Id $id
        if (-not $seen.Add($id)) { Invalid-Data 'duplicate_operation_id' }
        $history.Add($id)
    }
    return @{ schema = 1; storeId = $storeId; revision = [long]$revision; tasks = (Valid-Records (Property-Value $Value 'tasks') 'task'); events = (Valid-Records (Property-Value $Value 'events') 'event'); processedOpIds = $history.ToArray() }
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
        $state = @{ schema = 1; storeId = [Guid]::NewGuid().ToString(); revision = [long]0; tasks = @(); events = @(); processedOpIds = @() }
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
function Public-State($State) { return @{ schema = 1; storeId = $State.storeId; revision = $State.revision; tasks = @($State.tasks); events = @($State.events) } }
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
    $next = @{ schema = 1; storeId = $script:DashboardState.storeId; revision = $script:DashboardState.revision; tasks = @(); events = @(); processedOpIds = @() }
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
function Is-RequestTimeout($Exception) {
    while ($null -ne $Exception) {
        if ($Exception -is [TimeoutException]) { return $true }
        if ($Exception -is [Net.Sockets.SocketException] -and $Exception.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) { return $true }
        $Exception = $Exception.InnerException
    }
    return $false
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$listener.Start()
try {
    # Only the process that owns the loopback listener may initialize the store.
    $script:DashboardState = Load-State
    Write-Output "Xenon Edge dashboard bridge: http://127.0.0.1:$Port (loopback only)"
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $null
        $origin = ''
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
            $knownPath = $request.path -cin @('/', '/index.html', '/game.html', '/dashboard', '/now-playing')
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
                Write-JsonResponse $stream 200 'OK' $result $origin
                continue
            }
            if ($request.method -cne 'GET') { Write-JsonResponse $stream 405 'Method Not Allowed' @{ error = 'method_not_allowed' } $origin; continue }
            switch -CaseSensitive ($request.path) {
                '/dashboard' { Write-JsonResponse $stream 200 'OK' (Public-State $script:DashboardState) $origin }
                '/now-playing' { Write-JsonResponse $stream 200 'OK' (Get-NowPlaying) $origin }
                default {
                    $name = if ($request.path -ceq '/game.html') { 'game.html' } else { 'index.html' }
                    $path = Join-Path $PSScriptRoot $name
                    if (-not [IO.File]::Exists($path)) { Write-JsonResponse $stream 404 'Not Found' @{ error = 'page_not_found' } $origin }
                    else { Write-HttpResponse $stream 200 'OK' ([IO.File]::ReadAllBytes($path)) 'text/html; charset=utf-8' $origin }
                }
            }
        } catch {
            if ($null -ne $stream) {
                try {
                    if ($_.Exception -is [ArgumentException]) { Write-JsonResponse $stream 400 'Bad Request' @{ error = $_.Exception.Message } $origin }
                    elseif (Is-RequestTimeout $_.Exception) { Write-JsonResponse $stream 408 'Request Timeout' @{ error = 'request_timeout' } $origin }
                    else { Write-JsonResponse $stream 500 'Internal Server Error' @{ error = 'request_failed'; message = 'Reload /dashboard to check the current saved state.' } $origin }
                } catch {}
            }
        } finally { if ($null -ne $stream) { $stream.Dispose() }; $client.Close() }
    }
} finally { $listener.Stop() }
