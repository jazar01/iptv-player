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

    m.searchTask.ObserveField("ready", "onSearchReady")
    m.searchTask.ObserveField("results", "onSearchResults")
    m.searchTask.ObserveField("archive", "onArchiveList")
    m.searchTask.control = "RUN"
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
    for each kind in ["live", "movie", "series"]
        sendRequest({
            id: "catalogAll"
            action: catalogActions(kind).items
            context: { kind: kind }
            cacheFile: searchFile(kind)
            maxAgeSeconds: 86400
            saveOnly: true
            timeoutMs: 120000
        })
    end for
end sub

sub onCatalogAll(res as Object)
    kind = asString(res.context.kind)
    if not res.ok
        print "[main] couldn't download the full "; kind; " list for search: "; res.error
        m.searchIndexRequested = false
    else if not res.fromCache
        searchSend("load", { kind: kind, file: searchFile(kind) })
    end if
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
    searchSend("query", { id: m.searchQueryId, text: event.GetData() })
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
    return ids
end function
