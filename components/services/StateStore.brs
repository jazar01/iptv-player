' Saved state is one versioned JSON document per device (see the data model in
' docs/requirements.md). Records carry updatedAt; deletions are tombstones.

sub init()
    m.SCHEMA = 6
    m.RECENT_CAP = 15
    m.SEEN_CAP = 20
    m.SEEN_DAYS = 4
    m.RESUME_CAP = 50
    m.TOMBSTONE_DAYS = 28
    m.STALE_SERIES_DAYS = 30

    ' Usage scores: a separate, per-device table (not part of the synced
    ' document). See the Usage section below.
    m.usageSection = CreateObject("roRegistrySection", "iptv_usage")
    m.usage = invalid

    m.backend = RegistryBackend("iptv_state")
    m.doc = m.backend.read()
    restored = false
    if m.doc = invalid
        ' Nothing saved (fresh install, or wiped): use the restore bundle that
        ' deploy.ps1 packaged from backups\, if there is one for this Roku.
        m.doc = restoredDocument()
        restored = (m.doc <> invalid)
        if not restored
            print "[state] no saved state; starting fresh"
            m.doc = newDocument()
        end if
    end if
    normalizeDocument(m.doc)
    ' The last saved state: a failed save puts m.doc back to it (persist()).
    m.committed = copyDocument(m.doc)
    if restored and not persist() then print "[state] WARNING: restored state couldn't be saved yet; it will be on the next change"
end sub

' ---------------------------------------------------------------------------
' Manual backup and restore (until the V2 backup service).

' Settings -> Back up to computer: the whole saved document as JSON, which
' MainScene prints to the console for scripts\backup-roku.ps1.
function exportDocument() as String
    return FormatJson(m.doc)
end function

' pkg:/data/restore.json (deploy.ps1): { devices: [{ ip, name, document? }],
' household? }. This Roku's own backup if one matches its IP address, else
' the household copy (with this Roku's name from the deploy list, a new
' device ID and no per-device history). Only used when nothing is saved, so
' a Roku that has its own state never loses it to an old backup.
function restoredDocument() as Dynamic
    ' ReadAsciiFile, not roFileSystem: StateStore runs on the render thread,
    ' where roFileSystem can't be created. A missing file reads as "".
    text = ReadAsciiFile("pkg:/data/restore.json")
    if text = "" then return invalid
    bundle = ParseJson(text, "i")     ' "i": see copyDocument
    if type(bundle) <> "roAssociativeArray" then return invalid

    ips = {}
    addresses = CreateObject("roDeviceInfo").GetIPAddrs()
    for each iface in addresses
        ips[asString(addresses[iface])] = true
    end for

    name = ""
    if type(bundle.devices) = "roArray"
        for each d in bundle.devices
            if type(d) = "roAssociativeArray" and ips.DoesExist(asString(d.ip))
                name = asString(d.name)
                if type(d.document) = "roAssociativeArray"
                    print "[state] restored from the backup of '"; name; "'"
                    return d.document
                end if
            end if
        end for
    end if

    doc = bundle.household
    if type(doc) <> "roAssociativeArray" then return invalid
    doc.deviceId = CreateObject("roDeviceInfo").GetRandomUUID()
    doc.deviceName = name
    doc.recent = []
    doc.seenGames = []
    print "[state] restored from the household backup as '"; name; "'"
    return doc
end function

' ---------------------------------------------------------------------------
' Account and device

function isConfigured() as Boolean
    c = m.doc.credentials
    return type(c) = "roAssociativeArray" and asString(c.server) <> "" and asString(c.username) <> ""
end function

function getCredentials() as Dynamic
    return m.doc.credentials
end function

' Setup: account and device name saved together, so neither is saved alone.
' values: { server, username, password, deviceName }
function setAccount(values as Object) as Boolean
    m.doc.credentials = {
        server: asString(values.server)
        username: asString(values.username)
        password: asString(values.password)
    }
    m.doc.deviceName = asString(values.deviceName)
    return persist()
end function

function getDevice() as Object
    return { deviceId: m.doc.deviceId, deviceName: m.doc.deviceName }
end function

' The device's local TV market (My Teams local stations):
' { key: "GA|Atlanta", label: "Atlanta, GA" }, key "" when not chosen.
function getMarket() as Object
    return { key: asString(m.doc.market.key), label: asString(m.doc.market.label) }
end function

function setMarket(market as Object) as Boolean
    m.doc.market = { key: asString(market.key), label: asString(market.label) }
    return persist()
end function

' Per-device on/off options: { showMyTeams, showNoGameTeams,
' showFavoritesInRecent, myTeamsFirst }. New options
' join this object with a default (normalizeDocument), so adding one doesn't
' change the document's shape.
function getSettings() as Object
    return {
        showMyTeams: isTrue(m.doc.settings.showMyTeams)
        showNoGameTeams: isTrue(m.doc.settings.showNoGameTeams)
        showFavoritesInRecent: isTrue(m.doc.settings.showFavoritesInRecent)
        myTeamsFirst: isTrue(m.doc.settings.myTeamsFirst)
    }
end function

function setSetting(name as String, value as Dynamic) as Boolean
    m.doc.settings[name] = value
    return persist()
end function

' ---------------------------------------------------------------------------
' Favorites. Each carries its own name and epgChannelId so the home screen can
' draw without the network and favorites can be re-matched after renumbering.

function getFavorites() as Object
    out = []
    for each f in m.doc.favorites
        if not isTrue(f.deleted) then out.Push(f)
    end for
    return out
end function

function isFavorite(streamId as Dynamic) as Boolean
    f = findFavorite(toInt(streamId))
    return f <> invalid and not isTrue(f.deleted)
end function

' fav: { streamId, name, epgChannelId }
function addFavorite(fav as Object) as Boolean
    id = toInt(fav.streamId)
    f = findFavorite(id)
    if f = invalid
        f = { streamId: id, pinned: false, position: invalid }
        m.doc.favorites.Push(f)
    end if
    f.name = asString(fav.name)
    f.epgChannelId = asString(fav.epgChannelId)
    f.deleted = false
    f.updatedAt = nowSeconds()
    return persist()
end function

function removeFavorite(streamId as Dynamic) as Boolean
    f = findFavorite(toInt(streamId))
    if f = invalid or isTrue(f.deleted) then return true
    f.deleted = true
    f.updatedAt = nowSeconds()
    return persist()
end function

function findFavorite(streamId as Integer) as Dynamic
    for each f in m.doc.favorites
        if toInt(f.streamId) = streamId then return f
    end for
    return invalid
end function

' ---------------------------------------------------------------------------
' Recently viewed live channels (watched for about a minute). Newest first,
' capped; per device and least important, so trimmed first when space runs
' short.

function getRecent() as Object
    list = []
    list.Append(m.doc.recent)
    list.SortBy("updatedAt", "r")
    return list
end function

' channel: { streamId, name, epgChannelId }
function addRecent(channel as Object) as Boolean
    id = toInt(channel.streamId)
    kept = [{ streamId: id, name: shortName(channel.name), epgChannelId: asString(channel.epgChannelId), updatedAt: nowSeconds() }]
    for each r in getRecent()
        if toInt(r.streamId) <> id and kept.Count() < m.RECENT_CAP then kept.Push(r)
    end for
    m.doc.recent = kept
    return persist()
end function

' ---------------------------------------------------------------------------
' My Teams. team: { id, name, aliases[], exclusions[], sports[], updatedAt,
' deleted }. Deleting leaves a tombstone, like favorites.

function getTeams() as Object
    list = []
    for each t in m.doc.teams
        if not isTrue(t.deleted) then list.Push(t)
    end for
    return list
end function

' Adds a team (no id yet) or updates one; returns the saved team, or
' invalid if it couldn't be saved.
function saveTeam(team as Object) as Dynamic
    id = asString(team.id)
    t = invalid
    for each existing in m.doc.teams
        if existing.id = id then t = existing
    end for
    if t = invalid
        if id = "" then id = Left(CreateObject("roDeviceInfo").GetRandomUUID(), 8)
        t = { id: id }
        m.doc.teams.Push(t)
    end if
    t.name = capitalizeWords(shortName(team.name))
    t.aliases = capitalizedList(shortList(team.aliases))
    t.exclusions = capitalizedList(shortList(team.exclusions))
    t.sports = shortList(team.sports)
    t.deleted = false
    t.updatedAt = nowSeconds()
    if not persist() then return invalid
    return t
end function

function deleteTeam(id as String) as Boolean
    for each t in m.doc.teams
        if t.id = id
            t.deleted = true
            t.updatedAt = nowSeconds()
        end if
    end for
    return persist()
end function

' Team logo (My Teams cards): logo is an image URL, or "" when none was
' found; logoFor is the team name it was looked up for, so renaming the
' team looks it up again. Neither field is set until the first lookup.
function setTeamLogo(id as String, logo as String, logoFor as String) as Boolean
    for each t in m.doc.teams
        if t.id = id
            t.logo = Left(logo, 200)
            t.logoFor = logoFor
            t.updatedAt = nowSeconds()
            return persist()
        end if
    end for
    return true
end function

function capitalizedList(items as Object) as Object
    out = []
    for each item in items
        out.Push(capitalizeWords(item))
    end for
    return out
end function

function shortList(items as Dynamic) as Object
    out = []
    if type(items) <> "roArray" then return out
    for each item in items
        text = shortName(item).Trim()
        if text <> "" then out.Push(text)
    end for
    return out
end function

' Matchups already seen, for labelling replays: [{ key, start }]. Per device;
' only the last few days are kept.
function getSeenGames() as Object
    return m.doc.seenGames
end function

' games: [{ key, start }]. Keeps the earliest start per key.
function recordSeenGames(games as Object) as Boolean
    cutoff = nowSeconds() - m.SEEN_DAYS * 86400
    byKey = {}
    for each s in m.doc.seenGames
        if toInt(s.start) >= cutoff then byKey[s.key] = s
    end for
    changed = false
    for each g in games
        existing = byKey[g.key]
        if existing = invalid or toInt(g.start) < toInt(existing.start)
            byKey[g.key] = { key: g.key, start: toInt(g.start) }
            changed = true
        end if
    end for
    if not changed then return true
    list = []
    for each key in byKey
        list.Push(byKey[key])
    end for
    list.SortBy("start", "r")
    while list.Count() > m.SEEN_CAP
        list.Pop()
    end while
    m.doc.seenGames = list
    return persist()
end function

' ---------------------------------------------------------------------------
' Usage scores (requirements: Usage-based item ordering). A per-device table,
' kept apart from the synced document in its own registry section as one
' compact string: "c12345:3.25:1759600000;m777:1:1759500000;..." (key, score,
' when it was last updated). Keys: c<streamId> channels, m<id> movies,
' s<seriesId> series, t<teamId> teams. Each use adds 1; scores halve every
' halfLifeDays. Losing it only resets the ordering, so a failed write is
' logged and skipped.

function loadUsage() as Object
    if m.usage <> invalid then return m.usage
    m.usage = {}
    raw = ""
    if m.usageSection.Exists("table") then raw = m.usageSection.Read("table")
    for each part in raw.Split(";")
        fields = part.Split(":")
        if fields.Count() = 3 then m.usage[fields[0]] = { s: Val(fields[1]), t: Val(fields[2], 10) }
    end for
    return m.usage
end function

function usageConfig() as Object
    if m.usageConfig <> invalid then return m.usageConfig
    cfg = { halfLife: 14 * 86400, maxEntries: 60, channelViewSeconds: 180 }
    json = ParseJson(ReadAsciiFile("pkg:/data/guide-rules.json"))
    if type(json) = "roAssociativeArray" and type(json.usage) = "roAssociativeArray"
        if Val(asString(json.usage.halfLifeDays)) > 0 then cfg.halfLife = Int(Val(asString(json.usage.halfLifeDays)) * 86400)
        if toInt(json.usage.maxEntries) > 0 then cfg.maxEntries = toInt(json.usage.maxEntries)
        if toInt(json.usage.channelViewSeconds) > 0 then cfg.channelViewSeconds = toInt(json.usage.channelViewSeconds)
    end if
    m.usageConfig = cfg
    return cfg
end function

' Score now, with its decay since it was last updated.
function decayedScore(entry as Object, now as Integer) as Float
    age = now - entry.t
    if age <= 0 then return entry.s
    return entry.s * (0.5 ^ (age / usageConfig().halfLife))
end function

' One use of key ("c12345", "m777", "s55", "t1a2b3c4d").
function recordUsage(key as String) as Boolean
    usage = loadUsage()
    now = nowSeconds()
    entry = usage[key]
    score = 1.0
    if entry <> invalid then score = decayedScore(entry, now) + 1
    usage[key] = { s: score, t: now }

    ' Keep the strongest maxEntries.
    if usage.Count() > usageConfig().maxEntries
        ranked = []
        for each k in usage
            ranked.Push({ key: k, score: decayedScore(usage[k], now) })
        end for
        ranked.SortBy("score", "r")
        while ranked.Count() > usageConfig().maxEntries
            usage.Delete(ranked.Pop().key)
        end while
    end if

    text = ""
    for each k in usage
        e = usage[k]
        if text <> "" then text += ";"
        ' Two decimals are plenty for ordering and keep the string short.
        text += k + ":" + Str(Int(e.s * 100 + 0.5) / 100).Trim() + ":" + e.t.ToStr()
    end for
    if not m.usageSection.Write("table", text) or not m.usageSection.Flush()
        print "[state] couldn't save usage scores (registry full?); ordering unaffected this session"
        return false
    end if
    return true
end function

' { key: score now } for every entry, for ordering rows at launch.
function getUsageScores() as Object
    usage = loadUsage()
    now = nowSeconds()
    scores = {}
    for each k in usage
        scores[k] = decayedScore(usage[k], now)
    end for
    return scores
end function

function getChannelViewSeconds() as Integer
    return usageConfig().channelViewSeconds
end function

' Pinned favorites stay first, in the order they were pinned.
function setPinned(streamId as Dynamic, pinned as Boolean) as Boolean
    f = findFavorite(toInt(streamId))
    if f = invalid then return true
    if pinned
        highest = 0
        for each other in m.doc.favorites
            if isTrue(other.pinned) and toInt(other.position) > highest then highest = toInt(other.position)
        end for
        f.pinned = true
        f.position = highest + 1
    else
        f.pinned = false
        f.position = invalid
    end if
    f.updatedAt = nowSeconds()
    return persist()
end function

' ---------------------------------------------------------------------------
' Re-matching after the provider renumbers (requirements: Persistence).
' Applies what channel matching found; anything not in the map is untouched.

' map: { "<old streamId>": { streamId, name, epgChannelId } }. Favorites and
' Recently Viewed move to the new ID; a favorite whose new ID is already a
' favorite becomes a tombstone instead of a duplicate.
function remapChannels(map as Object) as Boolean
    if map.Count() = 0 then return true
    now = nowSeconds()
    for each f in m.doc.favorites
        target = map[toInt(f.streamId).ToStr()]
        if target <> invalid and not isTrue(f.deleted)
            existing = findFavorite(toInt(target.streamId))
            if existing <> invalid and not isTrue(existing.deleted)
                f.deleted = true
            else
                f.streamId = toInt(target.streamId)
                f.name = shortName(target.name)
                f.epgChannelId = asString(target.epgChannelId)
            end if
            f.updatedAt = now
        end if
    end for

    kept = []
    seen = {}
    for each r in getRecent()
        target = map[toInt(r.streamId).ToStr()]
        if target <> invalid
            r.streamId = toInt(target.streamId)
            r.name = shortName(target.name)
            r.epgChannelId = asString(target.epgChannelId)
        end if
        key = toInt(r.streamId).ToStr()
        if not seen.DoesExist(key)
            seen[key] = true
            kept.Push(r)
        end if
    end for
    m.doc.recent = kept
    return persist()
end function

' map: { "<old seriesId>": { seriesId, name, year } }. The series record and
' its episodes' resume entries move to the new ID. Episode IDs inside may
' have changed too; remapEpisodes() moves them by season and episode number
' once the series info is loaded.
function remapSeries(map as Object) as Boolean
    if map.Count() = 0 then return true
    for each s in m.doc.series
        target = map[toInt(s.seriesId).ToStr()]
        if target <> invalid
            s.seriesId = toInt(target.seriesId)
            s.name = shortName(target.name)
            if toInt(target.year) > 0 then s.year = toInt(target.year)
            s.updatedAt = nowSeconds()
        end if
    end for
    for each r in m.doc.resume
        if r.kind = "episode"
            target = map[toInt(r.seriesId).ToStr()]
            if target <> invalid then r.seriesId = toInt(target.seriesId)
        end if
    end for
    return persist()
end function

' Episode IDs can change in a renumbering too; season and episode number
' identify them. episodes: [{ id, season, episode }] from fresh series info
' (or just the one about to play). Saved positions and the current episode
' move to the listed ID; if a position is saved under both, the newer wins.
function remapEpisodes(seriesId as Dynamic, episodes as Object) as Boolean
    sid = toInt(seriesId)
    byNumber = {}
    for each e in episodes
        if toInt(e.season) > 0 or toInt(e.episode) > 0 then byNumber[toInt(e.season).ToStr() + ":" + toInt(e.episode).ToStr()] = toInt(e.id)
    end for
    changed = false

    kept = []
    byId = {}
    for each r in getResume()     ' newest first, so the newer copy is kept
        if r.kind = "episode" and toInt(r.seriesId) = sid
            newId = byNumber[toInt(r.season).ToStr() + ":" + toInt(r.episode).ToStr()]
            if newId <> invalid and newId <> toInt(r.id)
                r.id = newId
                changed = true
            end if
            key = toInt(r.id).ToStr()
            if byId.DoesExist(key)
                changed = true     ' an older duplicate: dropped
            else
                byId[key] = true
                kept.Push(r)
            end if
        else
            kept.Push(r)
        end if
    end for

    s = findSeries(sid)
    if s <> invalid and type(s.current) = "roAssociativeArray"
        newId = byNumber[toInt(s.current.season).ToStr() + ":" + toInt(s.current.episode).ToStr()]
        if newId <> invalid and newId <> toInt(s.current.episodeId)
            s.current.episodeId = newId
            changed = true
        end if
    end if

    if not changed then return true
    print "[state] re-found renumbered episodes of series "; sid
    m.doc.resume = kept
    return persist()
end function

' Favorite series: a `favorite` mark on the series record (so re-matching
' after a renumbering covers them, and they're never trimmed).
' entry: { seriesId, name, year }
function setSeriesFavorite(entry as Object, favorite as Boolean) as Boolean
    id = toInt(entry.seriesId)
    s = findSeries(id)
    if s = invalid
        if not favorite then return true
        s = { seriesId: id, watched: "", current: invalid }
        m.doc.series.Push(s)
    end if
    if asString(entry.name) <> "" then s.name = shortName(entry.name)
    if toInt(entry.year) > 0 then s.year = toInt(entry.year)
    if s.name = invalid then s.name = ""
    if s.year = invalid then s.year = 0
    s.favorite = favorite
    s.deleted = false
    s.updatedAt = nowSeconds()
    return persist()
end function

function isSeriesFavorite(seriesId as Dynamic) as Boolean
    s = findSeries(toInt(seriesId))
    return s <> invalid and not isTrue(s.deleted) and isTrue(s.favorite)
end function

' [{ seriesId, name, year, current, watched }] for favorite series.
function getFavoriteSeries() as Object
    list = []
    for each s in m.doc.series
        if not isTrue(s.deleted) and isTrue(s.favorite) then list.Push(s)
    end for
    return list
end function

' Every saved series (for re-matching), not only those in Continue Watching.
function getSavedSeries() as Object
    list = []
    for each s in m.doc.series
        if not isTrue(s.deleted) then list.Push({ seriesId: toInt(s.seriesId), name: asString(s.name), year: toInt(s.year) })
    end for
    return list
end function

' ---------------------------------------------------------------------------
' Resume positions for movies and episodes. Newest first.

function getResume() as Object
    list = []
    list.Append(m.doc.resume)
    list.SortBy("updatedAt", "r")
    return list
end function

function getPosition(kind as String, id as Dynamic) as Integer
    r = findResume(kind, toInt(id))
    if r = invalid then return 0
    return toInt(r.position)
end function

' entry: { kind: "movie" | "episode", id, name, ext, position, duration }
'   episodes also: seriesId, seriesName, year, season, episode
' Positions are seconds. Saving an episode also makes it its series' current
' episode, so Continue Watching shows the series.
function savePosition(entry as Object) as Boolean
    kind = asString(entry.kind)
    id = toInt(entry.id)
    r = findResume(kind, id)
    if r = invalid
        r = { kind: kind, id: id }
        m.doc.resume.Push(r)
    end if
    r.name = shortName(entry.name)
    r.ext = asString(entry.ext)
    r.position = toInt(entry.position)
    r.duration = toInt(entry.duration)
    r.updatedAt = nowSeconds()
    if kind = "episode"
        r.seriesId = toInt(entry.seriesId)
        r.season = toInt(entry.season)
        r.episode = toInt(entry.episode)
        touchSeries(entry, episodePointer(entry))
    end if
    return persist()
end function

function clearPosition(kind as String, id as Dynamic) as Boolean
    if not removeResume(kind, toInt(id)) then return true
    return persist()
end function

function removeResume(kind as String, id as Integer) as Boolean
    kept = []
    for each r in m.doc.resume
        if not (r.kind = kind and toInt(r.id) = id) then kept.Push(r)
    end for
    if kept.Count() = m.doc.resume.Count() then return false
    m.doc.resume = kept
    return true
end function

function findResume(kind as String, id as Integer) as Dynamic
    for each r in m.doc.resume
        if r.kind = kind and toInt(r.id) = id then return r
    end for
    return invalid
end function

' ---------------------------------------------------------------------------
' Watched tracking. Movies: watched clears the resume entry. Episodes: the
' series record keeps per-season ranges ("S1:1-10,S2:1-4") and `current`, the
' episode Continue Watching points to.
'
' current: { episodeId, season, episode, name, ext } or invalid when finished.

' entry: as savePosition, plus for episodes:
'   nextEpisode  pointer for the following episode (invalid if none)
'   fromPlayback true when playback reached the end; a manual mark only moves
'                current if the marked episode is the current one
function markWatched(entry as Object) as Boolean
    kind = asString(entry.kind)
    id = toInt(entry.id)
    removeResume(kind, id)
    if kind = "episode"
        s = findSeries(toInt(entry.seriesId))
        advance = isTrue(entry.fromPlayback) or s = invalid or s.current = invalid or toInt(s.current.episodeId) = id
        current = invalid
        if s <> invalid then current = s.current
        if advance
            current = invalid
            if type(entry.nextEpisode) = "roAssociativeArray" then current = episodePointer(entry.nextEpisode)
        end if
        s = touchSeries(entry, current)
        seasons = parseWatched(asString(s.watched))
        key = toInt(entry.season).ToStr()
        if seasons[key] = invalid then seasons[key] = {}
        seasons[key][toInt(entry.episode).ToStr()] = true
        s.watched = formatWatched(seasons)
    end if
    return persist()
end function

' * on a Continue Watching card. Movie: its saved position goes. Series: it
' leaves the row (no current episode) and its episodes' positions go, but the
' watched ranges stay; playing an episode later brings it back.
' entry: { resumeKind: "movie" | "episode", itemId, seriesId }
function removeFromContinue(entry as Object) as Boolean
    if entry.resumeKind = "movie"
        removeResume("movie", toInt(entry.itemId))
    else
        seriesId = toInt(entry.seriesId)
        s = findSeries(seriesId)
        if s <> invalid
            s.current = invalid
            s.updatedAt = nowSeconds()
        end if
        kept = []
        for each r in m.doc.resume
            if not (r.kind = "episode" and toInt(r.seriesId) = seriesId) then kept.Push(r)
        end for
        m.doc.resume = kept
    end if
    return persist()
end function

' Episodes only (manual). Leaves `current` alone.
function markUnwatched(entry as Object) as Boolean
    s = findSeries(toInt(entry.seriesId))
    if s = invalid then return true
    seasons = parseWatched(asString(s.watched))
    episodes = seasons[toInt(entry.season).ToStr()]
    if episodes = invalid then return true
    episodes.Delete(toInt(entry.episode).ToStr())
    s.watched = formatWatched(seasons)
    s.updatedAt = nowSeconds()
    return persist()
end function

' For the episode list: { watched: { "<season>:<episode>": true },
'   currentEpisodeId, resume: { "<episodeId>": { position, duration } } }
function getSeriesProgress(seriesId as Dynamic) as Object
    id = toInt(seriesId)
    out = { watched: {}, currentEpisodeId: 0, resume: {} }
    s = findSeries(id)
    if s <> invalid and not isTrue(s.deleted)
        seasons = parseWatched(asString(s.watched))
        for each season in seasons
            for each episode in seasons[season]
                out.watched[season + ":" + episode] = true
            end for
        end for
        if s.current <> invalid then out.currentEpisodeId = toInt(s.current.episodeId)
    end if
    for each r in m.doc.resume
        if r.kind = "episode" and toInt(r.seriesId) = id then out.resume[toInt(r.id).ToStr()] = { position: toInt(r.position), duration: toInt(r.duration) }
    end for
    return out
end function

' Series with an episode to continue, newest first.
function getSeriesList() as Object
    list = []
    for each s in m.doc.series
        if not isTrue(s.deleted) and type(s.current) = "roAssociativeArray" then list.Push(s)
    end for
    list.SortBy("updatedAt", "r")
    return list
end function

function findSeries(seriesId as Integer) as Dynamic
    for each s in m.doc.series
        if toInt(s.seriesId) = seriesId then return s
    end for
    return invalid
end function

' Create or update a series record from an episode entry and set `current`.
function touchSeries(entry as Object, current as Dynamic) as Object
    id = toInt(entry.seriesId)
    s = findSeries(id)
    if s = invalid
        s = { seriesId: id, watched: "" }
        m.doc.series.Push(s)
    end if
    if asString(entry.seriesName) <> "" then s.name = shortName(entry.seriesName)
    if toInt(entry.year) > 0 then s.year = toInt(entry.year)
    if s.name = invalid then s.name = ""
    if s.year = invalid then s.year = 0
    s.current = current
    s.deleted = false
    s.updatedAt = nowSeconds()
    return s
end function

function episodePointer(e as Object) as Object
    return {
        episodeId: toInt(e.id)
        season: toInt(e.season)
        episode: toInt(e.episode)
        name: shortName(e.name)
        ext: asString(e.ext)
    }
end function

' "S1:1-3,S1:5,S2:1-4" -> { "1": { "1": true, "2": true, ... }, "2": {...} }
function parseWatched(text as String) as Object
    seasons = {}
    if text = "" then return seasons
    for each part in text.Split(",")
        colon = Instr(1, part, ":")
        if Left(part, 1) = "S" and colon > 2
            season = Val(Mid(part, 2, colon - 2), 10).ToStr()
            if seasons[season] = invalid then seasons[season] = {}
            span = Mid(part, colon + 1)
            dash = Instr(1, span, "-")
            first = Val(span, 10)
            last = first
            if dash > 0
                first = Val(Left(span, dash - 1), 10)
                last = Val(Mid(span, dash + 1), 10)
            end if
            if first > 0 and last >= first and last - first < 1000
                for n = first to last
                    seasons[season][n.ToStr()] = true
                end for
            end if
        end if
    end for
    return seasons
end function

' Inverse of parseWatched, with consecutive episodes collapsed to ranges.
function formatWatched(seasons as Object) as String
    seasonNumbers = []
    for each season in seasons
        seasonNumbers.Push(Val(season, 10))
    end for
    seasonNumbers.Sort()

    parts = []
    for each season in seasonNumbers
        numbers = []
        for each episode in seasons[season.ToStr()]
            numbers.Push(Val(episode, 10))
        end for
        numbers.Sort()
        i = 0
        while i < numbers.Count()
            first = numbers[i]
            while i + 1 < numbers.Count() and numbers[i + 1] = numbers[i] + 1
                i = i + 1
            end while
            span = first.ToStr()
            if numbers[i] > first then span = span + "-" + numbers[i].ToStr()
            parts.Push("S" + season.ToStr() + ":" + span)
            i = i + 1
        end while
    end for

    out = ""
    for each part in parts
        if out <> "" then out += ","
        out += part
    end for
    return out
end function

' Names are for display only; cap them to save registry space.
function shortName(name as Dynamic) as String
    return Left(asString(name), 60)
end function

' ---------------------------------------------------------------------------
' Document lifecycle

function newDocument() as Object
    return {
        schema: m.SCHEMA
        deviceId: CreateObject("roDeviceInfo").GetRandomUUID()
        deviceName: ""
        credentials: invalid
        favorites: []
        series: []
        resume: []
        recent: []
        teams: []
        seenGames: []
        market: { key: "", label: "" }
        settings: { showMyTeams: true, showNoGameTeams: true, showFavoritesInRecent: false, myTeamsFirst: false }
    }
end function

' Fill anything missing so the rest of the code can trust the shape.
' Schema migrations go here when the schema number increases.
sub normalizeDocument(doc as Object)
    if toInt(doc.schema) > m.SCHEMA then print "[state] WARNING: saved schema "; doc.schema; " is newer than this build ("; m.SCHEMA; ")"
    if asString(doc.deviceId) = "" then doc.deviceId = CreateObject("roDeviceInfo").GetRandomUUID()
    doc.deviceName = asString(doc.deviceName)
    for each key in ["favorites", "series", "resume", "recent", "teams", "seenGames"]
        if type(doc[key]) <> "roArray" then doc[key] = []
    end for

    ' Schema 2: resume entries carry name and ext so Continue Watching can
    ' draw and play without the network.
    if toInt(doc.schema) < 2
        for each r in doc.resume
            if r.name = invalid then r.name = ""
            if r.ext = invalid then r.ext = ""
        end for
        doc.schema = 2
        print "[state] migrated saved state to schema 2"
    end if

    ' Schema 3: `recent` (Recently Viewed channels), created empty above.
    if toInt(doc.schema) < 3
        doc.schema = 3
        print "[state] migrated saved state to schema 3"
    end if

    ' Schema 4: `teams` (My Teams) and `seenGames` (replay detection),
    ' created empty above.
    if toInt(doc.schema) < 4
        doc.schema = 4
        print "[state] migrated saved state to schema 4"
    end if

    ' Schema 5: `market`, the device's local TV market. Left empty: each
    ' device picks its own in Settings (a default would be wrong elsewhere).
    if type(doc.market) <> "roAssociativeArray" then doc.market = { key: "", label: "" }
    if toInt(doc.schema) < 5
        doc.schema = 5
        print "[state] migrated saved state to schema 5"
    end if

    ' Schema 6: `settings`, per-device on/off options (My Teams on Home is on
    ' by default, as before).
    if type(doc.settings) <> "roAssociativeArray" then doc.settings = {}
    if doc.settings.showMyTeams = invalid then doc.settings.showMyTeams = true
    if doc.settings.showNoGameTeams = invalid then doc.settings.showNoGameTeams = true
    if doc.settings.showFavoritesInRecent = invalid then doc.settings.showFavoritesInRecent = false
    if doc.settings.myTeamsFirst = invalid then doc.settings.myTeamsFirst = false

    ' Team names are shown capitalized ("Alabama Crimson Tide"); tidy any saved
    ' before that rule (display only: matching ignores case).
    for each t in doc.teams
        t.name = capitalizeWords(asString(t.name))
        if type(t.aliases) = "roArray" then t.aliases = capitalizedList(t.aliases)
        if type(t.exclusions) = "roArray" then t.exclusions = capitalizedList(t.exclusions)
    end for
    if toInt(doc.schema) < 6
        doc.schema = 6
        print "[state] migrated saved state to schema 6"
    end if
end sub

' Save after every change. On a full registry, trim what can be re-created
' (tombstones, old resume entries, stale series) and retry. Favorites are
' never trimmed.
'
' A failed save undoes the change in memory too (trimming included): the app
' never shows a change that wasn't saved, and a later save can't quietly
' include one that was reported as failed.
function persist() as Boolean
    maintain()
    result = m.backend.write(m.doc)
    if result = "nospace" then result = writeWithTrimming()
    if result <> "ok"
        print "[state] SAVE FAILED ("; result; "); change undone"
        m.doc = copyDocument(m.committed)
        return false
    end if
    m.committed = copyDocument(m.doc)
    return true
end function

' Deep copy through JSON, the same form the backend saves. "i": parsed
' objects must be case-insensitive like literals; by default a dot write
' (doc.seenGames = x) adds a second, lower-case key next to the parsed
' "seenGames" instead of replacing it (found Oct 2026).
function copyDocument(doc as Object) as Object
    return ParseJson(FormatJson(doc), "i")
end function

sub maintain()
    purgeTombstones(nowSeconds() - m.TOMBSTONE_DAYS * 86400)
    if m.doc.resume.Count() > m.RESUME_CAP
        m.doc.resume.SortBy("updatedAt", "r")
        while m.doc.resume.Count() > m.RESUME_CAP
            m.doc.resume.Pop()
        end while
    end if
end sub

function writeWithTrimming() as String
    print "[state] registry nearly full; trimming"
    purgeTombstones(&h7FFFFFFF)
    result = m.backend.write(m.doc)

    ' Replay memory first, then recently viewed: least important, rebuilt by
    ' normal use.
    if result = "nospace" and m.doc.seenGames.Count() > 0
        m.doc.seenGames = []
        result = m.backend.write(m.doc)
    end if
    recent = m.doc.recent
    recent.SortBy("updatedAt")
    while result = "nospace" and recent.Count() > 0
        recent.Shift()
        result = m.backend.write(m.doc)
    end while

    resume = m.doc.resume
    resume.SortBy("updatedAt")
    while result = "nospace" and resume.Count() > 0
        resume.Shift()
        result = m.backend.write(m.doc)
    end while

    ' Stale series, oldest first; favorite series are never trimmed.
    series = m.doc.series
    series.SortBy("updatedAt")
    staleBefore = nowSeconds() - m.STALE_SERIES_DAYS * 86400
    i = 0
    while result = "nospace" and i < series.Count()
        if toInt(series[i].updatedAt) >= staleBefore then exit while
        if isTrue(series[i].favorite)
            i = i + 1
        else
            series.Delete(i)
            result = m.backend.write(m.doc)
        end if
    end while

    return result
end function

' Drop deleted records whose deletion is older than cutoff (UTC seconds).
sub purgeTombstones(cutoff as Integer)
    for each key in ["favorites", "series", "teams"]
        kept = []
        for each r in m.doc[key]
            if not (isTrue(r.deleted) and toInt(r.updatedAt) < cutoff) then kept.Push(r)
        end for
        m.doc[key] = kept
    end for
end sub
