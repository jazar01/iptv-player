' Milestone 1 flow:
'   saved credentials? -> log in -> print live categories
'   otherwise          -> Setup screen -> log in -> save -> print live categories
' Credentials are saved only after the provider accepts them.

sub init()
    m.store = m.top.FindNode("stateStore")
    m.api = m.top.FindNode("api")
    m.screenHost = m.top.FindNode("screenHost")
    m.message = m.top.FindNode("message")
    m.setup = invalid
    m.pendingSetup = invalid    ' values submitted from Setup, awaiting login

    m.api.ObserveField("response", "onApiResponse")
    m.api.control = "RUN"

    device = m.store.callFunc("getDevice")
    print "[main] device "; device.deviceId; " '"; device.deviceName; "'"

    if m.store.callFunc("isConfigured")
        connect(m.store.callFunc("getCredentials"))
    else
        showSetup("")
    end if
end sub

sub connect(creds as Object)
    print "[main] logging in to "; creds.server; " as "; creds.username
    if m.setup = invalid then showMessage("Connecting to " + creds.server + " ...")
    m.api.credentials = creds
    m.api.request = { id: "login", action: "" }
end sub

sub onApiResponse(event as Object)
    res = event.GetData()
    if res.id = "login"
        onLogin(res)
    else if res.id = "liveCategories"
        onLiveCategories(res)
    end if
end sub

' ---------------------------------------------------------------------------
' Login

sub onLogin(res as Object)
    login = evaluateLogin(res)
    if not login.ok
        print "[main] login failed: "; login.message
        showSetup(login.message)
        return
    end if

    print "[main] login ok. max_connections="; login.maxConnections; " active="; login.activeConnections; " expires="; login.expires; " server tz="; login.timezone
    print "[main] allowed_output_formats: "; joinStrings(login.formats, ", ")
    if not login.hls then print "[main] WARNING: provider does not list m3u8; live HLS playback may not work"

    if m.pendingSetup <> invalid
        p = m.pendingSetup
        m.pendingSetup = invalid
        saved = m.store.callFunc("setCredentials", { server: p.server, username: p.username, password: p.password })
        saved = m.store.callFunc("setDeviceName", p.deviceName) and saved
        if not saved then print "[main] WARNING: could not save setup; it will be asked again next launch"
    end if

    hideSetup()
    showMessage("Logged in. Loading live categories ...")
    m.api.request = { id: "liveCategories", action: "get_live_categories" }
end sub

' Xtream answers player_api.php with user_info/server_info. A bad login is
' usually auth=0 with HTTP 200, but some panels answer 401/403 instead.
function evaluateLogin(res as Object) as Object
    if not res.ok
        if res.code = 401 or res.code = 403 then return { ok: false, message: "Login rejected. Check the username and password." }
        if res.code > 0 then return { ok: false, message: "The server answered with an error (" + res.error + "). Check the server URL." }
        return { ok: false, message: "Can't reach the server: " + res.error }
    end if

    data = res.data
    if type(data) <> "roAssociativeArray" or type(data.user_info) <> "roAssociativeArray"
        return { ok: false, message: "That doesn't look like an Xtream Codes server. Check the server URL." }
    end if

    info = data.user_info
    if asString(info.auth) <> "1" then return { ok: false, message: "Login rejected. Check the username and password." }
    status = asString(info.status)
    if status <> "" and LCase(status) <> "active" then return { ok: false, message: "The account is " + status + "." }

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

' ---------------------------------------------------------------------------
' Live categories (milestone 1: debug console only)

sub onLiveCategories(res as Object)
    if not res.ok or type(res.data) <> "roArray"
        print "[main] could not load live categories: "; res.error
        showMessage("Could not load live categories: " + res.error)
        return
    end if

    categories = res.data
    print "[main] ---- live categories ("; categories.Count(); ") ----"
    for each c in categories
        print "  "; asString(c.category_id); "  "; asString(c.category_name)
    end for
    print "[main] ---- end live categories ----"
    showMessage("Logged in. " + categories.Count().ToStr() + " live categories printed to the debug console.")
end sub

' ---------------------------------------------------------------------------
' Screens

sub showSetup(status as String)
    if m.setup = invalid
        m.setup = CreateObject("roSGNode", "SetupScreen")
        m.setup.ObserveField("submit", "onSetupSubmit")
        m.screenHost.AppendChild(m.setup)
    end if

    values = m.pendingSetup
    if values = invalid
        values = { deviceName: m.store.callFunc("getDevice").deviceName }
        creds = m.store.callFunc("getCredentials")
        if creds <> invalid then values.Append(creds)
    end if
    m.pendingSetup = invalid

    m.setup.values = values
    m.setup.status = status
    m.setup.busy = false
    m.message.visible = false
    m.setup.SetFocus(true)
end sub

sub hideSetup()
    if m.setup = invalid then return
    m.screenHost.RemoveChild(m.setup)
    m.setup = invalid
end sub

sub onSetupSubmit(event as Object)
    values = event.GetData()
    m.pendingSetup = values
    m.setup.busy = true
    m.setup.status = "Connecting ..."
    connect({ server: values.server, username: values.username, password: values.password })
end sub

sub showMessage(text as String)
    m.message.text = text
    m.message.visible = true
end sub

function joinStrings(items as Object, separator as String) as String
    out = ""
    for each item in items
        if out <> "" then out += separator
        out += asString(item)
    end for
    return out
end function
