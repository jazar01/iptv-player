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
    if c.kind = "game"
        drawGame(c)
    else if isChannel
        drawChannel(c)
    else
        m.tick.control = "stop"
        drawInfo(c)
    end if
end sub

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
    else if c.kind = "seeAll"
        m.infoTitle.text = "See all"
        m.infoText.text = c.message
    else if c.kind = "noGame"
        ' My Teams: a team with nothing in the next 24 hours.
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
