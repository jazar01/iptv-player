' My Teams: keeps the games list fresh, labels replays, and wires the
' Settings -> My Teams screens. Finding games happens in SearchTask
' (MyTeams.brs); this side decides when to ask and what to do with them.

sub initTeams()
    m.games = []                ' last SearchTask result (see MyTeams.brs)
    m.teamsScreen = invalid
    m.teamEditScreen = invalid
    m.gameDialog = invalid
    ' Refresh every 30 minutes while Home is showing (requirements).
    m.gamesTimer = CreateObject("roSGNode", "Timer")
    m.gamesTimer.duration = 1800
    m.gamesTimer.repeat = true
    m.gamesTimer.ObserveField("fire", "onGamesTimer")
    m.gamesTimer.control = "start"
end sub

sub requestGames()
    teams = m.store.callFunc("getTeams")
    if teams.Count() = 0
        m.games = []
        refreshHome()
        return
    end if
    searchSend("gamesRequest", { id: "home", teams: teams })
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
