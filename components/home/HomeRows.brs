' Home screen rows. Each row is a module that supplies its own items from the
' services it's given; MainScene shows them in this fixed order. A new row
' (e.g. My Teams) is a new module added to homeRowModules().
'
' module: { id, title, emptyText, items(services) -> array of HomeItem field AAs }
' services: { store: StateStore, epg: EpgService }

' My Teams appears once a team is saved (unless switched off in Settings):
' below Favorites, or at the top while
' one of the games is live or starts within 30 minutes (requirements).
function homeRowModules(services as Object) as Object
    if not services.store.callFunc("getSettings").showMyTeams or services.store.callFunc("getTeams").Count() = 0 then return [favoritesRow(), continueWatchingRow(), recentRow()]
    if gameIsOnSoon(services.games) then return [myTeamsRow(), favoritesRow(), continueWatchingRow(), recentRow()]
    return [favoritesRow(), myTeamsRow(), continueWatchingRow(), recentRow()]
end function

function gameIsOnSoon(games as Dynamic) as Boolean
    if type(games) <> "roArray" then return false
    now = nowSeconds()
    for each g in games
        if g.live or (g.start >= now and g.start - now <= 1800) then return true
    end for
    return false
end function

' Usage ordering (requirements: Usage-based item ordering). services.usage is
' a snapshot of scores taken at launch, so rows don't reshuffle during a
' session. Ties keep the existing order.
function usageScore(usage as Dynamic, key as String) as Float
    if type(usage) <> "roAssociativeArray" or usage[key] = invalid then return 0
    return usage[key]
end function

' Sort key: higher score first, then lower index. Fixed-width digits so a
' plain string sort works.
function rankKey(score as Float, index as Integer) as String
    inverse = Int((100000 - score) * 1000)
    if inverse < 0 then inverse = 0
    return Right("000000000000" + inverse.ToStr(), 12) + Right("000000" + index.ToStr(), 6)
end function

' Pinned favorites first, in pin order; then by usage score.
function sortFavorites(favorites as Object, usage as Dynamic) as Object
    pinned = []
    rest = []
    for i = 0 to favorites.Count() - 1
        f = favorites[i]
        if isTrue(f.pinned)
            pinned.Push({ f: f, sortKey: Right("000000" + toInt(f.position).ToStr(), 6) + Right("000000" + i.ToStr(), 6) })
        else
            rest.Push({ f: f, sortKey: rankKey(usageScore(usage, "c" + toInt(f.streamId).ToStr()), i) })
        end if
    end for
    pinned.SortBy("sortKey")
    rest.SortBy("sortKey")
    out = []
    for each e in pinned
        out.Push(e.f)
    end for
    for each e in rest
        out.Push(e.f)
    end for
    return out
end function

' services: { store, epg, games, usage, launchTime }
function buildHomeRows(services as Object) as Object
    rows = []
    for each module in homeRowModules(services)
        rows.Push({ id: module.id, title: module.title, emptyText: module.emptyText, items: module.items(services) })
    end for
    return rows
end function

' ---------------------------------------------------------------------------
' Favorites: drawn from saved names and IDs, so no network is needed. Program
' info comes from EpgService's cache; fresh data arrives later via `programs`.

function favoritesRow() as Object
    return {
        id: "favorites"
        title: "Favorites"
        emptyText: "Press * on a channel in Live TV to add it here."
        items: favoritesRowItems
    }
end function

function favoritesRowItems(services as Object) as Object
    return channelItems(services, sortFavorites(services.store.callFunc("getFavorites"), services.usage))
end function

' Saved channel records { streamId, name, epgChannelId } -> channel cards,
' with now/next from EpgService's cache where it has it.
function channelItems(services as Object, channels as Object) as Object
    ids = []
    for each c in channels
        ids.Push(toInt(c.streamId))
    end for
    programs = services.epg.callFunc("getPrograms", ids)

    items = []
    for each c in channels
        id = toInt(c.streamId)
        item = {
            kind: "channel"
            itemKey: "live:" + id.ToStr()
            streamId: id
            name: asString(c.name)
            epgChannelId: asString(c.epgChannelId)
        }
        entry = programs[id.ToStr()]
        if entry <> invalid
            item.Append(programFields(entry))
            item.epgVersion = 1
        end if
        items.Push(item)
    end for
    return items
end function

' ---------------------------------------------------------------------------
' My Teams: saved teams' games in the next 24 hours, live first (found by
' SearchTask, replays labelled by MainScene).

function myTeamsRow() as Object
    return {
        id: "teams"
        title: "My Teams"
        emptyText: "No games for your teams in the next 24 hours."
        items: myTeamsRowItems
    }
end function

function myTeamsRowItems(services as Object) as Object
    items = []
    if type(services.games) <> "roArray" then services.games = []
    ' Live first, then start time; the team's usage score only breaks ties.
    ordered = []
    for i = 0 to services.games.Count() - 1
        g = services.games[i]
        liveFirst = "1"
        if g.live then liveFirst = "0"
        ordered.Push({ g: g, sortKey: liveFirst + Right("0000000000" + toInt(g.start).ToStr(), 10) + rankKey(usageScore(services.usage, "t" + asString(g.teamId)), i) })
    end for
    ordered.SortBy("sortKey")
    logos = {}      ' team ID -> logo URL ("" if none)
    for each t in services.store.callFunc("getTeams")
        logos[t.id] = asString(t.logo)
    end for
    for each o in ordered
        g = o.g
        flags = ""
        if g.live then flags = "live"
        if g.replay
            if flags <> "" then flags += ","
            flags += "replay"
        end if
        items.Push({
            kind: "game"
            itemKey: "game:" + g.key
            name: g.title
            teamName: g.teamName
            subtitle: g.sportLabel
            logo: asString(logos[asString(g.teamId)])
            nowStart: g.start
            nowEnd: g.start + 12600
            nowFlags: flags
            channels: g.channels
        })
    end for

    ' Teams with nothing in the next 24 hours, at the end in team order
    ' (Settings -> Show teams with no game).
    if services.store.callFunc("getSettings").showNoGameTeams
        playing = {}
        for each g in services.games
            playing[asString(g.teamId)] = true
        end for
        labels = sportLabelMap()
        for each t in services.store.callFunc("getTeams")
            if not playing.DoesExist(t.id)
                sports = ""
                for each s in t.sports
                    if sports <> "" then sports += ", "
                    sports += asString(labels[s])
                end for
                items.Push({
                    kind: "noGame"
                    itemKey: "team:" + t.id
                    name: t.name
                    teamName: t.name
                    subtitle: sports
                    logo: asString(t.logo)
                    message: "No game in 24 hours"
                })
            end if
        end for
    end if
    return items
end function

' Sport ID -> label, from data/guide-rules.json "myTeams".
function sportLabelMap() as Object
    labels = {}
    cfg = guideRules().myTeams
    if type(cfg) = "roAssociativeArray" and type(cfg.sports) = "roArray"
        for each s in cfg.sports
            labels[asString(s.id)] = asString(s.label)
        end for
    end if
    return labels
end function

' ---------------------------------------------------------------------------
' Recently Viewed: live channels watched for about a minute, newest first,
' leaving out channels already in Favorites.

function recentRow() as Object
    return {
        id: "recent"
        title: "Recently Viewed"
        emptyText: "Channels you watch will appear here."
        items: recentRowItems
    }
end function

function recentRowItems(services as Object) as Object
    favoriteIds = {}
    for each f in services.store.callFunc("getFavorites")
        favoriteIds[toInt(f.streamId).ToStr()] = true
    end for
    channels = []
    for each r in services.store.callFunc("getRecent")
        if not favoriteIds.DoesExist(toInt(r.streamId).ToStr()) then channels.Push(r)
    end for
    return channelItems(services, channels)
end function

' ---------------------------------------------------------------------------
' Continue Watching: movies with time left, and series pointing at their
' current episode (in progress or next unwatched), in usage order.
' Everything comes from saved state, so it draws without the network.

function continueWatchingRow() as Object
    return {
        id: "continue"
        title: "Continue Watching"
        emptyText: "Movies and episodes you start will appear here."
        items: continueWatchingRowItems
    }
end function

function continueWatchingRowItems(services as Object) as Object
    entries = []
    resumeByEpisode = {}
    for each r in services.store.callFunc("getResume")
        if r.kind = "movie"
            duration = toInt(r.duration)
            position = toInt(r.position)
            if duration > 0 and position < duration
                name = asString(r.name)
                if name = "" then name = "Movie " + asString(r.id)
                entries.Push({ updatedAt: toInt(r.updatedAt), usageKey: "m" + toInt(r.id).ToStr(), item: {
                    kind: "resume"
                    resumeKind: "movie"
                    itemKey: "movie:" + asString(r.id)
                    itemId: toInt(r.id)
                    name: name
                    ext: asString(r.ext)
                    position: position
                    duration: duration
                } })
            end if
        else if r.kind = "episode"
            resumeByEpisode[toInt(r.id).ToStr()] = r
        end if
    end for

    for each s in services.store.callFunc("getSeriesList")
        c = s.current
        item = {
            kind: "resume"
            resumeKind: "episode"
            itemKey: "series:" + asString(s.seriesId)
            itemId: toInt(c.episodeId)
            name: asString(s.name)
            seriesId: toInt(s.seriesId)
            seriesName: asString(s.name)
            year: toInt(s.year)
            season: toInt(c.season)
            episode: toInt(c.episode)
            ext: asString(c.ext)
            subtitle: "S" + toInt(c.season).ToStr() + " E" + toInt(c.episode).ToStr()
            position: 0
            duration: 0
        }
        r = resumeByEpisode[toInt(c.episodeId).ToStr()]
        if r <> invalid
            item.position = toInt(r.position)
            item.duration = toInt(r.duration)
        end if
        entries.Push({ updatedAt: toInt(s.updatedAt), usageKey: "s" + toInt(s.seriesId).ToStr(), item: item })
    end for

    ' Usage order: anything started since launch first (newest first), then by
    ' launch-time score, newest first among equals.
    entries.SortBy("updatedAt", "r")
    launchTime = toInt(services.launchTime)
    fresh = []
    ranked = []
    for i = 0 to entries.Count() - 1
        e = entries[i]
        if e.updatedAt > launchTime
            fresh.Push(e)
        else
            e.sortKey = rankKey(usageScore(services.usage, e.usageKey), i)
            ranked.Push(e)
        end if
    end for
    ranked.SortBy("sortKey")
    items = []
    for each e in fresh
        items.Push(e.item)
    end for
    for each e in ranked
        items.Push(e.item)
    end for
    return items
end function
