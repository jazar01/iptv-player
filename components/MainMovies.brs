' Movie details page: opened when a movie is chosen in Movies or Search
' (Continue Watching still resumes straight away). Details come from
' get_vod_info, cached in cachefs: like series info.

sub initMovies()
    m.movieScreen = invalid
    m.movieItem = invalid       ' { itemId, name, ext, year, poster } being shown
end sub

' item: { itemId (stream ID), name, ext, year, poster? }
sub openMovie(item as Object)
    m.movieItem = item
    m.movieScreen = CreateObject("roSGNode", "MovieScreen")
    m.movieScreen.ObserveField("play", "onMoviePlay")
    m.movieScreen.movie = { name: asString(item.name), year: toInt(item.year), poster: asString(item.poster) }
    m.movieScreen.status = "Loading details ..."
    m.movieScreen.position = m.store.callFunc("getPosition", "movie", item.itemId)
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
        m.movieScreen.status = ""
    else if not res.fromCache
        m.movieScreen.status = "Couldn't load the details: " + res.error
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
    backdrops = info.backdrop_path
    if type(backdrops) = "roArray" and backdrops.Count() > 0 then d.backdrop = asString(backdrops[0])
    if type(backdrops) = "roString" or type(backdrops) = "String" then d.backdrop = asString(backdrops)
    rating = Val(asString(info.rating))
    if rating > 0 then d.rating = Str(Int(rating * 10 + 0.5) / 10).Trim()
    if d.durationSecs > 0
        hours = d.durationSecs \ 3600
        minutes = (d.durationSecs mod 3600) \ 60
        if hours > 0 then d.runtime = hours.ToStr() + " h " + minutes.ToStr() + " min" else d.runtime = minutes.ToStr() + " min"
    end if
    d.year = Val(Left(firstText(info, ["releasedate", "release_date", "year"]), 4), 10)
    return d
end function

function firstText(aa as Object, keys as Object) as String
    for each k in keys
        text = asString(aa[k]).Trim()
        if text <> "" then return text
    end for
    return ""
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
