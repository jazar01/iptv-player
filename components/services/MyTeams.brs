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
    }
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

' Category ID -> name, for event categories only (from the cached list).
function eventCategoryNames() as Object
    if m.eventCategories <> invalid then return m.eventCategories
    names = {}
    rules = teamRules()
    cats = ParseJson(ReadAsciiFile("cachefs:/catalog/live_categories.json"))
    if type(cats) = "roArray"
        for each c in cats
            name = asString(c.category_name)
            if anyMatch(rules.eventCategories, name) and not anyMatch(rules.skipCategories, name) then names[asString(c.category_id)] = name
        end for
    end if
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
                    if found <> invalid and found.utc >= now - rules.lookbackSeconds and found.utc <= now + rules.aheadSeconds
                        sport = detectSport(LCase(categoryName + " " + e.name), rules)
                        replay = rules.replay <> invalid and rules.replay.IsMatch(e.name)
                        later = rules.later <> invalid and rules.later.IsMatch(e.name)
                        info = { start: found.utc, ends: 0, title: gameTitle(e.name, found.text, t, rules), sport: sport, replay: replay }
                        channel = { streamId: e.itemId, name: e.name, epgChannelId: e.epgChannelId, network: false, later: later }
                        if sport <> ""
                            if t.sports.Count() = 0 or t.sports.DoesExist(sport) then mergeGame(groups, t, info, channel, now, rules)
                        else if t.nameMatcher.IsMatch(e.name)
                            mergeGame(groups, t, info, channel, now, rules)
                        else
                            ' Unknown sport and only an alias ("Atlanta"): too weak to
                            ' be a game on its own; it may join one found another way.
                            weak.Push({ team: t, info: info, channel: channel })
                        end if
                    end if
                end if
            end for
        end if
    end for

    result.networks = resolveNetworks()
    if isTrue(req.withGuide) then addNetworkGames(groups, teams, result.networks, now, rules)

    ' Weak listings only add channels to games already found.
    for each w in weak
        if findGameGroup(groups, w.team, w.info.start) <> invalid then mergeGame(groups, w.team, w.info, w.channel, now, rules)
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
    print "[teams] "; result.games.Count(); " game(s) for "; teams.Count(); " team(s), guide "; isTrue(req.withGuide); " ("; timer.TotalMilliseconds(); " ms)"
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

' info: { start, ends (0 if unknown), title, sport, replay }
' channel: { streamId, name, epgChannelId, network, later }
' A team's listings starting within 90 minutes of each other are one game
' (one may include the pregame); it keeps the earliest start. A network
' listing's title and end time win, since guides are more exact than
' channel names.
sub mergeGame(groups as Object, team as Object, info as Object, channel as Object, now as Integer, rules as Object)
    g = findGameGroup(groups, team, info.start)
    if g = invalid
        g = {
            key: team.id + "|" + info.start.ToStr()
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
    if info.replay then g.replayChannels = g.replayChannels + 1
    for each c in g.channels
        if c.streamId = channel.streamId then return
    end for
    g.channels.Push(channel)
end sub

' The team's game starting within 90 minutes of start, or invalid.
function findGameGroup(groups as Object, team as Object, start as Integer) as Dynamic
    for each key in groups
        g = groups[key]
        if g.teamId = team.id and Abs(g.start - start) <= 5400 then return g
    end for
    return invalid
end function

' ---------------------------------------------------------------------------
' Network broadcasts

' The configured network channels that exist in the catalog:
' [{ label, streamId, name, epgChannelId, guideFile }]. Among channels with
' the guide ID, the first whose name doesn't match networkAvoid.
function resolveNetworks() as Object
    rules = teamRules()
    if m.epgGroups = invalid
        m.epgGroups = {}
        for each e in m.index.live
            if e.epgChannelId <> "" then addToGroup(m.epgGroups, LCase(e.epgChannelId), e)
        end for
    end if
    list = []
    for each n in rules.networks
        group = m.epgGroups[LCase(n.epg)]
        if group <> invalid
            chosen = group[0]
            for i = group.Count() - 1 to 0 step -1
                if rules.networkAvoid = invalid or not rules.networkAvoid.IsMatch(group[i].name) then chosen = group[i]
            end for
            list.Push({ label: n.label, streamId: chosen.itemId, name: chosen.name, epgChannelId: chosen.epgChannelId, guideFile: networkGuideFile(chosen.itemId) })
        end if
    end for
    return list
end function

function networkGuideFile(streamId as Integer) as String
    return "cachefs:/teams/guide_" + streamId.ToStr() + ".json"
end function

sub addNetworkGames(groups as Object, teams as Object, networks as Object, now as Integer, rules as Object)
    for each n in networks
        json = ParseJson(ReadAsciiFile(n.guideFile))
        if type(json) = "roAssociativeArray" and type(json.epg_listings) = "roArray"
            for each listing in json.epg_listings
                start = toInt(listing.start_timestamp)
                ends = toInt(listing.stop_timestamp)
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
