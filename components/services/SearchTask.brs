sub init()
    m.top.functionName = "runLoop"
end sub

sub runLoop()
    m.LIMIT = 50                ' results per kind
    m.index = { live: [], movie: [], series: [] }
    m.byId = { live: {}, movie: {}, series: {} }    ' "<id>" -> entry
    m.matchLookup = {}          ' kind -> { byEpg, byName }, built when first needed
    m.matchRules = invalid
    m.selfTested = false
    port = CreateObject("roMessagePort")
    m.top.ObserveField("load", port)
    m.top.ObserveField("query", port)
    m.top.ObserveField("matchRequest", port)
    m.top.ObserveField("gamesRequest", port)
    m.top.ObserveField("marketsRequest", port)
    m.top.ObserveField("localsRequest", port)
    m.top.ready = true

    while true
        msg = wait(0, port)
        if type(msg) = "roSGNodeEvent"
            if msg.GetField() = "load"
                loadKind(msg.GetData())
            else if msg.GetField() = "matchRequest"
                m.top.matchResult = matchSaved(msg.GetData())
            else if msg.GetField() = "gamesRequest"
                m.top.gamesResult = findGames(msg.GetData())
            else if msg.GetField() = "localsRequest"
                m.top.localsResult = listLocalStations(msg.GetData())
            else if msg.GetField() = "marketsRequest"
                m.top.marketsResult = { id: msg.GetData().id, ready: m.index.live.Count() > 0, markets: listMarkets() }
            else
                ' Typing sends a query per pause; answer only the newest.
                latest = msg.GetData()
                pending = port.PeekMessage()
                while pending <> invalid and type(pending) = "roSGNodeEvent" and pending.GetField() = "query"
                    latest = port.GetMessage().GetData()
                    pending = port.PeekMessage()
                end while
                answer(latest)
            end if
        end if
    end while
end sub

' ---------------------------------------------------------------------------
' Index

sub loadKind(req as Object)
    kind = asString(req.kind)
    file = asString(req.file)
    if kind = "reset"
        ' Account changed: drop the old account's lists until the new ones load.
        m.index = { live: [], movie: [], series: [] }
        m.byId = { live: {}, movie: {}, series: {} }
        m.matchLookup = {}
        resetCategoryLookups()
        m.top.counts = { live: 0, movie: 0, series: 0 }
        m.top.archive = {}
        print "[search] index cleared"
        return
    end if
    if kind = "categories"
        ' The live category list changed: My Teams and local stations re-read it.
        resetCategoryLookups()
        m.top.indexVersion = m.top.indexVersion + 1
        return
    end if
    if m.index[kind] = invalid or not CreateObject("roFileSystem").Exists(file) then return

    timer = CreateObject("roTimespan")
    raw = ParseJson(ReadAsciiFile(file))
    if type(raw) <> "roArray"
        print "[search] "; kind; " list unreadable; keeping the previous index"
        ' Drop its age stamp so the next refresh downloads it again.
        fs = CreateObject("roFileSystem")
        if fs.Exists(file + ".time") then fs.Delete(file + ".time")
        return
    end if

    entries = []
    byId = {}
    archive = {}
    for each item in raw
        if type(item) = "roAssociativeArray"
            e = indexEntry(kind, item)
            if e.name <> ""
                entries.Push(e)
                byId[e.itemId.ToStr()] = e
                if e.archiveDays > 0 then archive[e.itemId.ToStr()] = e.archiveDays
            end if
        end if
    end for
    raw = invalid
    m.index[kind] = entries
    m.byId[kind] = byId
    m.matchLookup.Delete(kind)

    counts = m.top.counts
    if type(counts) <> "roAssociativeArray" then counts = {}
    counts[kind] = entries.Count()
    m.top.counts = counts
    if kind = "live"
        m.top.archive = archive
        print "[search] live: "; entries.Count(); " channels, "; archive.Count(); " with a catch-up archive ("; timer.TotalMilliseconds(); " ms)"
    else
        print "[search] "; kind; ": "; entries.Count(); " indexed ("; timer.TotalMilliseconds(); " ms)"
    end if
    if kind = "live" then resetCategoryLookups()
    m.top.indexVersion = m.top.indexVersion + 1
    if m.top.selfTest and not m.selfTested and m.index.live.Count() > 0 and m.index.series.Count() > 0
        m.selfTested = true
        matchSelfTest()
    end if
end sub

' My Teams' lookups built from the live index and category list.
sub resetCategoryLookups()
    m.eventCategories = invalid
    m.epgGroups = invalid
    m.localStations = invalid
end sub

' ---------------------------------------------------------------------------
' Channel matching (rules in ChannelMatch.brs). Only saved items whose IDs
' are missing from the current catalog are looked up, and only against a
' fully loaded list, so a failed download can't re-match anything.

' req: { id, channels: [{ streamId, name, epgChannelId }], series: [{ seriesId, name, year }] }
function matchSaved(req as Object) as Object
    result = { id: req.id, liveReady: m.index.live.Count() > 0, seriesReady: m.index.series.Count() > 0, channels: {}, series: {}, unmatched: [] }
    if result.liveReady and type(req.channels) = "roArray"
        for each saved in req.channels
            oldId = toInt(saved.streamId).ToStr()
            if m.byId.live[oldId] = invalid and not result.channels.DoesExist(oldId)
                found = matchChannel(saved, lookupFor("live"), currentMatchRules())
                if found = invalid
                    result.unmatched.Push("channel " + oldId + " '" + asString(saved.name) + "'")
                else
                    e = found.entry
                    result.channels[oldId] = { streamId: e.itemId, name: e.name, epgChannelId: e.epgChannelId, method: found.method }
                    print "[match] channel "; oldId; " '"; saved.name; "' -> "; e.itemId; " '"; e.name; "' by "; found.method
                end if
            end if
        end for
    end if
    if result.seriesReady and type(req.series) = "roArray"
        for each saved in req.series
            oldId = toInt(saved.seriesId).ToStr()
            if m.byId.series[oldId] = invalid and not result.series.DoesExist(oldId)
                found = matchSeries(saved, lookupFor("series"), currentMatchRules())
                if found = invalid
                    result.unmatched.Push("series " + oldId + " '" + asString(saved.name) + "'")
                else
                    e = found.entry
                    result.series[oldId] = { seriesId: e.itemId, name: e.name, year: e.year, method: found.method }
                    print "[match] series "; oldId; " '"; saved.name; "' -> "; e.itemId; " '"; e.name; "' by "; found.method
                end if
            end if
        end for
    end if
    for each line in result.unmatched
        print "[match] no match for "; line; "; keeping it as is"
    end for
    return result
end function

function currentMatchRules() as Object
    if m.matchRules = invalid then m.matchRules = loadMatchRules()
    return m.matchRules
end function

' Guide-ID and name groups for a kind, built the first time a match needs
' them (not at every load: most refreshes have nothing missing).
function lookupFor(kind as String) as Object
    lookup = m.matchLookup[kind]
    if lookup = invalid
        lookup = { byEpg: {}, byName: {} }
        for each e in m.index[kind]
            if kind = "live" then addToGroup(lookup.byEpg, LCase(e.epgChannelId), e)
            addToGroup(lookup.byName, matchKey(e.name, currentMatchRules()), e)
        end for
        m.matchLookup[kind] = lookup
    end if
    return lookup
end function

' On-device check against the real catalog, run once when the manifest has
' match_selftest=1: saved items with made-up (missing) IDs must be found again.
sub matchSelfTest()
    print "[match] ---- self-test ----"
    withGuide = invalid
    for each e in m.index.live
        if withGuide = invalid and e.epgChannelId <> "" and lookupFor("live").byEpg[LCase(e.epgChannelId)].Count() = 1 then withGuide = e
    end for
    named = invalid
    for each e in m.index.live
        if named = invalid and e.epgChannelId = "" and lookupFor("live").byName[matchKey(e.name, currentMatchRules())].Count() = 1 then named = e
    end for
    ' A guide ID shared by several channels (HD/SD/backup copies of one feed).
    shared = invalid
    for each e in m.index.live
        if shared = invalid and e.epgChannelId <> "" and lookupFor("live").byEpg[LCase(e.epgChannelId)].Count() > 1 then shared = e
    end for
    show = invalid
    for each e in m.index.series
        if show = invalid and e.year > 0 and lookupFor("series").byName[matchKey(e.name, currentMatchRules())].Count() = 1 then show = e
    end for

    req = { id: "selftest", channels: [], series: [] }
    expected = {}
    if withGuide <> invalid
        req.channels.Push({ streamId: 900000001, name: "Renamed " + withGuide.name, epgChannelId: withGuide.epgChannelId })
        expected["900000001"] = withGuide.itemId
    end if
    if named <> invalid
        req.channels.Push({ streamId: 900000002, name: named.name + " (1080p)", epgChannelId: "" })
        expected["900000002"] = named.itemId
    end if
    req.channels.Push({ streamId: 900000003, name: "No Such Channel Anywhere 12345", epgChannelId: "" })
    expected["900000003"] = 0
    if shared <> invalid
        group = lookupFor("live").byEpg[LCase(shared.epgChannelId)]
        print "[match] shared guide ID '"; shared.epgChannelId; "' is on "; group.Count(); " channels"
        ' Same guide ID, same name: that channel, not just any in the group.
        ' Needs a name unique within the group (providers list exact
        ' duplicates, where either answer is right).
        distinct = invalid
        for each candidate in group
            sameKey = 0
            for each other in group
                if matchKey(other.name, currentMatchRules()) = matchKey(candidate.name, currentMatchRules()) then sameKey = sameKey + 1
            end for
            if sameKey = 1 and candidate.itemId <> group[0].itemId then distinct = candidate
        end for
        if distinct <> invalid
            req.channels.Push({ streamId: 900000005, name: distinct.name, epgChannelId: shared.epgChannelId })
            expected["900000005"] = distinct.itemId
        else
            print "[match] (no channel with a unique name in that group; skipping the same-name case)"
        end if
        ' Same guide ID, unknown name: the first channel carrying that feed.
        req.channels.Push({ streamId: 900000006, name: "Zzq Unknown Name", epgChannelId: shared.epgChannelId })
        expected["900000006"] = group[0].itemId
    end if
    if show <> invalid
        req.series.Push({ seriesId: 900000004, name: show.name, year: show.year })
        expected["900000004"] = show.itemId
    end if

    result = matchSaved(req)
    passed = 0
    for each oldId in expected
        got = 0
        if result.channels[oldId] <> invalid then got = result.channels[oldId].streamId
        if result.series[oldId] <> invalid then got = result.series[oldId].seriesId
        outcome = "FAIL"
        if got = expected[oldId]
            outcome = "PASS"
            passed = passed + 1
        end if
        print "[match] "; outcome; " "; oldId; ": expected "; expected[oldId]; ", got "; got
    end for
    print "[match] ---- self-test: "; passed; " of "; expected.Count(); " passed ----"
end sub

' Only what search shows and what playing or opening an item needs.
function indexEntry(kind as String, item as Object) as Object
    name = asString(item.name)
    e = { key: LCase(name), name: name, num: "", epgChannelId: "", ext: "", year: 0, archiveDays: 0 }
    if kind = "live"
        e.kind = "channel"
        e.itemId = toInt(item.stream_id)
        e.epgChannelId = asString(item.epg_channel_id)
        e.categoryId = asString(item.category_id)
        if toInt(item.tv_archive) = 1 then e.archiveDays = toInt(item.tv_archive_duration)
        if toInt(item.tv_archive) = 1 and e.archiveDays <= 0 then e.archiveDays = 1
    else
        e.kind = kind
        if kind = "series" then e.itemId = toInt(item.series_id) else e.itemId = toInt(item.stream_id)
        e.ext = asString(item.container_extension)
        e.year = itemYear(item)
        if e.year > 0 then e.num = e.year.ToStr()
    end if
    return e
end function

' ---------------------------------------------------------------------------
' Matching: every word must appear in the name; names starting with the
' search text come first.

sub answer(q as Object)
    text = LCase(asString(q.text)).Trim()
    items = []
    if text <> ""
        words = []
        for each w in text.Split(" ")
            if w <> "" then words.Push(w)
        end for
        ' The device's local stations that match come first among channels,
        ' tagged local: among ~200 affiliates for "abc", yours would otherwise
        ' be lost past the result cap.
        localIds = {}
        locals = []
        stations = localStations()[asString(q.market)]
        if stations <> invalid
            for each s in stations
                if wordsMatch(s.entry.key, words)
                    item = resultItem(s.entry)
                    item.local = true
                    locals.Push(item)
                    localIds[s.entry.itemId.ToStr()] = true
                end if
            end for
        end if
        items.Append(locals)
        for each item in matchKind(m.index.live, text, words)
            if not localIds.DoesExist(item.itemId.ToStr()) then items.Push(item)
        end for
        for each kind in ["movie", "series"]
            items.Append(matchKind(m.index[kind], text, words))
        end for
    end if
    m.top.results = { id: q.id, text: asString(q.text), items: items }
end sub

' A market's stations for Live TV's "Local stations" category, ABC, CBS, NBC,
' FOX order, in the shape of get_live_streams items so the catalog screen can
' show them like any other category.
function listLocalStations(req as Object) as Object
    result = { id: req.id, market: asString(req.market), ready: m.index.live.Count() > 0, items: [] }
    stations = localStations()[result.market]
    if stations = invalid then return result
    for each network in ["ABC", "CBS", "NBC", "FOX"]
        for each s in stations
            if s.network = network
                e = s.entry
                archive = 0
                if e.archiveDays > 0 then archive = 1
                result.items.Push({ stream_id: e.itemId, name: e.name, epg_channel_id: e.epgChannelId, tv_archive: archive, tv_archive_duration: e.archiveDays })
            end if
        end for
    end for
    return result
end function

function wordsMatch(key as String, words as Object) as Boolean
    for each w in words
        if Instr(1, key, w) = 0 then return false
    end for
    return true
end function

function matchKind(entries as Object, text as String, words as Object) as Object
    starts = []
    contains = []
    for each e in entries
        if starts.Count() >= m.LIMIT then exit for
        matched = true
        for each w in words
            if Instr(1, e.key, w) = 0
                matched = false
                exit for
            end if
        end for
        if matched
            if Left(e.key, text.Len()) = text
                starts.Push(e)
            else if contains.Count() < m.LIMIT
                contains.Push(e)
            end if
        end if
    end for

    out = []
    for each e in starts
        out.Push(resultItem(e))
    end for
    for each e in contains
        if out.Count() >= m.LIMIT then exit for
        out.Push(resultItem(e))
    end for
    return out
end function

function resultItem(e as Object) as Object
    return {
        kind: e.kind
        itemId: e.itemId
        streamId: e.itemId
        name: e.name
        num: e.num
        epgChannelId: e.epgChannelId
        ext: e.ext
        year: e.year
        archiveDays: e.archiveDays
        local: false
    }
end function
