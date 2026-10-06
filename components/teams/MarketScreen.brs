sub init()
    m.list = m.top.FindNode("list")
    m.status = m.top.FindNode("status")
    m.markets = []
    m.list.ObserveField("itemSelected", "onSelected")
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

sub onFocusedChild()
    if m.top.HasFocus() then m.list.SetFocus(true)
end sub

' First item is "None"; the current market is focused.
sub onMarkets()
    m.markets = m.top.markets
    content = CreateObject("roSGNode", "ContentNode")
    item = content.CreateChild("ContentNode")
    item.title = "None (national channels only)"
    focus = 0
    for i = 0 to m.markets.Count() - 1
        mk = m.markets[i]
        item = content.CreateChild("ContentNode")
        item.title = mk.label + "   -   " + mk.stations
        if mk.key = m.top.current then focus = i + 1
    end for
    m.list.content = content
    m.list.jumpToItem = focus
    m.status.visible = (m.markets.Count() = 0)
    ' Usually the channel list is still loading; this fills in by itself.
    m.status.text = "No markets yet. The channel list may still be loading; they'll appear here when it's ready."
end sub

sub onSelected()
    i = m.list.itemSelected
    if i = 0
        m.top.chosen = { key: "", label: "" }
    else if i - 1 < m.markets.Count()
        mk = m.markets[i - 1]
        m.top.chosen = { key: mk.key, label: mk.label }
    end if
end sub
