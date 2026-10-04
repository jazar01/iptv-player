' Live TV, Movies and Series browsers (one CatalogScreen each) and series
' pages. Catalog responses are cached in cachefs: and shown immediately, then
' refreshed.

sub initCatalog()
    m.catalogState = {}         ' kind -> { requested, categoriesShown, itemsShown }
    m.seriesScreen = invalid
    m.seriesScreenId = 0
    m.seriesInfo = {}           ' seriesId -> normalized info (see normalizeSeriesInfo)
    m.continueAfterInfo = invalid   ' Continue Watching card waiting for series info
end sub

function catalogState(kind as String) as Object
    state = m.catalogState[kind]
    if state = invalid
        state = { requested: false, categoriesShown: false, itemsShown: {} }
        m.catalogState[kind] = state
    end if
    return state
end function

function catalogActions(kind as String) as Object
    if kind = "movie" then return { categories: "get_vod_categories", items: "get_vod_streams" }
    if kind = "series" then return { categories: "get_series_categories", items: "get_series" }
    return { categories: "get_live_categories", items: "get_live_streams" }
end function

function createCatalogScreen(kind as String) as Object
    screen = CreateObject("roSGNode", "CatalogScreen")
    screen.kind = kind
    screen.ObserveField("wantCategory", "onWantCategory")
    screen.ObserveField("selected", "onItemSelected")
    screen.ObserveField("options", "onToggleFavorite")
    return screen
end function

function catalogScreen(kind as String) as Dynamic
    for each name in ["live", "movies", "series"]
        if sectionKind(name) = kind then return m.sections[name]
    end for
    return invalid
end function

sub onCatalogShown(screen as Object)
    kind = screen.kind
    screen.tags = catalogTags(kind)
    state = catalogState(kind)
    if state.requested then return
    state.requested = true
    sendRequest({
        id: "catalogCategories"
        action: catalogActions(kind).categories
        context: { kind: kind }
        cacheFile: "cachefs:/catalog/" + kind + "_categories.json"
        cacheFirst: true
    })
end sub

sub onCatalogCategories(res as Object)
    kind = asString(res.context.kind)
    screen = catalogScreen(kind)
    if screen = invalid or res.unchanged then return
    state = catalogState(kind)
    if res.ok and type(res.data) = "roArray"
        if not res.fromCache then print "[main] "; res.data.Count(); " "; kind; " categories"
        state.categoriesShown = true
        screen.categories = res.data
    else if not state.categoriesShown
        state.requested = false     ' try again next visit
        screen.status = "Couldn't load categories: " + res.error
    end if
end sub

sub onWantCategory(event as Object)
    kind = event.GetRoSGNode().kind
    id = event.GetData()
    sendRequest({
        id: "catalogItems"
        action: catalogActions(kind).items
        params: { category_id: id }
        context: { kind: kind, categoryId: id }
        cacheFile: "cachefs:/catalog/" + kind + "_" + id + ".json"
        cacheFirst: true
        timeoutMs: 30000
    })
end sub

sub onCatalogItems(res as Object)
    kind = asString(res.context.kind)
    id = asString(res.context.categoryId)
    screen = catalogScreen(kind)
    if screen = invalid or res.unchanged then return
    state = catalogState(kind)
    if res.ok and type(res.data) = "roArray"
        state.itemsShown[id] = true
        screen.items = { categoryId: id, items: res.data }
    else if not state.itemsShown.DoesExist(id)
        screen.items = { categoryId: id, items: [] }
        screen.status = "Couldn't load this category: " + res.error
    end if
end sub

' Right-hand tags in each catalog: favorites, movies in progress, series
' being watched.
function catalogTags(kind as String) as Object
    tags = {}
    if kind = "live"
        for each f in m.store.callFunc("getFavorites")
            tags[toInt(f.streamId).ToStr()] = "FAVORITE"
        end for
    else if kind = "movie"
        for each r in m.store.callFunc("getResume")
            if r.kind = "movie" then tags[toInt(r.id).ToStr()] = "IN PROGRESS"
        end for
    else if kind = "series"
        for each s in m.store.callFunc("getSeriesList")
            tags[toInt(s.seriesId).ToStr()] = "WATCHING"
        end for
    end if
    return tags
end function

sub updateCatalogTags()
    for each name in ["live", "movies", "series"]
        screen = m.sections[name]
        if screen <> invalid then screen.tags = catalogTags(screen.kind)
    end for
end sub

' After an account change: drop the catalog screens so they reload.
sub resetCatalogs()
    for each name in ["live", "movies", "series"]
        screen = m.sections[name]
        if screen <> invalid
            m.screenHost.RemoveChild(screen)
            m.sections.Delete(name)
        end if
    end for
    m.catalogState = {}
    m.seriesInfo = {}
end sub

' ---------------------------------------------------------------------------
' Series pages

' item: { itemId (series ID), name, year }
sub openSeries(item as Object)
    seriesId = toInt(item.itemId)
    m.seriesScreen = CreateObject("roSGNode", "SeriesScreen")
    m.seriesScreen.ObserveField("selected", "onEpisodeSelected")
    m.seriesScreen.ObserveField("options", "onEpisodeOptions")
    m.seriesScreenId = seriesId
    progress = m.store.callFunc("getSeriesProgress", seriesId)
    m.seriesScreen.focusEpisodeId = progress.currentEpisodeId
    m.seriesScreen.progress = progress
    pushOverlay(m.seriesScreen)

    cached = m.seriesInfo[seriesId.ToStr()]
    if cached <> invalid then m.seriesScreen.info = cached
    requestSeriesInfo(seriesId, asString(item.name), toInt(item.year))
end sub

sub requestSeriesInfo(seriesId as Integer, name as String, year as Integer)
    sendRequest({
        id: "seriesInfo"
        action: "get_series_info"
        params: { series_id: seriesId }
        context: { seriesId: seriesId, name: name, year: year }
        cacheFile: "cachefs:/catalog/series_info_" + seriesId.ToStr() + ".json"
        cacheFirst: true
        timeoutMs: 30000
    })
end sub

sub onSeriesInfo(res as Object)
    ctx = res.context
    seriesId = toInt(ctx.seriesId)
    key = seriesId.ToStr()
    if res.unchanged then return

    if res.ok and type(res.data) = "roAssociativeArray"
        info = normalizeSeriesInfo(ctx, res.data)
        m.seriesInfo[key] = info
        if m.seriesScreen <> invalid and m.seriesScreenId = seriesId then m.seriesScreen.info = info
        if m.continueAfterInfo <> invalid and toInt(m.continueAfterInfo.seriesId) = seriesId
            item = m.continueAfterInfo
            m.continueAfterInfo = invalid
            continueSeries(item)
        end if
    else if not res.fromCache and m.seriesInfo[key] = invalid
        if m.seriesScreen <> invalid and m.seriesScreenId = seriesId then m.seriesScreen.status = "Couldn't load episodes: " + res.error
        if m.continueAfterInfo <> invalid and toInt(m.continueAfterInfo.seriesId) = seriesId
            m.continueAfterInfo = invalid
            showToast("Couldn't load the series: " + res.error)
        end if
    end if
end sub

' get_series_info -> { seriesId, name, year, seasons: [{ season, episodes: [...] }] }
' Seasons in order with specials (season 0) last; episodes by number.
function normalizeSeriesInfo(ctx as Object, data as Object) as Object
    name = asString(ctx.name)
    year = toInt(ctx.year)
    if type(data.info) = "roAssociativeArray"
        if asString(data.info.name) <> "" then name = asString(data.info.name)
        y = Val(Left(asString(data.info.releaseDate), 4), 10)
        if y > 1900 then year = y
    end if

    seasons = []
    groups = data.episodes
    if type(groups) = "roAssociativeArray"
        for each seasonKey in groups
            seasons.Push(normalizeSeason(Val(seasonKey, 10), groups[seasonKey]))
        end for
    else if type(groups) = "roArray"
        ' Some panels send a list of season lists.
        for each group in groups
            if type(group) = "roArray" and group.Count() > 0 then seasons.Push(normalizeSeason(toInt(group[0].season), group))
        end for
    end if
    seasons.SortBy("season")
    if seasons.Count() > 1 and seasons[0].season = 0 then seasons.Push(seasons.Shift())

    return { seriesId: toInt(ctx.seriesId), name: name, year: year, seasons: seasons }
end function

function normalizeSeason(season as Integer, list as Dynamic) as Object
    episodes = []
    if type(list) = "roArray"
        for each e in list
            duration = 0
            if type(e.info) = "roAssociativeArray" then duration = toInt(e.info.duration_secs)
            episodes.Push({
                id: toInt(e.id)
                season: season
                episode: toInt(e.episode_num)
                name: asString(e.title)
                ext: asString(e.container_extension)
                duration: duration
            })
        end for
    end if
    episodes.SortBy("episode")
    return { season: season, episodes: episodes }
end function

' Episode descriptor for the episode after episodeId, or invalid if it's the
' last one (or the series info isn't loaded).
function nextEpisodeAfter(seriesId as Dynamic, episodeId as Dynamic) as Dynamic
    info = m.seriesInfo[toInt(seriesId).ToStr()]
    if info = invalid then return invalid
    found = false
    for each s in info.seasons
        for each e in s.episodes
            if found then return e
            if e.id = toInt(episodeId) then found = true
        end for
    end for
    return invalid
end function

function findEpisode(info as Object, episodeId as Integer) as Dynamic
    for each s in info.seasons
        for each e in s.episodes
            if e.id = episodeId
                return {
                    kind: "episode"
                    id: e.id
                    season: e.season
                    episode: e.episode
                    name: e.name
                    ext: e.ext
                    duration: e.duration
                    seriesId: info.seriesId
                    seriesName: info.name
                    year: info.year
                }
            end if
        end for
    end for
    return invalid
end function

sub onEpisodeSelected(event as Object)
    playEpisode(event.GetData(), true)
end sub

' * on an episode: mark it watched or unwatched by hand.
sub onEpisodeOptions(event as Object)
    ep = event.GetData()
    entry = {
        kind: "episode"
        id: ep.id
        name: ep.name
        ext: ep.ext
        seriesId: ep.seriesId
        seriesName: ep.seriesName
        year: ep.year
        season: ep.season
        episode: ep.episode
        fromPlayback: false
        nextEpisode: nextEpisodeAfter(ep.seriesId, ep.id)
    }
    if ep.state = "watched"
        saved = m.store.callFunc("markUnwatched", entry)
        message = "Marked E" + toInt(ep.episode).ToStr() + " as not watched"
    else
        saved = m.store.callFunc("markWatched", entry)
        message = "Marked E" + toInt(ep.episode).ToStr() + " as watched"
    end if
    if not saved then message = "Couldn't save the change. Storage may be full."
    showToast(message)
    refreshSeriesProgress()
    refreshHome()
    updateCatalogTags()
end sub

sub refreshSeriesProgress()
    if m.seriesScreen <> invalid then m.seriesScreen.progress = m.store.callFunc("getSeriesProgress", m.seriesScreenId)
end sub

' Continue Watching series card: play its current episode from where it was
' left. Needs the series info (cached on disk after the first time) to know
' the episode details and what comes next.
sub continueSeries(item as Object)
    info = m.seriesInfo[toInt(item.seriesId).ToStr()]
    if info = invalid
        m.continueAfterInfo = item
        requestSeriesInfo(toInt(item.seriesId), asString(item.seriesName), toInt(item.year))
        return
    end if
    ep = findEpisode(info, toInt(item.itemId))
    if ep = invalid
        showToast("That episode is no longer listed. Opening the series instead.")
        openSeries({ itemId: item.seriesId, name: item.seriesName, year: item.year })
        return
    end if
    playEpisode(ep, false)
end sub
