sub init()
    m.GRID_X = 420              ' programs start here; channel names to the left
    m.GRID_W = 1404             ' to x 1824
    m.WINDOW = 3 * 3600         ' 3 hours across
    m.PX = m.GRID_W / m.WINDOW  ' pixels per second
    m.ROW_H = 88
    m.ROWS = 7
    m.STEP = 1800               ' the window moves in half hours

    m.rowsGroup = m.top.FindNode("rows")
    m.timeHeader = m.top.FindNode("timeHeader")
    m.nowLine = m.top.FindNode("nowLine")
    m.statusLabel = m.top.FindNode("status")
    m.chooser = m.top.FindNode("chooser")
    m.chooserList = m.top.FindNode("chooserList")
    m.chooserList.ObserveField("itemSelected", "onChooserSelected")
    m.chooserTimer = CreateObject("roSGNode", "Timer")
    m.chooserTimer.duration = 0.05
    m.chooserTimer.ObserveField("fire", "onChooserTimer")
    m.top.AppendChild(m.chooserTimer)
    m.pendingChoice = ""

    m.channels = []
    m.schedules = {}            ' streamId -> [{ start, ends, title, desc }] (or invalid while loading)
    m.failed = {}               ' streamId -> true when its schedule couldn't be loaded
    m.categoryIds = []
    m.row = 0                   ' focused channel (index into m.channels)
    m.topRow = 0                ' first channel on screen
    m.windowMin = halfHour(nowSeconds())
    m.windowStart = m.windowMin
    m.focusTime = nowSeconds()
    m.minutes = 0

    ' Fixed row nodes, refilled on every redraw (only on-screen rows exist).
    m.rowNodes = []
    for r = 0 to m.ROWS - 1
        g = m.rowsGroup.CreateChild("Group")
        g.translation = [0, r * m.ROW_H]
        logo = g.CreateChild("Poster")
        logo.translation = [96, Int((m.ROW_H - 44) / 2)]
        logo.width = 72
        logo.height = 44
        logo.loadDisplayMode = "scaleToFit"
        name = g.CreateChild("Label")
        name.translation = [180, 0]
        name.width = 226
        name.height = m.ROW_H
        name.vertAlign = "center"
        name.wrap = true
        name.maxLines = 2
        name.font = "font:SmallestSystemFont"
        name.color = "0xD0D6DCFF"
        programs = g.CreateChild("Group")
        m.rowNodes.Push({ group: g, logo: logo, name: name, programs: programs })
    end for

    m.wantDelay = m.top.FindNode("wantDelay")
    m.wantDelay.ObserveField("fire", "reportWanted")
    timer = m.top.FindNode("nowTimer")
    timer.ObserveField("fire", "onMinute")
    timer.control = "start"
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

sub onFocusedChild()
    if m.top.HasFocus() and m.chooser.visible then m.chooserList.SetFocus(true)
end sub

function halfHour(t as Integer) as Integer
    return t - (t mod m.STEP)
end function

' ---------------------------------------------------------------------------
' Inputs

sub onChannels()
    m.channels = m.top.channels
    if type(m.channels) <> "roArray" then m.channels = []
    ' MainScene sends the new rows' schedules again (from its cache or fetched).
    m.schedules = {}
    m.failed = {}
    m.row = 0
    m.topRow = 0
    m.windowMin = halfHour(nowSeconds())
    m.windowStart = m.windowMin
    m.focusTime = nowSeconds()
    if m.channels.Count() = 0 then m.top.status = "No channels to show here." else m.top.status = ""
    redraw()
    reportWanted()
end sub

sub onSchedule()
    s = m.top.schedule
    key = asString(s.streamId)
    if isTrue(s.failed) then m.failed[key] = true
    if type(s.listings) = "roArray" then m.schedules[key] = s.listings
    redraw()
end sub

sub onStatus()
    m.statusLabel.text = m.top.status
    m.statusLabel.visible = (m.top.status <> "")
    m.rowsGroup.visible = not m.statusLabel.visible
    m.timeHeader.visible = m.rowsGroup.visible
end sub

sub onCategories()
    m.categoryIds = []
    content = CreateObject("roSGNode", "ContentNode")
    for each c in m.top.categories
        if type(c) = "roAssociativeArray"
            m.categoryIds.Push(asString(c.id))
            item = content.CreateChild("ContentNode")
            item.title = asString(c.name)
        end if
    end for
    m.chooserList.content = content
end sub

' The rows on screen (and the next screenful), once scrolling pauses.
sub reportWanted()
    ids = []
    last = m.topRow + m.ROWS * 2 - 1
    if last > m.channels.Count() - 1 then last = m.channels.Count() - 1
    for i = m.topRow to last
        ids.Push(m.channels[i].streamId)
    end for
    m.top.wantSchedules = ids
end sub

sub onMinute()
    ' Keep "now" current; the window never starts before the current half hour.
    m.windowMin = halfHour(nowSeconds())
    if m.windowStart < m.windowMin then m.windowStart = m.windowMin
    if m.focusTime < nowSeconds() then m.focusTime = nowSeconds()
    redraw()
    ' Every 10 minutes, ask again for the rows on screen; MainScene fetches
    ' only schedules more than an hour old.
    m.minutes = m.minutes + 1
    if m.minutes mod 10 = 0 and m.channels.Count() > 0 then reportWanted()
end sub

' ---------------------------------------------------------------------------
' Drawing

sub redraw()
    drawTimeHeader()
    now = nowSeconds()
    windowEnd = m.windowStart + m.WINDOW
    if now >= m.windowStart and now < windowEnd
        m.nowLine.translation = [m.GRID_X + Int((now - m.windowStart) * m.PX), 368]
        shown = m.channels.Count() - m.topRow
        if shown > m.ROWS then shown = m.ROWS
        m.nowLine.height = shown * m.ROW_H + 4     ' down to the last row shown
        m.nowLine.visible = m.rowsGroup.visible
    else
        m.nowLine.visible = false
    end if
    for r = 0 to m.ROWS - 1
        drawRow(r)
    end for
    drawInfo()
end sub

sub drawTimeHeader()
    m.timeHeader.RemoveChildrenIndex(m.timeHeader.GetChildCount(), 0)
    t = m.windowStart
    while t < m.windowStart + m.WINDOW
        label = m.timeHeader.CreateChild("Label")
        label.translation = [m.GRID_X + Int((t - m.windowStart) * m.PX) + 8, 0]
        label.width = Int(m.STEP * m.PX) - 8
        label.font = "font:SmallestSystemFont"
        label.color = "0x8C96A0FF"
        label.text = formatClock(t)
        t = t + m.STEP
    end while
end sub

sub drawRow(r as Integer)
    node = m.rowNodes[r]
    idx = m.topRow + r
    node.programs.RemoveChildrenIndex(node.programs.GetChildCount(), 0)
    if idx >= m.channels.Count()
        node.group.visible = false
        return
    end if
    node.group.visible = true
    ch = m.channels[idx]
    node.name.text = localizeName(asString(ch.name))
    if node.logo.uri <> asString(ch.logo) then node.logo.uri = asString(ch.logo)
    focusedRow = (idx = m.row)
    if focusedRow then node.name.color = "0xFFFFFFFF" else node.name.color = "0xB8C1CAFF"

    key = toInt(ch.streamId).ToStr()
    listings = m.schedules[key]
    windowEnd = m.windowStart + m.WINDOW
    if type(listings) <> "roArray" or listings.Count() = 0
        text = "Loading ..."
        if m.failed.DoesExist(key) or type(listings) = "roArray" then text = "No guide information"
        drawCell(node.programs, m.windowStart, windowEnd, text, focusedRow, false)
        return
    end if
    now = nowSeconds()
    for each p in listings
        if p.ends > m.windowStart and p.start < windowEnd
            focused = focusedRow and p.start <= m.focusTime and p.ends > m.focusTime
            drawCell(node.programs, p.start, p.ends, p.title, focused, (p.start <= now and p.ends > now))
        end if
    end for
end sub

' One program block, clipped to the window.
sub drawCell(parent as Object, start as Integer, ends as Integer, title as String, focused as Boolean, onNow as Boolean)
    windowEnd = m.windowStart + m.WINDOW
    a = start
    if a < m.windowStart then a = m.windowStart
    b = ends
    if b > windowEnd then b = windowEnd
    x = m.GRID_X + Int((a - m.windowStart) * m.PX)
    w = Int((b - a) * m.PX) - 4
    if w < 4 then return
    cell = parent.CreateChild("Rectangle")
    cell.translation = [x, 4]
    cell.width = w
    cell.height = m.ROW_H - 8
    if focused
        cell.color = "0x2F6FB5FF"
    else if onNow
        cell.color = "0x2A3542FF"
    else
        cell.color = "0x1C242DFF"
    end if
    if w < 40 then return
    label = parent.CreateChild("Label")
    label.translation = [x + 14, 4]
    label.width = w - 24
    label.height = m.ROW_H - 8
    label.vertAlign = "center"
    label.maxLines = 1
    label.font = "font:SmallSystemFont"
    if focused then label.color = "0xFFFFFFFF" else label.color = "0xD0D6DCFF"
    label.text = title
end sub

' Above the grid: what's shown, then the focused program's title, time and
' description.
sub drawInfo()
    showing = asString(m.top.title)
    p = invalid
    if m.row < m.channels.Count()
        ch = m.channels[m.row]
        showing = showing + "   -   " + localizeName(asString(ch.name))
        p = focusedProgram()
    end if
    m.top.FindNode("showing").text = showing
    title = m.top.FindNode("progTitle")
    time = m.top.FindNode("progTime")
    desc = m.top.FindNode("progDesc")
    if p = invalid
        title.text = ""
        time.text = ""
        desc.text = ""
        return
    end if
    title.text = p.title
    minutes = Int((p.ends - p.start) / 60)
    when = formatDayTime(p.start) + " - " + formatClock(p.ends) + "     " + minutes.ToStr() + " min"
    now = nowSeconds()
    if p.start <= now and p.ends > now then when = "On now     " + when
    time.text = when
    desc.text = asString(p.desc)
end sub

' The focused channel's program at the focus time, or invalid.
function focusedProgram() as Dynamic
    if m.row >= m.channels.Count() then return invalid
    listings = m.schedules[toInt(m.channels[m.row].streamId).ToStr()]
    if type(listings) <> "roArray" then return invalid
    for each p in listings
        if p.start <= m.focusTime and p.ends > m.focusTime then return p
    end for
    return invalid
end function

' ---------------------------------------------------------------------------
' Moving

sub moveRow(delta as Integer)
    target = m.row + delta
    if target < 0 or target >= m.channels.Count() then return
    m.row = target
    if m.row < m.topRow then m.topRow = m.row
    if m.row >= m.topRow + m.ROWS then m.topRow = m.row - m.ROWS + 1
    redraw()
    m.wantDelay.control = "stop"
    m.wantDelay.control = "start"
end sub

' Right: the next program in this row (or half an hour on, without a guide);
' the window follows, up to a day ahead.
sub moveNext()
    p = focusedProgram()
    target = m.focusTime + m.STEP
    listings = rowListings()
    if listings <> invalid
        after = m.focusTime
        if p <> invalid then after = p.start
        target = -1
        for each q in listings
            if q.start > after
                target = q.start
                exit for
            end if
        end for
        if target < 0 then return       ' end of the schedule
    end if
    if target > nowSeconds() + 26 * 3600 then return
    m.focusTime = target
    while m.focusTime >= m.windowStart + m.WINDOW - m.STEP
        m.windowStart = m.windowStart + m.STEP
    end while
    redraw()
end sub

' Left: the previous program (not before now).
sub movePrevious()
    p = focusedProgram()
    target = m.focusTime - m.STEP
    listings = rowListings()
    if listings <> invalid
        before = m.focusTime
        if p <> invalid then before = p.start
        target = -1
        for each q in listings
            if q.start < before then target = q.start
        end for
        if target < 0 then return
    end if
    now = nowSeconds()
    if target < now
        if m.focusTime <= now then return
        target = now                    ' the program on now
    end if
    m.focusTime = target
    while m.focusTime < m.windowStart and m.windowStart > m.windowMin
        m.windowStart = m.windowStart - m.STEP
    end while
    redraw()
end sub

function rowListings() as Dynamic
    if m.row >= m.channels.Count() then return invalid
    listings = m.schedules[toInt(m.channels[m.row].streamId).ToStr()]
    if type(listings) <> "roArray" or listings.Count() = 0 then return invalid
    return listings
end function

' OK: watch a program that's on now (or the channel, without a guide); a
' later one says when it starts.
sub selectProgram()
    if m.row >= m.channels.Count() then return
    p = focusedProgram()
    now = nowSeconds()
    if p <> invalid and p.start > now
        m.top.FindNode("progTime").text = "Not on yet: starts " + formatDayTime(p.start) + ". Move left to what's on now."
        return
    end if
    m.top.play = m.channels[m.row]
end sub

' ---------------------------------------------------------------------------
' Channels chooser (*)

sub openChooser()
    if m.categoryIds.Count() = 0 then return
    m.chooser.visible = true
    m.chooserList.SetFocus(true)
end sub

sub closeChooser()
    m.chooser.visible = false
    ' Take focus off the list first: SetFocus on the screen alone can leave a
    ' focused child (the hidden list) holding it, swallowing Up/Down.
    m.chooserList.SetFocus(false)
    m.top.SetFocus(true)
end sub

' Closed a moment after the pick, not inside this handler: the list takes
' focus back when its own key handling finishes, and a hidden list holding
' focus would swallow Up/Down from then on (seen on the Roku).
sub onChooserSelected()
    i = m.chooserList.itemSelected
    m.pendingChoice = ""
    if i >= 0 and i < m.categoryIds.Count() then m.pendingChoice = m.categoryIds[i]
    m.chooserTimer.control = "start"
end sub

sub onChooserTimer()
    closeChooser()
    if m.pendingChoice <> "" then m.top.categoryChosen = m.pendingChoice
    m.pendingChoice = ""
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.chooser.visible
        if key = "back" or key = "options"
            closeChooser()
            return true
        end if
        return false
    end if
    if key = "up" and m.row > 0
        moveRow(-1)
        return true
    else if key = "down"
        moveRow(1)
        return true
    else if key = "right"
        moveNext()
        return true
    else if key = "left"
        movePrevious()
        return true
    else if key = "OK"
        selectProgram()
        return true
    else if key = "options"
        openChooser()
        return true
    end if
    return false
end function
