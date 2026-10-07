' Search: keeps the SearchTask index fed and relays queries and results.
' The full catalog lists are downloaded by ApiTask straight to cachefs:
' (saveOnly), at most once a day, and SearchTask indexes them from disk, so
' the big lists never pass through the render thread.

sub initSearch()
    m.searchTask = m.top.FindNode("searchTask")
    m.searchPending = []        ' { field, value } set before the task is listening
    m.searchQueryId = 0
    m.searchIndexRequested = false
    m.archiveDays = {}          ' streamId -> catch-up archive days, from the live index
    m.searchIndexStarted = false    ' logged in and asked at least once

    ' A failed download is tried again after 5 minutes; every 6 hours the
    ' lists are checked, so a session left running still gets the daily
    ' refresh (each list is only downloaded when it's over a day old).
    m.searchRetryTimer = CreateObject("roSGNode", "Timer")
    m.searchRetryTimer.duration = 300
    m.searchRetryTimer.ObserveField("fire", "onSearchIndexTimer")
    m.searchDailyTimer = CreateObject("roSGNode", "Timer")
    m.searchDailyTimer.duration = 6 * 3600
    m.searchDailyTimer.repeat = true
    m.searchDailyTimer.ObserveField("fire", "onSearchIndexTimer")
    m.top.AppendChild(m.searchRetryTimer)
    m.top.AppendChild(m.searchDailyTimer)
    m.searchDailyTimer.control = "start"

    m.searchTask.ObserveField("ready", "onSearchReady")
    m.searchTask.ObserveField("results", "onSearchResults")
    m.searchTask.ObserveField("archive", "onArchiveList")
    m.searchTask.ObserveField("indexVersion", "onIndexChanged")
    m.searchTask.ObserveField("matchResult", "onMatchResult")
    m.searchTask.ObserveField("gamesResult", "onGamesResult")
    m.searchTask.ObserveField("marketsResult", "onMarketsResult")
    m.searchTask.ObserveField("localsResult", "onLocalsResult")
    m.searchTask.ObserveField("iconsResult", "onIconsResult")
    ' match_selftest=1 in the manifest runs the channel-matching self-test.
    m.searchTask.selfTest = (CreateObject("roAppInfo").GetValue("match_selftest") = "1")
    m.searchTask.control = "RUN"
end sub

' ---------------------------------------------------------------------------
' Channel matching: after every catalog (re)index, ask SearchTask to find
' saved channels and series whose IDs have gone missing.

sub onIndexChanged()
    channels = []
    seen = {}
    for each list in [m.store.callFunc("getFavorites"), m.store.callFunc("getRecent")]
        for each c in list
            key = toInt(c.streamId).ToStr()
            if not seen.DoesExist(key)
                seen[key] = true
                channels.Push({ streamId: c.streamId, name: c.name, epgChannelId: c.epgChannelId })
            end if
        end for
    end for
    searchSend("matchRequest", { id: "saved", channels: channels, series: m.store.callFunc("getSavedSeries") })
    ' The catalog changed: My Teams games may have too.
    requestGames()
    if m.localsWaiting then requestLocalStations("live")
    refreshMarketsScreen()
end sub

sub onMatchResult(event as Object)
    result = event.GetData()
    if result.id <> "saved" then return
    changed = 0
    if result.channels.Count() > 0
        if m.store.callFunc("remapChannels", result.channels) then changed = changed + result.channels.Count()
    end if
    if result.series.Count() > 0
        if m.store.callFunc("remapSeries", result.series) then changed = changed + result.series.Count()
    end if
    if changed = 0 then return
    print "[main] re-matched "; changed; " saved item(s) after a provider renumbering"
    showToast("The provider renumbered some channels; " + changed.ToStr() + " saved item(s) were found again.")
    refreshHome()
    updateCatalogTags()
end sub

function searchFile(kind as String) as String
    return "cachefs:/catalog/all_" + kind + ".json"
end function

sub searchSend(field as String, value as Object)
    if m.searchTask.ready
        m.searchTask.SetField(field, value)
    else
        m.searchPending.Push({ field: field, value: value })
    end if
end sub

' Index whatever the last session left on disk right away; the refresh
' after login replaces it if it's more than a day old.
sub onSearchReady()
    if not m.searchTask.ready then return
    for each kind in ["live", "movie", "series"]
        m.searchTask.load = { kind: kind, file: searchFile(kind) }
    end for
    for each p in m.searchPending
        m.searchTask.SetField(p.field, p.value)
    end for
    m.searchPending = []
end sub

' After login: download any full list older than a day.
sub refreshSearchIndex()
    if m.searchIndexRequested then return
    m.searchIndexRequested = true
    m.searchIndexStarted = true
    for each kind in ["live", "movie", "series"]
        sendRequest({
            id: "catalogAll"
            priority: "low"
            action: catalogActions(kind).items
            context: { kind: kind }
            cacheFile: searchFile(kind)
            maxAgeSeconds: 86400
            saveOnly: true
            timeoutMs: 120000
        })
    end for
    ' Live TV's category list: My Teams (event categories) and local
    ' stations need it even if Live TV hasn't been opened.
    sendRequest({
        id: "catalogAll"
        priority: "low"
        action: catalogActions("live").categories
        context: { kind: "categories" }
        cacheFile: liveCategoriesFile()
        maxAgeSeconds: 86400
        saveOnly: true
        timeoutMs: 30000
    })
end sub

function liveCategoriesFile() as String
    return "cachefs:/catalog/live_categories.json"
end function

sub onCatalogAll(res as Object)
    kind = asString(res.context.kind)
    if not res.ok
        print "[main] couldn't download the full "; kind; " list for search: "; res.error; "; trying again in 5 minutes"
        m.searchIndexRequested = false
        m.searchRetryTimer.control = "stop"
        m.searchRetryTimer.control = "start"
    else if not res.fromCache and kind = "categories"
        searchSend("load", { kind: "categories" })
    else if not res.fromCache
        searchSend("load", { kind: kind, file: searchFile(kind) })
    end if
end sub

sub onSearchIndexTimer()
    if not m.searchIndexStarted then return     ' not logged in yet
    m.searchIndexRequested = false
    refreshSearchIndex()
end sub

function searchIndexEmpty() as Boolean
    counts = m.searchTask.counts
    if type(counts) <> "roAssociativeArray" then return true
    total = 0
    for each kind in counts
        total = total + toInt(counts[kind])
    end for
    return total = 0
end function

function createSearchScreen() as Object
    screen = CreateObject("roSGNode", "SearchScreen")
    screen.ObserveField("query", "onSearchQuery")
    screen.ObserveField("selected", "onItemSelected")
    screen.ObserveField("options", "onToggleFavorite")
    return screen
end function

sub onSearchShown(screen as Object)
    screen.favoriteIds = favoriteIdSet()
end sub

sub onSearchQuery(event as Object)
    screen = m.sections.search
    if searchIndexEmpty()
        screen.status = "Search is still downloading the catalog. Try again in a minute."
        return
    end if
    m.searchQueryId = m.searchQueryId + 1
    searchSend("query", { id: m.searchQueryId, text: event.GetData(), market: m.store.callFunc("getMarket").key })
end sub

sub onSearchResults(event as Object)
    screen = m.sections.search
    if screen <> invalid then screen.results = event.GetData()
end sub

sub onArchiveList(event as Object)
    m.archiveDays = event.GetData()
end sub

function favoriteIdSet() as Object
    ids = {}
    for each f in m.store.callFunc("getFavorites")
        ids[toInt(f.streamId).ToStr()] = true
    end for
    for each s in m.store.callFunc("getFavoriteSeries")
        ids["s" + toInt(s.seriesId).ToStr()] = true     ' favorite series: "s<id>"
    end for
    return ids
end function
