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
    m.logoPending = {}          ' team ID -> true while its logo is being looked up
    m.marketScreen = invalid
    m.gameDialog = invalid
    ' Refresh every 30 minutes while Home is showing (requirements).
    m.gamesTimer = CreateObject("roSGNode", "Timer")
    m.gamesTimer.duration = 1800
    m.gamesTimer.repeat = true
    m.gamesTimer.ObserveField("fire", "onGamesTimer")
    m.gamesTimer.control = "start"

    ' Live scores (Settings -> Live scores on My Teams): game key -> line.
    m.scores = {}
    m.scoresPending = 0
    m.scoresFiles = []
    m.scoresTimer = CreateObject("roSGNode", "Timer")
    m.scoresTimer.repeat = true
    m.scoresTimer.ObserveField("fire", "onScoresTimer")
    m.top.AppendChild(m.scoresTimer)
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

' Settings -> Show teams with no game: cards at the end of the row for teams
' with nothing in the next 24 hours.
sub toggleNoGameTeams()
    show = not m.store.callFunc("getSettings").showNoGameTeams
    if m.store.callFunc("setSetting", "showNoGameTeams", show)
        if show then showToast("Teams with no game will show in My Teams") else showToast("Only teams with a game will show in My Teams")
    else
        showToast("Couldn't save the change. Storage may be full.")
    end if
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
    refreshHome()
end sub

sub requestGames()
    teams = m.store.callFunc("getTeams")
    if teams.Count() = 0 or not m.store.callFunc("getSettings").showMyTeams
        m.games = []
        refreshHome()
        return
    end if
    lookupTeamLogos()
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

' Until the channel and category lists are in, the list is empty; it's
' asked for again after each (re)index while the screen is open.
sub onMarketsResult(event as Object)
    if m.marketScreen = invalid then return
    result = event.GetData()
    m.marketScreen.loading = (result.markets.Count() = 0)
    m.marketScreen.markets = result.markets
end sub

sub refreshMarketsScreen()
    if m.marketScreen <> invalid and m.marketScreen.loading then searchSend("marketsRequest", { id: "settings" })
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
    onMarketChangedForCatalog()
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
    ' get_short_epg is capped by some providers (this one sends 4 listings,
    ' a few hours); get_simple_data_table is the channel's whole schedule.
    action = asString(cfg.guideAction)
    if action = "" then action = "get_short_epg"
    m.guideFetchedAt = nowSeconds()
    m.guidePending = networks.Count()
    for each n in networks
        params = { stream_id: n.streamId }
        if action = "get_short_epg" then params.limit = listings
        sendRequest({
            id: "teamGuide"
            priority: "low"
            action: action
            params: params
            cacheFile: n.guideFile
            saveOnly: true
            maxAgeSeconds: maxAge
            timeoutMs: 30000
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

' Replays: a matchup already seen (started) 6 to 15 hours earlier is
' labelled Replay: rebroadcasts air later that night or the next morning,
' while the next game of a series (the same matchup again) is at least
' about 17 hours later (a night game, then an afternoon one), and a
' doubleheader's second game under 6. Titles that say replay are labelled
' by the guide rules (MyTeams.brs). Games that have started are remembered
' for next time.
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
        if earlier <> invalid
            gap = g.start - earlier
            if gap > 6 * 3600 and gap < 15 * 3600 then g.replay = true
        end if
        if g.start <= now and not g.replay then started.Push({ key: key, start: g.start })
    end for
    if started.Count() > 0 then m.store.callFunc("recordSeenGames", started)
    m.games = result.games
    refreshHome()
    fetchScores()
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
    team = invalid
    if choice.action = "edit" then team = choice.team
    openTeamEdit(team)
end sub

' team: the team to edit, or invalid to add one.
sub openTeamEdit(team as Dynamic)
    m.teamEditScreen = CreateObject("roSGNode", "TeamEditScreen")
    m.teamEditScreen.ObserveField("save", "onTeamSave")
    m.teamEditScreen.ObserveField("remove", "onTeamRemove")
    m.teamEditScreen.ObserveField("lookupLogo", "onTeamLogoAgain")
    if team <> invalid then m.teamEditScreen.team = team
    if team <> invalid
        if m.logoPending.DoesExist(team.id)
            m.teamEditScreen.logoStatus = "looking"
        else if asString(team.logoFor) = team.name
            m.teamEditScreen.logoStatus = logoStatusFor(asString(team.logo))
        end if
    end if
    pushOverlay(m.teamEditScreen)
end sub

' A "no game" card on Home: open that team's settings (e.g. to fix aliases).
sub onNoGameTeamSelected(item as Object)
    teamId = Mid(asString(item.itemKey), 6)     ' "team:<id>"
    for each t in m.store.callFunc("getTeams")
        if t.id = teamId
            openTeamEdit(t)
            return
        end if
    end for
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

' ---------------------------------------------------------------------------
' Team logos (TheSportsDB, rules in data/guide-rules.json "myTeams.logos").
' Looked up once per team name: by the name, then each alias, keeping the
' first result in one of the team's sports. The card's Poster loads the
' image itself.

' Teams never looked up, or renamed since.
sub lookupTeamLogos()
    for each t in m.store.callFunc("getTeams")
        if asString(t.logoFor) <> t.name and not m.logoPending.DoesExist(t.id) then lookupTeamLogo(t)
    end for
end sub

sub lookupTeamLogo(team as Object)
    cfg = logoRules()
    if cfg = invalid then return
    names = [team.name]
    for each alias in team.aliases
        names.Push(alias)
    end for
    m.logoPending[team.id] = true
    if m.teamEditScreen <> invalid then m.teamEditScreen.logoStatus = "looking"
    requestTeamLogo({ teamId: team.id, teamName: team.name, sports: team.sports, names: names, index: 0 })
end sub

sub requestTeamLogo(ctx as Object)
    sendRequest({
        id: "teamLogo"
        priority: "low"
        url: logoRules().searchUrl + urlEncode(ctx.names[ctx.index])
        context: ctx
        timeoutMs: 15000
    })
end sub

function logoRules() as Dynamic
    cfg = guideRules().myTeams
    if type(cfg) <> "roAssociativeArray" or type(cfg.logos) <> "roAssociativeArray" or asString(cfg.logos.searchUrl) = "" then return invalid
    return cfg.logos
end function

sub onTeamLogo(res as Object)
    ctx = res.context
    if not res.ok
        ' Offline or the service is down: try again next time games refresh.
        print "[main] couldn't look up a logo for "; ctx.teamName; ": "; res.error
        m.logoPending.Delete(ctx.teamId)
        if m.teamEditScreen <> invalid then m.teamEditScreen.logoStatus = "failed"
        return
    end if
    logo = pickTeamLogo(res.data, ctx.sports)
    if logo = "" and ctx.index + 1 < ctx.names.Count()
        ctx.index = ctx.index + 1
        requestTeamLogo(ctx)
        return
    end if
    m.logoPending.Delete(ctx.teamId)
    if logo = "" then print "[main] no logo found for "; ctx.teamName else print "[main] logo found for "; ctx.teamName
    m.store.callFunc("setTeamLogo", ctx.teamId, logo, ctx.teamName)
    if m.teamEditScreen <> invalid then m.teamEditScreen.logoStatus = logoStatusFor(logo)
    refreshHome()
end sub

' searchteams.php -> { teams: [{ strTeam, strSport, strBadge }] } or teams null.
' The first team in one of the team's sports (any sport if none set).
function pickTeamLogo(data as Dynamic, sports as Object) as String
    if type(data) <> "roAssociativeArray" or type(data.teams) <> "roArray" then return ""
    cfg = logoRules()
    wanted = {}
    for each s in sports
        name = cfg.sports[s]
        if name <> invalid then wanted[LCase(name)] = true
    end for
    for each team in data.teams
        if type(team) = "roAssociativeArray"
            badge = asString(team.strBadge)
            if badge <> "" and (wanted.Count() = 0 or wanted.DoesExist(LCase(asString(team.strSport)))) then return badge + asString(cfg.imageSuffix)
        end if
    end for
    return ""
end function

function logoStatusFor(logo as String) as String
    if logo = "" then return "none"
    return "found"
end function

' Settings -> My Teams -> a team -> Logo: look it up again.
sub onTeamLogoAgain(event as Object)
    teamId = event.GetData()
    for each t in m.store.callFunc("getTeams")
        if t.id = teamId and not m.logoPending.DoesExist(t.id) then lookupTeamLogo(t)
    end for
end sub

' Settings -> My Teams on Home: After Favorites (default) or First. The row
' stays in that place.
sub toggleMyTeamsFirst()
    first = not m.store.callFunc("getSettings").myTeamsFirst
    if m.store.callFunc("setSetting", "myTeamsFirst", first)
        if first then showToast("My Teams is now first on Home") else showToast("My Teams is now after Favorites on Home")
    else
        showToast("Couldn't save the change. Storage may be full.")
    end if
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
    refreshHome()
end sub

' ---------------------------------------------------------------------------
' Live scores on game cards, from ESPN's scoreboards (data/guide-rules.json
' myTeams.scores). Only while Home is showing a live game that isn't a
' replay, every refreshSeconds; each league's scoreboard goes to cachefs:
' (saveOnly) and SearchTask matches it to the games (findScores). Anything
' missing just means no score line.

function scoresRules() as Dynamic
    cfg = guideRules().myTeams
    if type(cfg) <> "roAssociativeArray" or type(cfg.scores) <> "roAssociativeArray" then return invalid
    return cfg.scores
end function

' The live games scores are wanted for: [{ key, sport, names, start }].
function scoreGames() as Object
    list = []
    if not m.store.callFunc("getSettings").showScores then return list
    aliases = {}
    for each t in m.store.callFunc("getTeams")
        names = [asString(t.name)]
        if type(t.aliases) = "roArray" then names.Append(t.aliases)
        aliases[asString(t.id)] = names
    end for
    for each g in m.games
        if isTrue(g.live) and not isTrue(g.replay)
            names = aliases[asString(g.teamId)]
            if names = invalid then names = [asString(g.teamName)]
            list.Push({ key: g.key, sport: asString(g.sport), names: names, start: toInt(g.start) })
        end if
    end for
    return list
end function

sub fetchScores()
    rules = scoresRules()
    games = scoreGames()
    if rules = invalid or games.Count() = 0
        m.scoresTimer.control = "stop"
        if m.scores.Count() > 0
            m.scores = {}
            refreshHome()
        end if
        return
    end if
    seconds = toInt(rules.refreshSeconds)
    if seconds < 20 then seconds = 45
    if m.scoresTimer.duration <> seconds then m.scoresTimer.duration = seconds
    m.scoresTimer.control = "start"
    if m.scoresPending > 0 then return
    ' One request per league of the sports being played.
    sports = {}
    for each g in games
        sports[g.sport] = true
    end for
    m.scoresFiles = []
    requests = []
    for each sport in sports
        leagues = rules.leagues[sport]
        if type(leagues) = "roArray"
            for each league in leagues
                file = "cachefs:/teams/scores_" + safeKey(asString(league)) + ".json"
                m.scoresFiles.Push(file)
                requests.Push({ id: "teamScores", url: asString(rules.url).Replace("{league}", asString(league)), cacheFile: file, saveOnly: true, timeoutMs: 20000 })
            end for
        end if
    end for
    m.scoresPending = requests.Count()
    for each r in requests
        sendRequest(r)
    end for
end sub

sub onScoresTimer()
    if m.section = "home" and m.overlays.Count() = 0 then fetchScores()
end sub

sub onTeamScores(res as Object)
    if not res.ok then print "[main] couldn't get a scoreboard for live scores: "; res.error
    m.scoresPending = m.scoresPending - 1
    if m.scoresPending > 0 then return
    games = scoreGames()
    if games.Count() > 0 then searchSend("scoresRequest", { id: "home", files: m.scoresFiles, games: games })
end sub

sub onScoresResult(event as Object)
    result = event.GetData()
    if result.id <> "home" or type(result.scores) <> "roAssociativeArray" then return
    m.scores = result.scores
    refreshHome()
end sub

' Settings -> Live scores on My Teams.
sub toggleScores()
    show = not m.store.callFunc("getSettings").showScores
    if m.store.callFunc("setSetting", "showScores", show)
        if show then showToast("Live scores will show on My Teams game cards") else showToast("Live scores are hidden")
    else
        showToast("Couldn't save the change. Storage may be full.")
    end if
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
    m.scores = {}
    fetchScores()
    refreshHome()
end sub
