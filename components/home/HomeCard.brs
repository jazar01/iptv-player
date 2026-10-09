sub init()
    m.channel = m.top.FindNode("channel")
    m.name = m.top.FindNode("name")
    m.nowTitle = m.top.FindNode("nowTitle")
    m.tags = m.top.FindNode("tags")
    m.progressTrack = m.top.FindNode("progressTrack")
    m.progressFill = m.top.FindNode("progressFill")
    m.nextLine = m.top.FindNode("nextLine")

    m.info = m.top.FindNode("info")
    m.infoTitle = m.top.FindNode("infoTitle")
    m.infoText = m.top.FindNode("infoText")
    m.infoTrack = m.top.FindNode("infoTrack")
    m.infoFill = m.top.FindNode("infoFill")

    ' Card titles: explicit sizes (the named system fonts are too close in
    ' size to help); long names get the smaller one.
    m.titleFont = CreateObject("roSGNode", "Font")
    m.titleFont.uri = "font:BoldSystemFontFile"
    m.titleFont.size = 36
    m.titleFontSmall = CreateObject("roSGNode", "Font")
    m.titleFontSmall.uri = "font:BoldSystemFontFile"
    m.titleFontSmall.size = 28

    m.badge = m.top.FindNode("badge")
    m.initials = m.top.FindNode("initials")
    m.logo = m.top.FindNode("logo")
    m.logo.ObserveField("loadStatus", "onLogoStatus")
    m.channelLogo = m.top.FindNode("channelLogo")
    m.channelLogo.ObserveField("loadStatus", "onChannelLogoStatus")
    m.logoName = ""

    m.tick = m.top.FindNode("tick")
    m.tick.ObserveField("fire", "redraw")
    m.content = invalid
end sub

' Lists recycle card components, so move the epgVersion observer to the new
' content each time.
sub onItemContent()
    if m.content <> invalid then m.content.UnobserveFieldScoped("epgVersion")
    m.content = m.top.itemContent
    if m.content <> invalid then m.content.ObserveFieldScoped("epgVersion", "redraw")
    redraw()
end sub

sub redraw()
    c = m.content
    if c = invalid then return
    isChannel = (c.kind = "channel" or c.kind = "game")
    m.channel.visible = isChannel
    m.info.visible = not isChannel
    drawBadge(c)
    if c.kind = "game"
        drawGame(c)
    else if isChannel
        drawChannel(c)
    else
        m.tick.control = "stop"
        drawInfo(c)
    end if
    ' Last, so it can narrow the name drawn above (or reset a recycled card).
    drawChannelLogo(c, localizeName(asString(c.name)))
end sub

' Channel cards: the provider's logo at the top right, with the name beside
' it, but only for names short enough to fit there (about 15 characters);
' long event names, and cards whose logo is missing or fails to load, keep
' the full width.
sub drawChannelLogo(c as Object, name as String)
    logo = ""
    if c.kind = "channel" and name.Len() <= 15 then logo = c.logo
    m.logoName = name
    if m.channelLogo.uri <> logo then m.channelLogo.uri = logo
    onChannelLogoStatus()
end sub

sub onChannelLogoStatus()
    shown = (m.channelLogo.uri <> "" and m.channelLogo.loadStatus = "ready")
    m.channelLogo.visible = shown
    if shown
        m.name.width = 240
        ' Beside the logo the big font fits about 11 characters.
        if asString(m.logoName).Len() > 11 then m.name.font = m.titleFontSmall
    else
        m.name.width = 360
    end if
end sub

' My Teams cards get the team's logo (initials until it loads, or if there's
' none). Game cards: bottom right, so the matchup and start time keep the
' full width. "No game" cards: top right, beside the team name, so the
' message and sports below keep it. Text next to the logo is narrowed.
sub drawBadge(c as Object)
    isGame = (c.kind = "game")
    isTeam = isGame or c.kind = "noGame"
    m.badge.visible = isTeam
    narrow = 276
    full = 360
    if isGame then m.badge.translation = [306, 128] else m.badge.translation = [306, 14]
    m.tags.width = full
    m.nextLine.width = full
    m.infoTitle.width = full
    if isGame
        m.tags.width = narrow
        m.nextLine.width = narrow
    else if isTeam
        m.infoTitle.width = narrow
    end if
    if not isTeam
        m.logo.uri = ""
        return
    end if
    m.initials.text = teamInitials(c.teamName)
    if m.logo.uri <> c.logo then m.logo.uri = c.logo
    onLogoStatus()
end sub

sub onLogoStatus()
    loaded = (m.logo.uri <> "" and m.logo.loadStatus = "ready")
    m.logo.visible = loaded
    m.initials.visible = not loaded
end sub

' "Atlanta Braves" -> "AB", "Alabama" -> "AL".
function teamInitials(name as String) as String
    words = []
    for each w in name.Trim().Split(" ")
        if w <> "" then words.Push(w)
    end for
    if words.Count() = 0 then return ""
    if words.Count() = 1 then return UCase(Left(words[0], 2))
    return UCase(Left(words[0], 1) + Left(words[words.Count() - 1], 1))
end function

sub drawChannel(c as Object)
    name = localizeName(c.name)
    m.name.text = name
    ' Long names (event channels with times) step down a size so more fits.
    if name.Len() > 20 then m.name.font = m.titleFontSmall else m.name.font = m.titleFont
    now = nowSeconds()

    if c.nowTitle <> "" and c.nowEnd > now
        m.nowTitle.text = c.nowTitle
        m.tags.text = UCase(c.nowFlags.Replace(",", "  "))
        fraction = (now - c.nowStart) / (c.nowEnd - c.nowStart)
        if fraction < 0 then fraction = 0
        if fraction > 1 then fraction = 1
        m.progressFill.width = 360 * fraction
        m.progressTrack.visible = true
        m.progressFill.visible = true
        m.tick.control = "start"
    else
        ' epgVersion 0 means the guide hasn't answered yet: leave it blank.
        if c.epgVersion > 0 then m.nowTitle.text = "No guide information" else m.nowTitle.text = ""
        m.tags.text = ""
        m.progressTrack.visible = false
        m.progressFill.visible = false
        m.tick.control = "stop"
    end if

    if c.nextTitle <> "" and c.nextStart > 0
        m.nextLine.text = "Next  " + formatClock(c.nextStart) + "   " + c.nextTitle
    else
        m.nextLine.text = ""
    end if
end sub

' My Teams game: matchup, sport and start (or LIVE with progress), REPLAY
' tag, and the channel carrying it (+ how many more).
sub drawGame(c as Object)
    title = c.name
    m.name.text = title
    if title.Len() > 20 then m.name.font = m.titleFontSmall else m.name.font = m.titleFont
    now = nowSeconds()
    live = Instr(1, c.nowFlags, "live") > 0

    detail = c.subtitle
    if detail = "" then detail = c.teamName
    if not live and c.nowStart > now then detail = detail + "   " + formatDayTime(c.nowStart)
    ' A live score (My Teams, from ESPN) replaces the sport line while there is one.
    if c.message <> "" then detail = c.message
    m.nowTitle.text = detail
    m.tags.text = UCase(c.nowFlags.Replace(",", "  "))

    if live and c.nowEnd > c.nowStart
        fraction = (now - c.nowStart) / (c.nowEnd - c.nowStart)
        if fraction < 0 then fraction = 0
        if fraction > 1 then fraction = 1
        m.progressFill.width = 360 * fraction
        m.progressTrack.visible = true
        m.progressFill.visible = true
        m.tick.control = "start"
    else
        m.progressTrack.visible = false
        m.progressFill.visible = false
        m.tick.control = "stop"
    end if

    line = ""
    channels = c.channels
    if type(channels) = "roArray" and channels.Count() > 0
        if channels.Count() > 1
            more = channels.Count() - 1
            line = "+" + more.ToStr() + " more   "
        end if
        line = line + localizeName(asString(channels[0].name))
    end if
    m.nextLine.text = line
end sub

sub drawInfo(c as Object)
    m.infoTrack.visible = false
    m.infoFill.visible = false

    if c.kind = "resume"
        m.infoTitle.text = c.name
        detail = c.subtitle
        if c.duration > 0 and c.position > 0
            minutesLeft = Int((c.duration - c.position) / 60)
            if detail <> "" then detail = detail + "  -  "
            detail = detail + minutesLeft.ToStr() + " min left"
        else if c.resumeKind = "episode"
            detail = detail + "  -  next up"
        end if
        m.infoText.text = detail
        if c.duration > 0 and c.position > 0
            fraction = c.position / c.duration
            if fraction > 1 then fraction = 1
            m.infoFill.width = 360 * fraction
            m.infoTrack.visible = true
            m.infoFill.visible = true
        end if
    else if c.kind = "series"
        ' Favorite Series: name (year), and where you are in it.
        m.infoTitle.text = c.name
        m.infoText.text = c.subtitle
    else if c.kind = "movie"
        ' Watch List: name (year), and runtime or "Not available".
        m.infoTitle.text = c.name
        m.infoText.text = c.subtitle
    else if c.kind = "seeAll"
        m.infoTitle.text = "See all"
        m.infoText.text = c.message
    else if c.kind = "noGame"
        ' My Teams: a team with nothing in the guide yet (its next game, or none).
        ' Message first so it always shows; the sports go below (trimmed).
        m.infoTitle.text = c.name
        detail = c.message
        if c.subtitle <> "" then detail = detail + Chr(10) + c.subtitle
        m.infoText.text = detail
    else
        m.infoTitle.text = "Nothing here yet"
        m.infoText.text = c.message
    end if
end sub
