<#
Installs or updates the Dolby converter (pi\dolby-converter) on the home
Raspberry Pi: copies the folder over SSH and runs its install.sh, which
installs ffmpeg if needed and (re)starts the dolby-converter service.

    .\scripts\pi-deploy.ps1
    .\scripts\pi-deploy.ps1 -PiHost iptv-pi

-PiHost is an SSH host: a Host entry in ~\.ssh\config with a key the Pi
accepts (no password prompts), or user@address. Default: $LocalPi from
scripts\deploy.local.ps1, else "iptv-pi". The account needs sudo.
#>
param([string]$PiHost)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$localConfig = Join-Path $PSScriptRoot 'deploy.local.ps1'
if (Test-Path $localConfig) { . $localConfig }
if (-not $PiHost) { $PiHost = $LocalPi }
if (-not $PiHost) { $PiHost = 'iptv-pi' }

$source = Join-Path $root 'pi\dolby-converter'
Write-Host "Copying the converter to $PiHost ..."
& ssh -o BatchMode=yes $PiHost 'rm -rf ~/dolby-converter && mkdir -p ~/dolby-converter'
if ($LASTEXITCODE -ne 0) { throw "Couldn't reach $PiHost over SSH (key login needed; see the comment at the top of this script)." }
& scp -q -o BatchMode=yes (Join-Path $source '*') "${PiHost}:dolby-converter/"
if ($LASTEXITCODE -ne 0) { throw 'Copying failed.' }

Write-Host 'Installing ...'
& ssh -o BatchMode=yes $PiHost 'sudo sh ~/dolby-converter/install.sh'
if ($LASTEXITCODE -ne 0) { throw 'The install script failed (see above).' }

# The health page, from here: proves the service is up and reachable on the LAN.
$address = (& ssh -G $PiHost | Select-String '^hostname ' | ForEach-Object { ($_ -split ' ')[1] } | Select-Object -First 1)
try {
    $health = Invoke-RestMethod -Uri "http://${address}:8790/health" -TimeoutSec 5
    Write-Host "Converter is up at http://${address}:8790 (version $($health.version))."
}
catch {
    Write-Warning "Installed, but http://${address}:8790/health didn't answer from this PC: $($_.Exception.Message)"
}
