# Open the lua.tools Discord authorization page and receive its loopback callback.
param(
    [Parameter(Mandatory=$true)][string]$Launcher,
    [Parameter(Mandatory=$true)][string]$ResultFile
)

$ErrorActionPreference = "Stop"
$port = 53789
$redirect = "http://localhost:${port}/callback"
$listener = $null
$result = @{ error = "Could not start Discord sign-in. Try again or use a Discord code." }

function ConvertTo-Base64Url([byte[]]$bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Read-CallbackRequest($stream) {
    $buffer = New-Object byte[] 8192
    $offset = 0
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($offset -lt $buffer.Length) {
        $remaining = 2000 - [int]$deadline.ElapsedMilliseconds
        if ($remaining -le 0) { return }
        $read = $stream.ReadAsync($buffer, $offset, $buffer.Length - $offset)
        if (-not $read.Wait($remaining) -or $read.Result -eq 0) { return }
        $offset += $read.Result
        $request = [Text.Encoding]::ASCII.GetString($buffer, 0, $offset)
        if ($request.Contains("`r`n`r`n")) { return $request }
    }
}

function Send-CallbackResponse($stream, [string]$status, [string]$message) {
    $body = "<!doctype html><meta charset=utf-8><title>OSTLua</title><p>$message</p>"
    $response = "HTTP/1.1 $status`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n$body"
    $bytes = [Text.Encoding]::ASCII.GetBytes($response)
    $stream.WriteTimeout = 1000
    $stream.Write($bytes, 0, $bytes.Length)
}

try {
    if (-not (Test-Path -LiteralPath $Launcher)) { return }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
    $listener.ExclusiveAddressUse = $true
    try { $listener.Start() }
    catch {
        $result.error = "Could not open the local sign-in port. Close any other lua.tools sign-in and try again."
        throw
    }

    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = New-Object byte[] 64
        $random.GetBytes($bytes)
        $verifier = ConvertTo-Base64Url $bytes
        $challenge = ConvertTo-Base64Url ($sha256.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
    } finally {
        $random.Dispose()
        $sha256.Dispose()
    }

    $authUrl = "https://db.lua.tools/auth/v1/authorize?provider=discord&redirect_to=" +
        [Uri]::EscapeDataString($redirect) + "&code_challenge=$challenge&code_challenge_method=s256"
    Start-Process -FilePath $authUrl
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $result.error = "Discord sign-in timed out. Try again or use a Discord code."

    while ($deadline.Elapsed.TotalMinutes -lt 5 -and (Test-Path -LiteralPath $Launcher)) {
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 150
            continue
        }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $request = Read-CallbackRequest $stream
            if ($request -notmatch '\AGET (/callback\?[^ ]*) HTTP/1\.[01]\r\n') {
                Send-CallbackResponse $stream "404 Not Found" "Return to Steam to continue."
                continue
            }
            $target = $Matches[1]
            $headers = $request.Substring(0, $request.IndexOf("`r`n`r`n"))
            if ($headers -notmatch "(?im)^Host:[ \t]*localhost:${port}[ \t]*\r?$") {
                Send-CallbackResponse $stream "400 Bad Request" "Return to Steam to continue."
                continue
            }

            $query = [Uri]::new("http://localhost:${port}$target").Query
            if ($query -match '[?&]code=([A-Za-z0-9_-]+)(?:&|$)') {
                $result = @{ code = $Matches[1]; verifier = $verifier }
                Send-CallbackResponse $stream "200 OK" "Return to Steam to finish signing in to lua.tools."
                break
            }
            if ($query -match '[?&]error(?:_code|_description)?=') {
                $result.error = "Discord sign-in was declined or could not be completed."
                Send-CallbackResponse $stream "200 OK" "Discord sign-in did not complete. Return to Steam to try again."
                break
            }
            Send-CallbackResponse $stream "400 Bad Request" "This request did not contain a sign-in result."
        } catch {
            if ($result.code) { break }
        } finally {
            $client.Dispose()
        }
    }
} finally {
    if ($listener) { $listener.Stop() }
    if (Test-Path -LiteralPath $Launcher) {
        $temp = "$ResultFile.tmp"
        try {
            [IO.File]::WriteAllText($temp, ($result | ConvertTo-Json -Compress))
            [IO.File]::Move($temp, $ResultFile)
            if (-not (Test-Path -LiteralPath $Launcher)) {
                Remove-Item -LiteralPath $ResultFile -ErrorAction SilentlyContinue
            }
        } finally {
            Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
        }
    }
}
