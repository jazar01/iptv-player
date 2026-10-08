<#
.SYNOPSIS
    Saves a Roku's IPTV Player state (account, favorites, teams, progress,
    settings) to backups\ on this PC.

.DESCRIPTION
    Connects to the Roku's debug console (port 8085) and waits for the app's
    backup, which it prints when, on the TV, you open Settings, press * (the
    backup panel) and then Play/Pause. The backup is saved as backups\<Name>.json (the latest, which
    deploy.ps1 bundles for restoring) and backups\<Name>-<date>.json (a dated
    copy).

    The Roku is named as in $LocalRokus in scripts\deploy.local.ps1, or given
    by -RokuIp (then -Name sets the file name).

    The backup includes the provider password. backups\ is git-ignored; keep
    it private. Nothing from the backup is printed here.

.EXAMPLE
    .\scripts\backup-roku.ps1 -Roku Basement

.EXAMPLE
    .\scripts\backup-roku.ps1 -RokuIp 192.168.1.50 -Name 'Living room'
#>
[CmdletBinding()]
param(
    [string]$Roku,
    [string]$RokuIp,
    [string]$Name,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $RokuIp) {
    $localConfig = Join-Path $PSScriptRoot 'deploy.local.ps1'
    if (Test-Path $localConfig) { . $localConfig }
    if (-not $Roku) { throw 'Pass -Roku <name from $LocalRokus> or -RokuIp <address>.' }
    $match = @($LocalRokus) | Where-Object { $_ -and $_.Name -eq $Roku } | Select-Object -First 1
    if (-not $match) { throw "No Roku named '$Roku' in `$LocalRokus (scripts\deploy.local.ps1)." }
    $RokuIp = $match.Ip
    $Name = $match.Name
}
if (-not $Name) { $Name = $RokuIp }

Write-Host "Listening to $Name ($RokuIp). On that TV open Settings, press * and then Play/Pause ..."
$client = New-Object System.Net.Sockets.TcpClient($RokuIp, 8085)
$stream = $client.GetStream()
$stream.ReadTimeout = 2000
$buffer = New-Object byte[] 65536
$text = ''
$closed = $false
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
# On connect the Roku replays its recent log, which can hold an earlier
# backup: what arrives in the first second is checked for a busy console,
# then dropped.
$replayEnds = (Get-Date).AddSeconds(1)
try {
    while ((Get-Date) -lt $deadline -and ($replayEnds -or $text -notmatch '\[backup\] END')) {
        try {
            $n = $stream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { $closed = $true; break }   # the Roku hung up
            $text += [Text.Encoding]::UTF8.GetString($buffer, 0, $n)
        }
        catch [System.IO.IOException] { }   # read timeout: keep waiting
        if ($text -match 'already in use') { break }
        if ($replayEnds -and (Get-Date) -ge $replayEnds) { $text = ''; $replayEnds = $null }
    }
}
finally {
    $client.Close()
}
# Only one console connection at a time: a deploy -Console, telnet or another
# backup holding it means nothing would ever arrive here.
if ($text -match 'already in use') { throw "$Name's console is in use by another connection (deploy.ps1 -Console, telnet, or another backup). Close it and run this again." }
if ($closed -and $text -notmatch '\[backup\] END') { throw "$Name closed the console connection. Run this again." }
if ($text -notmatch '\[backup\] END') { throw "No backup arrived within $TimeoutSeconds s. Is IPTV Player open on that TV?" }

# The last BEGIN..END block: the "[backup] " lines between them, joined.
$lines = $text -split "`r?`n"
$begin = -1
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '\[backup\] BEGIN\s+(\d+)') { $begin = $i; $expected = [int]$Matches[1] } }
$data = ''
for ($i = $begin + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '\[backup\] END') { break }
    if ($lines[$i] -match '\[backup\] (\S+)') { $data += $Matches[1] }
}
if ($data.Length -ne $expected) { throw "The backup arrived incomplete ($($data.Length) of $expected characters). Try again." }

$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data))
# Read with case-sensitive keys: Roku documents can hold the same key in two
# casings ("seenGames" / "seengames"), which plain ConvertFrom-Json rejects.
# -AsHashtable in PowerShell 7; Windows PowerShell 5.1 doesn't have it, so
# .NET's JavaScriptSerializer there (as in deploy.ps1).
function ConvertFrom-RokuJson([string]$text) {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return , ($text | ConvertFrom-Json -AsHashtable) }
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    return , $serializer.DeserializeObject($text)
}
# The parser's message can quote the backup (and its password): not shown.
try { $doc = ConvertFrom-RokuJson $json } catch { $doc = $null }
if (-not ($doc -is [System.Collections.IDictionary])) { throw 'The backup arrived but is not valid JSON; nothing was saved. Try again.' }
$dupes = @($doc.Keys | Group-Object { $_.ToLower() } | Where-Object Count -gt 1 | ForEach-Object { ($_.Group -join ' / ') })
if ($dupes) { Write-Host "  note: keys in two casings: $($dupes -join ', ')" }
$backupDir = Join-Path $root 'backups'
New-Item -ItemType Directory -Force $backupDir | Out-Null
$latest = Join-Path $backupDir "$Name.json"
$dated = Join-Path $backupDir ("$Name-" + (Get-Date -Format 'yyyy-MM-dd-HHmm') + '.json')
[IO.File]::WriteAllText($latest, $json, (New-Object System.Text.UTF8Encoding($false)))
Copy-Item $latest $dated

# Keys may be in either casing (deviceName / devicename): look up ignoring it.
function Get-Field($table, [string]$key) {
    foreach ($k in $table.Keys) { if ($k -ieq $key) { return $table[$k] } }
    return $null
}
function Count-Live($items) { @($items | Where-Object { $_ -and -not (Get-Field $_ 'deleted') }).Count }
Write-Host "Saved $latest"
Write-Host "  (and $(Split-Path -Leaf $dated))"
Write-Host ("  device '{0}': {1} favorites, {2} teams, {3} series, {4} resume entries" -f `
    (Get-Field $doc 'deviceName'), (Count-Live (Get-Field $doc 'favorites')), (Count-Live (Get-Field $doc 'teams')), `
    (Count-Live (Get-Field $doc 'series')), @(Get-Field $doc 'resume').Count)
Write-Host 'deploy.ps1 will bundle it, and the app restores it if this TV ever starts with no saved state.'
