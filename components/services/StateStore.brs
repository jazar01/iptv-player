' Saved state is one versioned JSON document per device (see the data model in
' docs/requirements.md). Records carry updatedAt; deletions are tombstones.

sub init()
    m.SCHEMA = 3
    m.RECENT_CAP = 15
    m.RESUME_CAP = 50
    m.TOMBSTONE_DAYS = 28
    m.STALE_SERIES_DAYS = 30

    m.backend = RegistryBackend("iptv_state")
    m.doc = m.backend.read()
    if m.doc = invalid
        print "[state] no saved state; starting fresh"
        m.doc = newDocument()
    else
        normalizeDocument(m.doc)
    end if
end sub

' ---------------------------------------------------------------------------
' Account and device

function isConfigured() as Boolean
    c = m.doc.credentials
    return type(c) = "roAssociativeArray" and asString(c.server) <> "" and asString(c.username) <> ""
end function

function getCredentials() as Dynamic
    return m.doc.credentials
end function

function setCredentials(creds as Object) as Boolean
    m.doc.credentials = {
        server: asString(creds.server)
        username: asString(creds.username)
        password: asString(creds.password)
    }
    return persist()
end function

function getDevice() as Object
    return { deviceId: m.doc.deviceId, deviceName: m.doc.deviceName }
end function

function setDeviceName(name as String) as Boolean
    m.doc.deviceName = name
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
    }
end function

' Fill anything missing so the rest of the code can trust the shape.
' Schema migrations go here when the schema number increases.
sub normalizeDocument(doc as Object)
    if toInt(doc.schema) > m.SCHEMA then print "[state] WARNING: saved schema "; doc.schema; " is newer than this build ("; m.SCHEMA; ")"
    if asString(doc.deviceId) = "" then doc.deviceId = CreateObject("roDeviceInfo").GetRandomUUID()
    doc.deviceName = asString(doc.deviceName)
    for each key in ["favorites", "series", "resume", "recent"]
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
end sub

' Save after every change. On a full registry, trim what can be re-created
' (tombstones, old resume entries, stale series) and retry. Favorites are
' never trimmed.
function persist() as Boolean
    maintain()
    result = m.backend.write(m.doc)
    if result = "nospace" then result = writeWithTrimming()
    if result <> "ok"
        print "[state] SAVE FAILED ("; result; ")"
        return false
    end if
    return true
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

    ' Recently viewed first: least important, rebuilt by normal viewing.
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

    series = m.doc.series
    series.SortBy("updatedAt")
    staleBefore = nowSeconds() - m.STALE_SERIES_DAYS * 86400
    while result = "nospace" and series.Count() > 0 and toInt(series[0].updatedAt) < staleBefore
        series.Shift()
        result = m.backend.write(m.doc)
    end while

    return result
end function

' Drop deleted records whose deletion is older than cutoff (UTC seconds).
sub purgeTombstones(cutoff as Integer)
    for each key in ["favorites", "series"]
        kept = []
        for each r in m.doc[key]
            if not (isTrue(r.deleted) and toInt(r.updatedAt) < cutoff) then kept.Push(r)
        end for
        m.doc[key] = kept
    end for
end sub
