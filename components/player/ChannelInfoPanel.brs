sub init()
    m.logo = m.top.FindNode("logo")
    m.name = m.top.FindNode("name")
    m.copies = m.top.FindNode("copies")
    m.copyList = []
    m.copiesKey = ""
    ' Top to bottom, in this order, below the logo and name.
    m.stack = []
    for each id in ["facts", "playbackHead", "playbackLines", "programsHead", "programs", "nowDesc", "copiesHead", "copies"]
        m.stack.Push(m.top.FindNode(id))
    end for
    m.logo.ObserveField("loadStatus", "onLogoStatus")
    m.copies.ObserveField("itemSelected", "onCopySelected")
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

sub onDim()
    m.top.FindNode("shade").visible = m.top.dim
end sub

' The copies list takes focus when there is one; otherwise the panel keeps it
' (Back closes it either way).
sub onFocusedChild()
    if m.top.HasFocus() and m.copyList.Count() > 0 then m.copies.SetFocus(true)
end sub

sub onLogoStatus()
    m.logo.visible = (m.logo.loadStatus = "ready")
end sub

sub draw()
    info = m.top.info
    if type(info) <> "roAssociativeArray" then info = {}
    m.name.text = localizeName(asString(info.name))
    if m.logo.uri <> asString(info.logo) then m.logo.uri = asString(info.logo)
    onLogoStatus()

    setLines("facts", info.facts)
    playback = m.top.playback
    lines = invalid
    if type(playback) = "roAssociativeArray" then lines = playback.lines
    setLines("playbackLines", lines)
    m.top.FindNode("playbackHead").visible = m.top.FindNode("playbackLines").visible

    programs = m.top.FindNode("programs")
    if type(info.programs) = "roArray" and info.programs.Count() > 0
        setLines("programs", info.programs)
    else
        programs.text = asString(info.programsNote)
        programs.visible = (programs.text <> "")
    end if
    m.top.FindNode("programsHead").visible = programs.visible
    ' What's on now, described (when the guide has a description).
    nowDesc = m.top.FindNode("nowDesc")
    nowDesc.text = asString(info.nowDescription)
    nowDesc.visible = (nowDesc.text <> "")

    drawCopies(info.copies)
    layout()
end sub

sub setLines(id as String, lines as Dynamic)
    label = m.top.FindNode(id)
    text = ""
    if type(lines) = "roArray"
        for each line in lines
            if text <> "" then text += Chr(10)
            text += asString(line)
        end for
    end if
    label.text = text
    label.visible = (text <> "")
end sub

' Rebuilt only when the copies change, so focus stays put on redraws.
sub drawCopies(copies as Dynamic)
    list = []
    if type(copies) = "roArray" then list = copies
    key = ""
    for each c in list
        key += asString(c.streamId) + ","
    end for
    if key = m.copiesKey then return
    m.copiesKey = key
    m.copyList = list
    content = CreateObject("roSGNode", "ContentNode")
    for each c in list
        item = content.CreateChild("ContentNode")
        title = localizeName(asString(c.name))
        if toInt(c.archiveDays) > 0 then title = title + "   (rewind)"
        item.title = title
    end for
    m.copies.content = content
    m.copies.visible = (list.Count() > 0)
    m.top.FindNode("copiesHead").visible = m.copies.visible
    if m.top.IsInFocusChain() and list.Count() > 0 then m.copies.SetFocus(true)
end sub

' Stack the visible sections below the header; the copies list gets what
' room is left (2 to 4 rows).
sub layout()
    y = 200
    for each node in m.stack
        if node.visible
            if node.id = "copies"
                rows = Int((1030 - y) / 44)
                if rows > 4 then rows = 4
                if rows < 2 then rows = 2
                node.numRows = rows
            end if
            if node.id = "playbackHead" or node.id = "programsHead" or node.id = "copiesHead" then y = y + 14
            node.translation = [1160, y]
            y = y + node.boundingRect().height + 10
        end if
    end for
end sub

sub onCopySelected()
    i = m.copies.itemSelected
    if i >= 0 and i < m.copyList.Count() then m.top.chosen = m.copyList[i]
end sub
