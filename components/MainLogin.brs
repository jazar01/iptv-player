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
    if status <> "" and LCase(status) <> "active"
        ' "Expired", "Banned", "Disabled": what to do about it, too.
        message = "The account is " + LCase(status) + "."
        if LCase(status) = "expired"
            message = "The account has expired. Renew it with your IPTV provider, then try again."
        else
            message = message + " Contact your IPTV provider about it."
        end if
        return { ok: false, rejected: true, message: message }
    end if

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
        converter: converterText()
        backup: backupText()
        sharing: sharingText()
        market: m.store.callFunc("getMarket").label
        showMyTeams: m.store.callFunc("getSettings").showMyTeams
        showNoGameTeams: m.store.callFunc("getSettings").showNoGameTeams
        showFavoritesInRecent: m.store.callFunc("getSettings").showFavoritesInRecent
        myTeamsFirst: m.store.callFunc("getSettings").myTeamsFirst
        showScores: m.store.callFunc("getSettings").showScores
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
    else if choice = "scores"
        toggleScores()
    else if choice = "recentFavorites"
        toggleFavoritesInRecent()
    else if choice = "teamsPosition"
        toggleMyTeamsFirst()
    else if choice = "tvName"
        editTvName()
    else if choice = "sharing"
        openSharing()
    else if choice = "converter"
        editConverter()
    else if choice = "backup"
        backupToConsole()
    end if
end sub

' Settings backup panel (* then Play/Pause): the saved document, base64-encoded, on
' the debug console between markers, for scripts\backup-roku.ps1 to save.
' Short prefixed lines survive the console's line wrapping. It includes the
' provider password, so it's only ever printed here, on request.
' Settings -> TV name: saved as soon as it's typed (in "Account and device
' name" it saved only with Connect, so a name changed there and left with
' Back was lost: the Deck, Oct 2026), and backed up straight away, so the
' Pi and the admin page show it.
sub editTvName()
    dlg = CreateObject("roSGNode", "StandardKeyboardDialog")
    dlg.title = "TV name"
    dlg.message = ["A name for this TV, such as Living room. Backups on the Raspberry Pi and the admin page show it."]
    dlg.text = m.store.callFunc("getDevice").deviceName
    dlg.buttons = ["OK", "Cancel"]
    setKeyboardVoice(dlg, "generic")
    dlg.ObserveField("buttonSelected", "onTvNameButton")
    m.tvNameDialog = dlg
    m.top.dialog = dlg
end sub

sub onTvNameButton()
    dlg = m.tvNameDialog
    if dlg = invalid then return
    m.tvNameDialog = invalid
    choice = dlg.buttonSelected
    typed = dlg.text.Trim()
    dlg.close = true
    if choice <> 0 or typed = "" then return
    name = UCase(Left(typed, 1)) + Mid(typed, 2)        ' voice entry comes in lower case
    if not m.store.callFunc("setDeviceName", name)
        showToast("Couldn't save the change. Storage may be full.")
        return
    end if
    showToast("This TV is now called " + name)
    sendBackup()
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
end sub

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
    if not dd and not ddPlus
        ' What happens to Dolby channels on this TV depends on the converter.
        if converterAddress() = "" then return "Dolby audio: NO (this TV connection takes stereo only). Dolby channels play another copy where there is one; a Dolby converter plays them in full."
        if Left(asString(m.converterStatus), 7) = "working" then return "Dolby audio: NO (this TV connection takes stereo only). Dolby channels are converted to stereo by the Dolby converter and play in full."
        return "Dolby audio: NO (this TV connection takes stereo only). Dolby channels play through the Dolby converter when it answers, else another copy."
    end if
    if dd then return "Dolby Digital: yes   Dolby Digital Plus: NO"
    return "Dolby Digital: NO   Dolby Digital Plus: yes"
end function

' ---------------------------------------------------------------------------
' Settings -> Dolby converter: the address of the Raspberry Pi service that
' converts Dolby audio to stereo (MainPlayback). Per device; checked against
' its /health page whenever Settings opens or the address changes.

function converterText() as String
    address = converterAddress()
    if address = "" then return "off"
    status = asString(m.converterStatus)
    if status = "" then status = "checking ..."
    return address + "   (" + status + ")"
end function

sub checkConverter()
    address = converterAddress()
    if address = "" then return
    m.converterStatus = ""
    sendRequest({ id: "converterCheck", url: "http://" + address + "/health", context: { address: address }, timeoutMs: 4000 })
end sub

sub onConverterCheck(res as Object)
    if asString(res.context.address) <> converterAddress() then return
    if res.ok and type(res.data) = "roAssociativeArray"
        m.converterStatus = "working, version " + asString(res.data.version)
        m.converterDownUntil = 0        ' it's back: no need to wait out the pause
    else
        m.converterStatus = "NOT answering; Dolby channels use other copies"
    end if
    print "[main] Dolby converter "; converterAddress(); ": "; m.converterStatus
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
end sub

sub enterConverterAddress()
    dlg = CreateObject("roSGNode", "StandardKeyboardDialog")
    dlg.title = "Dolby converter"
    dlg.message = ["The Raspberry Pi's address on your home network, such as 192.168.222.99 (port 8790 unless you give another). Leave it empty to turn it off.", "Used only for channels whose Dolby audio this TV doesn't take."]
    dlg.text = converterAddress()
    dlg.buttons = ["OK", "Cancel"]
    setKeyboardVoice(dlg, "alphanumeric")
    dlg.ObserveField("buttonSelected", "onConverterButton")
    dlg.ObserveField("wasClosed", "onConverterClosed")
    m.converterDialog = dlg
    m.top.dialog = dlg
end sub

sub onConverterButton()
    dlg = m.converterDialog
    if dlg = invalid then return
    m.converterDialog = invalid
    choice = dlg.buttonSelected
    typed = dlg.text
    dlg.close = true
    if choice <> 0 then return
    address = converterAddressFrom(typed)
    if address = invalid
        showToast("That isn't an address like 192.168.222.99 or 192.168.222.99:8790.")
        return
    end if
    saveConverter(address)
end sub

sub saveConverter(address as String)
    if not m.store.callFunc("setSetting", "dolbyConverter", address)
        showToast("Couldn't save the change. Storage may be full.")
        return
    end if
    if address = "" then showToast("Dolby converter off") else showToast("Dolby converter: " + address)
    if address <> ""
        ' Channels marked as not playing here (Dolby, before there was a
        ' converter) get to try it; any that fail for other reasons are
        ' marked again on their next failure.
        m.converterDownUntil = 0
        if m.badStreams.Count() > 0
            print "[main] Dolby converter set: "; m.badStreams.Count(); " channel(s) marked as not playing here will try it"
            m.badStreams = {}
            saveStreamMarks()
        end if
    end if
    checkConverter()
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
end sub

' Settings -> Dolby converter: look for one on the home network first (the
' Pi answers a broadcast; StreamRelay asks), then offer what was found.
sub editConverter()
    dlg = CreateObject("roSGNode", "StandardProgressDialog")
    dlg.title = "Looking for a Dolby converter on your home network ..."
    dlg.ObserveField("wasClosed", "onConverterSearchClosed")
    m.converterDialog = dlg
    m.top.dialog = dlg
    m.converterSearchFor = "settings"
    m.converterSearchTimer.control = "start"     ' in case the relay doesn't answer
    m.relay.discover = { id: "settings" }
end sub

sub onConverterFound(event as Object)
    result = event.GetData()
    if asString(result.id) <> m.converterSearchFor then return
    if m.converterSearchFor = "playback"
        converterSearchDone(result)
        return
    end if
    showConverterChoice(result)
end sub

sub onConverterSearchTimeout()
    if m.converterSearchFor = "settings" then showConverterChoice({ found: false })
    if m.converterSearchFor = "playback" then converterSearchDone({ found: false })
end sub

sub showConverterChoice(result as Object)
    m.converterSearchFor = ""
    m.converterSearchTimer.control = "stop"
    searching = m.converterDialog
    m.converterDialog = invalid
    if searching <> invalid then searching.close = true
    current = converterAddress()
    actions = []
    buttons = []
    if isTrue(result.found)
        m.converterFound = asString(result.address)
        message = "Found a Dolby converter at " + m.converterFound + "."
        if m.converterFound = current then message = message + " This TV is set to use it."
        ' Always offered, even when it's already the one in use: choosing it
        ' is how you say yes to what was found.
        buttons.Push("Use this converter")
        actions.Push("use")
    else
        message = "No Dolby converter answered on this network. Check that the Raspberry Pi is on and connected, or enter its address."
        buttons.Push("Try again")
        actions.Push("again")
    end if
    buttons.Push("Enter an address")
    actions.Push("enter")
    if current <> ""
        buttons.Push("Turn off")
        actions.Push("off")
    end if
    buttons.Push("Cancel")
    actions.Push("cancel")
    dlg = CreateObject("roSGNode", "StandardMessageDialog")
    dlg.title = "Dolby converter"
    dlg.message = [message, "It's used only for channels whose Dolby audio this TV doesn't take: they play through it in stereo at full quality."]
    dlg.buttons = buttons
    dlg.ObserveField("buttonSelected", "onConverterChoice")
    dlg.ObserveField("wasClosed", "onConverterClosed")
    m.converterChoice = actions
    m.converterDialog = dlg
    m.top.dialog = dlg
end sub

sub onConverterChoice()
    dlg = m.converterDialog
    if dlg = invalid or type(m.converterChoice) <> "roArray" then return
    choice = dlg.buttonSelected
    m.converterDialog = invalid
    dlg.close = true
    if choice < 0 or choice >= m.converterChoice.Count() then return
    action = m.converterChoice[choice]
    if action = "use"
        saveConverter(m.converterFound)
    else if action = "off"
        saveConverter("")
    else if action = "again"
        editConverter()
    else if action = "enter"
        enterConverterAddress()
    end if
end sub

' Only for the dialog still current: a closed dialog reports it after the
' next one (the keyboard after "Enter an address") has already opened.
sub onConverterClosed(event as Object)
    closed = event.GetRoSGNode()
    if m.converterDialog <> invalid and m.converterDialog.IsSameNode(closed) then m.converterDialog = invalid
end sub

' Back while searching: stop waiting for it.
sub onConverterSearchClosed(event as Object)
    if m.converterDialog <> invalid and m.converterDialog.IsSameNode(event.GetRoSGNode())
        m.converterDialog = invalid
        m.converterSearchFor = ""
        m.converterSearchTimer.control = "stop"
    end if
end sub

' "192.168.222.99", "http://pi:8790/" -> "192.168.222.99:8790", "pi:8790";
' "" stays "" (off); anything else -> invalid.
function converterAddressFrom(typed as String) as Dynamic
    text = LCase(typed.Trim())
    if Left(text, 7) = "http://" then text = Mid(text, 8)
    while Right(text, 1) = "/"
        text = Left(text, text.Len() - 1)
    end while
    if text = "" then return ""
    if not CreateObject("roRegex", "^[a-z0-9.-]+(:[0-9]{1,5})?$", "").IsMatch(text) then return invalid
    if Instr(1, text, ":") = 0 then text = text + ":8790"
    port = Val(Mid(text, Instr(1, text, ":") + 1), 10)
    if port < 1 or port > 65535 then return invalid
    return text
end function

function canPlayAudio(info as Object, codec as String) as Boolean
    answer = info.CanDecodeAudio({ Codec: codec })
    return type(answer) = "roAssociativeArray" and isTrue(answer.result)
end function
