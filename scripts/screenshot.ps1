<#
.SYNOPSIS
    Saves a screenshot of what the Roku is showing (Developer Mode only).

.DESCRIPTION
    Uses the Roku's developer page (plugin_inspect) with the same IP and
    password resolution as deploy.ps1: -RokuIp/-Password, then
    $env:ROKU_IP/$env:ROKU_DEV_PASSWORD, then scripts\deploy.local.ps1.
    The sideloaded app must be running.

.EXAMPLE
    .\scripts\screenshot.ps1
    .\scripts\screenshot.ps1 -OutFile out\home.jpg
#>
[CmdletBinding()]
param(
    [string]$RokuIp = $env:ROKU_IP,
    [string]$Password = $env:ROKU_DEV_PASSWORD,
    [string]$User = 'rokudev',
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$localConfig = Join-Path $PSScriptRoot 'deploy.local.ps1'
if (Test-Path $localConfig) {
    . $localConfig
    if (-not $RokuIp) { $RokuIp = $LocalRokuIp }
    if (-not $Password) { $Password = $LocalRokuPassword }
}
if (-not $RokuIp -or -not $Password) { throw 'Roku IP or developer password not set (see deploy.ps1).' }
if (-not $OutFile) { $OutFile = Join-Path $root ('out\screenshot-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.jpg') }
New-Item -ItemType Directory -Force (Split-Path -Parent $OutFile) | Out-Null

# Credentials go to curl on stdin so the password isn't on the command line.
$escaped = $Password.Replace('\', '\\').Replace('"', '\"')
$curlConfig = "user = `"${User}:$escaped`""

$page = $curlConfig | & curl.exe --config - --silent --show-error --digest `
    --form 'mysubmit=Screenshot' --form 'archive=' --form 'passwd=' "http://$RokuIp/plugin_inspect"
if ($LASTEXITCODE -ne 0) { throw "Couldn't reach the Roku (curl exit code $LASTEXITCODE)." }
$link = [regex]::Match(($page -join "`n"), 'pkgs/dev\.(jpg|png)\?time=\d+')
if (-not $link.Success) { throw 'No screenshot returned. Is the sideloaded app running?' }

$curlConfig | & curl.exe --config - --silent --show-error --digest --output $OutFile "http://$RokuIp/$($link.Value)"
if ($LASTEXITCODE -ne 0) { throw "Couldn't download the screenshot (curl exit code $LASTEXITCODE)." }
Write-Host "Saved $OutFile"
