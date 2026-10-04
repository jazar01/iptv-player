' Home screen rows. Each row is a module that supplies its own items from the
' services it's given; MainScene shows them in this fixed order. A new row
' (e.g. My Teams) is a new module added to homeRowModules().
'
' module: { id, title, emptyText, items(services) -> array of HomeItem field AAs }
' services: { store: StateStore, epg: EpgService }

function homeRowModules() as Object
    return [favoritesRow(), continueWatchingRow()]
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
    favorites = services.store.callFunc("getFavorites")
    ids = []
    for each f in favorites
        ids.Push(toInt(f.streamId))
    end for
    programs = services.epg.callFunc("getPrograms", ids)

    items = []
    for each f in favorites
        id = toInt(f.streamId)
        item = {
            kind: "channel"
            itemKey: "live:" + id.ToStr()
            streamId: id
            name: asString(f.name)
            epgChannelId: asString(f.epgChannelId)
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
' Continue Watching: movies and episodes with time left. Filled once playback
' exists (next milestone).

function continueWatchingRow() as Object
    return {
        id: "continue"
        title: "Continue Watching"
        emptyText: "Movies and episodes you start will appear here."
        items: continueWatchingRowItems
    }
end function

function continueWatchingRowItems(services as Object) as Object
    items = []
    for each r in services.store.callFunc("getResume")
        duration = toInt(r.duration)
        position = toInt(r.position)
        if duration > 0 and position < duration
            name = asString(r.name)
            if name = "" then name = asString(r.kind) + " " + asString(r.id)
            items.Push({
                kind: "resume"
                itemKey: asString(r.kind) + ":" + asString(r.id)
                name: name
                position: position
                duration: duration
            })
        end if
    end for
    return items
end function
