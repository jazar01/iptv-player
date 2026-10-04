sub init()
    m.PAGE = 100
    m.categoryList = m.top.FindNode("categoryList")
    m.itemList = m.top.FindNode("itemList")
    m.status = m.top.FindNode("status")
    m.delay = m.top.FindNode("categoryDelay")

    m.categoryIds = []
    m.currentCategory = ""      ' requested
    m.shownCategory = ""        ' on screen
    m.allItems = []
    m.loaded = 0
    m.tags = {}
    m.inItems = false
    m.focusItemsWhenLoaded = false

    m.categoryList.ObserveField("itemFocused", "onCategoryFocused")
    m.categoryList.ObserveField("itemSelected", "onCategorySelected")
    m.itemList.ObserveField("itemFocused", "onItemFocused")
    m.itemList.ObserveField("itemSelected", "onItemSelected")
    m.delay.ObserveField("fire", "loadFocusedCategory")
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

sub onFocusedChild()
    if not m.top.HasFocus() then return
    if m.inItems and itemCount() > 0
        m.itemList.SetFocus(true)
    else
        m.inItems = false
        m.categoryList.SetFocus(true)
    end if
end sub

sub onStatus()
    m.status.text = m.top.status
    m.status.visible = (m.top.status <> "")
end sub

function kindNoun() as String
    if m.top.kind = "movie" then return "movie"
    if m.top.kind = "series" then return "series"
    return "live TV"
end function

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
        m.top.status = "This account has no " + kindNoun() + " categories."
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
    if m.shownCategory = m.currentCategory and itemCount() > 0
        focusItems()
    else
        m.focusItemsWhenLoaded = true
    end if
end sub

sub requestCategory(id as String)
    if id = m.currentCategory then return
    m.currentCategory = id
    m.focusItemsWhenLoaded = false
    m.top.status = "Loading ..."
    m.itemList.content = CreateObject("roSGNode", "ContentNode")
    m.shownCategory = ""
    m.top.wantCategory = id
end sub

' ---------------------------------------------------------------------------
' Items

sub onItems()
    d = m.top.items
    id = asString(d.categoryId)
    if id <> m.currentCategory then return

    ' A refresh of the list already on screen keeps the focused position.
    keep = 0
    if id = m.shownCategory and m.itemList.itemFocused > 0 then keep = m.itemList.itemFocused

    m.allItems = []
    if type(d.items) = "roArray" then m.allItems = d.items
    m.loaded = 0
    m.itemList.content = CreateObject("roSGNode", "ContentNode")
    while m.loaded < m.allItems.Count() and m.loaded <= keep
        appendPage()
    end while
    if keep > 0 and keep < m.loaded then m.itemList.jumpToItem = keep
    m.shownCategory = id

    if m.allItems.Count() = 0
        m.top.status = "Nothing in this category."
        if m.inItems then focusCategories()
    else
        m.top.status = ""
        if m.focusItemsWhenLoaded then focusItems()
    end if
    m.focusItemsWhenLoaded = false
end sub

sub appendPage()
    content = m.itemList.content
    last = m.loaded + m.PAGE - 1
    if last >= m.allItems.Count() then last = m.allItems.Count() - 1
    for i = m.loaded to last
        node = content.CreateChild("CatalogNode")
        fillNode(node, m.allItems[i])
    end for
    m.loaded = last + 1
end sub

' Raw Xtream item -> CatalogNode, by catalog kind.
sub fillNode(node as Object, raw as Object)
    kind = m.top.kind
    node.name = asString(raw.name)
    if kind = "series"
        node.itemId = toInt(raw.series_id)
    else
        node.itemId = toInt(raw.stream_id)
    end if

    if kind = "live"
        node.num = asString(raw.num)
        node.epgChannelId = asString(raw.epg_channel_id)
    else
        node.ext = asString(raw.container_extension)
        node.year = itemYear(raw)
        if node.year > 0 then node.num = node.year.ToStr()
    end if
    node.tag = asString(m.tags[node.itemId.ToStr()])
end sub

' Xtream puts the year in different fields depending on panel and kind.
function itemYear(raw as Object) as Integer
    for each field in ["year", "releaseDate", "release_date", "releasedate"]
        y = Val(Left(asString(raw[field]), 4), 10)
        if y > 1900 and y < 2200 then return y
    end for
    return 0
end function

sub onItemFocused()
    if m.loaded < m.allItems.Count() and m.itemList.itemFocused >= m.loaded - 20 then appendPage()
end sub

sub onTags()
    m.tags = m.top.tags
    content = m.itemList.content
    if content = invalid then return
    for i = 0 to content.GetChildCount() - 1
        node = content.GetChild(i)
        node.tag = asString(m.tags[node.itemId.ToStr()])
    end for
end sub

function itemCount() as Integer
    content = m.itemList.content
    if content = invalid then return 0
    return content.GetChildCount()
end function

function focusedItem() as Dynamic
    i = m.itemList.itemFocused
    if i < 0 or i >= itemCount() then return invalid
    return m.itemList.content.GetChild(i)
end function

function itemSummary(node as Object) as Object
    kind = m.top.kind
    if kind = "live" then kind = "channel"
    return {
        kind: kind
        itemId: node.itemId
        streamId: node.itemId
        name: node.name
        epgChannelId: node.epgChannelId
        ext: node.ext
        year: node.year
    }
end function

sub onItemSelected()
    i = m.itemList.itemSelected
    if i < 0 or i >= itemCount() then return
    m.top.selected = itemSummary(m.itemList.content.GetChild(i))
end sub

sub focusItems()
    m.inItems = true
    m.itemList.SetFocus(true)
end sub

sub focusCategories()
    m.inItems = false
    m.categoryList.SetFocus(true)
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "right" and m.categoryList.HasFocus() and itemCount() > 0
        focusItems()
        return true
    else if key = "left" and m.itemList.HasFocus()
        focusCategories()
        return true
    else if key = "options" and m.itemList.HasFocus()
        node = focusedItem()
        if node <> invalid and m.top.kind = "live" then m.top.options = itemSummary(node)
        return true
    end if
    return false
end function
