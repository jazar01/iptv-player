sub init()
    m.title = m.top.FindNode("title")
    m.seasonList = m.top.FindNode("seasonList")
    m.episodeList = m.top.FindNode("episodeList")
    m.status = m.top.FindNode("status")
    m.backdrop = m.top.FindNode("backdrop")
    m.cover = m.top.FindNode("cover")
    m.epPlot = m.top.FindNode("epPlot")
    m.backdrop.ObserveField("loadStatus", "onBackdropStatus")
    m.episodeList.ObserveField("itemFocused", "onEpisodeFocused")
    m.seasons = []
    m.shownSeason = -1
    m.inEpisodes = true

    m.seasonList.ObserveField("itemFocused", "onSeasonFocused")
    m.seasonList.ObserveField("itemSelected", "onSeasonSelected")
    m.episodeList.ObserveField("itemSelected", "onEpisodeSelected")
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

sub onFocusedChild()
    if not m.top.HasFocus() then return
    if m.inEpisodes and episodeCount() > 0
        m.episodeList.SetFocus(true)
    else
        m.inEpisodes = false
        m.seasonList.SetFocus(true)
    end if
end sub

sub onStatus()
    m.status.text = m.top.status
    m.status.visible = (m.top.status <> "")
end sub

' The title, marked when the series is a favorite.
sub drawTitle()
    title = asString(m.baseTitle)
    if m.top.isFavorite then title = title + "   -   Favorite"
    m.title.text = title
end sub

sub onInfo()
    info = m.top.info
    title = asString(info.name)
    ' Many providers already put the year in the name.
    year = toInt(info.year)
    if year > 0 and Instr(1, title, year.ToStr()) = 0 then title = title + "  (" + year.ToStr() + ")"
    m.baseTitle = title
    drawTitle()

    m.seasons = []
    m.shownSeason = -1
    if type(info.seasons) = "roArray" then m.seasons = info.seasons
    drawDetails(info.details)
    content = CreateObject("roSGNode", "ContentNode")
    for each s in m.seasons
        item = content.CreateChild("ContentNode")
        if s.season = 0 then item.title = "Specials" else item.title = "Season " + s.season.ToStr()
    end for
    m.seasonList.content = content
    if m.seasons.Count() = 0
        m.top.status = "No episodes found for this series."
        return
    end if
    m.top.status = ""

    ' Open on the series' current episode, else the first season.
    seasonIndex = 0
    episodeIndex = 0
    for si = 0 to m.seasons.Count() - 1
        episodes = m.seasons[si].episodes
        for ei = 0 to episodes.Count() - 1
            if episodes[ei].id = m.top.focusEpisodeId
                seasonIndex = si
                episodeIndex = ei
            end if
        end for
    end for
    m.seasonList.jumpToItem = seasonIndex
    showSeason(seasonIndex)
    m.episodeList.jumpToItem = episodeIndex
    m.inEpisodes = true
    if m.top.IsInFocusChain() then m.episodeList.SetFocus(true)
end sub

sub onSeasonFocused()
    showSeason(m.seasonList.itemFocused)
end sub

sub onSeasonSelected()
    showSeason(m.seasonList.itemSelected)
    if episodeCount() > 0
        m.inEpisodes = true
        m.episodeList.SetFocus(true)
    end if
end sub

sub showSeason(index as Integer)
    if index < 0 or index >= m.seasons.Count() or index = m.shownSeason then return
    m.shownSeason = index
    content = CreateObject("roSGNode", "ContentNode")
    for each e in m.seasons[index].episodes
        node = content.CreateChild("EpisodeNode")
        node.episodeId = e.id
        node.season = e.season
        node.episode = e.episode
        node.name = e.name
        node.displayName = episodeTitle(e.name)
        node.ext = e.ext
        node.duration = e.duration
        node.plot = asString(e.plot)
        node.airDate = asString(e.airDate)
    end for
    m.episodeList.content = content
    applyProgress()
    onEpisodeFocused()
end sub

' Header: cover, backdrop, year / genre / rating, plot, director and cast.
sub drawDetails(details as Dynamic)
    if type(details) <> "roAssociativeArray" then details = {}
    m.cover.uri = asString(details.cover)
    m.backdrop.uri = asString(details.backdrop)
    onBackdropStatus()
    meta = []
    year = toInt(m.top.info.year)
    if year > 0 then meta.Push(year.ToStr())
    seasonCount = m.seasons.Count()
    if seasonCount = 1
        meta.Push("1 season")
    else if seasonCount > 1
        meta.Push(seasonCount.ToStr() + " seasons")
    end if
    if asString(details.genre) <> "" then meta.Push(asString(details.genre))
    if asString(details.rating) <> "" then meta.Push("Rated " + asString(details.rating) + " / 10")
    text = ""
    for each part in meta
        if text <> "" then text += "     "
        text += part
    end for
    m.top.FindNode("meta").text = text
    m.top.FindNode("plot").text = asString(details.plot)
    people = ""
    if asString(details.director) <> "" then people = "Director:  " + asString(details.director) + "     "
    if asString(details.cast) <> "" then people = people + "Cast:  " + asString(details.cast)
    m.top.FindNode("people").text = people
end sub

sub onBackdropStatus()
    m.backdrop.visible = (m.backdrop.uri <> "" and m.backdrop.loadStatus = "ready")
end sub

' Below the list: the focused episode's air date, length and description.
sub onEpisodeFocused()
    i = m.episodeList.itemFocused
    content = m.episodeList.content
    plot = ""
    if content <> invalid and i >= 0 and i < content.GetChildCount()
        node = content.GetChild(i)
        ' "Aired Feb 10, 2019     22 min", then the description if there is one.
        facts = []
        aired = friendlyDate(node.airDate)
        if aired <> "" then facts.Push("Aired " + aired)
        if node.duration > 0 then facts.Push(Int((node.duration + 30) / 60).ToStr() + " min")
        for each f in facts
            if plot <> "" then plot += "     "
            plot += f
        end for
        if node.plot <> ""
            if plot <> "" then plot += Chr(10)
            plot += node.plot
        end if
    end if
    m.epPlot.text = plot
end sub

' "The Last Kingdom (2015) - S01E01 - Episode 1" -> "Episode 1", using the
' episodeTitlePrefix rule from data/guide-rules.json. Display only.
function episodeTitle(name as String) as String
    if m.episodePrefix = invalid
        m.episodePrefix = false
        json = ParseJson(ReadAsciiFile("pkg:/data/guide-rules.json"))
        if type(json) = "roAssociativeArray" and asString(json.episodeTitlePrefix) <> "" then m.episodePrefix = CreateObject("roRegex", json.episodeTitlePrefix, "i")
    end if
    if type(m.episodePrefix) <> "roRegex" then return name
    short = m.episodePrefix.Replace(name, "").Trim()
    if short = "" then return name
    return short
end function

sub onProgress()
    applyProgress()
end sub

sub applyProgress()
    progress = m.top.progress
    content = m.episodeList.content
    if content = invalid or type(progress) <> "roAssociativeArray" then return
    for i = 0 to content.GetChildCount() - 1
        node = content.GetChild(i)
        r = progress.resume[node.episodeId.ToStr()]
        if progress.watched.DoesExist(node.season.ToStr() + ":" + node.episode.ToStr())
            node.state = "watched"
            node.stateText = "WATCHED"
        else if r <> invalid and r.position > 0
            node.state = "progress"
            node.stateText = "IN PROGRESS"
            if r.duration > r.position then node.stateText = Int((r.duration - r.position) / 60).ToStr() + " MIN LEFT"
        else
            node.state = "new"
            node.stateText = "NEW"
        end if
    end for
end sub

function episodeCount() as Integer
    content = m.episodeList.content
    if content = invalid then return 0
    return content.GetChildCount()
end function

function episodeSummary(node as Object) as Object
    info = m.top.info
    return {
        kind: "episode"
        id: node.episodeId
        itemId: node.episodeId
        season: node.season
        episode: node.episode
        name: node.name
        ext: node.ext
        duration: node.duration
        state: node.state
        seriesId: toInt(info.seriesId)
        seriesName: asString(info.name)
        year: toInt(info.year)
    }
end function

sub onEpisodeSelected()
    i = m.episodeList.itemSelected
    if i >= 0 and i < episodeCount() then m.top.selected = episodeSummary(m.episodeList.content.GetChild(i))
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "right" and m.seasonList.HasFocus() and episodeCount() > 0
        m.inEpisodes = true
        m.episodeList.SetFocus(true)
        return true
    else if key = "left" and m.episodeList.HasFocus()
        m.inEpisodes = false
        m.seasonList.SetFocus(true)
        return true
    else if key = "options" and m.seasonList.HasFocus()
        ' * on the seasons: add the whole series to (or remove it from) Favorite Series.
        info = m.top.info
        if type(info) = "roAssociativeArray" then m.top.favoriteToggle = { itemId: info.seriesId, name: info.name, year: info.year }
        return true
    else if key = "options" and m.episodeList.HasFocus()
        i = m.episodeList.itemFocused
        if i >= 0 and i < episodeCount() then m.top.options = episodeSummary(m.episodeList.content.GetChild(i))
        return true
    end if
    return false
end function

' "2019-02-10" -> "Feb 10, 2019"; anything else is shown as given ("" stays "").
function friendlyDate(text as String) as String
    parts = text.Split("-")
    if parts.Count() < 3 then return text
    month = Val(parts[1], 10)
    day = Val(Left(parts[2], 2), 10)
    if month < 1 or month > 12 or day < 1 then return text
    names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return names[month - 1] + " " + day.ToStr() + ", " + parts[0]
end function
