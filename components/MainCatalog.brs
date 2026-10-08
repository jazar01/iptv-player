' Live TV, Movies and Series browsers (one CatalogScreen each) and series
' pages. Catalog responses are cached in cachefs: and shown immediately, then
' refreshed.

sub initCatalog()
    m.catalogState = {}         ' kind -> { requested, categoriesShown, itemsShown (this request) }
    m.seriesScreen = invalid
    m.seriesScreenId = 0
    m.seriesInfo = {}           ' seriesId -> normalized info (see normalizeSeriesInfo)
    m.continueAfterInfo = invalid   ' Continue Watching card waiting for series info
    m.liveCategories = invalid  ' last live category list from the provider
    m.localIds = {}             ' stream IDs of the market's local stations
    m.localsWaiting = false     ' "Local stations" asked for before the index was ready
end sub

' ---------------------------------------------------------------------------
' Live TV "Local stations": a category at the top with the device's market
' stations (Settings -> Local stations), answered from SearchTask's index.

function liveCategoriesWithLocal(categories as Object) as Object
    market = m.store.callFunc("getMarket")
    if market.key = "" then return categories
    list = [{ category_id: "__local", category_name: "Local stations - " + market.label }]
    list.Append(categories)
    return list
end function

sub requestLocalStations(id as String)
    market = m.store.callFunc("getMarket").key
    if market = "" then return
    searchSend("localsRequest", { id: id, market: market })
end sub

sub onLocalsResult(event as Object)
    result = event.GetData()
    m.localIds = {}
    for each item in result.items
        m.localIds[toInt(item.stream_id).ToStr()] = true
    end for
    updateCatalogTags()
    if result.id = "guide"
        showGuideLocals(result)
        return
    end if

    screen = catalogScreen("live")
    if screen = invalid or result.id <> "live" then return
    if not result.ready
        m.localsWaiting = true     ' asked again when the index is loaded
        screen.items = { categoryId: "__local", items: [] }
        screen.status = "Loading local stations ..."
    else
        m.localsWaiting = false
        screen.items = { categoryId: "__local", items: result.items }
        if result.items.Count() = 0 then screen.status = "No local stations found for this market."
    end if
end sub

' ---------------------------------------------------------------------------
' Favorite series: a "Favorite series" category first in the Series list
' (while there are any), FAVORITE tags, and * to add or remove one from the
' Series list, Search, a series page or the Home row.

function seriesCategoriesWithFavorites(categories as Object) as Object
    if m.store.callFunc("getFavoriteSeries").Count() = 0 then return categories
    list = [{ category_id: "__favseries", category_name: "Favorite series" }]
    list.Append(categories)
    return list
end function

' The category's items, from saved state (get_series-shaped, by name).
sub showFavoriteSeriesCategory()
    screen = catalogScreen("series")
    if screen = invalid then return
    items = []
    for each s in m.store.callFunc("getFavoriteSeries")
        items.Push({ series_id: s.seriesId, name: s.name, year: s.year })
    end for
    items.SortBy("name", "i")
    screen.items = { categoryId: "__favseries", items: items }
end sub

' item: { itemId (series ID), name, year } (seriesName preferred if present).
sub toggleSeriesFavorite(item as Object)
    seriesId = toInt(item.itemId)
    if seriesId = 0 then seriesId = toInt(item.seriesId)
    if seriesId = 0 then return
    name = asString(item.seriesName)
    if name = "" then name = asString(item.name)
    favorite = not m.store.callFunc("isSeriesFavorite", seriesId)
    if m.store.callFunc("setSeriesFavorite", { seriesId: seriesId, name: name, year: item.year }, favorite)
        if favorite then showToast("Added " + name + " to Favorite Series") else showToast("Removed " + name + " from Favorite Series")
    else
        showToast("Couldn't save the change. Storage may be full.")
    end if
    onFavoriteSeriesChanged()
end sub

sub onFavoriteSeriesChanged()
    refreshHome()
    updateCatalogTags()
    screen = catalogScreen("series")
    if screen <> invalid and m.seriesCategories <> invalid
        screen.categories = seriesCategoriesWithFavorites(m.seriesCategories)
        showFavoriteSeriesCategory()    ' only shown if it's the open category
    end if
    search = m.sections.search
    if search <> invalid then search.favoriteIds = favoriteIdSet()
    if m.seriesScreen <> invalid then m.seriesScreen.isFavorite = m.store.callFunc("isSeriesFavorite", m.seriesScreenId)
end sub

' Settings -> Local stations changed: refresh the Live TV entry and tags.
sub onMarketChangedForCatalog()
    m.localIds = {}
    screen = catalogScreen("live")
    if screen <> invalid and m.liveCategories <> invalid then screen.categories = liveCategoriesWithLocal(m.liveCategories)
    requestLocalStations("live")
    updateCatalogTags()
end sub

function catalogState(kind as String) as Object
    state = m.catalogState[kind]
    if state = invalid
        state = { requested: false, requestedAt: 0, categoriesShown: false, itemsShown: {} }
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
    screen.ObserveField("retryCategories", "onRetryCategories")
    screen.ObserveField("selected", "onItemSelected")
    screen.ObserveField("options", "onCatalogOptions")      ' favorite / channel info, Favorite Series, Watch List
    screen.ObserveField("visibleChannels", "onCatalogVisible")      ' live: what's on now
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
    if kind = "live" then requestLocalStations("tags")
    screen.tags = catalogTags(kind)
    state = catalogState(kind)
    ' Asked already: wait for it, unless it was over 90 s ago and nothing came
    ' (a lost reply would otherwise leave the categories empty for good).
    if state.requested and (state.categoriesShown or nowSeconds() - state.requestedAt < 90) then return
    state.requested = true
    state.requestedAt = nowSeconds()
    sendRequest({
        id: "catalogCategories"
        action: catalogActions(kind).categories
        context: { kind: kind }
        cacheFile: "cachefs:/catalog/" + kind + "_categories.json"
        cacheFirst: true
    })
end sub

' OK after the category list failed: ask for it again now.
sub onRetryCategories(event as Object)
    screen = event.GetRoSGNode()
    state = catalogState(screen.kind)
    state.requested = false
    onCatalogShown(screen)
end sub

sub onCatalogCategories(res as Object)
    kind = asString(res.context.kind)
    screen = catalogScreen(kind)
    if screen = invalid or res.unchanged then return
    state = catalogState(kind)
    if res.ok and type(res.data) = "roArray"
        if not res.fromCache then print "[main] "; res.data.Count(); " "; kind; " categories"
        state.categoriesShown = true
        ' Most used first, then this Roku's country (categoryOrder).
        ordered = orderCategories(res.data, kind)
        if kind = "live"
            ' Same file My Teams reads (liveCategoriesFile): tell it when fresh.
            if not res.fromCache then searchSend("load", { kind: "categories" })
            m.liveCategories = ordered
            screen.categories = liveCategoriesWithLocal(ordered)
        else if kind = "series"
            m.seriesCategories = ordered
            screen.categories = seriesCategoriesWithFavorites(ordered)
        else if kind = "movie"
            m.movieCategories = ordered
            screen.categories = movieCategoriesWithWatchList(ordered)
        else
            screen.categories = ordered
        end if
    else if not state.categoriesShown
        state.requested = false     ' try again next visit
        screen.status = "Couldn't load the categories. " + friendlyRequestError(res) + " Press OK to try again."
        screen.categoriesFailed = true
    end if
end sub

sub onWantCategory(event as Object)
    kind = event.GetRoSGNode().kind
    id = event.GetData()
    if id = "__local"
        requestLocalStations("live")
        return
    end if
    if id = "__favseries"
        showFavoriteSeriesCategory()
        return
    end if
    if id = "__watchlist"
        showWatchListCategory()
        return
    end if
    ' Shown-for-this-request: a cached copy delivered now counts; an earlier
    ' visit's success doesn't (a failed reload must show its error to retry).
    state = catalogState(kind)
    state.itemsShown.Delete(id)
    sendRequest({
        id: "catalogItems"
        action: catalogActions(kind).items
        params: { category_id: id }
        context: { kind: kind, categoryId: id }
        cacheFile: "cachefs:/catalog/" + kind + "_" + safeKey(id) + ".json"
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
        screen.items = { categoryId: id, items: [], failed: true }
        screen.status = "Couldn't load this category. " + friendlyRequestError(res) + " Press OK to try again."
    end if
end sub

' Right-hand tags in each catalog: favorites (over local stations), movies in
' progress (over the Watch List), series being watched.
function catalogTags(kind as String) as Object
    tags = {}
    if kind = "live"
        for each id in m.localIds
            tags[id] = "LOCAL"
        end for
        for each f in m.store.callFunc("getFavorites")
            tags[toInt(f.streamId).ToStr()] = "FAVORITE"
        end for
    else if kind = "movie"
        for each w in m.store.callFunc("getWatchList")
            tags[toInt(w.id).ToStr()] = "LIST"
        end for
        for each r in m.store.callFunc("getResume")
            if r.kind = "movie" then tags[toInt(r.id).ToStr()] = "IN PROGRESS"
        end for
    else if kind = "series"
        for each s in m.store.callFunc("getSeriesList")
            tags[toInt(s.seriesId).ToStr()] = "WATCHING"
        end for
        for each s in m.store.callFunc("getFavoriteSeries")
            tags[toInt(s.seriesId).ToStr()] = "FAVORITE"
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
    m.liveCategories = invalid
    m.seriesCategories = invalid
    m.movieCategories = invalid
end sub

' ---------------------------------------------------------------------------
' Series pages

' item: { itemId (series ID), name, year }
sub openSeries(item as Object)
    seriesId = toInt(item.itemId)
    m.seriesScreen = CreateObject("roSGNode", "SeriesScreen")
    m.seriesScreen.ObserveField("selected", "onEpisodeSelected")
    m.seriesScreen.ObserveField("options", "onEpisodeOptions")
    m.seriesScreen.ObserveField("favoriteToggle", "onSeriesFavoriteToggle")
    m.seriesScreenId = seriesId
    m.seriesScreen.isFavorite = m.store.callFunc("isSeriesFavorite", seriesId)
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
        ' Fresh from the provider: move saved positions to any renumbered
        ' episode IDs (a cached copy may still hold the old ones).
        if not res.fromCache then reconcileEpisodes(info)
        if m.seriesScreen <> invalid and m.seriesScreenId = seriesId then m.seriesScreen.info = info
        if m.continueAfterInfo <> invalid and toInt(m.continueAfterInfo.seriesId) = seriesId
            item = m.continueAfterInfo
            m.continueAfterInfo = invalid
            continueSeries(item)
        end if
    else if not res.fromCache and m.seriesInfo[key] = invalid
        if m.seriesScreen <> invalid and m.seriesScreenId = seriesId then m.seriesScreen.status = "Couldn't load the episodes. " + friendlyRequestError(res)
        if m.continueAfterInfo <> invalid and toInt(m.continueAfterInfo.seriesId) = seriesId
            m.continueAfterInfo = invalid
            showToast("Couldn't load the series. " + friendlyRequestError(res))
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
            if type(group) = "roArray" and group.Count() > 0 and type(group[0]) = "roAssociativeArray" then seasons.Push(normalizeSeason(toInt(group[0].season), group))
        end for
    end if
    seasons.SortBy("season")
    if seasons.Count() > 1 and seasons[0].season = 0 then seasons.Push(seasons.Shift())

    ' Artwork and details for the series page (field names vary by panel).
    ' Anything missing is left out.
    details = { cover: "", backdrop: "", plot: "", genre: "", rating: "", cast: "", director: "" }
    info = data.info
    if type(info) = "roAssociativeArray"
        details.cover = firstText(info, ["cover", "cover_big", "movie_image"])
        details.plot = firstText(info, ["plot", "description"])
        details.genre = firstText(info, ["genre"])
        details.cast = firstText(info, ["cast", "actors"])
        details.director = firstText(info, ["director"])
        details.backdrop = firstBackdrop(info)
        details.rating = ratingText(info.rating)
    end if

    return { seriesId: toInt(ctx.seriesId), name: name, year: year, seasons: seasons, details: details }
end function

function normalizeSeason(season as Integer, list as Dynamic) as Object
    episodes = []
    if type(list) = "roArray"
        for each e in list
            ' Skip anything that isn't an episode object (review R07).
            if type(e) = "roAssociativeArray"
                duration = 0
                plot = ""
                airDate = ""
                if type(e.info) = "roAssociativeArray"
                    duration = toInt(e.info.duration_secs)
                    plot = firstText(e.info, ["plot", "description", "overview"])
                    airDate = firstText(e.info, ["air_date", "releasedate", "release_date"])
                end if
                episodes.Push({
                    id: toInt(e.id)
                    season: season
                    episode: toInt(e.episode_num)
                    name: asString(e.title)
                    ext: asString(e.container_extension)
                    duration: duration
                    plot: plot
                    airDate: airDate
                })
            end if
        end for
    end if
    episodes.SortBy("episode")
    return { season: season, episodes: episodes }
end function

sub reconcileEpisodes(info as Object)
    episodes = []
    for each s in info.seasons
        episodes.Append(s.episodes)
    end for
    if episodes.Count() = 0 then return
    m.store.callFunc("remapEpisodes", info.seriesId, episodes)
    refreshSeriesProgress()
end sub

' Episode descriptor for the first episode after episodeId that isn't marked
' watched, or invalid if there's none (the series is finished) or the series
' info isn't loaded.
function nextEpisodeAfter(seriesId as Dynamic, episodeId as Dynamic) as Dynamic
    info = m.seriesInfo[toInt(seriesId).ToStr()]
    if info = invalid then return invalid
    watched = m.store.callFunc("getSeriesProgress", seriesId).watched
    found = false
    for each s in info.seasons
        for each e in s.episodes
            if found and not watched.DoesExist(e.season.ToStr() + ":" + e.episode.ToStr()) then return e
            if e.id = toInt(episodeId) then found = true
        end for
    end for
    return invalid
end function

function findEpisode(info as Object, episodeId as Integer) as Dynamic
    for each s in info.seasons
        for each e in s.episodes
            if e.id = episodeId then return episodeSummaryFor(info, e)
        end for
    end for
    return invalid
end function

function findEpisodeByNumber(info as Object, season as Integer, episode as Integer) as Dynamic
    if season = 0 and episode = 0 then return invalid
    for each s in info.seasons
        for each e in s.episodes
            if e.season = season and e.episode = episode then return episodeSummaryFor(info, e)
        end for
    end for
    return invalid
end function

function episodeSummaryFor(info as Object, e as Object) as Object
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
end function

sub onSeriesFavoriteToggle(event as Object)
    toggleSeriesFavorite(event.GetData())
end sub

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
    ' After a provider renumbering the saved episode ID may be gone; the
    ' season and episode number still identify it.
    if ep = invalid then ep = findEpisodeByNumber(info, toInt(item.season), toInt(item.episode))
    if ep = invalid
        showToast("That episode is no longer listed. Opening the series instead.")
        openSeries({ itemId: item.seriesId, name: item.seriesName, year: item.year })
        return
    end if
    ' Marked watched by hand since it became current (and not started): go on
    ' to the next unwatched one.
    progress = m.store.callFunc("getSeriesProgress", info.seriesId)
    if progress.watched.DoesExist(ep.season.ToStr() + ":" + ep.episode.ToStr()) and not progress.resume.DoesExist(ep.id.ToStr())
        nextEp = nextEpisodeAfter(info.seriesId, ep.id)
        if nextEp <> invalid then ep = episodeSummaryFor(info, nextEp)
    end if
    playEpisode(ep, false)
end sub

' Live TV rows on screen: programs the guide already has go straight to the
' rows; EpgService fetches the rest (onPrograms relays them).
sub onCatalogVisible(event as Object)
    ids = event.GetData()
    screen = event.GetRoSGNode()
    m.lastVisible = ids
    cached = m.epg.callFunc("getPrograms", ids)
    for each key in cached
        screen.programs = cached[key]
    end for
    m.epg.callFunc("want", ids)
end sub

' ---------------------------------------------------------------------------
' Category order (data/guide-rules.json "categoryOrder"): the most-used
' categories first (usage scores, as at launch, so lists don't reshuffle
' while browsing), then this Roku's country ("US | ..."), then the rest, each
' group in the provider's order.

' Picking something from a category is one use of it ("kc"/"km"/"ks" + ID in
' the usage table). Virtual categories ("__local", "__favseries") don't count.
sub recordCategoryUse(kind as String, categoryId as Dynamic)
    id = asString(categoryId)
    if id = "" or Left(id, 2) = "__" then return
    m.store.callFunc("recordUsage", categoryUsageKey(kind, id))
end sub

function categoryUsageKey(kind as String, id as String) as String
    letter = "c"
    if kind = "movie" then letter = "m"
    if kind = "series" then letter = "s"
    return "k" + letter + safeKey(id)
end function

' categories: provider list [{ category_id, category_name }] (or the Guide's
' [{ id, name }]). Returns a new list in display order.
function orderCategories(categories as Object, kind as String) as Object
    rules = categoryOrderRules()

    ' The most-used few, best first.
    scored = []
    for i = 0 to categories.Count() - 1
        c = categories[i]
        if type(c) = "roAssociativeArray"
            score = usageScore(m.usageScores, categoryUsageKey(kind, categoryField(c, "id")))
            if score > 0 then scored.Push({ c: c, sortKey: rankKey(score, i) })
        end if
    end for
    scored.SortBy("sortKey")
    top = []
    topIds = {}
    for each s in scored
        if top.Count() < rules.topUsed
            top.Push(s.c)
            topIds[categoryField(s.c, "id")] = true
        end if
    end for

    ' The rest in the provider's order: this country's, then the others.
    mine = []
    others = []
    for each c in categories
        if type(c) = "roAssociativeArray" and not topIds.DoesExist(categoryField(c, "id"))
            if isMyCountry(categoryField(c, "name"), rules) then mine.Push(c) else others.Push(c)
        end if
    end for
    ordered = []
    ordered.Append(top)
    ordered.Append(mine)
    ordered.Append(others)
    return ordered
end function

' A category's ID or name, from the provider's shape (category_id,
' category_name) or the Guide's (id, name).
function categoryField(c as Object, field as String) as String
    if field = "id"
        if c.category_id <> invalid then return asString(c.category_id)
        return asString(c.id)
    end if
    if c.category_name <> invalid then return asString(c.category_name)
    return asString(c.name)
end function

function isMyCountry(name as String, rules as Object) as Boolean
    if rules.regex = invalid or rules.prefixes.Count() = 0 then return false
    match = rules.regex.Match(name)
    if match.Count() < 2 then return false
    return rules.prefixes.DoesExist(UCase(match[1]))
end function

function categoryOrderRules() as Object
    if m.categoryOrder <> invalid then return m.categoryOrder
    rules = { topUsed: 5, regex: invalid, prefixes: {} }
    cfg = guideRules().categoryOrder
    if type(cfg) = "roAssociativeArray"
        if toInt(cfg.topUsed) > 0 then rules.topUsed = toInt(cfg.topUsed)
        rules.regex = rulesRegex(cfg.countryPattern, "")
        info = CreateObject("roDeviceInfo")
        country = UCase(info.GetUserCountryCode())
        if country = "" then country = UCase(info.GetCountryCode())
        accepted = [country]
        if type(cfg.countryPrefixes) = "roAssociativeArray" and type(cfg.countryPrefixes[country]) = "roArray" then accepted = cfg.countryPrefixes[country]
        for each p in accepted
            if asString(p) <> "" then rules.prefixes[UCase(asString(p))] = true
        end for
        print "[main] category order: country "; country; ", top "; rules.topUsed; " used first"
    end if
    m.categoryOrder = rules
    return rules
end function
