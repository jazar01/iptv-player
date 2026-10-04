sub init()
    m.PAGE = 100
    m.categoryList = m.top.FindNode("categoryList")
    m.channelList = m.top.FindNode("channelList")
    m.status = m.top.FindNode("status")
    m.delay = m.top.FindNode("categoryDelay")

    m.categoryIds = []
    m.currentCategory = ""      ' requested
    m.shownCategory = ""        ' on screen
    m.allChannels = []
    m.loaded = 0
    m.favoriteIds = {}
    m.inChannels = false
    m.focusChannelsWhenLoaded = false

    m.categoryList.ObserveField("itemFocused", "onCategoryFocused")
    m.categoryList.ObserveField("itemSelected", "onCategorySelected")
    m.channelList.ObserveField("itemFocused", "onChannelFocused")
    m.channelList.ObserveField("itemSelected", "onChannelSelected")
    m.delay.ObserveField("fire", "loadFocusedCategory")
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

sub onFocusedChild()
    if not m.top.HasFocus() then return
    if m.inChannels and channelCount() > 0
        m.channelList.SetFocus(true)
    else
        m.inChannels = false
        m.categoryList.SetFocus(true)
    end if
end sub

sub onStatus()
    m.status.text = m.top.status
    m.status.visible = (m.top.status <> "")
end sub

' ---------------------------------------------------------------------------
' Categories

sub onCategories()
    content = CreateObject("roSGNode", "ContentNode")
    m.categoryIds = []
    focus = 0
    for each c in m.top.categories
        id = asString(c.category_id)
        if id = m.currentCategory then focus = m.categoryIds.Count()
        m.categoryIds.Push(id)
        item = content.CreateChild("ContentNode")
        item.title = asString(c.category_name)
    end for
    m.categoryList.content = content
    if m.categoryIds.Count() = 0
        m.top.status = "This account has no live TV categories."
        return
    end if
    m.categoryList.jumpToItem = focus
    if m.currentCategory = "" then requestCategory(m.categoryIds[focus])
end sub

sub onCategoryFocused()
    m.delay.control = "stop"
    m.delay.control = "start"
end sub

sub loadFocusedCategory()
    i = m.categoryList.itemFocused
    if i >= 0 and i < m.categoryIds.Count() then requestCategory(m.categoryIds[i])
end sub

sub onCategorySelected()
    i = m.categoryList.itemSelected
    if i < 0 or i >= m.categoryIds.Count() then return
    requestCategory(m.categoryIds[i])
    if m.shownCategory = m.currentCategory and channelCount() > 0
        focusChannels()
    else
        m.focusChannelsWhenLoaded = true
    end if
end sub

sub requestCategory(id as String)
    if id = m.currentCategory then return
    m.currentCategory = id
    m.focusChannelsWhenLoaded = false
    m.top.status = "Loading channels ..."
    m.channelList.content = CreateObject("roSGNode", "ContentNode")
    m.shownCategory = ""
    m.top.wantCategory = id
end sub

' ---------------------------------------------------------------------------
' Channels

sub onChannels()
    d = m.top.channels
    id = asString(d.categoryId)
    if id <> m.currentCategory then return

    ' A refresh of the list already on screen keeps the focused position.
    keep = 0
    if id = m.shownCategory and m.channelList.itemFocused > 0 then keep = m.channelList.itemFocused

    m.allChannels = []
    if type(d.items) = "roArray" then m.allChannels = d.items
    m.loaded = 0
    m.channelList.content = CreateObject("roSGNode", "ContentNode")
    while m.loaded < m.allChannels.Count() and m.loaded <= keep
        appendPage()
    end while
    if keep > 0 and keep < m.loaded then m.channelList.jumpToItem = keep
    m.shownCategory = id

    if m.allChannels.Count() = 0
        m.top.status = "No channels in this category."
        if m.inChannels then focusCategories()
    else
        m.top.status = ""
        if m.focusChannelsWhenLoaded then focusChannels()
    end if
    m.focusChannelsWhenLoaded = false
end sub

sub appendPage()
    content = m.channelList.content
    last = m.loaded + m.PAGE - 1
    if last >= m.allChannels.Count() then last = m.allChannels.Count() - 1
    for i = m.loaded to last
        raw = m.allChannels[i]
        node = content.CreateChild("ChannelNode")
        node.streamId = toInt(raw.stream_id)
        node.num = asString(raw.num)
        node.name = asString(raw.name)
        node.epgChannelId = asString(raw.epg_channel_id)
        node.isFavorite = m.favoriteIds.DoesExist(node.streamId.ToStr())
    end for
    m.loaded = last + 1
end sub

sub onChannelFocused()
    if m.loaded < m.allChannels.Count() and m.channelList.itemFocused >= m.loaded - 20 then appendPage()
end sub

sub onFavoriteIds()
    m.favoriteIds = m.top.favoriteIds
    content = m.channelList.content
    if content = invalid then return
    for i = 0 to content.GetChildCount() - 1
        node = content.GetChild(i)
        node.isFavorite = m.favoriteIds.DoesExist(node.streamId.ToStr())
    end for
end sub

function channelCount() as Integer
    content = m.channelList.content
    if content = invalid then return 0
    return content.GetChildCount()
end function

function focusedChannel() as Dynamic
    i = m.channelList.itemFocused
    if i < 0 or i >= channelCount() then return invalid
    return m.channelList.content.GetChild(i)
end function

function channelSummary(node as Object) as Object
    return { kind: "channel", streamId: node.streamId, name: node.name, epgChannelId: node.epgChannelId }
end function

sub onChannelSelected()
    i = m.channelList.itemSelected
    if i < 0 or i >= channelCount() then return
    m.top.selected = channelSummary(m.channelList.content.GetChild(i))
end sub

sub focusChannels()
    m.inChannels = true
    m.channelList.SetFocus(true)
end sub

sub focusCategories()
    m.inChannels = false
    m.categoryList.SetFocus(true)
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "right" and m.categoryList.HasFocus() and channelCount() > 0
        focusChannels()
        return true
    else if key = "left" and m.channelList.HasFocus()
        focusCategories()
        return true
    else if key = "options" and m.channelList.HasFocus()
        node = focusedChannel()
        if node <> invalid then m.top.options = channelSummary(node)
        return true
    end if
    return false
end function
