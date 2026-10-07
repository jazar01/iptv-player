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
    m.top.ObserveField("infoRequest", port)
    m.top.ObserveField("iconsRequest", port)
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
            else if msg.GetField() = "iconsRequest"
                m.top.iconsResult = channelIcons(msg.GetData())
            else if msg.GetField() = "infoRequest"
                m.top.infoResult = channelDetails(msg.GetData())
            else if msg.GetField() = "localsRequest"
                m.top.localsResult = listLocalStations(msg.GetData())
            else if msg.GetField() = "marketsRequest"
                m.top.marketsResult = { id: msg.GetData().id, ready: m.index.live.Count() > 0 and liveCategories() <> invalid, markets: listMarkets() }
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
    m.vocabulary = invalid      ' fuzzy search's word list, rebuilt when next needed

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
    m.categoryNames = invalid
end sub

' Home channel cards: logo URLs for these stream IDs ("" when the channel
' has none or isn't in the list). req: { id, streamIds: [] }
function channelIcons(req as Object) as Object
    result = { id: req.id, ready: m.index.live.Count() > 0, icons: {} }
    if not result.ready then return result
    if type(req.streamIds) <> "roArray" then req.streamIds = []
    for each id in req.streamIds
        key = toInt(id).ToStr()
        e = m.byId.live[key]
        icon = ""
        if e <> invalid then icon = asString(e.icon)
        result.icons[key] = icon
    end for
    return result
end function

' Channel info: one live channel's details and its other copies (same
' guide ID), from the index. req: { id, streamId, market }
function channelDetails(req as Object) as Object
    result = { id: req.id, streamId: toInt(req.streamId), found: false, copies: [] }
    e = m.byId.live[toInt(req.streamId).ToStr()]
    if e = invalid then return result
    result.found = true
    result.name = e.name
    result.icon = asString(e.icon)
    result.epgChannelId = e.epgChannelId
    result.archiveDays = e.archiveDays
    result.category = liveCategoryName(e.categoryId)
    result.local = false
    stations = localStations()[asString(req.market)]
    if stations <> invalid
        for each s in stations
            if s.entry.itemId = e.itemId then result.local = true
        end for
    end if
    if e.epgChannelId <> ""
        group = epgGroup(e.epgChannelId)
        if group <> invalid
            for each c in group
                if c.itemId <> e.itemId and result.copies.Count() < 15 then result.copies.Push({ streamId: c.itemId, name: c.name, epgChannelId: c.epgChannelId, archiveDays: c.archiveDays })
            end for
        end if
    end if
    ' No copies and asked for (a failed channel): similar channels by name.
    result.similar = []
    if result.copies.Count() = 0 and isTrue(req.similar) then result.similar = similarChannels(e)
    return result
end function

' Channels whose names share this one's main words, for a channel with no
' copies ("Tennis Channel 2" -> Tennis Channel, Tennis Channel Plus). Main
' words: the name after any provider prefix ("US | "), without quality tags,
' punctuation, numbers or short words. Shorter names first, up to 15.
function similarChannels(e as Object) as Object
    name = e.name
    bar = 0
    p = Instr(1, name, "|")
    while p > 0
        bar = p
        p = Instr(p + 1, name, "|")
    end while
    if bar > 0 then name = Mid(name, bar + 1)
    words = []
    for each w in matchKey(name, currentMatchRules()).Split(" ")
        if w.Len() >= 3 and not CreateObject("roRegex", "^[0-9]+$", "").IsMatch(w) then words.Push(w)
    end for
    found = []
    if words.Count() = 0 then return found
    for each c in m.index.live
        if c.itemId <> e.itemId
            matched = true
            for each w in words
                if Instr(1, c.key, w) = 0
                    matched = false
                    exit for
                end if
            end for
            if matched then found.Push({ streamId: c.itemId, name: c.name, epgChannelId: c.epgChannelId, archiveDays: c.archiveDays, length: c.name.Len() })
        end if
    end for
    found.SortBy("length")
    while found.Count() > 15
        found.Pop()
    end while
    return found
end function

' Live category ID -> name, from the cached category list.
function liveCategoryName(id as String) as String
    if m.categoryNames = invalid
        cats = liveCategories()
        if cats = invalid then return ""
        m.categoryNames = {}
        for each c in cats
            m.categoryNames[asString(c.category_id)] = asString(c.category_name)
        end for
    end if
    return asString(m.categoryNames[id])
end function

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
        e.icon = asString(item.stream_icon)     ' logo URL, for channel info
        if toInt(item.tv_archive) = 1 then e.archiveDays = toInt(item.tv_archive_duration)
        if toInt(item.tv_archive) = 1 and e.archiveDays <= 0 then e.archiveDays = 1
    else
        e.kind = kind
        if kind = "series" then e.itemId = toInt(item.series_id) else e.itemId = toInt(item.stream_id)
        e.ext = asString(item.container_extension)
        e.year = itemYear(item)
        ' Movie poster or series cover: the details page and Continue Watching.
        e.icon = asString(item.stream_icon)
        if e.icon = "" then e.icon = asString(item.cover)
        ' Movies show the year in a column; series keep it in the name.
        if e.year > 0 and kind = "movie" then e.num = e.year.ToStr()
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
        items = searchItems(q, text, searchTerms(words, false))
        ' Nothing as typed or spoken: try close spellings ("bitish" -> british).
        if items.Count() = 0 then items = searchItems(q, text, searchTerms(words, true))
        ' Still nothing: names with all but one of the words, for a word voice
        ' got wrong ("british break off" -> British Bake Off).
        if items.Count() = 0 and words.Count() >= 2 then items = allButOneItems(q, text, searchTerms(words, true))
    end if
    m.top.results = { id: q.id, text: asString(q.text), items: items }
end sub

' Channels (the market's local stations first), then movies, then series.
function searchItems(q as Object, text as String, terms as Object) as Object
    ' The device's local stations that match come first among channels,
    ' tagged local: among ~200 affiliates for "abc", yours would otherwise
    ' be lost past the result cap.
    localIds = {}
    items = []
    stations = localStations()[asString(q.market)]
    if stations <> invalid
        for each s in stations
            if termsMatch(s.entry.key, terms)
                item = resultItem(s.entry)
                item.local = true
                items.Push(item)
                localIds[s.entry.itemId.ToStr()] = true
            end if
        end for
    end if
    for each item in matchKind(m.index.live, text, terms)
        if not localIds.DoesExist(item.itemId.ToStr()) then items.Push(item)
    end for
    for each kind in ["movie", "series"]
        items.Append(matchKind(m.index[kind], text, terms))
    end for
    return items
end function

' A market's stations for Live TV's "Local stations" category, ABC, CBS, NBC,
' FOX order, in the shape of get_live_streams items so the catalog screen can
' show them like any other category.
function listLocalStations(req as Object) as Object
    ' Ready only once both lists are in: stations are found from channel
    ' names within the live categories (an empty answer before then would be
    ' taken as final).
    result = { id: req.id, market: asString(req.market), ready: m.index.live.Count() > 0 and liveCategories() <> invalid, items: [] }
    stations = localStations()[result.market]
    if stations = invalid then return result
    for each network in ["ABC", "CBS", "NBC", "FOX"]
        for each s in stations
            if s.network = network
                e = s.entry
                archive = 0
                if e.archiveDays > 0 then archive = 1
                result.items.Push({ stream_id: e.itemId, name: e.name, epg_channel_id: e.epgChannelId, tv_archive: archive, tv_archive_duration: e.archiveDays, stream_icon: asString(e.icon) })
            end if
        end for
    end for
    return result
end function

' Every search word must be in the name, in some form: terms holds, per
' word, the strings that count for it (its stem and synonyms).
function termsMatch(key as String, terms as Object) as Boolean
    for each alternatives in terms
        found = false
        for each a in alternatives
            if Instr(1, key, a) > 0
                found = true
                exit for
            end if
        end for
        if not found then return false
    end for
    return true
end function

' Search words -> [[strings that count for each word]]: the word's stem,
' the stems of its synonyms (data/guide-rules.json "search"), and with fuzzy
' also catalog words spelled almost the same.
function searchTerms(words as Object, fuzzy as Boolean) as Object
    synonyms = searchSynonyms()
    terms = []
    for each w in words
        s = wordStem(w)
        alternatives = [s]
        group = synonyms[s]
        if group <> invalid
            for each other in group
                if other <> s then alternatives.Push(other)
            end for
        end if
        if fuzzy then alternatives.Append(closeWords(w))
        terms.Push(alternatives)
    end for
    return terms
end function

' Word forms without a dictionary: common endings come off so "baking",
' "baked", "bakes" and "bake" all become "bak" and match each other as
' substrings. Stems keep at least 3 letters; short words (news, kids) stay.
function wordStem(w as String) as String
    if Right(w, 2) = "ss" or w.Len() < 4 then return w
    for each suffix in ["ing", "ed", "es", "s"]
        n = suffix.Len()
        if Right(w, n) = suffix and w.Len() - n >= 3 and not (suffix = "s" and w.Len() <= 4) and not (suffix = "ed" and Right(w, 3) = "eed")
            s = Left(w, w.Len() - n)
            ' running -> runn -> run
            if suffix <> "s" and suffix <> "es" and s.Len() >= 4 and Right(s, 1) = Mid(s, s.Len() - 1, 1) then s = Left(s, s.Len() - 1)
            return s
        end if
    end for
    if Right(w, 1) = "e" then return Left(w, w.Len() - 1)   ' bake -> bak
    return w
end function

' Results for the search with each word left out in turn, merged without
' repeats (channels first, then movies, then series, as usual).
function allButOneItems(q as Object, text as String, terms as Object) as Object
    seen = {}
    byKind = { channel: [], movie: [], series: [] }
    for skip = 0 to terms.Count() - 1
        fewer = []
        for i = 0 to terms.Count() - 1
            if i <> skip then fewer.Push(terms[i])
        end for
        for each item in searchItems(q, text, fewer)
            key = item.kind + ":" + item.itemId.ToStr()
            if seen[key] = invalid and byKind[item.kind] <> invalid and byKind[item.kind].Count() < m.LIMIT
                seen[key] = true
                byKind[item.kind].Push(item)
            end if
        end for
    end for
    items = []
    for each kind in ["channel", "movie", "series"]
        items.Append(byKind[kind])
    end for
    return items
end function

' ---------------------------------------------------------------------------
' Fuzzy search: catalog words spelled almost like a search word. Used only
' when a search finds nothing as typed. Compares against catalog words with
' the same first letter and about the same length: up to 1 letter off for
' 4-6 letter words, 2 for longer ones (shorter words aren't guessed at).

function closeWords(w as String) as Object
    out = []
    limit = 1
    if w.Len() < 4 then return out
    if w.Len() >= 7 then limit = 2
    bucket = vocabulary()[Left(w, 1)]
    if bucket = invalid then return out
    for each candidate in bucket
        if Abs(candidate.Len() - w.Len()) <= limit and candidate <> w
            if editDistance(w, candidate, limit) <= limit and out.Count() < 10 then out.Push(candidate)
        end if
    end for
    return out
end function

' First letter -> distinct words (4+ letters) in every indexed name. Built
' when first needed (about a second), dropped when a list reloads.
function vocabulary() as Object
    if m.vocabulary <> invalid then return m.vocabulary
    timer = CreateObject("roTimespan")
    ' Keys here are catalog words, so no method calls on seen: a word like
    ' "count" would shadow .Count() (it did). Brackets and a counter only.
    seen = {}
    total = 0
    m.vocabulary = {}
    splitter = CreateObject("roRegex", "[^a-z0-9]+", "")
    for each kind in ["live", "movie", "series"]
        for each e in m.index[kind]
            for each word in splitter.Split(e.key)
                if word.Len() >= 4 and seen[word] = invalid
                    seen[word] = true
                    total = total + 1
                    first = Left(word, 1)
                    if m.vocabulary[first] = invalid then m.vocabulary[first] = []
                    m.vocabulary[first].Push(word)
                end if
            end for
        end for
    end for
    print "[search] fuzzy word list: "; total; " words ("; timer.TotalMilliseconds(); " ms)"
    return m.vocabulary
end function

' Levenshtein distance, giving up (returning limit + 1) once every path is
' over limit.
function editDistance(a as String, b as String, limit as Integer) as Integer
    previous = []
    for j = 0 to b.Len()
        previous.Push(j)
    end for
    for i = 1 to a.Len()
        current = [i]
        best = i
        ca = Mid(a, i, 1)
        for j = 1 to b.Len()
            cost = 1
            if ca = Mid(b, j, 1) then cost = 0
            v = previous[j - 1] + cost
            if previous[j] + 1 < v then v = previous[j] + 1
            if current[j - 1] + 1 < v then v = current[j - 1] + 1
            current.Push(v)
            if v < best then best = v
        end for
        if best > limit then return limit + 1
        previous = current
    end for
    return previous[b.Len()]
end function

' Stem -> stems of its whole synonym group, loaded once.
function searchSynonyms() as Object
    if m.searchSynonyms <> invalid then return m.searchSynonyms
    m.searchSynonyms = {}
    json = ParseJson(ReadAsciiFile("pkg:/data/guide-rules.json"))
    if type(json) <> "roAssociativeArray" or type(json.search) <> "roAssociativeArray" or type(json.search.synonyms) <> "roArray" then return m.searchSynonyms
    for each group in json.search.synonyms
        if type(group) = "roArray"
            stems = []
            for each word in group
                text = LCase(asString(word)).Trim()
                if text <> ""
                    if Instr(1, text, " ") = 0 then text = wordStem(text)
                    stems.Push(text)
                end if
            end for
            for each s in stems
                m.searchSynonyms[s] = stems
            end for
        end if
    end for
    return m.searchSynonyms
end function

function matchKind(entries as Object, text as String, terms as Object) as Object
    starts = []
    contains = []
    for each e in entries
        if starts.Count() >= m.LIMIT then exit for
        if termsMatch(e.key, terms)
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
        icon: asString(e.icon)      ' channels only
        local: false
    }
end function
