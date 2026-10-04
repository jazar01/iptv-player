' Home rows, the Favorites grid, favorites toggling, now/next relays, and
' routing of selected cards and list items.

sub initHome()
    m.favoritesScreen = invalid
    m.lastVisible = []
end sub

sub refreshHome()
    home = m.sections.home
    if home = invalid then return
    rows = buildHomeRows({ store: m.store, epg: m.epg })
    home.rows = rows
    if m.favoritesScreen <> invalid
        for each row in rows
            if row.id = "favorites" then m.favoritesScreen.items = row.items
        end for
    end if
end sub

sub openFavorites()
    m.favoritesScreen = CreateObject("roSGNode", "FavoritesScreen")
    m.favoritesScreen.ObserveField("selected", "onItemSelected")
    m.favoritesScreen.ObserveField("options", "onToggleFavorite")
    m.favoritesScreen.ObserveField("visibleChannels", "onVisibleChannels")
    pushOverlay(m.favoritesScreen)
    refreshHome()
end sub

' A card or list item was chosen on Home, the Favorites grid or a catalog.
sub onItemSelected(event as Object)
    item = event.GetData()
    if item.kind = "seeAll" and item.rowId = "favorites"
        openFavorites()
    else if item.kind = "channel"
        playLive(item)
    else if item.kind = "movie"
        playMovie(item, true)
    else if item.kind = "series"
        openSeries(item)
    else if item.kind = "resume" and item.resumeKind = "movie"
        playMovie(item, false)
    else if item.kind = "resume" and item.resumeKind = "episode"
        continueSeries(item)
    end if
end sub

' * on any channel: add it to favorites, or remove it if it's already one.
sub onToggleFavorite(event as Object)
    channel = event.GetData()
    if channel.streamId = invalid or channel.streamId = 0 then return
    if m.store.callFunc("isFavorite", channel.streamId)
        saved = m.store.callFunc("removeFavorite", channel.streamId)
        message = "Removed " + channel.name + " from Favorites"
    else
        saved = m.store.callFunc("addFavorite", { streamId: channel.streamId, name: channel.name, epgChannelId: channel.epgChannelId })
        message = "Added " + channel.name + " to Favorites"
    end if
    if not saved then message = "Couldn't save the change. Storage may be full."
    showToast(message)
    refreshHome()
    updateCatalogTags()
end sub

' ---------------------------------------------------------------------------
' Now/next

sub onVisibleChannels(event as Object)
    m.lastVisible = event.GetData()
    m.epg.callFunc("want", m.lastVisible)
end sub

sub onEpgTimer()
    if m.lastVisible.Count() > 0 then m.epg.callFunc("want", m.lastVisible)
    if m.player <> invalid and m.playing <> invalid and m.playing.kind = "live" then m.epg.callFunc("want", [m.playing.id])
end sub

sub onPrograms(event as Object)
    entry = event.GetData()
    home = m.sections.home
    if home <> invalid then home.programs = entry
    if m.favoritesScreen <> invalid then m.favoritesScreen.programs = entry
    if m.player <> invalid then m.player.programs = entry
end sub
