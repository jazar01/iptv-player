' Login, Setup and Settings. Credentials are saved only after the provider
' accepts them.

sub initLogin()
    m.setup = invalid
    m.pendingSetup = invalid    ' values submitted from Setup, awaiting login
    ' server_info.timezone, for timeshift URLs: the last one seen is saved, so
    ' rewind works even before (or without) a successful login this session.
    m.serverTimezone = m.store.callFunc("getSettings").serverTimezone
    m.accountExpires = 0        ' user_info.exp_date (UTC seconds), 0 if none
    m.expiryNoted = false       ' the "expires soon" notice, once per session

    ' A launch login that fails for network reasons is retried in the
    ' background: 1 minute, then doubling up to 15 minutes.
    m.loginRetryDelay = 60
    m.loginRetryTimer = CreateObject("roSGNode", "Timer")
    m.loginRetryTimer.ObserveField("fire", "onLoginRetry")
    m.top.AppendChild(m.loginRetryTimer)
end sub

sub onLoginRetry()
    if m.pendingSetup = invalid and m.store.callFunc("isConfigured") then login()
end sub

sub login()
    creds = m.api.credentials
    print "[main] logging in to "; redact(creds.server)
    sendRequest({ id: "login", action: "" })
end sub

sub onLogin(res as Object)
    result = evaluateLogin(res)
    if not result.ok
        print "[main] login failed: "; redact(result.message)
        if m.pendingSetup <> invalid
            ' Still on Setup: say why, and keep the saved (working) account active.
            m.pendingSetup = invalid
            restoreSavedCredentials()
            m.setup.status = result.message
            m.setup.busy = false
        else if result.rejected
            showSetup(result.message)
        else
            ' Offline or server trouble: keep going on saved and cached data,
            ' and try again later.
            showToast(result.message)
            print "[main] will retry the login in "; m.loginRetryDelay; " s"
            m.loginRetryTimer.duration = m.loginRetryDelay
            m.loginRetryTimer.control = "start"
            m.loginRetryDelay = m.loginRetryDelay * 2
            if m.loginRetryDelay > 900 then m.loginRetryDelay = 900
        end if
        return
    end if

    print "[main] login ok. max_connections="; result.maxConnections; " active="; result.activeConnections; " expires="; result.expires; " server tz="; result.timezone
    print "[main] allowed_output_formats: "; joinStrings(result.formats, ", ")
    if not result.hls then print "[main] WARNING: provider does not list m3u8; live HLS playback may not work"
    ' Save (and, for a new account, clear the old one's data) before the
    ' catalog refresh, so the refresh is for this account. If the save fails,
    ' nothing changes: the saved account stays active and Setup stays open.
    newSetup = m.pendingSetup
    if newSetup <> invalid
        m.pendingSetup = invalid
        if not saveSetup(newSetup)
            restoreSavedCredentials()
            m.setup.status = "Connected, but the setup couldn't be saved (storage may be full). Nothing was changed."
            m.setup.busy = false
            return
        end if
    end if
    m.loginRetryTimer.control = "stop"
    m.loginRetryDelay = 60
    if result.timezone <> "" and result.timezone <> m.serverTimezone
        m.store.callFunc("setSetting", "serverTimezone", result.timezone)
        m.serverTimezone = result.timezone
    end if
    noteAccountExpiry(toInt(result.expires))
    m.connections = { active: result.activeConnections, max: result.maxConnections }
    refreshSearchIndex()

    if newSetup <> invalid
        closeSetup()
        if m.section = ""
            showSection("home")
        else
            refreshHome()
            showSection(m.section)
        end if
    end if
end sub

' Xtream answers player_api.php with user_info/server_info. A bad login is
' usually auth=0 with HTTP 200, but some panels answer 401/403 instead.
' rejected=true means the account itself was refused (not a network problem).
function evaluateLogin(res as Object) as Object
    if not res.ok
        if res.code = 401 or res.code = 403 then return { ok: false, rejected: true, message: "Login rejected. Check the username and password." }
        if res.code = 404 then return { ok: false, rejected: false, message: "The server doesn't answer like an Xtream Codes server (HTTP 404). Check the server URL." }
        return { ok: false, rejected: false, message: friendlyRequestError(res) }
    end if

    data = res.data
    if type(data) <> "roAssociativeArray" or type(data.user_info) <> "roAssociativeArray"
        return { ok: false, rejected: true, message: "That doesn't look like an Xtream Codes server. Check the server URL." }
    end if

    info = data.user_info
    if asString(info.auth) <> "1" then return { ok: false, rejected: true, message: "Login rejected. Check the username and password." }
    status = asString(info.status)
    if status <> "" and LCase(status) <> "active" then return { ok: false, rejected: true, message: "The account is " + status + "." }

    formats = []
    if type(info.allowed_output_formats) = "roArray" then formats = info.allowed_output_formats
    hls = false
    for each f in formats
        if LCase(asString(f)) = "m3u8" then hls = true
    end for

    timezone = ""
    if type(data.server_info) = "roAssociativeArray" then timezone = asString(data.server_info.timezone)

    return {
        ok: true
        maxConnections: toInt(info.max_connections)
        activeConnections: toInt(info.active_cons)
        formats: formats
        hls: hls
        expires: asString(info.exp_date)
        timezone: timezone
    }
end function

sub showSetup(status as String)
    if m.setup = invalid
        m.setup = CreateObject("roSGNode", "SetupScreen")
        m.setup.ObserveField("submit", "onSetupSubmit")
        values = { deviceName: m.store.callFunc("getDevice").deviceName }
        creds = m.store.callFunc("getCredentials")
        if creds <> invalid then values.Append(creds)
        m.setup.values = values
        pushOverlay(m.setup)
    end if
    m.setup.status = status
    m.setup.busy = false
end sub

sub closeSetup()
    if m.setup = invalid then return
    if m.pendingSetup <> invalid
        m.pendingSetup = invalid
        restoreSavedCredentials()
    end if
    setup = m.setup
    m.setup = invalid
    removeOverlay(setup)
end sub

sub onSetupSubmit(event as Object)
    values = event.GetData()
    m.pendingSetup = values
    m.setup.busy = true
    m.setup.status = "Connecting ..."
    m.api.credentials = { server: values.server, username: values.username, password: values.password }
    login()
end sub

sub restoreSavedCredentials()
    if m.store.callFunc("isConfigured") then m.api.credentials = m.store.callFunc("getCredentials")
end sub

' Saves the account and device name; on success, a new account's cached
' data is cleared. Returns false (and changes nothing) if it couldn't be saved.
function saveSetup(values as Object) as Boolean
    old = m.store.callFunc("getCredentials")
    accountChanged = (old <> invalid and (old.server <> values.server or old.username <> values.username))

    if not m.store.callFunc("setAccount", { server: values.server, username: values.username, password: values.password, deviceName: values.deviceName }) then return false

    if accountChanged
        ' Different provider account: cached catalog and guide no longer apply.
        print "[main] account changed; clearing cached catalog and guide"
        sendRequest({ id: "clearCache", op: "clearCache" })
        m.epg.callFunc("clear")
        resetCatalogs()
        m.searchIndexRequested = false
        m.archiveDays = {}
        searchSend("load", { kind: "reset" })     ' old account's search results
        m.games = []                              ' and its My Teams guides
        m.guideReady = false
        m.guideFetchedAt = 0
        m.localIds = {}
    end if
    return true
end function

' ---------------------------------------------------------------------------
' Settings

function settingsInfo() as Object
    device = m.store.callFunc("getDevice")
    server = ""
    creds = m.store.callFunc("getCredentials")
    if creds <> invalid then server = creds.server
    if server <> "" and not isEncryptedServer(server) then server = server + "   (not encrypted)"
    return {
        deviceName: device.deviceName
        deviceId: device.deviceId
        server: server
        version: CreateObject("roAppInfo").GetVersion()
        connections: connectionsText()
        expires: accountExpiryText()
        audio: dolbyAudioText()
        market: m.store.callFunc("getMarket").label
        showMyTeams: m.store.callFunc("getSettings").showMyTeams
        showNoGameTeams: m.store.callFunc("getSettings").showNoGameTeams
        showFavoritesInRecent: m.store.callFunc("getSettings").showFavoritesInRecent
        myTeamsFirst: m.store.callFunc("getSettings").myTeamsFirst
    }
end function

sub onSettingsChosen(event as Object)
    choice = event.GetData()
    if choice = "account"
        showSetup("")
    else if choice = "teams"
        openTeams()
    else if choice = "market"
        openMarkets()
    else if choice = "teamsRow"
        toggleMyTeamsRow()
    else if choice = "noGameTeams"
        toggleNoGameTeams()
    else if choice = "recentFavorites"
        toggleFavoritesInRecent()
    else if choice = "teamsPosition"
        toggleMyTeamsFirst()
    else if choice = "backup"
        backupToConsole()
    end if
end sub

' Settings backup panel (* then Play/Pause): the saved document, base64-encoded, on
' the debug console between markers, for scripts\backup-roku.ps1 to save.
' Short prefixed lines survive the console's line wrapping. It includes the
' provider password, so it's only ever printed here, on request.
sub backupToConsole()
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(m.store.callFunc("exportDocument"))
    data = bytes.ToBase64String()
    name = m.store.callFunc("getDevice").deviceName
    print "[backup] BEGIN "; data.Len(); " "; name
    i = 1
    while i <= data.Len()
        print "[backup] "; Mid(data, i, 96)
        i = i + 96
    end while
    print "[backup] END"
    showToast("Backup sent to the computer (scripts\backup-roku.ps1 saves it).")
end sub

' user_info.exp_date: shown in Settings, and a notice once per session when
' the account ends within 7 days. 0 (or "null") means no end date.
sub noteAccountExpiry(expires as Integer)
    m.accountExpires = expires
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
    if expires <= 0 or m.expiryNoted then return
    daysLeft = Int((expires - nowSeconds()) / 86400)
    if daysLeft < 0 or daysLeft > 7 then return
    m.expiryNoted = true
    when = "today"
    if daysLeft = 1 then when = "tomorrow"
    if daysLeft > 1 then when = "in " + daysLeft.ToStr() + " days"
    showToast("Your IPTV account expires " + when + " (" + formatDate(expires) + ").")
end sub

function accountExpiryText() as String
    if m.accountExpires <= 0 then return ""
    return formatDate(m.accountExpires)
end function

' What this Roku, as connected to its TV (or soundbar), can play of the two
' Dolby formats channels use: Dolby Digital (AC-3) and Dolby Digital Plus
' (E-AC-3). Roku players mostly pass Dolby on over HDMI for the TV to
' decode; a TV that reports stereo only makes every Dolby channel fail
' ("Unsupported audio format: Dolby Digital", Family Room, Oct 2026).
' Checked each time Settings opens: changing the TV's settings or HDMI
' port (and restarting the Roku) can change the answer.
function dolbyAudioText() as String
    info = CreateObject("roDeviceInfo")
    dd = canPlayAudio(info, "ac3")
    ddPlus = canPlayAudio(info, "eac3")
    print "[main] audio this Roku can play: Dolby Digital="; dd; ", Dolby Digital Plus="; ddPlus; ", AAC="; canPlayAudio(info, "aac"); " ("; FormatJson(info.GetAudioDecodeInfo()); ")"
    if dd and ddPlus then return "Dolby Digital and Dolby Digital Plus: yes"
    if not dd and not ddPlus then return "Dolby audio: NO (this TV connection takes stereo only; Dolby channels won't play)"
    if dd then return "Dolby Digital: yes   Dolby Digital Plus: NO"
    return "Dolby Digital: NO   Dolby Digital Plus: yes"
end function

function canPlayAudio(info as Object, codec as String) as Boolean
    answer = info.CanDecodeAudio({ Codec: codec })
    return type(answer) = "roAssociativeArray" and isTrue(answer.result)
end function
