' Home rows, the "See all" grids, favorites toggling, now/next relays, and
' routing of selected cards and list items.

sub initHome()
    m.rowGrid = invalid          ' "See all" grid open on top of Home
    m.lastVisible = []
    ' Usage scores as they were at launch: rows are ordered by these all
    ' session, so nothing reshuffles (requirements: re-sort at launch only).
    m.launchTime = nowSeconds()
    m.usageScores = m.store.callFunc("getUsageScores")
    m.channelIcons = {}         ' streamId -> logo URL ("" = none), from SearchTask
    m.iconsPending = false
end sub

sub refreshHome()
    home = m.sections.home
    if home = invalid then return
    rows = buildHomeRows({ store: m.store, epg: m.epg, games: m.games, usage: m.usageScores, launchTime: m.launchTime, icons: m.channelIcons })
    home.rows = rows
    requestChannelIcons(rows)
    if m.rowGrid <> invalid
        for each row in rows
            if row.id = m.rowGridId then m.rowGrid.row = row
        end for
    end if
end sub

' Channel logos for the channel cards, asked once per channel; the rows
' are rebuilt when new ones arrive. Until the channel list is indexed the
' answer is empty and the next refresh asks again.
sub requestChannelIcons(rows as Object)
    if m.iconsPending or m.searchTask = invalid then return
    missing = []
    for each row in rows
        for each item in row.items
            if item.kind = "channel" and not m.channelIcons.DoesExist(toInt(item.streamId).ToStr()) then missing.Push(item.streamId)
        end for
    end for
    if missing.Count() = 0 then return
    m.iconsPending = true
    searchSend("iconsRequest", { id: "home", streamIds: missing })
end sub

sub onIconsResult(event as Object)
    result = event.GetData()
    m.iconsPending = false
    if not result.ready then return
    found = false
    for each key in result.icons
        m.channelIcons[key] = result.icons[key]
        if result.icons[key] <> "" then found = true
    end for
    if found then refreshHome()
end sub

' "See all" on any Home row: every item of that row in a full-screen grid,
' kept up to date by refreshHome().
sub openRowGrid(rowId as String)
    m.rowGrid = CreateObject("roSGNode", "RowGridScreen")
    m.rowGridId = rowId
    m.rowGrid.ObserveField("selected", "onItemSelected")
    m.rowGrid.ObserveField("options", "onRowGridOptions")
    m.rowGrid.ObserveField("visibleChannels", "onVisibleChannels")
    pushOverlay(m.rowGrid)
    refreshHome()
end sub

' * in a "See all" grid: as on Home, except Favorites offers pin / remove.
sub onRowGridOptions(event as Object)
    item = event.GetData()
    if item.kind = "resume"
        removeContinue(item)
    else if item.rowId = "favorites"
        favoriteOptions(item)
    else
        toggleFavorite(item)
    end if
end sub

' A card or list item was chosen on Home, a "See all" grid or a catalog.
sub onItemSelected(event as Object)
    item = event.GetData()
    if item.kind = "seeAll"
        openRowGrid(item.rowId)
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
    else if item.kind = "game"
        onGameSelected(item)
    else if item.kind = "noGame"
        onNoGameTeamSelected(item)
    end if
end sub

' * on any channel: add it to favorites, or remove it if it's already one.
sub onToggleFavorite(event as Object)
    toggleFavorite(event.GetData())
end sub

sub toggleFavorite(channel as Object)
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
    search = m.sections.search
    if search <> invalid then search.favoriteIds = favoriteIdSet()
end sub

' * in the Favorites grid: pin to the front (or unpin), or remove. Pinned
' favorites stay first in the order they were pinned; the rest follow usage.
sub favoriteOptions(item as Object)
    pinned = false
    for each f in m.store.callFunc("getFavorites")
        if toInt(f.streamId) = toInt(item.streamId) then pinned = isTrue(f.pinned)
    end for
    pinLabel = "Pin to front"
    if pinned then pinLabel = "Unpin"
    dlg = CreateObject("roSGNode", "StandardMessageDialog")
    dlg.title = localizeName(item.name)
    dlg.message = ["Pinned favorites always come first, in the order you pin them. The rest are ordered by how much you watch them."]
    dlg.buttons = [pinLabel, "Remove from Favorites", "Cancel"]
    dlg.ObserveField("buttonSelected", "onFavoriteOptionChosen")
    m.favoriteDialog = { dialog: dlg, item: item, pinned: pinned }
    m.top.dialog = dlg
end sub

sub onFavoriteOptionChosen()
    d = m.favoriteDialog
    if d = invalid then return
    m.favoriteDialog = invalid
    choice = d.dialog.buttonSelected
    d.dialog.close = true
    if choice = 0
        if m.store.callFunc("setPinned", d.item.streamId, not d.pinned)
            if d.pinned then showToast("Unpinned " + d.item.name) else showToast("Pinned " + d.item.name + " to the front")
        else
            showToast("Couldn't save the change. Storage may be full.")
        end if
        refreshHome()
    else if choice = 1
        toggleFavorite(d.item)
    end if
end sub

' * on a Continue Watching card: take it off the row (watched history stays).
sub onRemoveContinue(event as Object)
    removeContinue(event.GetData())
end sub

sub removeContinue(item as Object)
    if m.store.callFunc("removeFromContinue", item)
        showToast("Removed " + item.name + " from Continue Watching")
    else
        showToast("Couldn't save the change. Storage may be full.")
    end if
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
    if m.rowGrid <> invalid then m.rowGrid.programs = entry
    if m.player <> invalid then m.player.programs = entry
end sub
