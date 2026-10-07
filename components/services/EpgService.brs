sub init()
    m.cache = {}        ' streamId -> { now, upcoming, validUntil }
    m.inflight = {}
    m.wanted = []           ' channels on screen (want); pump() fetches from these
    m.MAX_INFLIGHT = 6
    m.deferred = invalid    ' wanted before ApiTask was listening
    m.rules = loadGuideRules()
end sub

sub onApi()
    api = m.top.api
    if api = invalid then return
    api.ObserveFieldScoped("response", "onApiResponse")
    api.ObserveFieldScoped("ready", "onApiReady")
end sub

sub onApiReady()
    if m.top.api.ready and m.deferred <> invalid
        ids = m.deferred
        m.deferred = invalid
        want(ids)
    end if
end sub

' The channels on screen now (the latest call wins). At most MAX_INFLIGHT
' guide requests run at a time, always for channels still wanted, so fast
' scrolling never queues requests for rows that are already gone.
function want(streamIds as Object) as Boolean
    api = m.top.api
    if api = invalid then return false
    if not api.ready
        m.deferred = streamIds
        return false
    end if
    m.wanted = streamIds
    pump()
    return true
end function

sub pump()
    api = m.top.api
    if api = invalid or type(m.wanted) <> "roArray" then return
    now = nowSeconds()
    for each id in m.wanted
        if m.inflight.Count() >= m.MAX_INFLIGHT then return
        key = toInt(id).ToStr()
        entry = m.cache[key]
        if key <> "0" and m.inflight[key] = invalid and (entry = invalid or entry.validUntil <= now)
            m.inflight[key] = true
            api.request = { id: "epg:" + key, action: "get_short_epg", params: { stream_id: key, limit: 4 } }
        end if
    end for
end sub

function getPrograms(streamIds as Object) as Object
    out = {}
    for each id in streamIds
        key = toInt(id).ToStr()
        entry = m.cache[key]
        if entry <> invalid then out[key] = { streamId: key, now: entry.now, upcoming: entry.upcoming }
    end for
    return out
end function

function clear() as Boolean
    m.cache = {}
    return true
end function

sub onApiResponse(event as Object)
    res = event.GetData()
    if Left(res.id, 4) <> "epg:" then return
    key = Mid(res.id, 5)
    m.inflight.Delete(key)
    now = nowSeconds()

    if not res.ok
        ' Don't hammer a failing channel; try again in two minutes.
        m.cache[key] = { now: invalid, upcoming: invalid, validUntil: now + 120 }
        pump()
        return
    end if

    programs = []
    if type(res.data) = "roAssociativeArray" and type(res.data.epg_listings) = "roArray"
        for each listing in res.data.epg_listings
            ' Skip anything that isn't a listing object (malformed provider data).
            if type(listing) = "roAssociativeArray"
                p = toProgram(listing)
                if p <> invalid then programs.Push(p)
            end if
        end for
    end if
    programs.SortBy("start")

    current = invalid
    for each p in programs
        if p.start <= now and p.ends > now
            current = p
            exit for
        end if
    end for
    upcomingAfter = now
    if current <> invalid then upcomingAfter = current.ends
    upcoming = invalid
    for each p in programs
        if p.start >= upcomingAfter
            upcoming = p
            exit for
        end if
    end for

    validUntil = now + 900
    if current <> invalid
        validUntil = current.ends
    else if upcoming <> invalid
        validUntil = upcoming.start
    end if
    if validUntil < now + 30 then validUntil = now + 30

    m.cache[key] = { now: current, upcoming: upcoming, validUntil: validUntil }
    m.top.programs = { streamId: key, now: current, upcoming: upcoming }
    pump()      ' next wanted channel, if any
end sub

' Xtream short EPG listing -> { title, flags, start, ends, description }. Uses the UTC
' start/stop timestamps, never the provider's local-time strings.
function toProgram(listing as Object) as Dynamic
    start = toInt(listing.start_timestamp)
    ends = toInt(listing.stop_timestamp)
    if start <= 0 or ends <= start then return invalid

    title = asString(listing.title)
    description = asString(listing.description)
    if m.rules.base64Titles
        title = decodeBase64(title)
        description = decodeBase64(description)
    end if
    clean = cleanTitle(title)
    ' The description (episode synopsis) for the player strip and channel info.
    return { title: clean.title, flags: clean.flags, start: start, ends: ends, description: cleanTitle(description).title }
end function

function decodeBase64(text as String) as String
    if text = "" then return ""
    bytes = CreateObject("roByteArray")
    bytes.FromBase64String(text)
    decoded = bytes.ToAsciiString()
    if decoded = "" then return text
    return decoded
end function

' Strip superscript tags (e.g. Live/New) for display and keep them as flags.
function cleanTitle(title as String) as Object
    flags = []
    for each tag in m.rules.titleTags
        if Instr(1, title, tag.text) > 0
            flags.Push(tag.flag)
            title = title.Replace(tag.text, "")
        end if
    end for
    title = title.Trim()
    while Instr(1, title, "  ") > 0
        title = title.Replace("  ", " ")
    end while
    return { title: title, flags: flags }
end function

function loadGuideRules() as Object
    rules = { base64Titles: true, titleTags: [] }
    json = ParseJson(ReadAsciiFile("pkg:/data/guide-rules.json"))
    if type(json) <> "roAssociativeArray"
        print "[epg] WARNING: data/guide-rules.json missing or invalid; using defaults"
        return rules
    end if
    if type(json.epg) = "roAssociativeArray" and json.epg.base64Titles <> invalid then rules.base64Titles = isTrue(json.epg.base64Titles)
    if type(json.titleTags) = "roArray"
        for each tag in json.titleTags
            if type(tag) = "roAssociativeArray" and asString(tag.text) <> "" then rules.titleTags.Push({ text: asString(tag.text), flag: asString(tag.flag) })
        end for
    end if
    return rules
end function
