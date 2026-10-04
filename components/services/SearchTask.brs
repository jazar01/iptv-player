sub init()
    m.top.functionName = "runLoop"
end sub

sub runLoop()
    m.LIMIT = 50                ' results per kind
    m.index = { live: [], movie: [], series: [] }
    port = CreateObject("roMessagePort")
    m.top.ObserveField("load", port)
    m.top.ObserveField("query", port)
    m.top.ready = true

    while true
        msg = wait(0, port)
        if type(msg) = "roSGNodeEvent"
            if msg.GetField() = "load"
                loadKind(msg.GetData())
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
    if m.index[kind] = invalid or not CreateObject("roFileSystem").Exists(file) then return

    timer = CreateObject("roTimespan")
    raw = ParseJson(ReadAsciiFile(file))
    if type(raw) <> "roArray"
        print "[search] "; kind; " list unreadable; keeping the previous index"
        return
    end if

    entries = []
    archive = {}
    for each item in raw
        if type(item) = "roAssociativeArray"
            e = indexEntry(kind, item)
            if e.name <> ""
                entries.Push(e)
                if e.archiveDays > 0 then archive[e.itemId.ToStr()] = e.archiveDays
            end if
        end if
    end for
    raw = invalid
    m.index[kind] = entries

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
end sub

' Only what search shows and what playing or opening an item needs.
function indexEntry(kind as String, item as Object) as Object
    name = asString(item.name)
    e = { key: LCase(name), name: name, num: "", epgChannelId: "", ext: "", year: 0, archiveDays: 0 }
    if kind = "live"
        e.kind = "channel"
        e.itemId = toInt(item.stream_id)
        e.epgChannelId = asString(item.epg_channel_id)
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
        for each kind in ["live", "movie", "series"]
            items.Append(matchKind(m.index[kind], text, words))
        end for
    end if
    m.top.results = { id: q.id, text: asString(q.text), items: items }
end sub

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
    }
end function
