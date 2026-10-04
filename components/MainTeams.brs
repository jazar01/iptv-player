' My Teams: keeps the games list fresh, labels replays, and wires the
' Settings -> My Teams screens. Finding games happens in SearchTask
' (MyTeams.brs); this side decides when to ask and what to do with them.

sub initTeams()
    m.games = []                ' last SearchTask result (see MyTeams.brs)
    m.guideReady = false        ' network guides saved to cachefs: at least once
    m.guideFetchedAt = 0
    m.guidePending = 0
    m.teamsScreen = invalid
    m.teamEditScreen = invalid
    m.marketScreen = invalid
    m.gameDialog = invalid
    ' Refresh every 30 minutes while Home is showing (requirements).
    m.gamesTimer = CreateObject("roSGNode", "Timer")
    m.gamesTimer.duration = 1800
    m.gamesTimer.repeat = true
    m.gamesTimer.ObserveField("fire", "onGamesTimer")
    m.gamesTimer.control = "start"
end sub

' Settings -> Show My Teams on Home. Off hides the row and skips the game
' searches and guide downloads behind it; teams stay saved.
sub toggleMyTeamsRow()
    show = not m.store.callFunc("getSettings").showMyTeams
    if m.store.callFunc("setSetting", "showMyTeams", show)
        if show then showToast("My Teams is on the Home screen") else showToast("My Teams is hidden from the Home screen")
    else
        showToast("Couldn't save the change. Storage may be full.")
    end if
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
    requestGames()
end sub

sub requestGames()
    teams = m.store.callFunc("getTeams")
    if teams.Count() = 0 or not m.store.callFunc("getSettings").showMyTeams
        m.games = []
        refreshHome()
        return
    end if
    searchSend("gamesRequest", { id: "home", teams: teams, withGuide: m.guideReady, market: m.store.callFunc("getMarket").key })
end sub

' ---------------------------------------------------------------------------
' Settings -> Local stations

sub openMarkets()
    m.marketScreen = CreateObject("roSGNode", "MarketScreen")
    m.marketScreen.current = m.store.callFunc("getMarket").key
    m.marketScreen.ObserveField("chosen", "onMarketChosen")
    pushOverlay(m.marketScreen)
    searchSend("marketsRequest", { id: "settings" })
end sub

sub onMarketsResult(event as Object)
    if m.marketScreen <> invalid then m.marketScreen.markets = event.GetData().markets
end sub

sub onMarketChosen(event as Object)
    market = event.GetData()
    if m.store.callFunc("setMarket", market)
        if market.key = "" then showToast("Local stations off") else showToast("Local stations: " + market.label)
    else
        showToast("Couldn't save the change. Storage may be full.")
    end if
    if m.marketScreen <> invalid
        screen = m.marketScreen
        m.marketScreen = invalid
        removeOverlay(screen)
    end if
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
    ' Different stations: fetch their guides afresh.
    m.guideFetchedAt = 0
    m.guideReady = false
    requestGames()
end sub

' Network broadcasts: each network channel's short guide goes to cachefs:
' through ApiTask (saveOnly) for SearchTask to read. Refetched when older than
' guideMaxAgeMinutes; when all are in, games are found again with them.
sub fetchNetworkGuides(networks as Object)
    if networks.Count() = 0 or m.guidePending > 0 then return
    cfg = guideRules().myTeams
    if type(cfg) <> "roAssociativeArray" then cfg = {}
    maxAge = toInt(cfg.guideMaxAgeMinutes) * 60
    if maxAge <= 0 then maxAge = 1500
    if nowSeconds() - m.guideFetchedAt < maxAge then return
    listings = toInt(cfg.guideListings)
    if listings <= 0 then listings = 30
    m.guideFetchedAt = nowSeconds()
    m.guidePending = networks.Count()
    for each n in networks
        sendRequest({
            id: "teamGuide"
            action: "get_short_epg"
            params: { stream_id: n.streamId, limit: listings }
            cacheFile: n.guideFile
            saveOnly: true
            maxAgeSeconds: maxAge
            timeoutMs: 20000
        })
    end for
end sub

sub onTeamGuide(res as Object)
    if not res.ok then print "[main] couldn't get a network guide for My Teams: "; res.error
    m.guidePending = m.guidePending - 1
    if m.guidePending > 0 then return
    m.guideReady = true
    requestGames()
end sub

sub onGamesTimer()
    if m.section = "home" and m.overlays.Count() = 0 then requestGames()
end sub

' Replays: a matchup already seen (started) in the last few days, at least
' six hours earlier, is labelled Replay. Games that have started are
' remembered for next time.
sub onGamesResult(event as Object)
    result = event.GetData()
    if result.id <> "home" then return
    now = nowSeconds()
    seen = {}
    for each s in m.store.callFunc("getSeenGames")
        seen[s.key] = toInt(s.start)
    end for
    started = []
    for each g in result.games
        key = matchupKey(g)
        earlier = seen[key]
        if earlier <> invalid and earlier < g.start - 6 * 3600 then g.replay = true
        if g.start <= now and not g.replay then started.Push({ key: key, start: g.start })
    end for
    if started.Count() > 0 then m.store.callFunc("recordSeenGames", started)
    m.games = result.games
    refreshHome()
    if type(result.networks) = "roArray" then fetchNetworkGuides(result.networks)
end sub

' Same team, same opponents in the same order of words: "Alabama vs. Texas".
function matchupKey(game as Object) as String
    key = CreateObject("roRegex", "[^a-z0-9]+", "").ReplaceAll(LCase(game.title), " ").Trim()
    return game.teamId + "|" + key
end function

' A game card was chosen. More than 15 minutes before the start, say so
' first: event channels usually aren't on until shortly before the game
' (this provider refuses them with HTTP 407 until then).
sub onGameSelected(item as Object)
    ' Usage ordering: choosing a team's game is a use of that team (the ID is
    ' in the card's key, "game:<teamId>|<start>").
    teamId = Mid(asString(item.itemKey), 6)
    bar = Instr(1, teamId, "|")
    if bar > 0 then m.store.callFunc("recordUsage", "t" + Left(teamId, bar - 1))

    if toInt(item.start) > nowSeconds() + 900
        dlg = CreateObject("roSGNode", "StandardMessageDialog")
        dlg.title = item.name
        dlg.message = ["Starts " + formatDayTime(toInt(item.start)) + ". Event channels usually aren't on until shortly before the game."]
        dlg.buttons = ["Play anyway", "Cancel"]
        dlg.ObserveField("buttonSelected", "onEarlyGameChoice")
        dlg.ObserveField("wasClosed", "onGameDialogClosed")
        m.gameDialog = { dialog: dlg, item: item, early: true }
        m.top.dialog = dlg
        return
    end if
    chooseGameChannel(item)
end sub

sub onEarlyGameChoice()
    d = m.gameDialog
    if d = invalid or not isTrue(d.early) then return
    m.gameDialog = invalid
    choice = d.dialog.buttonSelected
    d.dialog.close = true
    if choice = 0 then chooseGameChannel(d.item)
end sub

' Play the game's channel, or offer the channels carrying it.
sub chooseGameChannel(item as Object)
    channels = item.channels
    if type(channels) <> "roArray" or channels.Count() = 0 then return
    if channels.Count() = 1
        playLive(channels[0])
        return
    end if
    buttons = []
    shown = []
    for each c in channels
        if buttons.Count() < 6
            buttons.Push(localizeName(c.name))
            shown.Push(c)
        end if
    end for
    dlg = CreateObject("roSGNode", "StandardMessageDialog")
    dlg.title = item.name
    dlg.message = ["Channels showing this game:"]
    dlg.buttons = buttons
    dlg.ObserveField("buttonSelected", "onGameChannelChosen")
    dlg.ObserveField("wasClosed", "onGameDialogClosed")
    m.gameDialog = { dialog: dlg, channels: shown }
    m.top.dialog = dlg
end sub

sub onGameChannelChosen()
    d = m.gameDialog
    if d = invalid then return
    m.gameDialog = invalid
    choice = d.dialog.buttonSelected
    d.dialog.close = true
    if choice >= 0 and choice < d.channels.Count() then playLive(d.channels[choice])
end sub

sub onGameDialogClosed()
    m.gameDialog = invalid
end sub

' ---------------------------------------------------------------------------
' Settings -> My Teams

sub openTeams()
    m.teamsScreen = CreateObject("roSGNode", "TeamsScreen")
    m.teamsScreen.ObserveField("chosen", "onTeamChosen")
    m.teamsScreen.teams = m.store.callFunc("getTeams")
    pushOverlay(m.teamsScreen)
end sub

sub onTeamChosen(event as Object)
    choice = event.GetData()
    m.teamEditScreen = CreateObject("roSGNode", "TeamEditScreen")
    m.teamEditScreen.ObserveField("save", "onTeamSave")
    m.teamEditScreen.ObserveField("remove", "onTeamRemove")
    if choice.action = "edit" then m.teamEditScreen.team = choice.team
    pushOverlay(m.teamEditScreen)
end sub

sub onTeamSave(event as Object)
    saved = m.store.callFunc("saveTeam", event.GetData())
    if saved = invalid
        showToast("Couldn't save the team. Storage may be full.")
        return
    end if
    showToast("Saved " + saved.name)
    closeTeamEdit()
end sub

sub onTeamRemove(event as Object)
    if m.store.callFunc("deleteTeam", event.GetData()) then showToast("Team removed") else showToast("Couldn't save the change. Storage may be full.")
    closeTeamEdit()
end sub

sub closeTeamEdit()
    if m.teamEditScreen <> invalid
        screen = m.teamEditScreen
        m.teamEditScreen = invalid
        removeOverlay(screen)
    end if
    if m.teamsScreen <> invalid then m.teamsScreen.teams = m.store.callFunc("getTeams")
    requestGames()
end sub
