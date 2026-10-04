' My Teams: finds saved teams' games in event-channel names (requirements:
' Later features, My Teams). Runs in SearchTask over the live index.
' Rules: data/guide-rules.json "myTeams"; event times: "nameTimes" (Utils).
'
' A game is a channel in an event category whose name mentions a team (name
' or alias, whole words, no exclusion), has an event time from lookbackHours
' ago to aheadHours ahead, and whose sport is one of the team's (or unknown).
' Channels for the same team within 15 minutes of each other are one game.

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
    }
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
        teams.Push({ id: asString(t.id), name: asString(t.name), matchers: matchers, exclusions: exclusions, sports: sports })
    end for

    groups = {}
    for each e in m.index.live
        categoryName = categories[e.categoryId]
        if categoryName <> invalid
            for each t in teams
                ' Team words first: cheap, and rules out almost every channel.
                if anyMatch(t.matchers, e.name) and not anyMatch(t.exclusions, e.name)
                    found = findNameTime(e.name, false)
                    if found <> invalid and found.utc >= now - rules.lookbackSeconds and found.utc <= now + rules.aheadSeconds
                        sport = detectSport(LCase(categoryName + " " + e.name), rules)
                        if sport = "" or t.sports.Count() = 0 or t.sports.DoesExist(sport)
                            addGameChannel(groups, t, e, found, sport, now, rules)
                        end if
                    end if
                end if
            end for
        end if
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
    print "[teams] "; result.games.Count(); " game(s) for "; teams.Count(); " team(s) ("; timer.TotalMilliseconds(); " ms)"
    return result
end function

' A team's listings starting within 90 minutes of each other are one game
' (one listing may include the pregame); the game keeps the earliest start.
sub addGameChannel(groups as Object, team as Object, e as Object, found as Object, sport as String, now as Integer, rules as Object)
    g = invalid
    for each key in groups
        other = groups[key]
        if g = invalid and other.teamId = team.id and Abs(other.start - found.utc) <= 5400 then g = other
    end for
    if g <> invalid
        if found.utc < g.start
            g.start = found.utc
            g.live = (now >= found.utc and now < found.utc + rules.liveSeconds)
        end if
        if g.sport = "" and sport <> ""
            g.sport = sport
            g.sportLabel = asString(rules.sportLabels[sport])
        end if
    end if
    if g = invalid
        key = team.id + "|" + found.utc.ToStr()
        g = {
            key: key
            teamId: team.id
            teamName: team.name
            title: gameTitle(e.name, found.text, team, rules)
            sport: sport
            sportLabel: asString(rules.sportLabels[sport])
            start: found.utc
            live: (now >= found.utc and now < found.utc + rules.liveSeconds)
            replayChannels: 0
            channels: []
        }
        groups[key] = g
    end if
    if rules.replay <> invalid and rules.replay.IsMatch(e.name) then g.replayChannels = g.replayChannels + 1
    later = rules.later <> invalid and rules.later.IsMatch(e.name)
    g.channels.Push({ streamId: e.itemId, name: e.name, epgChannelId: e.epgChannelId, later: later })
end sub

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
    text = name.Replace(timeText, " ")
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

' Main-language channels first, then the rest, keeping provider order.
function sortChannels(channels as Object) as Object
    first = []
    rest = []
    for each c in channels
        later = c.later
        c.Delete("later")
        if later then rest.Push(c) else first.Push(c)
    end for
    first.Append(rest)
    return first
end function

function asArray(value as Dynamic) as Object
    if type(value) = "roArray" then return value
    return []
end function
