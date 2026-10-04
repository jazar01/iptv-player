' Home screen rows. Each row is a module that supplies its own items from the
' services it's given; MainScene shows them in this fixed order. A new row
' (e.g. My Teams) is a new module added to homeRowModules().
'
' module: { id, title, emptyText, items(services) -> array of HomeItem field AAs }
' services: { store: StateStore, epg: EpgService }

function homeRowModules() as Object
    return [favoritesRow(), continueWatchingRow(), recentRow()]
end function

function buildHomeRows(services as Object) as Object
    rows = []
    for each module in homeRowModules()
        rows.Push({ id: module.id, title: module.title, emptyText: module.emptyText, items: module.items(services) })
    end for
    return rows
end function

' ---------------------------------------------------------------------------
' Favorites: drawn from saved names and IDs, so no network is needed. Program
' info comes from EpgService's cache; fresh data arrives later via `programs`.

function favoritesRow() as Object
    return {
        id: "favorites"
        title: "Favorites"
        emptyText: "Press * on a channel in Live TV to add it here."
        items: favoritesRowItems
    }
end function

function favoritesRowItems(services as Object) as Object
    return channelItems(services, services.store.callFunc("getFavorites"))
end function

' Saved channel records { streamId, name, epgChannelId } -> channel cards,
' with now/next from EpgService's cache where it has it.
function channelItems(services as Object, channels as Object) as Object
    ids = []
    for each c in channels
        ids.Push(toInt(c.streamId))
    end for
    programs = services.epg.callFunc("getPrograms", ids)

    items = []
    for each c in channels
        id = toInt(c.streamId)
        item = {
            kind: "channel"
            itemKey: "live:" + id.ToStr()
            streamId: id
            name: asString(c.name)
            epgChannelId: asString(c.epgChannelId)
        }
        entry = programs[id.ToStr()]
        if entry <> invalid
            item.Append(programFields(entry))
            item.epgVersion = 1
        end if
        items.Push(item)
    end for
    return items
end function

' ---------------------------------------------------------------------------
' Recently Viewed: live channels watched for about a minute, newest first,
' leaving out channels already in Favorites.

function recentRow() as Object
    return {
        id: "recent"
        title: "Recently Viewed"
        emptyText: "Channels you watch will appear here."
        items: recentRowItems
    }
end function

function recentRowItems(services as Object) as Object
    favoriteIds = {}
    for each f in services.store.callFunc("getFavorites")
        favoriteIds[toInt(f.streamId).ToStr()] = true
    end for
    channels = []
    for each r in services.store.callFunc("getRecent")
        if not favoriteIds.DoesExist(toInt(r.streamId).ToStr()) then channels.Push(r)
    end for
    return channelItems(services, channels)
end function

' ---------------------------------------------------------------------------
' Continue Watching: movies with time left, and series pointing at their
' current episode (in progress or next unwatched). Newest first. Everything
' comes from saved state, so it draws without the network.

function continueWatchingRow() as Object
    return {
        id: "continue"
        title: "Continue Watching"
        emptyText: "Movies and episodes you start will appear here."
        items: continueWatchingRowItems
    }
end function

function continueWatchingRowItems(services as Object) as Object
    entries = []
    resumeByEpisode = {}
    for each r in services.store.callFunc("getResume")
        if r.kind = "movie"
            duration = toInt(r.duration)
            position = toInt(r.position)
            if duration > 0 and position < duration
                name = asString(r.name)
                if name = "" then name = "Movie " + asString(r.id)
                entries.Push({ updatedAt: toInt(r.updatedAt), item: {
                    kind: "resume"
                    resumeKind: "movie"
                    itemKey: "movie:" + asString(r.id)
                    itemId: toInt(r.id)
                    name: name
                    ext: asString(r.ext)
                    position: position
                    duration: duration
                } })
            end if
        else if r.kind = "episode"
            resumeByEpisode[toInt(r.id).ToStr()] = r
        end if
    end for

    for each s in services.store.callFunc("getSeriesList")
        c = s.current
        item = {
            kind: "resume"
            resumeKind: "episode"
            itemKey: "series:" + asString(s.seriesId)
            itemId: toInt(c.episodeId)
            name: asString(s.name)
            seriesId: toInt(s.seriesId)
            seriesName: asString(s.name)
            year: toInt(s.year)
            season: toInt(c.season)
            episode: toInt(c.episode)
            ext: asString(c.ext)
            subtitle: "S" + toInt(c.season).ToStr() + " E" + toInt(c.episode).ToStr()
            position: 0
            duration: 0
        }
        r = resumeByEpisode[toInt(c.episodeId).ToStr()]
        if r <> invalid
            item.position = toInt(r.position)
            item.duration = toInt(r.duration)
        end if
        entries.Push({ updatedAt: toInt(s.updatedAt), item: item })
    end for

    entries.SortBy("updatedAt", "r")
    items = []
    for each e in entries
        items.Push(e.item)
    end for
    return items
end function
