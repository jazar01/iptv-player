' MainScene core: start-up, request routing, sections, overlays, focus and the
' toast. Feature logic lives in the other Main*.brs files:
'   MainLogin.brs     login, Setup, Settings
'   MainHome.brs      Home rows, favorites, now/next
'   MainCatalog.brs   Live TV / Movies / Series browsers, series pages
'   MainPlayback.brs  player, resume, watched tracking, live pause/rewind
'   MainSearch.brs    search index and queries, channel matching
'   MainTeams.brs     My Teams games, replays, logos, Settings -> My Teams
'   MainChannelInfo.brs  channel info panel, * menu in Live TV
'   MainMovies.brs    movie details page
'
' Launch: with saved credentials, Home draws immediately from saved favorites
' and cached data while the login is re-validated in the background. Without
' them, Setup runs first.

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
    m.pendingRequests = []      ' held until ApiTask is listening
    initLogin()
    initHome()
    initCatalog()
    initPlayback()
    initTeams()
    initSearch()
    initChannelInfo()
    initMovies()

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

' ---------------------------------------------------------------------------
' Requests

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
    else if res.id = "connCheck"
        onConnectionCheck(res)
    else if res.id = "catalogCategories"
        onCatalogCategories(res)
    else if res.id = "catalogItems"
        onCatalogItems(res)
    else if res.id = "seriesInfo"
        onSeriesInfo(res)
    else if res.id = "catalogAll"
        onCatalogAll(res)
    else if res.id = "movieInfo"
        onMovieInfo(res)
    else if res.id = "channelGuide"
        onChannelGuide(res)
    else if res.id = "teamLogo"
        onTeamLogo(res)
    else if res.id = "teamGuide"
        onTeamGuide(res)
    end if
end sub

' ---------------------------------------------------------------------------
' Sections (Home, Live TV, Movies, Series, Settings)

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
    else if name = "settings"
        screen.info = settingsInfo()
        checkConnections("settings")
    else if name = "search"
        onSearchShown(screen)
    else
        onCatalogShown(screen)
    end if
    focusContent()
end sub

function createSection(name as String) as Object
    if name = "home"
        screen = CreateObject("roSGNode", "HomeScreen")
        screen.ObserveField("selected", "onItemSelected")
        screen.ObserveField("options", "onToggleFavorite")
        screen.ObserveField("removeContinue", "onRemoveContinue")
        screen.ObserveField("visibleChannels", "onVisibleChannels")
    else if name = "settings"
        screen = CreateObject("roSGNode", "SettingsScreen")
        screen.ObserveField("chosen", "onSettingsChosen")
    else if name = "search"
        screen = createSearchScreen()
    else
        screen = createCatalogScreen(sectionKind(name))
    end if
    return screen
end function

' Section name -> catalog kind.
function sectionKind(name as String) as String
    if name = "movies" then return "movie"
    if name = "series" then return "series"
    return "live"
end function

sub onTopBarChosen()
    showSection(m.topBar.chosen)
end sub

' ---------------------------------------------------------------------------
' Overlays (Setup, "See all" grids, series and movie pages, info panel,
' player) and focus

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
    if m.rowGrid <> invalid and m.rowGrid.IsSameNode(node) then m.rowGrid = invalid
    if m.movieScreen <> invalid and m.movieScreen.IsSameNode(node)
        m.movieScreen = invalid
        m.movieItem = invalid
    end if
    if m.seriesScreen <> invalid and m.seriesScreen.IsSameNode(node) then m.seriesScreen = invalid
    if m.teamsScreen <> invalid and m.teamsScreen.IsSameNode(node) then m.teamsScreen = invalid
    if m.teamEditScreen <> invalid and m.teamEditScreen.IsSameNode(node) then m.teamEditScreen = invalid
    if m.marketScreen <> invalid and m.marketScreen.IsSameNode(node) then m.marketScreen = invalid
    if m.infoPanel <> invalid and m.infoPanel.IsSameNode(node)
        m.infoPanel = invalid
        m.infoFor = invalid
    end if
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
' Toast and helpers

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
