sub init()
    m.grid = m.top.FindNode("grid")
    m.empty = m.top.FindNode("empty")
    m.byStream = {}
    m.lastVisibleKey = ""

    m.grid.ObserveField("itemSelected", "onItemSelected")
    m.grid.ObserveField("itemFocused", "updateVisible")
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

sub onFocusedChild()
    if m.top.HasFocus() then m.grid.SetFocus(true)
end sub

' What * does in each row's grid (rows not listed: nothing).
function rowHint(rowId as String) as String
    if rowId = "favorites" then return "Press * to pin or remove a favorite."
    if rowId = "recent" then return "Press * to add a channel to Favorites."
    if rowId = "continue" then return "Press * to remove an item from Continue Watching."
    if rowId = "favseries" then return "Press * to remove a series from Favorite Series."
    return ""
end function

sub onRow()
    row = m.top.row
    rowId = asString(row.id)
    m.top.FindNode("title").text = asString(row.title)
    m.top.FindNode("hint").text = rowHint(rowId)
    m.empty.text = asString(row.emptyText)

    focus = m.grid.itemFocused
    root = CreateObject("roSGNode", "ContentNode")
    m.byStream = {}
    items = row.items
    if type(items) <> "roArray" then items = []
    for each item in items
        node = createHomeItem(root, item)
        node.rowId = rowId
        if node.kind = "channel"
            key = node.streamId.ToStr()
            if m.byStream[key] = invalid then m.byStream[key] = []
            m.byStream[key].Push(node)
        end if
    end for

    m.grid.content = root
    count = root.GetChildCount()
    m.empty.visible = (count = 0)
    if count > 0 and focus > 0
        if focus >= count then focus = count - 1
        m.grid.jumpToItem = focus
    end if
    m.lastVisibleKey = ""
    updateVisible()
end sub

sub onPrograms()
    entry = m.top.programs
    nodes = m.byStream[asString(entry.streamId)]
    if nodes = invalid then return
    for each node in nodes
        applyPrograms(node, entry)
    end for
end sub

function focusedNode() as Dynamic
    content = m.grid.content
    i = m.grid.itemFocused
    if content = invalid or i < 0 or i >= content.GetChildCount() then return invalid
    return content.GetChild(i)
end function

sub onItemSelected()
    content = m.grid.content
    i = m.grid.itemSelected
    if content = invalid or i < 0 or i >= content.GetChildCount() then return
    m.top.selected = itemSummary(content.GetChild(i))
end sub

' One row above the focus through three below.
sub updateVisible()
    content = m.grid.content
    if content = invalid then return
    focus = m.grid.itemFocused
    if focus < 0 then focus = 0
    start = Int(focus / 4) * 4 - 4
    if start < 0 then start = 0

    ids = []
    key = ""
    for i = start to start + 19
        if i < content.GetChildCount()
            node = content.GetChild(i)
            if node.kind = "channel"
                ids.Push(node.streamId)
                key += node.streamId.ToStr() + ","
            end if
        end if
    end for
    if key <> m.lastVisibleKey
        m.lastVisibleKey = key
        m.top.visibleChannels = ids
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if press and key = "options"
        node = focusedNode()
        if node <> invalid and (node.kind = "channel" or node.kind = "resume" or node.kind = "series") then m.top.options = itemSummary(node)
        return true
    end if
    return false
end function
