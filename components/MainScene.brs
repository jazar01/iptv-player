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
'   MainGuide.brs     the Guide (channels-by-time grid)
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
    initGuide()
    initBackup()

    m.api.ObserveField("response", "onApiResponse")
    m.api.ObserveField("ready", "onApiReady")
    m.api.control = "RUN"
    ' The services' threads are watched: one that stops is restarted.
    m.taskRestarts = {}
    for each task in [m.api, m.searchTask, m.relay]
        task.ObserveField("state", "onTaskState")
        ' Stopped already, before it was watched: no change event will come.
        taskStateChanged(task, asString(task.state))
    end for
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
        offerRestore()      ' a backup on the Pi, if this TV is one of them
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

' Every reply passes through here, and the handlers read provider data, the
' likeliest source of a surprise. A runtime error in one is caught and
' logged: uncaught, it would open the debugger on a sideloaded Roku and
' freeze the app.
sub onApiResponse(event as Object)
    res = event.GetData()
    try
        routeApiResponse(res)
    catch e
        print "[main] ERROR handling a "; asString(res.id); " reply (recovered): "; redact(e.message)
    end try
end sub

sub routeApiResponse(res as Object)
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
    else if res.id = "guideTable"
        onGuideTable(res)
    else if res.id = "movieInfo"
        onMovieInfo(res)
    else if res.id = "channelGuide"
        onChannelGuide(res)
    else if res.id = "teamLogo"
        onTeamLogo(res)
    else if res.id = "teamGuide"
        onTeamGuide(res)
    else if res.id = "teamScores"
        onTeamScores(res)
    else if res.id = "converterPing"
        onConverterPing(res)
    else if res.id = "converterCheck"
        onConverterCheck(res)
    end if
end sub

' ---------------------------------------------------------------------------
' Service threads. ApiTask, SearchTask and StreamRelay run for the life of
' the app; if one stops (its loop ended, or a runtime error ended the
' thread) its work would silently stop with it: no catalog, search, My
' Teams or audio repair. So it's restarted, marked not ready first so new
' requests queue instead of vanishing, with what was waiting on it
' cleared. At most 3 restarts in 10 minutes each, then it's left stopped
' and the viewer is told.

sub onTaskState(event as Object)
    taskStateChanged(event.GetRoSGNode(), asString(event.GetData()))
end sub

sub taskStateChanged(task as Object, newState as String)
    state = LCase(newState)
    if state <> "stop" and state <> "done" then return
    if isTrue(m.exiting) then return
    name = task.Subtype()
    now = nowSeconds()
    recent = []
    for each t in asArray(m.taskRestarts[name])
        if now - t < 600 then recent.Push(t)
    end for
    if recent.Count() >= 3
        print "[main] ERROR: "; name; " stopped again ("; recent.Count(); " restarts in 10 minutes); leaving it stopped"
        showToast("Part of the app stopped working. To fix it, press Home and open Dixie TV again.")
        return
    end if
    recent.Push(now)
    m.taskRestarts[name] = recent
    print "[main] WARNING: "; name; " stopped (state "; state; "); restarting it"
    if task.IsSameNode(m.api)
        m.api.ready = false
        onApiRestart()
    else if task.IsSameNode(m.searchTask)
        m.searchTask.ready = false
        onSearchTaskRestart()
    else if task.IsSameNode(m.relay)
        m.relay.port = 0        ' until it listens again: streams play without the fix
    end if
    task.control = "RUN"
end sub

' ApiTask restarted: replies to what was in flight won't come.
sub onApiRestart()
    m.guidePending = 0
    m.guideFetchedAt = 0        ' that batch is lost: fetch the guides again
    m.scoresPending = 0
    m.guideInflight = {}
    m.logoPending = {}
    for each kind in m.catalogState
        state = m.catalogState[kind]
        if not state.categoriesShown then state.requested = false
    end for
end sub

' SearchTask restarted: its index is gone until onSearchReady reloads it
' from the saved lists.
sub onSearchTaskRestart()
    m.iconsPending = false
    m.searchTask.counts = {}
    if m.autoCopyFor <> invalid then onAutoCopyTimeout()
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
        refreshScoresIfStale()
        syncIfStale()
    else if name = "settings"
        screen.info = settingsInfo()
        checkConnections("settings")
        checkConverter()
    else if name = "search"
        onSearchShown(screen)
    else if name = "guide"
        onGuideShown(screen)
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
    else if name = "guide"
        screen = createGuideScreen()
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
    ' A list whose itemSelected opened this takes focus back when its key
    ' handling ends; hidden behind the overlay, it then gets the keys (*,
    ' Up/Down and OK did nothing in a channel played from Search, Oct 2026).
    ' So look again a moment later.
    if m.focusCheck = invalid
        m.focusCheck = CreateObject("roSGNode", "Timer")
        m.focusCheck.duration = 0.2
        m.focusCheck.ObserveField("fire", "onFocusCheck")
        m.top.AppendChild(m.focusCheck)
    end if
    m.focusCheck.control = "stop"
    m.focusCheck.control = "start"
end sub

sub onFocusCheck()
    if m.overlays.Count() = 0 then return
    ' A dialog showing has the keys on purpose.
    dlg = m.top.dialog
    if dlg <> invalid and dlg.IsInFocusChain() then return
    top = m.overlays.Peek()
    if top.IsInFocusChain() then return
    print "[main] focus was taken back from "; top.Subtype(); "; returned to it"
    focusContent()
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
    if m.sharingScreen <> invalid and m.sharingScreen.IsSameNode(node) then m.sharingScreen = invalid
    if m.infoPanel <> invalid and m.infoPanel.IsSameNode(node)
        m.infoPanel = invalid
        m.infoFor = invalid
    end if
    ' Back on the Guide (after playing, say): fetch what it was waiting for.
    if m.section = "guide" then pumpGuide()
    if m.section = "home" then refreshScoresIfStale()
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
    else if key = "back" and m.section = "home"
        confirmExit()
        return true
    end if
    return false
end function

' Back on Home: ask first, so a stray Back doesn't close the app. Back again
' (or Cancel) stays.
sub confirmExit()
    dlg = CreateObject("roSGNode", "StandardMessageDialog")
    dlg.title = "Exit Dixie TV?"
    dlg.buttons = ["Exit", "Cancel"]
    dlg.ObserveField("buttonSelected", "onExitChoice")
    m.exitDialog = dlg
    m.top.dialog = dlg
end sub

sub onExitChoice()
    dlg = m.exitDialog
    if dlg = invalid then return
    m.exitDialog = invalid
    choice = dlg.buttonSelected
    dlg.close = true
    if choice = 0
        print "[main] exit chosen"
        ' A backup still waiting (a change in the last minute, a new device
        ' name, say) goes first: closed now, the Pi would keep the old one.
        if m.backupDue
            showToast("Saving a backup ...")
            sendBackup()
            m.exitTimer = CreateObject("roSGNode", "Timer")
            m.exitTimer.duration = 2.5
            m.exitTimer.ObserveField("fire", "exitNow")
            m.top.AppendChild(m.exitTimer)
            m.exitTimer.control = "start"
            return
        end if
        exitNow()
    end if
end sub

sub exitNow()
    m.exiting = true        ' threads stop as the app closes: not restarted
    m.top.exitApp = true
end sub

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
