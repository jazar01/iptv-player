<#
Installs or updates the services on the home Raspberry Pi: the Dolby
converter (pi\dolby-converter) and the backup service (pi\backup-service).
Copies each folder over SSH and runs its install.sh.

    .\scripts\pi-deploy.ps1                     both
    .\scripts\pi-deploy.ps1 -Service converter
    .\scripts\pi-deploy.ps1 -Service backup

-PiHost is an SSH host: a Host entry in ~\.ssh\config with a key the Pi
accepts (no password prompts), or user@address. Default: $LocalPi from
scripts\deploy.local.ps1, else "iptv-pi". The account needs sudo.

The backup service needs the household key, $BackupKey in deploy.local.ps1
(64 hex characters; the same key goes into the app at deploy). It's sent
to /etc/iptv-backup/key over SSH's input, never on a command line.
#>
param(
    [string]$PiHost,
    [ValidateSet('all', 'converter', 'backup')][string]$Service = 'all'
)

# Not 'Stop': Windows PowerShell 5.1 turns any line a native program writes to
# stderr (ssh's notices) into a fatal error. Exit codes are checked instead.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$localConfig = Join-Path $PSScriptRoot 'deploy.local.ps1'
if (Test-Path $localConfig) { . $localConfig }
if (-not $PiHost) { $PiHost = $LocalPi }
if (-not $PiHost) { $PiHost = 'iptv-pi' }

& ssh -T -o BatchMode=yes $PiHost 'true'
if ($LASTEXITCODE -ne 0) { throw "Couldn't reach $PiHost over SSH (key login needed; see the comment at the top of this script)." }
$address = (& ssh -G $PiHost 2>$null | Select-String '^hostname ' | ForEach-Object { ($_ -split ' ')[1] } | Select-Object -First 1)

function Install-Folder([string]$folder, [string]$remote) {
    Write-Host "Copying $folder to $PiHost ..."
    & ssh -T -o BatchMode=yes $PiHost "rm -rf ~/$remote && mkdir -p ~/$remote"
    & scp -q -o BatchMode=yes (Join-Path $root "pi\$folder\*") "${PiHost}:$remote/"
    if ($LASTEXITCODE -ne 0) { throw "Copying $folder failed." }
    Write-Host 'Installing ...'
    & ssh -T -o BatchMode=yes $PiHost "sudo sh ~/$remote/install.sh"
    if ($LASTEXITCODE -ne 0) { throw "The $folder install script failed (see above)." }
}

function Test-Health([string]$what, [int]$port) {
    try {
        $health = Invoke-RestMethod -Uri "http://${address}:$port/health" -TimeoutSec 5
        Write-Host "$what is up at http://${address}:$port (version $($health.version))."
    }
    catch {
        Write-Warning "$what installed, but http://${address}:$port/health didn't answer from this PC: $($_.Exception.Message)"
    }
}

if ($Service -eq 'all' -or $Service -eq 'converter') {
    Install-Folder 'dolby-converter' 'dolby-converter'
    Test-Health 'Dolby converter' 8790
}

if ($Service -eq 'all' -or $Service -eq 'backup') {
    if (-not ($BackupKey -match '^[0-9a-fA-F]{64}$')) { throw 'Set $BackupKey (64 hex characters) in scripts\deploy.local.ps1 first.' }
    # No quotes in the remote command: Windows PowerShell 5.1 mangles them.
    $BackupKey | & ssh -T -o BatchMode=yes $PiHost 'sudo install -d -m 0750 /etc/iptv-backup && tr -cd 0-9a-fA-F | sudo tee /etc/iptv-backup/key >/dev/null'
    if ($LASTEXITCODE -ne 0) { throw "Couldn't write the household key on $PiHost." }
    Install-Folder 'backup-service' 'iptv-backup'
    Test-Health 'Backup service' 8792
}
