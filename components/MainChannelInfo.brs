' Channel info: the side panel over the player (OK twice) and over Live TV
' (* -> Channel info). Details and other copies come from SearchTask's
' index, the coming-up list from the channel's guide (ApiTask), and the live
' stream details from the player itself.

sub initChannelInfo()
    m.infoFor = invalid         ' { source: "player" | "catalog", streamId, name, details, programs, programsNote }
    m.infoPanel = invalid       ' the panel over Live TV
    m.channelDialog = invalid
    m.searchTask.ObserveField("infoResult", "onInfoResult")
end sub

' channel: { streamId, name, epgChannelId }
sub showChannelInfo(channel as Object, source as String)
    streamId = toInt(channel.streamId)
    m.infoFor = { source: source, streamId: streamId, name: asString(channel.name), epgChannelId: asString(channel.epgChannelId), details: invalid, programs: invalid, programsNote: "Loading the guide ..." }
    if source = "catalog"
        m.infoPanel = CreateObject("roSGNode", "ChannelInfoPanel")
        m.infoPanel.dim = true
        m.infoPanel.ObserveField("chosen", "onInfoCopyChosen")
        pushOverlay(m.infoPanel)
    end if
    deliverChannelInfo()
    checkConnections("info")
    searchSend("infoRequest", { id: source, streamId: streamId, market: m.store.callFunc("getMarket").key })
    sendRequest({
        id: "channelGuide"
        action: "get_simple_data_table"
        params: { stream_id: streamId }
        context: { streamId: streamId }
        timeoutMs: 20000
    })
end sub

sub onInfoResult(event as Object)
    result = event.GetData()
    if result.id = "failed"
        ' For the error panel (onPlayerFailed): only if that channel is still the one failing.
        if m.player = invalid or m.playing = invalid or toInt(m.playing.id) <> result.streamId then return
        if type(result.copies) = "roArray" and result.copies.Count() > 0
            print "[main] offering "; result.copies.Count(); " other copies"
            m.player.errorCopiesLabel = "Try another copy of this channel   (OK to play)"
            m.player.errorCopies = result.copies
        else if type(result.similar) = "roArray" and result.similar.Count() > 0
            ' No copies: channels with similar names (may be different programming).
            print "[main] no copies; offering "; result.similar.Count(); " similar channels"
            m.player.errorCopiesLabel = "No other copies. Similar channels   (OK to play)"
            m.player.errorCopies = result.similar
        end if
        return
    end if
    if m.infoFor = invalid or result.streamId <> m.infoFor.streamId then return
    if result.found then m.infoFor.details = result
    deliverChannelInfo()
end sub

' get_simple_data_table -> the next 4 programs, from what's on now.
sub onChannelGuide(res as Object)
    if m.infoFor = invalid or toInt(res.context.streamId) <> m.infoFor.streamId then return
    m.infoFor.programs = []
    m.infoFor.programsNote = ""
    if not res.ok
        m.infoFor.programsNote = "Couldn't load the guide: " + res.error
    else if type(res.data) = "roAssociativeArray" and type(res.data.epg_listings) = "roArray"
        now = nowSeconds()
        upcoming = []
        for each listing in res.data.epg_listings
            if type(listing) = "roAssociativeArray" and toInt(listing.stop_timestamp) > now and toInt(listing.start_timestamp) > 0 then upcoming.Push(listing)
        end for
        upcoming.SortBy("start_timestamp")
        today = formatDayTime(now).Split(" ")[0]
        for each listing in upcoming
            if m.infoFor.programs.Count() < 4
                start = toInt(listing.start_timestamp)
                when = formatClock(start)
                if start <= now
                    when = "Now"
                    m.infoFor.nowDescription = guideTitle(listing.description)
                end if
                if formatDayTime(start).Split(" ")[0] <> today then when = formatDayTime(start)
                m.infoFor.programs.Push(when + "   " + guideTitle(listing.title))
            end if
        end for
    end if
    if m.infoFor.programs.Count() = 0 and m.infoFor.programsNote = "" then m.infoFor.programsNote = "No guide information for this channel."
    deliverChannelInfo()
end sub

' Guide titles: base64 (per the rules) with superscript tags removed.
function guideTitle(value as Dynamic) as String
    text = asString(value)
    rules = guideRules()
    base64 = true
    if type(rules.epg) = "roAssociativeArray" and rules.epg.base64Titles <> invalid then base64 = isTrue(rules.epg.base64Titles)
    if base64 and text <> ""
        bytes = CreateObject("roByteArray")
        bytes.FromBase64String(text)
        decoded = bytes.ToAsciiString()
        if decoded <> "" then text = decoded
    end if
    if type(rules.titleTags) = "roArray"
        for each tag in rules.titleTags
            if type(tag) = "roAssociativeArray" and asString(tag.text) <> "" then text = text.Replace(asString(tag.text), "")
        end for
    end if
    return text.Trim()
end function

sub deliverChannelInfo()
    f = m.infoFor
    if f = invalid then return
    d = f.details
    name = f.name
    logo = ""
    facts = []
    copies = []
    epg = f.epgChannelId
    if d <> invalid
        name = d.name
        logo = d.icon
        epg = d.epgChannelId
        if d.category <> "" then facts.Push(d.category)
        copies = d.copies
    end if
    ' Short lines, combined, so the panel leaves room for Other copies.
    line = []
    if d <> invalid
        if d.archiveDays > 0 then line.Push("Rewind " + d.archiveDays.ToStr() + " days") else line.Push("No rewind")
    end if
    quality = qualityFromName(name)
    if quality <> "" then line.Push(quality + " (by name)")
    if m.store.callFunc("isFavorite", f.streamId) then line.Push("Favorite")
    if d <> invalid and isTrue(d.local) then line.Push("Local station")
    if line.Count() > 0 then facts.Push(joinStrings(line, "   -   "))
    guide = "Guide " + epg
    if epg = "" then guide = "No guide ID"
    facts.Push(guide + "   -   Stream " + f.streamId.ToStr())
    connections = connectionsText()
    if connections <> "" then facts.Push("Account connections:   " + connections)

    info = { name: name, logo: logo, facts: facts, programs: f.programs, programsNote: f.programsNote, nowDescription: asString(f.nowDescription), copies: copies }
    if f.source = "player"
        if m.player <> invalid then m.player.channelInfo = info
    else if m.infoPanel <> invalid
        m.infoPanel.info = info
    end if
end sub

' Resolution from the tags providers put in names: "ESPN (1080p)", "BBC One HD".
function qualityFromName(name as String) as String
    n = UCase(name)
    if CreateObject("roRegex", "\b(4K|UHD|2160P?)\b", "").IsMatch(n) then return "4K"
    if CreateObject("roRegex", "\b(FHD|1080[PI]?)\b", "").IsMatch(n) then return "1080p"
    if CreateObject("roRegex", "\b(720P?)\b", "").IsMatch(n) then return "720p"
    if CreateObject("roRegex", "\bHD\b", "").IsMatch(n) then return "HD"
    if CreateObject("roRegex", "\bSD\b", "").IsMatch(n) then return "SD"
    return ""
end function

' A copy picked from Other copies: watch it.
sub onInfoCopyChosen(event as Object)
    copy = event.GetData()
    if m.infoPanel <> invalid
        panel = m.infoPanel
        m.infoPanel = invalid
        removeOverlay(panel)
    end if
    m.infoFor = invalid
    playLive({ streamId: copy.streamId, name: copy.name, epgChannelId: copy.epgChannelId, archiveDays: copy.archiveDays })
end sub

sub onPlayerInfoRequested(event as Object)
    showChannelInfo(event.GetData(), "player")
end sub

' ---------------------------------------------------------------------------
' * in Live TV: Add to / Remove from Favorites, or Channel info.

sub onCatalogOptions(event as Object)
    channel = event.GetData()
    if asString(channel.kind) = "series"
        toggleSeriesFavorite(channel)      ' Series list: * adds or removes it
        return
    end if
    if channel.streamId = invalid or channel.streamId = 0 then return
    favLabel = "Add to Favorites"
    if m.store.callFunc("isFavorite", channel.streamId) then favLabel = "Remove from Favorites"
    dlg = CreateObject("roSGNode", "StandardMessageDialog")
    dlg.title = localizeName(asString(channel.name))
    dlg.buttons = [favLabel, "Channel info", "Cancel"]
    dlg.ObserveField("buttonSelected", "onCatalogOptionChosen")
    dlg.ObserveField("wasClosed", "onCatalogOptionsClosed")
    m.channelDialog = { dialog: dlg, channel: channel }
    m.top.dialog = dlg
end sub

sub onCatalogOptionChosen()
    d = m.channelDialog
    if d = invalid then return
    m.channelDialog = invalid
    choice = d.dialog.buttonSelected
    d.dialog.close = true
    if choice = 0
        toggleFavorite(d.channel)
    else if choice = 1
        showChannelInfo(d.channel, "catalog")
    end if
end sub

sub onCatalogOptionsClosed()
    m.channelDialog = invalid
end sub
