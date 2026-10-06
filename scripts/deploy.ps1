<#
.SYNOPSIS
    Zips the app and sideloads it to a Roku in Developer Mode.

.DESCRIPTION
    Builds out\iptv-player.zip from manifest, source\, components\, data\ and images\
    (zip entries use forward slashes, which Roku requires), then uploads it to
    the Roku's developer installer at http://<ip>/plugin_install with digest
    auth via curl.exe.

    Before packaging, the code is checked with the BrighterScript compiler
    (via npx; needs Node.js). Any error stops the script. -SkipCheck skips it.

    With -Console, the script connects to the Roku debug console (port 8085)
    before installing, so nothing printed at launch is missed, and streams it
    until Ctrl+C.

    The Roku IP and developer password come from, in order: -RokuIp/-Password,
    $env:ROKU_IP/$env:ROKU_DEV_PASSWORD, then scripts\deploy.local.ps1 if it
    exists (copy deploy.local.example.ps1; it is git-ignored).

    With -All, the package is built once and installed on every Roku listed in
    $LocalRokus in deploy.local.ps1, continuing past any that fail, with a
    summary at the end (exit code 1 if any failed).

.EXAMPLE
    .\scripts\deploy.ps1 -Console

.EXAMPLE
    .\scripts\deploy.ps1 -All

.EXAMPLE
    $env:ROKU_IP = '192.168.1.50'; $env:ROKU_DEV_PASSWORD = '...'
    .\scripts\deploy.ps1 -Console

.EXAMPLE
    .\scripts\deploy.ps1 -PackageOnly
#>
[CmdletBinding()]
param(
    [string]$RokuIp = $env:ROKU_IP,
    [string]$Password = $env:ROKU_DEV_PASSWORD,
    [string]$User = 'rokudev',
    [switch]$PackageOnly,
    [switch]$SkipCheck,
    [switch]$Console,
    [switch]$All
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
$zipPath = Join-Path $outDir 'iptv-player.zip'
$include = @('manifest', 'source', 'components', 'data', 'images')

if (-not (Test-Path (Join-Path $root 'manifest'))) { throw "No manifest found in $root" }

# Local settings (Roku list, passwords): needed for the restore bundle below.
$localConfig = Join-Path $PSScriptRoot 'deploy.local.ps1'
if (Test-Path $localConfig) { . $localConfig }

# --- Check -------------------------------------------------------------------

if (-not $SkipCheck) {
    # A shell opened before Node was installed won't have it on PATH, and
    # npx.cmd itself needs node on PATH, so add it for this process.
    if (-not (Get-Command node -ErrorAction SilentlyContinue) -and (Test-Path "$env:ProgramFiles\nodejs\node.exe")) {
        $env:Path = "$env:ProgramFiles\nodejs;$env:Path"
    }
    $npx = (Get-Command npx.cmd -ErrorAction SilentlyContinue).Source
    if (-not $npx) { throw 'npx not found; install Node.js LTS (winget install OpenJS.NodeJS.LTS) or pass -SkipCheck.' }

    Write-Host 'Checking code with BrighterScript ...'
    Push-Location $root
    try {
        # Pinned to v0: v1 changes the CLI and diagnostics.
        & $npx --yes brighterscript@0 --rootDir . --files manifest 'source/**/*' 'components/**/*' `
            --createPackage false --copyToStaging false --logLevel error
        $checkExit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($checkExit -ne 0) { throw 'Code check failed; nothing was packaged or uploaded. Fix the errors above.' }

    # Rules the Roku's compiler enforces but BrighterScript doesn't. A build the
    # Roku won't compile is worse than a failed check: the failed install
    # removes the existing dev app, and its saved data (registry) with it.
    # Learned Oct 6, 2026, when that wiped the Basement Roku.
    #   - A statement can't start with a call result: catalogState(k).x.Delete(id)
    $rokuOnly = @()
    foreach ($file in Get-ChildItem (Join-Path $root 'components'), (Join-Path $root 'source') -Recurse -Filter *.brs) {
        $n = 0
        foreach ($line in Get-Content $file.FullName) {
            $n++
            if ($line -match '^\s*[A-Za-z_][A-Za-z0-9_]*\([^()]*\)\.[A-Za-z_]') {
                $rokuOnly += "$($file.FullName.Substring($root.Length + 1)):${n}: statement starts with a call result: $($line.Trim())"
            }
        }
    }
    if ($rokuOnly) {
        $rokuOnly | ForEach-Object { Write-Host $_ }
        throw 'The Roku would refuse to compile this (see above); nothing was uploaded. Assign the call to a variable first.'
    }
    Write-Host 'Code check passed.'
}

# --- Package -----------------------------------------------------------------

New-Item -ItemType Directory -Force $outDir | Out-Null
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# Restore bundle (data/restore.json in the package): each Roku's latest backup
# from backups\ (scripts\backup-roku.ps1), matched by the IPs in $LocalRokus,
# plus backups\household.json for any Roku without one. A Roku with no saved
# state at launch restores from it; one that has state ignores it. Contains
# the provider password, like the backups themselves; out\ and backups\ are
# git-ignored.
function Get-RestoreBundle {
    $backupDir = Join-Path $root 'backups'
    if (-not (Test-Path $backupDir)) { return $null }
    # Backups are embedded as their own text, not re-parsed: a Roku document
    # can hold one key in two casings, which ConvertFrom-Json rejects.
    function Read-Backup([string]$path) {
        $text = (Get-Content $path -Raw).Trim()
        if (-not ($text.StartsWith('{') -and $text.EndsWith('}'))) { throw "$path doesn't look like a backup." }
        return $text
    }
    $devices = @()
    $withDocs = 0
    foreach ($roku in @($LocalRokus)) {
        if (-not $roku) { continue }
        $entry = '{"ip":' + ($roku.Ip | ConvertTo-Json) + ',"name":' + ($roku.Name | ConvertTo-Json)
        $file = Join-Path $backupDir "$($roku.Name).json"
        if (Test-Path $file) { $entry += ',"document":' + (Read-Backup $file); $withDocs++ }
        $devices += $entry + '}'
    }
    $bundle = '{"devices":[' + ($devices -join ',') + ']'
    $household = Join-Path $backupDir 'household.json'
    $hasHousehold = Test-Path $household
    if ($hasHousehold) { $bundle += ',"household":' + (Read-Backup $household) }
    $bundle += '}'
    if ($withDocs -eq 0 -and -not $hasHousehold) { return $null }
    Write-Host "Restore bundle: $withDocs Roku backup(s)$(if ($hasHousehold) { ' + household' })"
    return $bundle
}

$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    $restoreJson = Get-RestoreBundle
    if ($restoreJson) {
        $entry = $zip.CreateEntry('data/restore.json', 'Optimal')
        $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
        try { $writer.Write($restoreJson) } finally { $writer.Dispose() }
    }
    foreach ($name in $include) {
        $path = Join-Path $root $name
        if (-not (Test-Path $path)) { continue }
        $files = if ((Get-Item $path).PSIsContainer) { Get-ChildItem $path -Recurse -File } else { Get-Item $path }
        foreach ($file in $files) {
            $entry = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entry, 'Optimal') | Out-Null
        }
    }
}
finally {
    $zip.Dispose()
}
Write-Host "Packaged $zipPath ($([math]::Round((Get-Item $zipPath).Length / 1KB, 1)) KB)"

if ($PackageOnly) { return }

# --- Sideload ----------------------------------------------------------------

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe not found (it ships with Windows 10 and later).' }

# Uploads the package to one Roku's developer installer. Returns 'installed'
# or 'identical' (already has this exact build); throws on failure.
function Install-Roku([string]$Ip, [string]$DevPassword) {
    # Credentials go to curl on stdin so the password isn't on the command line.
    $escaped = $DevPassword.Replace('\', '\\').Replace('"', '\"')
    $curlConfig = "user = `"${User}:$escaped`""
    $output = $curlConfig | & curl.exe --config - --silent --show-error --digest `
        --connect-timeout 10 --max-time 120 --write-out "`n%{http_code}" `
        --form 'mysubmit=Install' --form "archive=@$zipPath" `
        "http://$Ip/plugin_install"
    if ($LASTEXITCODE -ne 0) { throw "Upload failed (curl exit code $LASTEXITCODE). Is the Roku on and in Developer Mode?" }

    $lines = @($output)
    $status = $lines[-1].Trim()
    $body = ($lines | Select-Object -SkipLast 1) -join "`n"
    if ($status -eq '401') { throw 'The Roku rejected the developer password (HTTP 401).' }

    # The installer page reports results as on-page messages (also on errors,
    # so they're shown before giving up).
    $messages = [regex]::Matches($body, "'Set message content', '([^']*)'") | ForEach-Object { $_.Groups[1].Value }
    if (-not $messages) { $messages = [regex]::Matches($body, '<font color="red">([^<]*)</font>') | ForEach-Object { $_.Groups[1].Value } }
    $messages | Where-Object { $_ } | ForEach-Object { Write-Host "  Roku: $_" }
    if ($status -ne '200') { throw "The Roku installer answered HTTP $status." }

    if ($body -match 'Install Failure') { throw 'Install failed. Run with -Console (or telnet to port 8085) to see compiler errors.' }
    if ($body -match 'Identical to previous version') { return 'identical' }
    return 'installed'
}


# --- Every Roku in deploy.local.ps1 ($LocalRokus) ---------------------------

if ($All) {
    if ($Console) { throw '-Console works with one Roku; leave it off with -All.' }
    if (-not $LocalRokus) { throw 'No Rokus listed. Add $LocalRokus to scripts\deploy.local.ps1 (see deploy.local.example.ps1).' }
    $results = @()
    foreach ($roku in $LocalRokus) {
        $name = if ($roku.Name) { $roku.Name } else { $roku.Ip }
        $devPassword = if ($roku.Password) { $roku.Password } elseif ($Password) { $Password } else { $LocalRokuPassword }
        Write-Host "Installing on $name ($($roku.Ip)) ..."
        try {
            if (-not $devPassword) { throw 'No developer password (set Password for it or $LocalRokuPassword).' }
            $outcome = Install-Roku $roku.Ip $devPassword
            $text = if ($outcome -eq 'identical') { 'already up to date' } else { 'installed' }
            $results += [pscustomobject]@{ Roku = $name; IP = $roku.Ip; Result = $text }
        }
        catch {
            Write-Warning "  $name failed: $($_.Exception.Message)"
            $results += [pscustomobject]@{ Roku = $name; IP = $roku.Ip; Result = "FAILED: $($_.Exception.Message)" }
        }
    }
    Write-Host ''
    $results | Format-Table -AutoSize | Out-String | Write-Host
    if ($results | Where-Object { $_.Result -like 'FAILED*' }) { exit 1 }
    return
}

# --- One Roku ----------------------------------------------------------------

if (-not $RokuIp) { $RokuIp = $LocalRokuIp }
if (-not $Password) { $Password = $LocalRokuPassword }
if (-not $RokuIp) { throw 'Roku IP not set. Pass -RokuIp, set $env:ROKU_IP, or put it in scripts\deploy.local.ps1.' }
if (-not $Password) { throw 'Developer password not set. Pass -Password, set $env:ROKU_DEV_PASSWORD, or put it in scripts\deploy.local.ps1.' }

$consoleClient = $null
if ($Console) {
    try {
        $consoleClient = [System.Net.Sockets.TcpClient]::new($RokuIp, 8085)
    }
    catch {
        Write-Warning "Could not connect to the debug console on ${RokuIp}:8085: $($_.Exception.Message)"
    }
}

try {
    Write-Host "Installing on $RokuIp ..."
    $outcome = Install-Roku $RokuIp $Password
    if ($outcome -eq 'identical') {
        Write-Host 'The Roku already has this exact build; it was not reinstalled.'
    }
    else {
        Write-Host 'Installed.'
    }

    if ($consoleClient) {
        Write-Host "--- debug console ${RokuIp}:8085 (Ctrl+C to stop) ---"
        $stream = $consoleClient.GetStream()
        $buffer = New-Object byte[] 8192
        while ($consoleClient.Connected) {
            if ($stream.DataAvailable) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                [Console]::Write([System.Text.Encoding]::UTF8.GetString($buffer, 0, $read))
            }
            else {
                Start-Sleep -Milliseconds 100
            }
        }
    }
}
finally {
    if ($consoleClient) { $consoleClient.Dispose() }
}
