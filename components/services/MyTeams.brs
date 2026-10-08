' My Teams: finds saved teams' games (requirements: Later features, My Teams).
' Runs in SearchTask over the live index. Rules: data/guide-rules.json
' "myTeams"; event times: "nameTimes" (Utils).
'
' Two sources, merged into one card per game:
'   Event channels: a channel in an event category whose name mentions a
'     team (name or alias, whole words, no exclusion) and has an event time
'     from lookbackHours ago to aheadHours ahead.
'   Network broadcasts: a program in a network channel's short guide (saved
'     to cachefs: by ApiTask) whose title, or else description, mentions a team.
' Either way the sport must be one of the team's. An event channel whose
' sport can't be told makes a game only if it names the team in full; with
' just an alias it can only join a game found another way. A network program
' must name its sport. A team's
' listings starting within 90 minutes of each other are one game; network
' channels are listed first (always on, unlike event channels).

function teamRules() as Object
    if m.teamRules <> invalid then return m.teamRules
    cfg = {}
    json = ParseJson(ReadAsciiFile("pkg:/data/guide-rules.json"))
    if type(json) = "roAssociativeArray" and type(json.myTeams) = "roAssociativeArray" then cfg = json.myTeams
    rules = {
        eventCategories: regexList(cfg.eventCategories)
        skipCategories: regexList(cfg.skipCategories)
        sportRules: []
        sportLabels: {}
        replay: optionalRegex(cfg.replayWords)
        later: optionalRegex(cfg.laterLanguages)
        separators: optionalRegex(joinPatterns(cfg.separators))
        liveSeconds: hoursToSeconds(cfg.liveHours, 3.5)
        lookbackSeconds: hoursToSeconds(cfg.lookbackHours, 4.0)
        aheadSeconds: hoursToSeconds(cfg.aheadHours, 24.0)
        segments: CreateObject("roRegex", "[:|]", "")
        parens: CreateObject("roRegex", "\([^)]*\)|\[[^\]]*\]", "")
        ranks: CreateObject("roRegex", "#\d+\s*|(^|\s)\d{1,2}\s+(?=[A-Za-z])|^\s*(19|20)\d{2}\s+", "")
        spaces: CreateObject("roRegex", "\s+", "")
        networks: []
        networkAvoid: optionalRegex(cfg.networkAvoid)
        guideListings: toInt(cfg.guideListings)
        guideMaxAgeSeconds: toInt(cfg.guideMaxAgeMinutes) * 60
        base64Titles: true
        titleTags: []
        localCategories: invalid
        localName: invalid
    }
    if asString(cfg.localCategories) <> "" then rules.localCategories = CreateObject("roRegex", cfg.localCategories, "i")
    if asString(cfg.localName) <> "" then rules.localName = CreateObject("roRegex", cfg.localName, "")
    if rules.guideListings <= 0 then rules.guideListings = 30
    if rules.guideMaxAgeSeconds <= 0 then rules.guideMaxAgeSeconds = 1500
    if type(cfg.networks) = "roArray"
        for each n in cfg.networks
            if asString(n.epg) <> "" then rules.networks.Push({ epg: asString(n.epg), label: asString(n.label) })
        end for
    end if
    ' Guide titles: base64 and superscript tags, as for now/next (EpgService).
    if type(json) = "roAssociativeArray"
        if type(json.epg) = "roAssociativeArray" and json.epg.base64Titles <> invalid then rules.base64Titles = isTrue(json.epg.base64Titles)
        if type(json.titleTags) = "roArray"
            for each tag in json.titleTags
                if asString(tag.text) <> "" then rules.titleTags.Push({ text: asString(tag.text), flag: asString(tag.flag) })
            end for
        end if
    end if
    if type(cfg.sportRules) = "roArray"
        for each r in cfg.sportRules
            rules.sportRules.Push({ regex: CreateObject("roRegex", asString(r.pattern), "i"), sport: asString(r.sport) })
        end for
    end if
    if type(cfg.sports) = "roArray"
        for each s in cfg.sports
            rules.sportLabels[asString(s.id)] = asString(s.label)
        end for
    end if
    m.teamRules = rules
    return rules
end function

function regexList(patterns as Dynamic) as Object
    list = []
    if type(patterns) = "roArray"
        for each p in patterns
            list.Push(CreateObject("roRegex", asString(p), "i"))
        end for
    end if
    return list
end function

function optionalRegex(pattern as Dynamic) as Dynamic
    if asString(pattern) = "" then return invalid
    return CreateObject("roRegex", asString(pattern), "i")
end function

function joinPatterns(patterns as Dynamic) as String
    out = ""
    if type(patterns) <> "roArray" then return out
    for each p in patterns
        if out <> "" then out += "|"
        out += asString(p)
    end for
    return out
end function

function hoursToSeconds(hours as Dynamic, fallback as Float) as Integer
    h = Val(asString(hours))
    if h <= 0 then h = fallback
    return Int(h * 3600)
end function

function anyMatch(list as Object, text as String) as Boolean
    for each re in list
        if re.IsMatch(text) then return true
    end for
    return false
end function

' Characters with a meaning in regexes, escaped so a team name matches literally.
function escapeRegex(text as String) as String
    special = "\^$.|?*+()[]{}"
    out = ""
    for i = 1 to text.Len()
        ch = Mid(text, i, 1)
        if Instr(1, special, ch) > 0 then out += "\"
        out += ch
    end for
    return out
end function

function wordRegex(phrase as String) as Object
    return CreateObject("roRegex", "\b" + escapeRegex(phrase.Trim()) + "\b", "i")
end function

' The cached live category list (Live TV's, also fetched with the search
' catalog), or invalid if it isn't on disk or doesn't parse.
function liveCategoriesPath() as String
    return "cachefs:/catalog/live_categories.json"
end function

function liveCategories() as Dynamic
    path = liveCategoriesPath()
    if not CreateObject("roFileSystem").Exists(path) then return invalid
    cats = ParseJson(ReadAsciiFile(path))
    if type(cats) <> "roArray" then return invalid
    return cats
end function

' Category ID -> name, for event categories only (from the cached list).
function eventCategoryNames() as Object
    if m.eventCategories <> invalid then return m.eventCategories
    names = {}
    rules = teamRules()
    cats = liveCategories()
    if cats = invalid then return names     ' not downloaded yet: not remembered
    for each c in cats
        if type(c) = "roAssociativeArray"
            name = asString(c.category_name)
            if anyMatch(rules.eventCategories, name) and not anyMatch(rules.skipCategories, name) then names[asString(c.category_id)] = name
        end if
    end for
    m.eventCategories = names
    return names
end function

' req: { id, teams: [{ id, name, aliases[], exclusions[], sports[] }] }
' -> { id, ready, games: [{ key, teamId, teamName, title, sport, sportLabel,
'      start, live, replay, channels: [{ streamId, name, epgChannelId }] }] }
' Live games first, then by start time.
function findGames(req as Object) as Object
    result = { id: req.id, ready: m.index.live.Count() > 0, games: [] }
    if not result.ready or type(req.teams) <> "roArray" or req.teams.Count() = 0 then return result
    rules = teamRules()
    categories = eventCategoryNames()
    now = nowSeconds()
    timer = CreateObject("roTimespan")
    m.teamSkips = []            ' listings naming a team that didn't make a game (logged)

    teams = []
    for each t in req.teams
        matchers = [wordRegex(asString(t.name))]
        for each alias in asArray(t.aliases)
            if asString(alias).Trim() <> "" then matchers.Push(wordRegex(asString(alias)))
        end for
        exclusions = []
        for each phrase in asArray(t.exclusions)
            if asString(phrase).Trim() <> "" then exclusions.Push(wordRegex(asString(phrase)))
        end for
        sports = {}
        for each s in asArray(t.sports)
            sports[asString(s)] = true
        end for
        teams.Push({ id: asString(t.id), name: asString(t.name), nameMatcher: matchers[0], matchers: matchers, exclusions: exclusions, sports: sports })
    end for

    groups = {}
    weak = []
    for each e in m.index.live
        categoryName = categories[e.categoryId]
        if categoryName <> invalid
            for each t in teams
                ' Team words first: cheap, and rules out almost every channel.
                if anyMatch(t.matchers, e.name) and not anyMatch(t.exclusions, e.name)
                    found = findNameTime(e.name, false)
                    if found = invalid
                        noteSkip(e.name, "no date and time in the name")
                    else if found.utc < now - rules.lookbackSeconds or found.utc > now + rules.aheadSeconds
                        noteSkip(e.name, "starts " + formatDayTime(found.utc) + ", outside the window")
                    end if
                    if found <> invalid and found.utc >= now - rules.lookbackSeconds and found.utc <= now + rules.aheadSeconds
                        sport = detectSport(LCase(categoryName + " " + e.name), rules)
                        replay = rules.replay <> invalid and rules.replay.IsMatch(e.name)
                        later = rules.later <> invalid and rules.later.IsMatch(e.name)
                        info = { start: found.utc, ends: 0, title: gameTitle(e.name, found.text, t, rules), sport: sport, replay: replay }
                        channel = { streamId: e.itemId, name: e.name, epgChannelId: e.epgChannelId, network: false, later: later }
                        if sport <> ""
                            if t.sports.Count() = 0 or t.sports.DoesExist(sport) then mergeGame(groups, t, info, channel, now, rules) else noteSkip(e.name, "sport " + sport + " isn't one of " + t.name + "'s")
                        else if t.nameMatcher.IsMatch(e.name)
                            mergeGame(groups, t, info, channel, now, rules)
                        else
                            ' Unknown sport and only an alias ("Atlanta"): too weak to
                            ' be a game on its own; it may join one found another way.
                            weak.Push({ team: t, info: info, channel: channel })
                            noteSkip(e.name, "sport unknown and only an alias matched (can only join a game)")
                        end if
                    end if
                end if
            end for
        else
            ' Not an event category: say so if it looks like a game listing.
            for each t in teams
                if anyMatch(t.matchers, e.name) and findNameTime(e.name, false) <> invalid then noteSkip(e.name, "category " + e.categoryId + " isn't an event category")
            end for
        end if
    end for

    result.networks = resolveNetworks(req.market)
    if isTrue(req.withGuide) then addNetworkGames(groups, teams, result.networks, now, rules)

    ' Weak listings only add channels to games already found.
    for each w in weak
        if findGameGroup(groups, w.team, w.info, true) <> invalid then mergeGame(groups, w.team, w.info, w.channel, now, rules)
    end for

    live = []
    later = []
    for each key in groups
        g = groups[key]
        g.replay = (g.replayChannels = g.channels.Count())
        g.channels = sortChannels(g.channels)
        g.Delete("replayChannels")
        if g.live then live.Push(g) else later.Push(g)
    end for
    live.SortBy("start")
    later.SortBy("start")
    result.games.Append(live)
    result.games.Append(later)
    print "[teams] "; result.games.Count(); " game(s) for "; teams.Count(); " team(s), guide "; isTrue(req.withGuide); ", "; result.networks.Count(); " networks, market '"; asString(req.market); "' ("; timer.TotalMilliseconds(); " ms)"
    locals = ""
    for each n in result.networks
        if Instr(1, n.label, "(") > 0
            if locals <> "" then locals += ", "
            locals += n.label
        end if
    end for
    if locals <> "" then print "[teams]   local stations: "; locals
    for each s in m.teamSkips
        print "[teams]   skipped: "; s
    end for
    for each g in result.games
        names = ""
        for each c in g.channels
            if names <> "" then names += ", "
            names += c.name
        end for
        print "[teams]   "; g.title; " | "; g.sportLabel; " | "; formatDayTime(g.start); " | live "; g.live; " | "; Left(names, 160)
    end for
    return result
end function

' Why a listing naming a team didn't become a game, for the console (first 20).
sub noteSkip(name as String, reason as String)
    if m.teamSkips <> invalid and m.teamSkips.Count() < 20 then m.teamSkips.Push(Left(name, 100) + "  -- " + reason)
end sub

' info: { start, ends (0 if unknown), title, sport, replay }
' channel: { streamId, name, epgChannelId, network, later }
' A team's listings of the same sport starting within 90 minutes of each
' other are one game (one may include the pregame); it keeps the earliest
' start. A listing whose sport isn't known joins the nearest such game. A network
' listing's title and end time win, since guides are more exact than
' channel names.
sub mergeGame(groups as Object, team as Object, info as Object, channel as Object, now as Integer, rules as Object)
    g = findGameGroup(groups, team, info, false)
    if g = invalid
        g = {
            key: team.id + "|" + info.start.ToStr() + "|" + info.sport     ' two sports can start together
            teamId: team.id
            teamName: team.name
            title: info.title
            sport: info.sport
            sportLabel: asString(rules.sportLabels[info.sport])
            start: info.start
            ends: info.ends
            replayChannels: 0
            channels: []
        }
        groups[g.key] = g
    else
        if info.start < g.start then g.start = info.start
        if channel.network
            g.title = info.title
            if info.ends > 0 then g.ends = info.ends
        end if
        if g.sport = "" and info.sport <> ""
            g.sport = info.sport
            g.sportLabel = asString(rules.sportLabels[info.sport])
        end if
    end if
    ends = g.ends
    if ends <= 0 then ends = g.start + rules.liveSeconds
    g.live = (now >= g.start and now < ends)
    for each c in g.channels
        if c.streamId = channel.streamId then return     ' listed twice: count it once
    end for
    if info.replay then g.replayChannels = g.replayChannels + 1
    g.channels.Push(channel)
end sub

' The team's game starting within 90 minutes of info.start whose sport fits
' (same sport, or either one unknown), the nearest if several; invalid if
' none. strict: also invalid when several fit (a weak listing must not
' guess between, say, a football and a volleyball game).
function findGameGroup(groups as Object, team as Object, info as Object, strict as Boolean) as Dynamic
    best = invalid
    fits = 0
    for each key in groups
        g = groups[key]
        gap = Abs(g.start - info.start)
        if g.teamId = team.id and gap <= 5400 and (g.sport = "" or info.sport = "" or g.sport = info.sport)
            fits = fits + 1
            if best = invalid or gap < Abs(best.start - info.start) then best = g
        end if
    end for
    if strict and fits > 1 then return invalid
    return best
end function

' Live channels sharing a guide ID (HD, SD and backup copies of one feed),
' or invalid. The lookup is built once per index.
function epgGroup(epgChannelId as String) as Dynamic
    if m.epgGroups = invalid
        m.epgGroups = {}
        for each e in m.index.live
            if e.epgChannelId <> "" then addToGroup(m.epgGroups, LCase(e.epgChannelId), e)
        end for
    end if
    return m.epgGroups[LCase(epgChannelId)]
end function

' ---------------------------------------------------------------------------
' Network broadcasts

' The configured network channels that exist in the catalog:
' [{ label, streamId, name, epgChannelId, guideFile }]. Among channels with
' the guide ID, the first whose name doesn't match networkAvoid.
function resolveNetworks(market as Dynamic) as Object
    rules = teamRules()
    list = []
    seen = {}
    for each n in rules.networks
        group = epgGroup(n.epg)
        if group <> invalid
            chosen = preferredCopy(group, rules)
            seen[LCase(chosen.epgChannelId)] = true
            list.Push({ label: n.label, streamId: chosen.itemId, name: chosen.name, epgChannelId: chosen.epgChannelId, guideFile: networkGuideFile(chosen.itemId) })
        end if
    end for
    ' The device's market: its ABC, CBS, NBC and FOX stations.
    stations = localStations()[asString(market)]
    if stations <> invalid
        for each s in stations
            epg = LCase(s.entry.epgChannelId)
            if epg = "" or not seen.DoesExist(epg)
                if epg <> "" then seen[epg] = true
                list.Push({ label: s.label, streamId: s.entry.itemId, name: s.entry.name, epgChannelId: s.entry.epgChannelId, guideFile: networkGuideFile(s.entry.itemId) })
            end if
        end for
    end if
    return list
end function

' Among copies of one feed, the first whose name doesn't match networkAvoid.
function preferredCopy(group as Object, rules as Object) as Object
    chosen = group[0]
    for i = group.Count() - 1 to 0 step -1
        if rules.networkAvoid = invalid or not rules.networkAvoid.IsMatch(group[i].name) then chosen = group[i]
    end for
    return chosen
end function

' ---------------------------------------------------------------------------
' Local markets, from the provider's local-station channels
' ("GA | Atlanta | ABC 2 WSB" in "US | Local ABC").

' { "GA|Atlanta": [{ network, label: "ABC (WSB)", entry }] }, built once per index.
function localStations() as Object
    if m.localStations <> invalid then return m.localStations
    rules = teamRules()
    if rules.localCategories = invalid or rules.localName = invalid then return {}
    ' Not remembered until both lists are in, so a later download is used.
    cats = liveCategories()
    if cats = invalid or m.index.live.Count() = 0 then return {}
    m.localStations = {}

    networkOf = {}      ' category ID -> "ABC"
    for each c in cats
        if type(c) = "roAssociativeArray"
            found = rules.localCategories.Match(asString(c.category_name))
            if found.Count() > 1 then networkOf[asString(c.category_id)] = UCase(found[1])
        end if
    end for

    byEpg = {}          ' one channel per station feed, per market
    for each e in m.index.live
        network = networkOf[e.categoryId]
        if network <> invalid
            parts = rules.localName.Match(e.name)
            if parts.Count() > 3
                key = parts[1] + "|" + parts[2].Trim()
                words = parts[3].Trim().Split(" ")
                callSign = words[words.Count() - 1]
                feed = key + "|" + LCase(e.epgChannelId)
                if e.epgChannelId = "" then feed = key + "|" + e.itemId.ToStr()
                previous = byEpg[feed]
                if previous = invalid or (rules.networkAvoid <> invalid and rules.networkAvoid.IsMatch(previous.entry.name) and not rules.networkAvoid.IsMatch(e.name))
                    station = { network: network, label: network + " (" + callSign + ")", entry: e }
                    if previous = invalid
                        if m.localStations[key] = invalid then m.localStations[key] = []
                        m.localStations[key].Push(station)
                        byEpg[feed] = station
                    else
                        previous.label = station.label
                        previous.entry = e
                    end if
                end if
            end if
        end if
    end for
    return m.localStations
end function

' [{ key: "GA|Atlanta", label: "Atlanta, GA", stations: "ABC, CBS, FOX, NBC" }],
' sorted by label.
function listMarkets() as Object
    markets = []
    all = localStations()
    for each key in all
        networks = {}
        for each s in all[key]
            networks[s.network] = true
        end for
        names = ""
        for each n in ["ABC", "CBS", "NBC", "FOX"]
            if networks.DoesExist(n)
                if names <> "" then names += ", "
                names += n
            end if
        end for
        bar = Instr(1, key, "|")
        markets.Push({ key: key, label: Mid(key, bar + 1) + ", " + Left(key, bar - 1), stations: names })
    end for
    markets.SortBy("label")
    return markets
end function

function networkGuideFile(streamId as Integer) as String
    ' "schedule": the whole-schedule guide (guideAction), not the old short one.
    return "cachefs:/teams/schedule_" + streamId.ToStr() + ".json"
end function

sub addNetworkGames(groups as Object, teams as Object, networks as Object, now as Integer, rules as Object)
    for each n in networks
        json = ParseJson(ReadAsciiFile(n.guideFile))
        if type(json) = "roAssociativeArray" and type(json.epg_listings) = "roArray"
            for each listing in json.epg_listings
                ' A non-object entry gets no times, so it's skipped below.
                start = 0
                ends = 0
                if type(listing) = "roAssociativeArray"
                    start = toInt(listing.start_timestamp)
                    ends = toInt(listing.stop_timestamp)
                end if
                if start > 0 and ends > now and start <= now + rules.aheadSeconds
                    title = guideText(listing.title, rules)
                    description = guideText(listing.description, rules)
                    ' A description only counts when the title is a game
                    ' ("College Football", "Braves at Dodgers"), not a talk
                    ' show that mentions teams in passing.
                    titleIsGame = detectSport(LCase(title), rules) <> "" or (rules.separators <> invalid and rules.separators.IsMatch(title))
                    for each t in teams
                        inTitle = anyMatch(t.matchers, title)
                        inDescription = not inTitle and titleIsGame and anyMatch(t.matchers, description)
                        text = title + " " + description
                        if (inTitle or inDescription) and not anyMatch(t.exclusions, text)
                            ' Network programs must name their sport ("MLB Baseball",
                            ' "WNBA Basketball"), which keeps out news and talk shows.
                            sport = detectSport(LCase(text), rules)
                            if sport = "" then noteSkip(n.label + ": " + title, "guide listing doesn't name its sport")
                            if sport <> "" and (t.sports.Count() = 0 or t.sports.DoesExist(sport))
                                replay = rules.replay <> invalid and rules.replay.IsMatch(title)
                                ' Matchup from the title, or from the description's first sentence.
                                source = title
                                if inDescription
                                    source = description
                                    periodAt = Instr(1, source, ". ")
                                    if periodAt > 0 then source = Left(source, periodAt - 1)
                                end if
                                mergeGame(groups, t, {
                                    start: start
                                    ends: ends
                                    title: gameTitle(source, "", t, rules)
                                    sport: sport
                                    replay: replay
                                }, { streamId: n.streamId, name: n.label, epgChannelId: n.epgChannelId, network: true, later: false }, now, rules)
                            end if
                        end if
                    end for
                end if
            end for
        end if
    end for
end sub

' Guide text: base64-decoded (if the rules say so), superscript tags removed.
function guideText(value as Dynamic, rules as Object) as String
    text = asString(value)
    if rules.base64Titles and text <> ""
        bytes = CreateObject("roByteArray")
        bytes.FromBase64String(text)
        decoded = bytes.ToAsciiString()
        if decoded <> "" then text = decoded
    end if
    for each tag in rules.titleTags
        text = text.Replace(tag.text, " ")
    end for
    return text.Trim()
end function

function detectSport(text as String, rules as Object) as String
    for each r in rules.sportRules
        if r.regex.IsMatch(text) then return r.sport
    end for
    return ""
end function

' "NCAAF 01: #7 Alabama vs. #16 Mississippi State @ 3 Oct 12:00 PM ET"
'   -> "Alabama vs. Mississippi State": the ':' or '|' segment that mentions
' the team, without the time, labels in brackets or rankings.
function gameTitle(name as String, timeText as String, team as Object, rules as Object) as String
    text = name
    if timeText <> "" then text = name.Replace(timeText, " ")
    chosen = ""
    for each segment in rules.segments.Split(text)
        if chosen = "" and anyMatch(team.matchers, segment) then chosen = segment
    end for
    if chosen = "" then chosen = text
    chosen = rules.parens.ReplaceAll(chosen, " ")
    chosen = rules.ranks.ReplaceAll(chosen, " ")
    chosen = rules.spaces.ReplaceAll(chosen, " ").Trim()
    if chosen = "" then return team.name
    return chosen
end function

' Network channels first (always on), then main-language event channels,
' then the rest, keeping provider order within each.
function sortChannels(channels as Object) as Object
    networks = []
    first = []
    rest = []
    for each c in channels
        later = c.later
        c.Delete("later")
        if c.network
            networks.Push(c)
        else if later
            rest.Push(c)
        else
            first.Push(c)
        end if
    end for
    networks.Append(first)
    networks.Append(rest)
    return networks
end function

function asArray(value as Dynamic) as Object
    if type(value) = "roArray" then return value
    return []
end function

' ---------------------------------------------------------------------------
' Live scores (ESPN scoreboards saved by ApiTask; rules: myTeams.scores).
' req: { id, files: [paths], games: [{ key, names: [team name, aliases...], start }] }
' -> { id, scores: { "<game key>": "LAD 3 - ATL 1   Top 8th" } }. A game is
' matched by a competitor's name (display name, short name, or location plus
' nickname) and a start within 12 hours of the listing's. Games not found,
' or not started, get no line: the card keeps its usual text.
function findScores(req as Object) as Object
    result = { id: req.id, scores: {} }
    if type(req.games) <> "roArray" or type(req.files) <> "roArray" then return result
    for each file in req.files
        board = ParseJson(ReadAsciiFile(asString(file)))
        if type(board) = "roAssociativeArray" and type(board.events) = "roArray"
            for each ev in board.events
                line = scoreLine(ev)
                if line.text <> ""
                    for each g in req.games
                        if not result.scores.DoesExist(g.key) and Abs(line.start - toInt(g.start)) < 12 * 3600 and namesMatch(g.names, line.names)
                            result.scores[g.key] = line.text
                        end if
                    end for
                end if
            end for
        end if
    end for
    return result
end function

' One ESPN event -> { text, start, names }; text "" before it starts.
function scoreLine(ev as Dynamic) as Object
    out = { text: "", start: 0, names: [] }
    if type(ev) <> "roAssociativeArray" or type(ev.competitions) <> "roArray" or ev.competitions.Count() = 0 then return out
    comp = ev.competitions[0]
    if type(comp) <> "roAssociativeArray" or type(comp.competitors) <> "roArray" then return out
    status = comp.status
    if type(status) <> "roAssociativeArray" then status = ev.status
    if type(status) <> "roAssociativeArray" or type(status.type) <> "roAssociativeArray" then return out
    state = asString(status.type.state)       ' pre | in | post
    detail = asString(status.type.shortDetail)
    dt = CreateObject("roDateTime")
    iso = asString(ev.date)
    if Len(iso) = 17 then iso = Left(iso, 16) + ":00Z"     ' "2026-10-07T22:00Z"
    dt.FromISO8601String(iso)
    out.start = dt.AsSeconds()
    away = invalid
    home = invalid
    for each c in comp.competitors
        if type(c) = "roAssociativeArray" and type(c.team) = "roAssociativeArray"
            t = c.team
            out.names.Push(LCase(asString(t.displayName)))
            out.names.Push(LCase(asString(t.shortDisplayName)))
            full = asString(t.location) + " " + asString(t.name)     ' "Atlanta Braves"
            out.names.Push(LCase(full.Trim()))
            side = { abbr: asString(t.abbreviation), score: asString(c.score) }
            if asString(c.homeAway) = "home" then home = side else away = side
        end if
    end for
    if away = invalid or home = invalid then return out
    if state = "in" or state = "post"
        out.text = away.abbr + " " + away.score + " - " + home.abbr + " " + home.score + "   " + detail
    end if
    return out
end function

function namesMatch(ours as Dynamic, theirs as Object) as Boolean
    if type(ours) <> "roArray" then return false
    for each n in ours
        mine = LCase(asString(n)).Trim()
        if mine <> ""
            for each t in theirs
                if t = mine then return true
            end for
        end if
    end for
    return false
end function
