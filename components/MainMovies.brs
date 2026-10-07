' Movie details page: opened when a movie is chosen in Movies, Search or the
' Watch List (Continue Watching still resumes straight away). Details come
' from get_vod_info, cached in cachefs: like series info. Also the Watch
' List: movies saved to watch later (* on a movie, or the page's button).

sub initMovies()
    m.movieScreen = invalid
    m.movieItem = invalid       ' { itemId, name, ext, year, poster } being shown
    m.movieCategories = invalid ' last movie category list from the provider
    m.missingMovies = {}        ' Watch List IDs gone from the provider's catalog
end sub

' item: { itemId (stream ID), name, ext, year, poster? }
sub openMovie(item as Object)
    m.movieItem = item
    m.movieScreen = CreateObject("roSGNode", "MovieScreen")
    m.movieScreen.ObserveField("play", "onMoviePlay")
    m.movieScreen.ObserveField("watchListToggle", "onMovieWatchListToggle")
    m.movieScreen.movie = { name: asString(item.name), year: toInt(item.year), poster: asString(item.poster) }
    m.movieScreen.status = "Loading details ..."
    m.movieScreen.position = m.store.callFunc("getPosition", "movie", item.itemId)
    m.movieScreen.onWatchList = m.store.callFunc("isOnWatchList", item.itemId)
    pushOverlay(m.movieScreen)
    id = toInt(item.itemId)
    sendRequest({
        id: "movieInfo"
        action: "get_vod_info"
        params: { vod_id: id }
        context: { id: id }
        cacheFile: "cachefs:/catalog/vod_info_" + id.ToStr() + ".json"
        cacheFirst: true
        timeoutMs: 20000
    })
end sub

sub onMovieInfo(res as Object)
    if m.movieScreen = invalid or m.movieItem = invalid or toInt(res.context.id) <> toInt(m.movieItem.itemId) or res.unchanged then return
    if res.ok and type(res.data) = "roAssociativeArray"
        details = movieDetails(res.data)
        m.movieScreen.details = details
        ' The real runtime helps Continue Watching show the time left.
        if details.durationSecs > 0 then m.movieItem.duration = details.durationSecs
        if details.year > 0 and toInt(m.movieItem.year) = 0 then m.movieItem.year = details.year
        ' A movie on the Watch List gets its runtime for the Home card.
        m.store.callFunc("updateWatchListDetails", { id: m.movieItem.itemId, mins: details.durationSecs \ 60, year: details.year })
        m.movieScreen.status = ""
    else if not res.fromCache
        m.movieScreen.status = "Couldn't load the details. " + friendlyRequestError(res)
    end if
end sub

' get_vod_info -> what the page shows. Providers differ in field names, so
' several are tried; anything missing is left out.
function movieDetails(data as Object) as Object
    info = data.info
    if type(info) <> "roAssociativeArray" then info = {}
    d = {
        name: firstText(info, ["name", "o_name", "title"])
        plot: firstText(info, ["plot", "description"])
        genre: firstText(info, ["genre"])
        director: firstText(info, ["director"])
        cast: firstText(info, ["cast", "actors"])
        poster: firstText(info, ["movie_image", "cover_big", "cover"])
        backdrop: ""
        rating: ""
        runtime: ""
        year: 0
        durationSecs: toInt(info.duration_secs)
    }
    d.backdrop = firstBackdrop(info)
    d.rating = ratingText(info.rating)
    if d.durationSecs > 0
        hours = d.durationSecs \ 3600
        minutes = (d.durationSecs mod 3600) \ 60
        if hours > 0 then d.runtime = hours.ToStr() + " h " + minutes.ToStr() + " min" else d.runtime = minutes.ToStr() + " min"
    end if
    d.year = Val(Left(firstText(info, ["releasedate", "release_date", "year"]), 4), 10)
    return d
end function

' Play / Resume / Start over: the page stays underneath, so Back from the
' player returns to it.
sub onMoviePlay(event as Object)
    if m.movieItem = invalid then return
    choice = event.GetData()
    item = m.movieItem
    id = toInt(item.itemId)
    ext = asString(item.ext)
    if ext = "" then ext = "mp4"
    startPlayer({
        kind: "movie"
        id: id
        name: asString(item.name)
        ext: ext
        duration: toInt(item.duration)
        url: streamUrl("movie", id, ext)
        streamFormat: streamFormatFor(ext)
    }, toInt(choice.position))
end sub

' ---------------------------------------------------------------------------
' Watch List

sub onMovieWatchListToggle()
    if m.movieItem <> invalid then toggleWatchList(m.movieItem)
end sub

' item: { itemId, name, ext, year, duration? } (a catalog row, search result,
' Home card or the details page).
sub toggleWatchList(item as Object)
    id = toInt(item.itemId)
    if id = 0 then return
    name = asString(item.name)
    if m.store.callFunc("isOnWatchList", id)
        saved = m.store.callFunc("setOnWatchList", { id: id }, false)
        message = "Removed " + name + " from your Watch List"
    else if m.store.callFunc("watchListFull")
        showToast("Your Watch List is full (30 movies). Remove one first.")
        return
    else
        saved = m.store.callFunc("setOnWatchList", { id: id, name: name, year: item.year, ext: item.ext, mins: toInt(item.duration) \ 60 }, true)
        message = "Added " + name + " to your Watch List"
    end if
    if not saved then message = "Couldn't save the change. Storage may be full."
    showToast(message)
    onWatchListChanged()
end sub

sub onWatchListChanged()
    refreshHome()
    updateCatalogTags()
    screen = catalogScreen("movie")
    if screen <> invalid and m.movieCategories <> invalid
        screen.categories = movieCategoriesWithWatchList(m.movieCategories)
        showWatchListCategory()     ' only shown if it's the open category
    end if
    search = m.sections.search
    if search <> invalid then search.favoriteIds = favoriteIdSet()
    if m.movieScreen <> invalid and m.movieItem <> invalid then m.movieScreen.onWatchList = m.store.callFunc("isOnWatchList", m.movieItem.itemId)
end sub

' Movies: a "Watch List" category first while it has movies.
function movieCategoriesWithWatchList(categories as Object) as Object
    if m.store.callFunc("getWatchList").Count() = 0 then return categories
    list = [{ category_id: "__watchlist", category_name: "Watch List" }]
    list.Append(categories)
    return list
end function

' The category's items, from saved state (get_vod_streams-shaped), newest
' added first.
sub showWatchListCategory()
    screen = catalogScreen("movie")
    if screen = invalid then return
    items = []
    for each w in m.store.callFunc("getWatchList")
        items.Push({ stream_id: w.id, name: w.name, year: w.year, container_extension: w.ext })
    end for
    screen.items = { categoryId: "__watchlist", items: items }
end sub
