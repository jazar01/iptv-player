' Guide (top bar): a channels-by-time grid. The channels are one or more
' sets ticked in its chooser (the "Channels" button, Up from the top row, or
' *): Favorites, the market's local stations, Live TV categories (SearchTask,
' from its index), shown one after another, each channel once. The choice is
' saved per TV (setting guideChoices). Each channel's schedule from
' get_simple_data_table, fetched only for the rows on screen while the Guide
' is showing, and kept for an hour. A failed schedule is tried again after
' 1 minute, then 5, then every 15 (a timer asks, so it happens without
' scrolling). It was 5, 15 and 60, and a guide that failed once stayed empty
' for most of an hour, looking like a channel with no guide (Willy Nilly TV,
' Oct 9, 2026).

sub initGuide()
    m.guideTables = {}              ' streamId -> { listings, at }
    m.guideWanted = []              ' stream IDs the grid is showing (latest)
    m.guideInflight = {}            ' streamId -> when its schedule was asked for
    m.guideFailed = {}              ' streamId -> { count, retryAt }
    m.guideWaiting = false          ' showing "Still loading"; asked again after indexing
    m.guideCategories = []          ' [{ id, name }] from SearchTask
    m.searchTask.ObserveField("guideResult", "onGuideResult")
    m.guideRetryTimer = CreateObject("roSGNode", "Timer")
    m.guideRetryTimer.duration = 60
    m.guideRetryTimer.ObserveField("fire", "onGuideRetry")
    m.top.AppendChild(m.guideRetryTimer)
end sub

function createGuideScreen() as Object
    screen = CreateObject("roSGNode", "GuideScreen")
    screen.ObserveField("wantSchedules", "onGuideWant")
    screen.ObserveField("play", "onGuidePlay")
    screen.ObserveField("choicesChosen", "onGuideChoices")
    return screen
end function

sub onGuideShown(screen as Object)
    requestGuideSets()
    pumpGuide()
end sub

' After a (re)index: a Guide still waiting for the channel list asks again.
sub refreshGuideIfWaiting()
    if not m.guideWaiting or m.sections.guide = invalid then return
    m.guideWaiting = false
    requestGuideSets()
end sub

' The ticked sets, in the chooser's order: "favorites", "__local", category
' IDs. Favorites when nothing is saved.
function guideChoices() as Object
    saved = m.store.callFunc("getSettings").guideChoices
    out = []
    if type(saved) = "roArray"
        for each id in saved
            if asString(id) <> "" then out.Push(asString(id))
        end for
    end if
    if out.Count() = 0 then out = ["favorites"]
    return out
end function

' The channels of every ticked set but Favorites come from SearchTask (the
' category list for the chooser too); the grid is put together when they
' arrive (onGuideResult).
sub requestGuideSets()
    ids = []
    for each id in guideChoices()
        if id <> "favorites" then ids.Push(id)
    end for
    searchSend("guideRequest", { id: "guide", categoryIds: ids, market: m.store.callFunc("getMarket").key })
end sub

sub onGuideResult(event as Object)
    result = event.GetData()
    screen = m.sections.guide
    if screen = invalid or result.id <> "guide" then return
    if type(result.categories) = "roArray" and result.categories.Count() > 0 then m.guideCategories = orderCategories(result.categories, "channel")
    sets = guideSetList()
    chosen = {}
    for each id in guideChoices()
        chosen[id] = true
    end for
    screen.categories = sets
    screen.selected = guideChoices()

    ' The ticked sets in the list's order, each channel once (in the first
    ' set it's in), marked with its set for the divider and the heading.
    channels = []
    seen = {}
    names = []
    for each s in sets
        if chosen.DoesExist(s.id)
            list = invalid
            if s.id = "favorites"
                list = favoriteGuideChannels()
            else if type(result.sets) = "roAssociativeArray"
                list = result.sets[s.id]
            end if
            if type(list) = "roArray"
                ' Short on the button and heading: "Local stations", not its market.
                short = s.name
                if s.id = "__local" then short = "Local stations"
                names.Push(short)
                first = true
                for each ch in list
                    key = toInt(ch.streamId).ToStr()
                    if not seen.DoesExist(key)
                        seen[key] = true
                        ch.group = short
                        ch.groupId = s.id
                        ch.groupStart = first
                        first = false
                        channels.Push(ch)
                    end if
                end for
            end if
        end if
    end for
    needsIndex = (names.Count() < chosen.Count()) or not (chosen.Count() = 1 and chosen.DoesExist("favorites"))
    m.guideWaiting = needsIndex and not isTrue(result.ready)
    screen.title = names
    screen.channels = channels
    if channels.Count() > 0 then return
    if m.guideWaiting
        screen.status = "Still loading the channel list ..."
    else if chosen.Count() = 1 and chosen.DoesExist("favorites")
        screen.status = "No favorites yet. Press * on a channel in Live TV to add one, or press Up here to choose other channels."
    else
        screen.status = "No channels in the sets chosen. Press Up to choose others."
    end if
end sub

' The chooser's list: Favorites, the market's local stations, then the live
' categories (most-used first, as in Live TV).
function guideSetList() as Object
    sets = [{ id: "favorites", name: "Favorites" }]
    market = m.store.callFunc("getMarket")
    if market.key <> "" then sets.Push({ id: "__local", name: "Local stations - " + market.label })
    sets.Append(m.guideCategories)
    return sets
end function

function favoriteGuideChannels() as Object
    channels = []
    for each f in m.store.callFunc("getFavorites")
        channels.Push({ streamId: toInt(f.streamId), name: f.name, epgChannelId: f.epgChannelId, logo: asString(m.channelIcons[toInt(f.streamId).ToStr()]) })
    end for
    return channels
end function

' The chooser's Show: saved for this TV, then the grid is rebuilt.
sub onGuideChoices(event as Object)
    ids = []
    for each id in event.GetData()
        if asString(id) <> "" then ids.Push(asString(id))
    end for
    if ids.Count() = 0 then return
    if not m.store.callFunc("setSetting", "guideChoices", ids) then print "[guide] couldn't save the channels chosen"
    m.guideWaiting = false
    screen = m.sections.guide
    if screen <> invalid then screen.status = "Loading ..."
    requestGuideSets()
end sub

sub onGuidePlay(event as Object)
    ch = event.GetData()
    group = asString(ch.groupId)
    if group <> "" and group <> "favorites" and group <> "__local" then recordCategoryUse("channel", group)
    playLive({ streamId: ch.streamId, name: ch.name, epgChannelId: ch.epgChannelId, archiveDays: ch.archiveDays })
end sub

' ---------------------------------------------------------------------------
' Schedules: cached ones go straight to the grid; the rest are fetched, at
' most 4 at a time, always for rows still on screen, and only while the Guide
' is the section showing with nothing over it.

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

' The next failed schedule's retry time: asks again then (pumpGuide skips
' it while the Guide isn't showing; showing it asks anyway).
sub scheduleGuideRetry()
    soonest = 0
    now = nowSeconds()
    for each key in m.guideFailed
        wait = m.guideFailed[key].retryAt - now
        if soonest = 0 or wait < soonest then soonest = wait
    end for
    if soonest <= 0 then return
    m.guideRetryTimer.control = "stop"
    m.guideRetryTimer.duration = soonest + 1
    m.guideRetryTimer.control = "start"
end sub

sub onGuideRetry()
    pumpGuide()
    scheduleGuideRetry()
end sub

sub pumpGuide()
    if m.section <> "guide" or m.overlays.Count() > 0 then return
    now = nowSeconds()
    ' A request unanswered after 90 s (ApiTask gives up well before) is
    ' forgotten, so a lost reply can't hold a slot for the session.
    for each key in m.guideInflight.Keys()
        if now - m.guideInflight[key] > 90 then m.guideInflight.Delete(key)
    end for
    for each id in m.guideWanted
        if m.guideInflight.Count() >= 4 then return
        key = toInt(id).ToStr()
        t = m.guideTables[key]
        f = m.guideFailed[key]
        waiting = f <> invalid and now < f.retryAt
        if not m.guideInflight.DoesExist(key) and not waiting and (t = invalid or now - t.at >= 3600)
            m.guideInflight[key] = now
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
        ' Wait before trying this channel again; a schedule already shown stays.
        f = m.guideFailed[key]
        if f = invalid then f = { count: 0 }
        f.count = f.count + 1
        waits = [60, 300, 900]
        n = f.count
        if n > waits.Count() then n = waits.Count()
        f.retryAt = nowSeconds() + waits[n - 1]
        m.guideFailed[key] = f
        if screen <> invalid and m.guideTables[key] = invalid then screen.schedule = { streamId: key, failed: true }
        print "[guide] "; key; ": couldn't load ("; friendlyRequestError(res); "); trying again in "; waits[n - 1]; " s"
        scheduleGuideRetry()
        pumpGuide()
        return
    end if
    m.guideFailed.Delete(key)
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
    if listings.Count() = 0
        raw = 0
        first = 0
        if type(res.data) = "roAssociativeArray" and type(res.data.epg_listings) = "roArray"
            raw = res.data.epg_listings.Count()
            if raw > 0 and type(res.data.epg_listings[0]) = "roAssociativeArray" then first = toInt(res.data.epg_listings[0].start_timestamp)
        else
            print "[guide] "; key; ": answer is "; type(res.data)
        end if
        print "[guide] "; key; ": none of "; raw; " listings kept (now "; now; ", first starts "; first; ")"
    end if
    m.guideTables[key] = { listings: listings, at: now }
    trimGuideTables(now)
    if screen <> invalid then screen.schedule = { streamId: key, listings: listings }
    pumpGuide()
end sub

' At most 150 schedules are kept: past that, ones more than an hour old go,
' then the oldest, so browsing many categories doesn't keep them all.
sub trimGuideTables(now as Integer)
    if m.guideTables.Count() <= 150 then return
    entries = []
    for each key in m.guideTables
        entries.Push({ key: key, at: m.guideTables[key].at })
    end for
    entries.SortBy("at")
    extra = entries.Count() - 150
    for each e in entries
        if extra <= 0 and now - e.at < 3600 then exit for
        m.guideTables.Delete(e.key)
        extra = extra - 1
    end for
end sub
