sub init()
    m.keyboard = m.top.FindNode("keyboard")
    m.resultList = m.top.FindNode("resultList")
    m.status = m.top.FindNode("status")
    m.delay = m.top.FindNode("typingDelay")
    m.favoriteIds = {}
    m.inResults = false

    m.keyboard.ObserveField("text", "onText")
    m.delay.ObserveField("fire", "sendQuery")
    m.resultList.ObserveField("itemSelected", "onItemSelected")
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

sub onFocusedChild()
    if not m.top.HasFocus() then return
    if m.inResults and resultCount() > 0
        m.resultList.SetFocus(true)
    else
        m.inResults = false
        m.keyboard.SetFocus(true)
    end if
end sub

sub onStatus()
    m.status.text = m.top.status
    m.status.visible = (m.top.status <> "")
end sub

sub onText()
    m.delay.control = "stop"
    m.delay.control = "start"
end sub

sub sendQuery()
    text = m.keyboard.text.Trim()
    if text = ""
        m.resultList.content = CreateObject("roSGNode", "ContentNode")
        m.top.status = "Type to search channels, movies and series."
        return
    end if
    m.top.query = text
end sub

sub onResults()
    r = m.top.results
    ' Ignore answers to text that has since changed.
    if asString(r.text) <> m.keyboard.text.Trim() then return

    content = CreateObject("roSGNode", "ContentNode")
    for each item in r.items
        node = content.CreateChild("CatalogNode")
        node.itemKind = item.kind
        node.itemId = item.itemId
        node.name = item.name
        node.num = item.num
        node.epgChannelId = item.epgChannelId
        node.ext = item.ext
        node.year = item.year
        node.archiveDays = item.archiveDays
        node.isLocal = isTrue(item.local)
        node.tag = resultTag(node)
    end for
    m.resultList.content = content
    if content.GetChildCount() = 0
        m.top.status = "Nothing matches """ + r.text + """."
        if m.inResults then focusKeyboard()
    else
        m.top.status = ""
    end if
end sub

function resultTag(node as Object) as String
    if node.itemKind = "channel"
        if m.favoriteIds.DoesExist(node.itemId.ToStr()) then return "FAVORITE"
        if node.isLocal then return "LOCAL"
        if node.archiveDays > 0 then return "REWIND"
        return "CHANNEL"
    end if
    if node.itemKind = "movie" then return "MOVIE"
    return "SERIES"
end function

sub onFavoriteIds()
    m.favoriteIds = m.top.favoriteIds
    content = m.resultList.content
    if content = invalid then return
    for i = 0 to content.GetChildCount() - 1
        node = content.GetChild(i)
        node.tag = resultTag(node)
    end for
end sub

function resultCount() as Integer
    content = m.resultList.content
    if content = invalid then return 0
    return content.GetChildCount()
end function

function resultSummary(node as Object) as Object
    return {
        kind: node.itemKind
        itemId: node.itemId
        streamId: node.itemId
        name: node.name
        epgChannelId: node.epgChannelId
        ext: node.ext
        year: node.year
        archiveDays: node.archiveDays
    }
end function

sub onItemSelected()
    i = m.resultList.itemSelected
    if i >= 0 and i < resultCount() then m.top.selected = resultSummary(m.resultList.content.GetChild(i))
end sub

sub focusKeyboard()
    m.inResults = false
    m.keyboard.SetFocus(true)
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "right" and m.keyboard.IsInFocusChain() and resultCount() > 0
        m.inResults = true
        m.resultList.SetFocus(true)
        return true
    else if key = "left" and m.resultList.HasFocus()
        focusKeyboard()
        return true
    else if key = "options" and m.resultList.HasFocus()
        i = m.resultList.itemFocused
        if i >= 0 and i < resultCount()
            node = m.resultList.content.GetChild(i)
            if node.itemKind = "channel" then m.top.options = resultSummary(node)
        end if
        return true
    end if
    return false
end function
