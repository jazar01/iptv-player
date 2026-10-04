sub init()
    m.title = m.top.FindNode("title")
    m.seasonList = m.top.FindNode("seasonList")
    m.episodeList = m.top.FindNode("episodeList")
    m.status = m.top.FindNode("status")
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

sub onInfo()
    info = m.top.info
    title = asString(info.name)
    if toInt(info.year) > 0 then title = title + "  (" + toInt(info.year).ToStr() + ")"
    m.title.text = title

    m.seasons = []
    m.shownSeason = -1
    if type(info.seasons) = "roArray" then m.seasons = info.seasons
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
        node.ext = e.ext
        node.duration = e.duration
    end for
    m.episodeList.content = content
    applyProgress()
end sub

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
    else if key = "options" and m.episodeList.HasFocus()
        i = m.episodeList.itemFocused
        if i >= 0 and i < episodeCount() then m.top.options = episodeSummary(m.episodeList.content.GetChild(i))
        return true
    end if
    return false
end function
