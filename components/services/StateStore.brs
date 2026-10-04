' Saved state is one versioned JSON document per device (see the data model in
' docs/requirements.md). Records carry updatedAt; deletions are tombstones.

sub init()
    m.SCHEMA = 1
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

' entry: { kind: "movie" | "episode", id, position, duration }  (seconds)
function savePosition(entry as Object) as Boolean
    kind = asString(entry.kind)
    id = toInt(entry.id)
    r = findResume(kind, id)
    if r = invalid
        r = { kind: kind, id: id }
        m.doc.resume.Push(r)
    end if
    r.position = toInt(entry.position)
    r.duration = toInt(entry.duration)
    r.updatedAt = nowSeconds()
    return persist()
end function

function clearPosition(kind as String, id as Dynamic) as Boolean
    id = toInt(id)
    kept = []
    for each r in m.doc.resume
        if not (r.kind = kind and toInt(r.id) = id) then kept.Push(r)
    end for
    if kept.Count() = m.doc.resume.Count() then return true
    m.doc.resume = kept
    return persist()
end function

function findResume(kind as String, id as Integer) as Dynamic
    for each r in m.doc.resume
        if r.kind = kind and toInt(r.id) = id then return r
    end for
    return invalid
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
    }
end function

' Fill anything missing so the rest of the code can trust the shape.
' Schema migrations go here when the schema number increases.
sub normalizeDocument(doc as Object)
    if toInt(doc.schema) > m.SCHEMA then print "[state] WARNING: saved schema "; doc.schema; " is newer than this build ("; m.SCHEMA; ")"
    if asString(doc.deviceId) = "" then doc.deviceId = CreateObject("roDeviceInfo").GetRandomUUID()
    doc.deviceName = asString(doc.deviceName)
    for each key in ["favorites", "series", "resume"]
        if type(doc[key]) <> "roArray" then doc[key] = []
    end for
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
