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

# Date and time on the output, so a terminal scrolled back shows when each
# deploy and install happened.
function Get-Stamp { return (Get-Date).ToString('ddd MMM d, yyyy  h:mm:ss tt') }
Write-Host "=== Deploy started $(Get-Stamp) ==="

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
    #   - A statement can't start with a function's result:
    #     catalogState(k).x.Delete(id), also after "then" / "else" on one line
    #     and with a call in the arguments: f(g(x)).y = 1. (A method's result
    #     is fine: m.top.FindNode("x").visible = true runs on the Roku.)
    #   - A statement can't start with a parenthesis: (a + b).ToStr()
    # Strings and comments are blanked first, so their text can't match.
    $callStart = '[A-Za-z_][A-Za-z0-9_]*\((?:[^()]|\([^()]*\))*\)\.[A-Za-z_]'
    $patterns = @(
        @{ Regex = "^\s*$callStart"; Why = 'statement starts with a call result' }
        @{ Regex = "\b(?:then|else)\s+$callStart"; Why = 'statement starts with a call result' }
        @{ Regex = '^\s*\('; Why = 'statement starts with a parenthesis' }
        @{ Regex = '\b(?:then|else)\s+\('; Why = 'statement starts with a parenthesis' }
    )
    $rokuOnly = @()
    foreach ($file in Get-ChildItem (Join-Path $root 'components'), (Join-Path $root 'source') -Recurse -Filter *.brs) {
        $n = 0
        foreach ($line in Get-Content $file.FullName) {
            $n++
            $code = ($line -replace '"[^"]*"', '""') -replace "'.*$", ''
            if ($code -match '^\s*rem\b') { continue }
            foreach ($p in $patterns) {
                if ($code -match $p.Regex) {
                    $rokuOnly += "$($file.FullName.Substring($root.Length + 1)):${n}: $($p.Why): $($line.Trim())"
                    break
                }
            }
        }
    }
    if ($rokuOnly) {
        $rokuOnly | ForEach-Object { Write-Host $_ }
        throw 'The Roku would refuse to compile this (see above); nothing was uploaded. Assign the call to a variable first.'
    }
    Write-Host 'Code check passed.'
}

# --- Rules files ---------------------------------------------------------------

# data\*.json must parse: a broken guide-rules.json would quietly switch off
# every rule (guide tags, My Teams, search synonyms, time zones). Patterns are
# also compiled here; .NET's regex dialect differs a little from the Roku's,
# so a pattern that fails only warns (the app skips one that won't compile).
function Get-RulePatterns($rules) {
    $list = @()
    foreach ($t in @($rules.nameTimes)) { if ($t.pattern) { $list += $t.pattern } }
    $teams = $rules.myTeams
    if ($teams) {
        $list += @($teams.eventCategories) + @($teams.skipCategories) + @($teams.separators)
        foreach ($r in @($teams.sportRules)) { if ($r.pattern) { $list += $r.pattern } }
        $list += @($teams.replayWords, $teams.laterLanguages, $teams.localCategories, $teams.localName, $teams.networkAvoid)
    }
    if ($rules.categoryOrder) { $list += $rules.categoryOrder.countryPattern }
    if ($rules.channelMatching) { $list += @($rules.channelMatching.ignorePatterns) }
    $list += $rules.episodeTitlePrefix
    return @($list | Where-Object { $_ })
}
foreach ($file in Get-ChildItem (Join-Path $root 'data') -Filter *.json) {
    $text = Get-Content $file.FullName -Raw -Encoding UTF8
    try { $rules = $text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "data\$($file.Name) isn't valid JSON, so nothing was packaged: $($_.Exception.Message)" }
    # ConvertFrom-Json lets control characters through, but strict JSON (and
    # the Roku) may not: a "\b" typed through a shell became a backspace in a
    # pattern (Oct 9, 2026).
    if ($text -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { throw "data\$($file.Name) contains a control character (a mistyped \b or \t?), so nothing was packaged." }
    if ($file.Name -eq 'guide-rules.json') {
        foreach ($pattern in Get-RulePatterns $rules) {
            try { [void][regex]::new($pattern) }
            catch { Write-Warning "data\$($file.Name): a pattern may not compile on the Roku (it will be skipped there): $pattern" }
        }
    }
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
        # Must be complete JSON with the saved document's basics, read with
        # case-sensitive keys so a backup with "seenGames" and "seengames"
        # both still reads: -AsHashtable in PowerShell 7, .NET's serializer
        # in Windows PowerShell 5.1 (which has no -AsHashtable). The raw text
        # is what gets bundled.
        try {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $doc = $text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            } else {
                Add-Type -AssemblyName System.Web.Extensions
                $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
                $serializer.MaxJsonLength = [int]::MaxValue
                $doc = $serializer.DeserializeObject($text)
            }
            if ($null -eq $doc -or -not ($doc -is [System.Collections.IDictionary])) { throw 'not an object' }
        }
        # The parser's message can quote the file (and its password): not shown.
        catch { throw "$path isn't valid JSON." }
        $keys = @($doc.Keys | ForEach-Object { "$_".ToLower() })
        foreach ($required in 'schema', 'credentials') {
            if ($keys -notcontains $required) { throw "$path doesn't look like a backup (no `"$required`")." }
        }
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
    # The household key for backups on the Pi (BackupTask), from $BackupKey in
    # deploy.local.ps1; without it the app's backups are off.
    if ($BackupKey -match '^[0-9a-fA-F]{64}$') {
        $entry = $zip.CreateEntry('data/backup.json', 'Optimal')
        $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
        try { $writer.Write('{"key":"' + $BackupKey.ToLower() + '"}') } finally { $writer.Dispose() }
        Write-Host 'Backups: household key included'
    }
    else {
        Write-Host 'Backups: off (no $BackupKey in deploy.local.ps1)'
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
    # Plain UTF-8 without a byte-order mark: in a console switched to UTF-8
    # (ssh does that), Windows PowerShell 5.1 otherwise starts what it pipes
    # with one, and curl reads "<BOM>user" as an unknown option (Oct 2026).
    $savedOutput = $OutputEncoding
    $savedInput = [Console]::InputEncoding
    $plain = New-Object System.Text.UTF8Encoding $false
    try {
        $OutputEncoding = $plain
        try { [Console]::InputEncoding = $plain } catch { }      # no console: nothing to change
        $output = $curlConfig | & curl.exe --config - --silent --show-error --digest `
            --connect-timeout 10 --max-time 120 --write-out "`n%{http_code}" `
            --form 'mysubmit=Install' --form "archive=@$zipPath" `
            "http://$Ip/plugin_install"
    }
    finally {
        $OutputEncoding = $savedOutput
        try { [Console]::InputEncoding = $savedInput } catch { }
    }
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


# A failed install removes the dev app and its saved data; it comes back only
# from a recent backup: the TV's own on the Pi (V2, it offers to restore it),
# or backups\<name>.json from backup-roku.ps1 (bundled). Warns, doesn't stop.
$script:piBackups = $null
function Get-PiBackups {
    if ($null -ne $script:piBackups) { return $script:piBackups }
    $script:piBackups = @()
    # Only a check: nothing here may stop the deploy. ('Stop' would, under
    # Windows PowerShell 5.1, for any notice ssh writes to stderr.)
    $ErrorActionPreference = 'Continue'
    # Found the way the TVs find it (a broadcast, UDP 8793), not with ssh:
    # running ssh switches the console to UTF-8, after which Windows
    # PowerShell 5.1 puts a byte-order mark before what it pipes to curl,
    # and the install's credentials stop working (Oct 2026).
    $address = $null
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 1500
        $ask = [Text.Encoding]::ASCII.GetBytes('IPTV-BACKUP?')
        [void]$udp.Send($ask, $ask.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, 8793)))
        $from = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $reply = [Text.Encoding]::ASCII.GetString($udp.Receive([ref]$from))
        if ($reply -like 'IPTV-BACKUP *') { $address = $from.Address.ToString() }
    }
    catch { }
    finally { $udp.Close() }
    if ($address) {
        # Through the pipeline: Windows PowerShell 5.1 returns a JSON array as
        # one item holding the array.
        try { $script:piBackups = @(Invoke-RestMethod -Uri "http://${address}:8792/devices" -TimeoutSec 4 | ForEach-Object { $_ }) }
        catch { Write-Host "  (The Pi's backup service didn't answer; checking backups\ only.)" }
    }
    return $script:piBackups
}

function Test-Backup([string]$Ip) {
    $roku = @($LocalRokus) | Where-Object { $_ -and $_.Ip -eq $Ip } | Select-Object -First 1
    if (-not $roku -or -not $roku.Name) { return }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $onPi = @(Get-PiBackups) | Where-Object { $_.name -eq $roku.Name } | Sort-Object savedAt -Descending | Select-Object -First 1
    if ($onPi -and ($now - [long]$onPi.savedAt) -lt 14 * 86400) { return }
    $file = Join-Path (Join-Path $root 'backups') "$($roku.Name).json"
    if ((Test-Path $file) -and ((Get-Date) - (Get-Item $file).LastWriteTime).TotalDays -lt 14) { return }
    $how = "open the app on it for a minute (it backs up to the Pi), or run .\scripts\backup-roku.ps1 -Roku '$($roku.Name)'"
    if ($onPi) {
        $days = [int](($now - [long]$onPi.savedAt) / 86400)
        Write-Warning "$($roku.Name)'s backup on the Pi is $days days old. A failed install would restore it as it was then; $how"
    }
    else {
        Write-Warning "$($roku.Name) has no recent backup (none named '$($roku.Name)' on the Pi or in backups\). If this install failed, its saved data would be lost; $how"
    }
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
        Test-Backup $roku.Ip
        try {
            if (-not $devPassword) { throw 'No developer password (set Password for it or $LocalRokuPassword).' }
            $outcome = Install-Roku $roku.Ip $devPassword
            $text = if ($outcome -eq 'identical') { 'already up to date' } else { 'installed' }
            $results += [pscustomobject]@{ Roku = $name; IP = $roku.Ip; Result = $text; Time = (Get-Date).ToString('h:mm:ss tt') }
        }
        catch {
            Write-Warning "  $name failed: $($_.Exception.Message)"
            $results += [pscustomobject]@{ Roku = $name; IP = $roku.Ip; Result = "FAILED: $($_.Exception.Message)"; Time = (Get-Date).ToString('h:mm:ss tt') }
        }
    }
    Write-Host ''
    Write-Host "=== Finished $(Get-Stamp) ==="
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
    Test-Backup $RokuIp
    $outcome = Install-Roku $RokuIp $Password
    if ($outcome -eq 'identical') {
        Write-Host "The Roku already has this exact build; it was not reinstalled. ($(Get-Stamp))"
    }
    else {
        Write-Host "Installed $(Get-Stamp)."
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
