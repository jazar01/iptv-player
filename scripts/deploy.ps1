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

.EXAMPLE
    .\scripts\deploy.ps1 -Console

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
    [switch]$Console
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'out'
$zipPath = Join-Path $outDir 'iptv-player.zip'
$include = @('manifest', 'source', 'components', 'data', 'images')

if (-not (Test-Path (Join-Path $root 'manifest'))) { throw "No manifest found in $root" }

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
    Write-Host 'Code check passed.'
}

# --- Package -----------------------------------------------------------------

New-Item -ItemType Directory -Force $outDir | Out-Null
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
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

$localConfig = Join-Path $PSScriptRoot 'deploy.local.ps1'
if (Test-Path $localConfig) {
    . $localConfig
    if (-not $RokuIp) { $RokuIp = $LocalRokuIp }
    if (-not $Password) { $Password = $LocalRokuPassword }
}
if (-not $RokuIp) { throw 'Roku IP not set. Pass -RokuIp, set $env:ROKU_IP, or put it in scripts\deploy.local.ps1.' }
if (-not $Password) { throw 'Developer password not set. Pass -Password, set $env:ROKU_DEV_PASSWORD, or put it in scripts\deploy.local.ps1.' }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe not found (it ships with Windows 10 and later).' }

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
    # Credentials go to curl on stdin so the password isn't on the command line.
    $escaped = $Password.Replace('\', '\\').Replace('"', '\"')
    $curlConfig = "user = `"${User}:$escaped`""
    Write-Host "Installing on $RokuIp ..."
    $output = $curlConfig | & curl.exe --config - --silent --show-error --digest `
        --max-time 120 --write-out "`n%{http_code}" `
        --form 'mysubmit=Install' --form "archive=@$zipPath" `
        "http://$RokuIp/plugin_install"
    if ($LASTEXITCODE -ne 0) { throw "Upload failed (curl exit code $LASTEXITCODE). Is the Roku on and in Developer Mode?" }

    $lines = @($output)
    $status = $lines[-1].Trim()
    $body = ($lines | Select-Object -SkipLast 1) -join "`n"
    if ($status -eq '401') { throw 'The Roku rejected the developer password (HTTP 401).' }
    if ($status -ne '200') { throw "The Roku installer answered HTTP $status." }

    # The installer page reports results as on-page messages.
    $messages = [regex]::Matches($body, "'Set message content', '([^']*)'") | ForEach-Object { $_.Groups[1].Value }
    if (-not $messages) { $messages = [regex]::Matches($body, '<font color="red">([^<]*)</font>') | ForEach-Object { $_.Groups[1].Value } }
    $messages | Where-Object { $_ } | ForEach-Object { Write-Host "  Roku: $_" }

    if ($body -match 'Install Failure') {
        throw 'Install failed. Run with -Console (or telnet to port 8085) to see compiler errors.'
    }
    if ($body -match 'Identical to previous version') {
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
