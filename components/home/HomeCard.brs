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
    isChannel = (c.kind = "channel")
    m.channel.visible = isChannel
    m.info.visible = not isChannel
    if isChannel
        drawChannel(c)
    else
        m.tick.control = "stop"
        drawInfo(c)
    end if
end sub

sub drawChannel(c as Object)
    m.name.text = c.name
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
    else
        m.infoTitle.text = "Nothing here yet"
        m.infoText.text = c.message
    end if
end sub
