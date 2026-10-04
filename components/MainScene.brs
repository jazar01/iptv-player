' Launch: with saved credentials, Home draws immediately from saved favorites
' and cached data while the login is re-validated in the background. Without
' them, Setup runs first. Credentials are saved only after the provider
' accepts them.

sub init()
    m.store = m.top.FindNode("stateStore")
    m.api = m.top.FindNode("api")
    m.epg = m.top.FindNode("epg")
    m.screenHost = m.top.FindNode("screenHost")
    m.overlayHost = m.top.FindNode("overlayHost")
    m.topBar = m.top.FindNode("topBar")
    m.toast = m.top.FindNode("toast")
    m.toastText = m.top.FindNode("toastText")
    m.toastTimer = m.top.FindNode("toastTimer")
    m.epgTimer = m.top.FindNode("epgTimer")

    m.sections = {}             ' name -> screen node, created on first visit
    m.section = ""
    m.overlays = []
    m.setup = invalid
    m.favoritesScreen = invalid
    m.pendingSetup = invalid    ' values submitted from Setup, awaiting login
    m.lastVisible = []
    m.liveCategoriesRequested = false
    m.liveCategoriesShown = false
    m.liveStreamsShown = {}
    m.pendingRequests = []      ' held until ApiTask is listening

    m.api.ObserveField("response", "onApiResponse")
    m.api.ObserveField("ready", "onApiReady")
    m.api.control = "RUN"
    m.epg.api = m.api
    m.epg.ObserveField("programs", "onPrograms")
    m.topBar.ObserveField("chosen", "onTopBarChosen")
    m.toastTimer.ObserveField("fire", "hideToast")
    m.epgTimer.ObserveField("fire", "onEpgTimer")
    m.epgTimer.control = "start"

    device = m.store.callFunc("getDevice")
    print "[main] device "; device.deviceId; " '"; device.deviceName; "'"

    if m.store.callFunc("isConfigured")
        m.api.credentials = m.store.callFunc("getCredentials")
        showSection("home")
        login()
    else
        showSetup("")
    end if
end sub

' All MainScene requests go through here: ApiTask drops requests set before
' its thread is listening.
sub sendRequest(req as Object)
    if m.api.ready
        m.api.request = req
    else
        m.pendingRequests.Push(req)
    end if
end sub

sub onApiReady()
    if not m.api.ready then return
    for each req in m.pendingRequests
        m.api.request = req
    end for
    m.pendingRequests = []
end sub

sub onApiResponse(event as Object)
    res = event.GetData()
    if res.id = "login"
        onLogin(res)
    else if res.id = "liveCategories"
        onLiveCategories(res)
    else if res.id = "liveStreams"
        onLiveStreams(res)
    end if
end sub

' ---------------------------------------------------------------------------
' Login and setup

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
        live = m.sections.live
        if live <> invalid
            m.screenHost.RemoveChild(live)
            m.sections.Delete("live")
        end if
        m.liveCategoriesRequested = false
        m.liveCategoriesShown = false
        m.liveStreamsShown = {}
    end if
end sub

' ---------------------------------------------------------------------------
' Sections, overlays and focus

sub showSection(name as String)
    screen = m.sections[name]
    if screen = invalid
        screen = createSection(name)
        m.sections[name] = screen
        m.screenHost.AppendChild(screen)
    end if
    for each key in m.sections
        m.sections[key].visible = (key = name)
    end for
    m.section = name
    m.topBar.visible = true
    m.topBar.section = name

    if name = "home"
        refreshHome()
    else if name = "live"
        onLiveShown()
    else if name = "settings"
        screen.info = settingsInfo()
    end if
    focusContent()
end sub

function createSection(name as String) as Object
    if name = "home"
        screen = CreateObject("roSGNode", "HomeScreen")
        screen.ObserveField("selected", "onItemSelected")
        screen.ObserveField("options", "onToggleFavorite")
        screen.ObserveField("visibleChannels", "onVisibleChannels")
    else if name = "live"
        screen = CreateObject("roSGNode", "LiveScreen")
        screen.ObserveField("wantCategory", "onWantCategory")
        screen.ObserveField("selected", "onItemSelected")
        screen.ObserveField("options", "onToggleFavorite")
    else if name = "settings"
        screen = CreateObject("roSGNode", "SettingsScreen")
        screen.ObserveField("chosen", "onSettingsChosen")
    else
        screen = CreateObject("roSGNode", "MessageScreen")
        title = "Movies"
        if name = "series" then title = "Series"
        screen.text = title + " arrive in a later milestone."
    end if
    return screen
end function

sub onTopBarChosen()
    showSection(m.topBar.chosen)
end sub

sub pushOverlay(node as Object)
    m.overlayHost.AppendChild(node)
    m.overlays.Push(node)
    node.SetFocus(true)
end sub

sub removeOverlay(node as Object)
    for i = m.overlays.Count() - 1 to 0 step -1
        if m.overlays[i].IsSameNode(node) then m.overlays.Delete(i)
    end for
    m.overlayHost.RemoveChild(node)
    if m.favoritesScreen <> invalid and m.favoritesScreen.IsSameNode(node) then m.favoritesScreen = invalid
    focusContent()
end sub

sub focusContent()
    if m.overlays.Count() > 0
        m.overlays.Peek().SetFocus(true)
    else if m.section <> ""
        m.sections[m.section].SetFocus(true)
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false

    if m.overlays.Count() > 0
        if key <> "back" then return false
        top = m.overlays.Peek()
        if m.setup <> invalid and top.IsSameNode(m.setup)
            if not m.store.callFunc("isConfigured") then return false     ' first run: Back exits
            closeSetup()
        else
            removeOverlay(top)
        end if
        return true
    end if

    if m.topBar.IsInFocusChain()
        if key = "down" or key = "back"
            focusContent()
            return true
        end if
        return false
    end if

    if key = "up" and m.section <> ""
        m.topBar.SetFocus(true)
        return true
    else if key = "back" and m.section <> "home" and m.section <> ""
        showSection("home")
        return true
    end if
    return false
end function

' ---------------------------------------------------------------------------
' Home and favorites

sub refreshHome()
    home = m.sections.home
    if home = invalid then return
    rows = buildHomeRows({ store: m.store, epg: m.epg })
    home.rows = rows
    if m.favoritesScreen <> invalid
        for each row in rows
            if row.id = "favorites" then m.favoritesScreen.items = row.items
        end for
    end if
end sub

sub openFavorites()
    m.favoritesScreen = CreateObject("roSGNode", "FavoritesScreen")
    m.favoritesScreen.ObserveField("selected", "onItemSelected")
    m.favoritesScreen.ObserveField("options", "onToggleFavorite")
    m.favoritesScreen.ObserveField("visibleChannels", "onVisibleChannels")
    pushOverlay(m.favoritesScreen)
    refreshHome()
end sub

sub onItemSelected(event as Object)
    item = event.GetData()
    if item.kind = "seeAll" and item.rowId = "favorites"
        openFavorites()
    else if item.kind = "channel"
        print "[main] selected channel "; item.streamId; " "; item.name
        showToast(item.name + ": playback arrives in the next milestone.")
    else if item.kind = "resume"
        showToast("Playback arrives in the next milestone.")
    end if
end sub

' * on any channel: add it to favorites, or remove it if it's already one.
sub onToggleFavorite(event as Object)
    channel = event.GetData()
    if channel.streamId = invalid or channel.streamId = 0 then return
    if m.store.callFunc("isFavorite", channel.streamId)
        saved = m.store.callFunc("removeFavorite", channel.streamId)
        message = "Removed " + channel.name + " from Favorites"
    else
        saved = m.store.callFunc("addFavorite", { streamId: channel.streamId, name: channel.name, epgChannelId: channel.epgChannelId })
        message = "Added " + channel.name + " to Favorites"
    end if
    if not saved then message = "Couldn't save the change. Storage may be full."
    showToast(message)
    refreshHome()
    live = m.sections.live
    if live <> invalid then live.favoriteIds = favoriteIdSet()
end sub

function favoriteIdSet() as Object
    ids = {}
    for each f in m.store.callFunc("getFavorites")
        ids[toInt(f.streamId).ToStr()] = true
    end for
    return ids
end function

' ---------------------------------------------------------------------------
' Guide (now/next)

sub onVisibleChannels(event as Object)
    m.lastVisible = event.GetData()
    m.epg.callFunc("want", m.lastVisible)
end sub

sub onEpgTimer()
    if m.lastVisible.Count() > 0 then m.epg.callFunc("want", m.lastVisible)
end sub

sub onPrograms(event as Object)
    entry = event.GetData()
    home = m.sections.home
    if home <> invalid then home.programs = entry
    if m.favoritesScreen <> invalid then m.favoritesScreen.programs = entry
end sub

' ---------------------------------------------------------------------------
' Live TV catalog. Cached in cachefs: and shown immediately, then refreshed.

sub onLiveShown()
    live = m.sections.live
    live.favoriteIds = favoriteIdSet()
    if m.liveCategoriesRequested then return
    m.liveCategoriesRequested = true
    sendRequest({
        id: "liveCategories"
        action: "get_live_categories"
        cacheFile: "cachefs:/catalog/live_categories.json"
        cacheFirst: true
    })
end sub

sub onLiveCategories(res as Object)
    live = m.sections.live
    if live = invalid or res.unchanged then return
    if res.ok and type(res.data) = "roArray"
        if not res.fromCache then print "[main] "; res.data.Count(); " live categories"
        m.liveCategoriesShown = true
        live.categories = res.data
    else if not m.liveCategoriesShown
        m.liveCategoriesRequested = false     ' try again next visit
        live.status = "Couldn't load categories: " + res.error
    end if
end sub

sub onWantCategory(event as Object)
    id = event.GetData()
    sendRequest({
        id: "liveStreams"
        action: "get_live_streams"
        params: { category_id: id }
        context: id
        cacheFile: "cachefs:/catalog/live_" + id + ".json"
        cacheFirst: true
        timeoutMs: 30000
    })
end sub

sub onLiveStreams(res as Object)
    live = m.sections.live
    if live = invalid or res.unchanged then return
    id = asString(res.context)
    if res.ok and type(res.data) = "roArray"
        m.liveStreamsShown[id] = true
        live.channels = { categoryId: id, items: res.data }
    else if not m.liveStreamsShown.DoesExist(id)
        live.channels = { categoryId: id, items: [] }
        live.status = "Couldn't load channels: " + res.error
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
    }
end function

sub onSettingsChosen(event as Object)
    if event.GetData() = "account" then showSetup("")
end sub

' ---------------------------------------------------------------------------
' Toast

sub showToast(text as String)
    m.toastText.text = text
    m.toast.visible = true
    m.toastTimer.control = "stop"
    m.toastTimer.control = "start"
end sub

sub hideToast()
    m.toast.visible = false
end sub

function joinStrings(items as Object, separator as String) as String
    out = ""
    for each item in items
        if out <> "" then out += separator
        out += asString(item)
    end for
    return out
end function
