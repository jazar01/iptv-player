' Guide (top bar): a channels-by-time grid. Channels come from Favorites,
' the market's local stations, or a Live TV category (SearchTask, from its
' index); each channel's schedule from get_simple_data_table, fetched only for
' the rows on screen and kept for an hour.

sub initGuide()
    m.guideChoice = "favorites"     ' "favorites" | "__local" | a category ID
    m.guideTables = {}              ' streamId -> { listings, at }
    m.guideWanted = []              ' stream IDs the grid is showing (latest)
    m.guideInflight = {}
    m.guideCategories = []          ' [{ id, name }] from SearchTask
    m.searchTask.ObserveField("guideResult", "onGuideResult")
end sub

function createGuideScreen() as Object
    screen = CreateObject("roSGNode", "GuideScreen")
    screen.ObserveField("wantSchedules", "onGuideWant")
    screen.ObserveField("play", "onGuidePlay")
    screen.ObserveField("categoryChosen", "onGuideCategory")
    return screen
end function

sub onGuideShown(screen as Object)
    ' The category list (and, for a category, its channels) from SearchTask.
    searchSend("guideRequest", { id: "guide", categoryId: guideCategoryId() })
    if m.guideChoice = "favorites" or m.guideChoice = "__local" then showGuideChannels()
end sub

' The SearchTask category to load, or "" for Favorites / Local stations.
function guideCategoryId() as String
    if m.guideChoice = "favorites" or m.guideChoice = "__local" then return ""
    return m.guideChoice
end function

sub onGuideResult(event as Object)
    result = event.GetData()
    screen = m.sections.guide
    if screen = invalid or result.id <> "guide" then return
    if type(result.categories) = "roArray" and result.categories.Count() > 0 then m.guideCategories = orderCategories(result.categories, "channel")
    choices = [{ id: "favorites", name: "Favorites" }]
    market = m.store.callFunc("getMarket")
    if market.key <> "" then choices.Push({ id: "__local", name: "Local stations - " + market.label })
    choices.Append(m.guideCategories)
    screen.categories = choices
    if result.categoryId <> "" and result.categoryId = m.guideChoice
        if not result.ready
            screen.status = "Still loading the channel list. Try again in a minute."
            return
        end if
        screen.title = guideChoiceName()
        screen.channels = result.channels
    end if
end sub

' Favorites and Local stations come from saved state and the locals list.
sub showGuideChannels()
    screen = m.sections.guide
    if screen = invalid then return
    channels = []
    if m.guideChoice = "favorites"
        for each f in m.store.callFunc("getFavorites")
            channels.Push({ streamId: toInt(f.streamId), name: f.name, epgChannelId: f.epgChannelId, logo: asString(m.channelIcons[toInt(f.streamId).ToStr()]) })
        end for
        screen.title = "Favorites"
        screen.channels = channels
        if channels.Count() = 0 then screen.status = "No favorites yet. Press * on a channel in Live TV to add one, or * here to pick other channels."
    else
        requestLocalStations("guide")
    end if
end sub

' Local stations for the Guide arrive through onLocalsResult (MainCatalog).
sub showGuideLocals(result as Object)
    screen = m.sections.guide
    if screen = invalid or m.guideChoice <> "__local" then return
    channels = []
    for each item in result.items
        channels.Push({ streamId: toInt(item.stream_id), name: asString(item.name), epgChannelId: asString(item.epg_channel_id), logo: asString(item.stream_icon) })
    end for
    screen.title = guideChoiceName()
    screen.channels = channels
    if not result.ready then screen.status = "Still loading the channel list. Try again in a minute."
end sub

function guideChoiceName() as String
    if m.guideChoice = "favorites" then return "Favorites"
    if m.guideChoice = "__local" then return "Local stations - " + m.store.callFunc("getMarket").label
    for each c in m.guideCategories
        if c.id = m.guideChoice then return c.name
    end for
    return ""
end function

sub onGuideCategory(event as Object)
    m.guideChoice = event.GetData()
    screen = m.sections.guide
    if screen = invalid then return
    screen.status = "Loading ..."
    if m.guideChoice = "favorites" or m.guideChoice = "__local"
        showGuideChannels()
    else
        searchSend("guideRequest", { id: "guide", categoryId: m.guideChoice })
    end if
end sub

sub onGuidePlay(event as Object)
    ch = event.GetData()
    if m.guideChoice <> "favorites" and m.guideChoice <> "__local" then recordCategoryUse("channel", m.guideChoice)
    playLive({ streamId: ch.streamId, name: ch.name, epgChannelId: ch.epgChannelId, archiveDays: ch.archiveDays })
end sub

' ---------------------------------------------------------------------------
' Schedules: cached ones go straight to the grid; the rest are fetched, at
' most 4 at a time, always for rows still on screen.

sub onGuideWant(event as Object)
    m.guideWanted = event.GetData()
    screen = event.GetRoSGNode()
    now = nowSeconds()
    for each id in m.guideWanted
        key = toInt(id).ToStr()
        t = m.guideTables[key]
        if t <> invalid and now - t.at < 3600 then screen.schedule = { streamId: key, listings: t.listings }
    end for
    pumpGuide()
end sub

sub pumpGuide()
    now = nowSeconds()
    for each id in m.guideWanted
        if m.guideInflight.Count() >= 4 then return
        key = toInt(id).ToStr()
        t = m.guideTables[key]
        if not m.guideInflight.DoesExist(key) and (t = invalid or now - t.at >= 3600)
            m.guideInflight[key] = true
            sendRequest({
                id: "guideTable"
                action: "get_simple_data_table"
                params: { stream_id: key }
                context: { streamId: key }
                timeoutMs: 20000
            })
        end if
    end for
end sub

sub onGuideTable(res as Object)
    key = asString(res.context.streamId)
    m.guideInflight.Delete(key)
    screen = m.sections.guide
    if not res.ok
        if screen <> invalid then screen.schedule = { streamId: key, failed: true }
        pumpGuide()
        return
    end if
    ' Keep from 3 hours back to 30 ahead, decoded, in start order.
    now = nowSeconds()
    listings = []
    if type(res.data) = "roAssociativeArray" and type(res.data.epg_listings) = "roArray"
        for each l in res.data.epg_listings
            if type(l) = "roAssociativeArray"
                start = toInt(l.start_timestamp)
                ends = toInt(l.stop_timestamp)
                if start > 0 and ends > start and ends > now - 3 * 3600 and start < now + 30 * 3600
                    listings.Push({ start: start, ends: ends, title: guideTitle(l.title), desc: guideTitle(l.description) })
                end if
            end if
        end for
    end if
    listings.SortBy("start")
    m.guideTables[key] = { listings: listings, at: now }
    if screen <> invalid then screen.schedule = { streamId: key, listings: listings }
    pumpGuide()
end sub
