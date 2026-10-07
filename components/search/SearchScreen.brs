sub init()
    m.keyboard = m.top.FindNode("keyboard")
    ' Hold the remote's voice button and say "british bake off": whole words.
    setKeyboardVoice(m.keyboard, "generic")
    m.resultList = m.top.FindNode("resultList")
    m.status = m.top.FindNode("status")
    m.recentHead = m.top.FindNode("recentHead")
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
    if m.keyboard.text.Trim() <> "" then m.recentHead.visible = false
    m.delay.control = "stop"
    m.delay.control = "start"
end sub

sub sendQuery()
    text = m.keyboard.text.Trim()
    if text = ""
        showRecentSearches()
        return
    end if
    m.top.query = text
end sub

sub onResults()
    r = m.top.results
    ' Ignore answers to text that has since changed.
    if asString(r.text) <> m.keyboard.text.Trim() then return
    m.recentHead.visible = false

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
        node.showLogo = (item.kind = "channel")
        node.logo = asString(item.icon)
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
    if node.itemKind = "movie" and m.favoriteIds.DoesExist("m" + node.itemId.ToStr()) then return "LIST"
    if node.itemKind = "movie" then return "MOVIE"
    if m.favoriteIds.DoesExist("s" + node.itemId.ToStr()) then return "FAVORITE"
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
        poster: node.logo
    }
end function

sub onItemSelected()
    i = m.resultList.itemSelected
    if i < 0 or i >= resultCount() then return
    node = m.resultList.content.GetChild(i)
    if node.itemKind = "recent"
        runRecentSearch(node.name)
        return
    end if
    m.top.searchUsed = m.keyboard.text.Trim()
    m.top.selected = resultSummary(node)
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
            if node.itemKind = "recent" then m.top.removeRecent = node.name
            if node.itemKind = "channel" or node.itemKind = "series" or node.itemKind = "movie" then m.top.options = resultSummary(node)
        end if
        return true
    end if
    return false
end function

' ---------------------------------------------------------------------------
' Recent searches: listed (tagged RECENT) while the box is empty. OK runs
' one again; * forgets it.

sub onRecentSearches()
    if m.keyboard.text.Trim() = "" then showRecentSearches()
end sub

sub showRecentSearches()
    content = CreateObject("roSGNode", "ContentNode")
    recent = m.top.recentSearches
    if type(recent) = "roArray"
        for each q in recent
            node = content.CreateChild("CatalogNode")
            node.itemKind = "recent"
            node.name = asString(q)
            node.tag = "RECENT"
        end for
    end if
    m.resultList.content = content
    if content.GetChildCount() > 0
        m.top.status = ""
        m.recentHead.visible = true
    else
        m.recentHead.visible = false
        m.top.status = "Type to search channels, movies and series."
        if m.inResults then focusKeyboard()
    end if
end sub

sub runRecentSearch(text as String)
    m.delay.control = "stop"
    m.keyboard.text = text
    m.delay.control = "stop"    ' the text change restarted it; search now instead
    m.top.query = text
end sub

' Opened from the top bar: start with an empty box and the recent searches
' (the last search is the first of them). Coming back from a result keeps
' the results instead.
sub onReset()
    m.delay.control = "stop"
    m.keyboard.text = ""
    m.delay.control = "stop"
    m.inResults = false
    showRecentSearches()
end sub
