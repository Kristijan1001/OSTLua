# ostlua_install.ps1 — download a lua/manifest package from one or more sources
# and install it.
#   .lua       -> <Steam>\config\<lua_dir_name>\
#   .manifest  -> <Steam>\depotcache\
# Tries each source in -SourcesFile order (main first, then fallbacks) until one
# yields a usable .lua. Each source may return a ZIP or a raw .lua.
#
# Args: -AppId <id> -SteamPath <path> -PluginDir <path> -ResultFile <path> [-SourcesFile <path>]

param(
    [Parameter(Mandatory=$true)][string]$AppId,
    [Parameter(Mandatory=$true)][string]$SteamPath,
    [Parameter(Mandatory=$true)][string]$PluginDir,
    [Parameter(Mandatory=$true)][string]$ResultFile,
    [string]$SourcesFile = ""
)

$ErrorActionPreference = "Stop"
$result = [ordered]@{ success = $false; appid = $AppId; error = $null; lua = $null; manifests = @(); source = $null; tried = @() }
Add-Type -AssemblyName System.IO.Compression.FileSystem

try {
    $cfgPath = Join-Path $PluginDir "backend\config.json"
    if (Test-Path $cfgPath) {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    } else {
        $cfg = [pscustomobject]@{ api_key = ""; api_base = "https://hubcapmanifest.com/api/v1"; lua_dir_name = "lua" }
    }
    if (-not $cfg.lua_dir_name) { $cfg | Add-Member -NotePropertyName lua_dir_name -NotePropertyValue "lua" -Force }
    if (-not $cfg.api_base)     { $cfg | Add-Member -NotePropertyName api_base -NotePropertyValue "https://hubcapmanifest.com/api/v1" -Force }
    $apiKey  = $cfg.api_key
    $luaDir  = Join-Path $SteamPath ("config\" + $cfg.lua_dir_name)
    $depotCache = Join-Path $SteamPath "depotcache"
    New-Item -ItemType Directory -Force -Path $luaDir     | Out-Null
    New-Item -ItemType Directory -Force -Path $depotCache | Out-Null

    # Source order: from -SourcesFile, else default to Hubcap.
    # NOTE: no @() around ConvertFrom-Json — in PS 5.1 that wraps the whole array
    # into a single element, so the foreach would iterate once over all of them.
    $sources = $null
    if ($SourcesFile -and (Test-Path $SourcesFile)) {
        $sources = Get-Content $SourcesFile -Raw | ConvertFrom-Json
    }
    if (-not $sources) {
        $sources = [pscustomobject]@{ name = "Hubcap"; url = ("" + $cfg.api_base + "/manifest/" + $AppId); auth = $true }
    }

    $tmp = Join-Path $env:TEMP ("ostlua_" + $AppId + ".dl")
    $ext = Join-Path $env:TEMP ("ostlua_" + $AppId + "_x")
    $lastErr = "no sources"

    foreach ($src in $sources) {
        $result.tried += $src.name
        try {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            if (Test-Path $ext) { Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue }

            $headers = @{}
            if ($src.auth) { $headers["Authorization"] = "Bearer $apiKey" }
            Invoke-WebRequest -Uri $src.url -Headers $headers -OutFile $tmp -UseBasicParsing `
                -UserAgent "OSTLua/1.0" -TimeoutSec 20

            # ZIP (starts with "PK") vs raw .lua text.
            $bytes = [System.IO.File]::ReadAllBytes($tmp)
            $isZip = ($bytes.Length -ge 2 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)

            if ($isZip) {
                # ExtractToDirectory works on any filename (Expand-Archive requires a .zip extension).
                [System.IO.Compression.ZipFile]::ExtractToDirectory($tmp, $ext)
                $luaFile = Get-ChildItem $ext -Recurse -Filter *.lua | Select-Object -First 1
                if (-not $luaFile) { throw "archive contained no .lua" }
                Get-ChildItem $ext -Recurse -Filter *.lua | ForEach-Object {
                    $dest = Join-Path $luaDir $_.Name
                    # Comment out setManifestid on install so a fresh game defaults to
                    # latest / updatable — freezing is an explicit choice in the UI.
                    $luaText = [System.IO.File]::ReadAllText($_.FullName)
                    $luaText = [regex]::Replace($luaText, '(?im)^(\s*)(setManifestid\s*\()', '$1-- $2')
                    [System.IO.File]::WriteAllText($dest, $luaText, (New-Object System.Text.UTF8Encoding $false))
                    $result.lua = $dest
                }
                Get-ChildItem $ext -Recurse -Filter *.manifest | ForEach-Object {
                    $dest = Join-Path $depotCache $_.Name; Copy-Item $_.FullName $dest -Force; $result.manifests += $_.Name
                }
            } else {
                $text = [System.Text.Encoding]::UTF8.GetString($bytes)
                if ($text -notmatch "(?i)addappid") { throw "response was neither a zip nor a lua" }
                $dest = Join-Path $luaDir ($AppId + ".lua")
                $text = [regex]::Replace($text, '(?im)^(\s*)(setManifestid\s*\()', '$1-- $2')
                [System.IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding $false))
                $result.lua = $dest
            }

            $result.source  = $src.name
            $result.success = $true
            break
        }
        catch {
            $lastErr = "" + $src.name + ": " + $_.Exception.Message
        }
    }

    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue

    if (-not $result.success) { throw $lastErr }
}
catch {
    $result.error = $_.Exception.Message
}

[System.IO.File]::WriteAllText($ResultFile, ($result | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
