' Login, Setup and Settings. Credentials are saved only after the provider
' accepts them.

sub initLogin()
    m.setup = invalid
    m.pendingSetup = invalid    ' values submitted from Setup, awaiting login
    m.serverTimezone = ""       ' server_info.timezone, for timeshift URLs
end sub

sub login()
    creds = m.api.credentials
    print "[main] logging in to "; creds.server; " as "; creds.username
    sendRequest({ id: "login", action: "" })
end sub

sub onLogin(res as Object)
    result = evaluateLogin(res)
    if not result.ok
        print "[main] login failed: "; result.message
        if m.pendingSetup <> invalid
            ' Still on Setup: say why, and keep the saved (working) account active.
            m.pendingSetup = invalid
            restoreSavedCredentials()
            m.setup.status = result.message
            m.setup.busy = false
        else if result.rejected
            showSetup(result.message)
        else
            ' Offline or server trouble: keep going on saved and cached data.
            showToast(result.message)
        end if
        return
    end if

    print "[main] login ok. max_connections="; result.maxConnections; " active="; result.activeConnections; " expires="; result.expires; " server tz="; result.timezone
    print "[main] allowed_output_formats: "; joinStrings(result.formats, ", ")
    if not result.hls then print "[main] WARNING: provider does not list m3u8; live HLS playback may not work"
    m.serverTimezone = result.timezone
    refreshSearchIndex()

    if m.pendingSetup <> invalid
        saveSetup(m.pendingSetup)
        m.pendingSetup = invalid
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
        if res.code > 0 then return { ok: false, rejected: false, message: "The server answered with an error (" + res.error + "). Check the server URL." }
        return { ok: false, rejected: false, message: "Can't reach the server: " + res.error }
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

sub saveSetup(values as Object)
    old = m.store.callFunc("getCredentials")
    accountChanged = (old <> invalid and (old.server <> values.server or old.username <> values.username))

    saved = m.store.callFunc("setCredentials", { server: values.server, username: values.username, password: values.password })
    saved = m.store.callFunc("setDeviceName", values.deviceName) and saved
    if not saved then showToast("Couldn't save the setup. It will be asked again next time.")

    if accountChanged
        ' Different provider account: cached catalog and guide no longer apply.
        print "[main] account changed; clearing cached catalog and guide"
        sendRequest({ id: "clearCache", op: "clearCache" })
        m.epg.callFunc("clear")
        resetCatalogs()
        m.searchIndexRequested = false
        m.archiveDays = {}
    end if
end sub

' ---------------------------------------------------------------------------
' Settings

function settingsInfo() as Object
    device = m.store.callFunc("getDevice")
    server = ""
    creds = m.store.callFunc("getCredentials")
    if creds <> invalid then server = creds.server
    return {
        deviceName: device.deviceName
        deviceId: device.deviceId
        server: server
        version: CreateObject("roAppInfo").GetVersion()
        market: m.store.callFunc("getMarket").label
        showMyTeams: m.store.callFunc("getSettings").showMyTeams
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
    end if
end sub
