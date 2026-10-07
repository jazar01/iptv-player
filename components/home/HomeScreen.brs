sub init()
    m.ROW_LIMIT = 15
    m.list = m.top.FindNode("list")
    m.rowIds = []
    m.byStream = {}         ' streamId -> [HomeItem], for in-place guide updates
    m.lastVisibleKey = ""

    m.list.ObserveField("rowItemSelected", "onItemSelected")
    m.list.ObserveField("rowItemFocused", "onFocusMoved")
    m.visibleDelay = m.top.FindNode("visibleDelay")
    m.visibleDelay.ObserveField("fire", "updateVisible")
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

' Focus moves: report the cards on screen once it settles (EpgService).
sub onFocusMoved()
    m.visibleDelay.control = "stop"
    m.visibleDelay.control = "start"
end sub

sub onFocusedChild()
    if m.top.HasFocus() then m.list.SetFocus(true)
end sub

' Rebuild all rows, keeping focus on the same row and position (clamped).
sub onRows()
    focus = m.list.rowItemFocused
    root = CreateObject("roSGNode", "ContentNode")
    m.rowIds = []
    m.byStream = {}

    for each row in m.top.rows
        rowNode = root.CreateChild("ContentNode")
        rowNode.title = row.title
        m.rowIds.Push(row.id)
        items = row.items
        shown = items.Count()
        if shown > m.ROW_LIMIT then shown = m.ROW_LIMIT
        for i = 0 to shown - 1
            node = createHomeItem(rowNode, items[i])
            node.rowId = row.id
            if node.kind = "channel" then indexStream(node)
        end for
        if items.Count() > m.ROW_LIMIT
            createHomeItem(rowNode, { kind: "seeAll", rowId: row.id, message: items.Count().ToStr() + " in " + row.title })
        else if items.Count() = 0
            createHomeItem(rowNode, { kind: "empty", rowId: row.id, message: row.emptyText })
        end if
    end for

    m.list.content = root
    if type(focus) = "roArray" and focus.Count() = 2 and focus[0] >= 0 and root.GetChildCount() > 0
        r = clampIndex(focus[0], root.GetChildCount())
        c = clampIndex(focus[1], root.GetChild(r).GetChildCount())
        m.list.jumpToRowItem = [r, c]
    end if
    m.lastVisibleKey = ""
    updateVisible()
end sub

sub indexStream(node as Object)
    key = node.streamId.ToStr()
    if m.byStream[key] = invalid then m.byStream[key] = []
    m.byStream[key].Push(node)
end sub

sub onPrograms()
    entry = m.top.programs
    nodes = m.byStream[asString(entry.streamId)]
    if nodes = invalid then return
    for each node in nodes
        applyPrograms(node, entry)
    end for
end sub

function itemAt(position as Dynamic) as Dynamic
    content = m.list.content
    if content = invalid or type(position) <> "roArray" or position.Count() < 2 then return invalid
    if position[0] < 0 or position[0] >= content.GetChildCount() then return invalid
    row = content.GetChild(position[0])
    if position[1] < 0 or position[1] >= row.GetChildCount() then return invalid
    return row.GetChild(position[1])
end function

sub onItemSelected()
    node = itemAt(m.list.rowItemSelected)
    if node = invalid or node.kind = "empty" then return
    m.top.selected = itemSummary(node)
end sub

' Report the Favorites cards on screen (plus one either side) so EpgService
' fetches guide data for those only. Covers every row of channel cards
' (Favorites, Recently Viewed): the focused row from the focused card, the
' others from their start.
sub updateVisible()
    content = m.list.content
    if content = invalid then return
    focus = m.list.rowItemFocused

    ids = []
    key = ""
    for r = 0 to content.GetChildCount() - 1
        row = content.GetChild(r)
        start = 0
        if type(focus) = "roArray" and focus.Count() = 2 and focus[0] = r and focus[1] > 0 then start = focus[1] - 1
        for i = start to start + 6
            if i < row.GetChildCount()
                node = row.GetChild(i)
                if node.kind = "channel"
                    ids.Push(node.streamId)
                    key += node.streamId.ToStr() + ","
                end if
            end if
        end for
    end for
    if key <> m.lastVisibleKey
        m.lastVisibleKey = key
        m.top.visibleChannels = ids
    end if
end sub

function clampIndex(i as Integer, count as Integer) as Integer
    if i >= count then i = count - 1
    if i < 0 then i = 0
    return i
end function

function onKeyEvent(key as String, press as Boolean) as Boolean
    if press and key = "options"
        node = itemAt(m.list.rowItemFocused)
        if node <> invalid and (node.kind = "channel" or node.kind = "series") then m.top.options = itemSummary(node)
        if node <> invalid and node.kind = "resume" then m.top.removeContinue = itemSummary(node)
        return true
    end if
    return false
end function
