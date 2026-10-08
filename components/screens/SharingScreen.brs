sub init()
    m.list = m.top.FindNode("list")
    m.kinds = ["favorites", "teams", "series", "progress", "account"]
    m.labels = {
        favorites: "Favorites (live channels)"
        teams: "My Teams"
        series: "Favorite Series and Watch List"
        progress: "Watch progress (where you stopped, watched episodes)"
        account: "Account changes from the admin page (server, password)"
    }
    m.list.ObserveField("itemSelected", "onSelected")
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

sub onFocusedChild()
    if m.top.HasFocus() then m.list.SetFocus(true)
end sub

' Redrawn in place, so focus stays on the row just toggled.
sub draw()
    share = m.top.share
    if type(share) <> "roAssociativeArray" then share = {}
    focus = m.list.itemFocused
    content = CreateObject("roSGNode", "ContentNode")
    for each kind in m.kinds
        item = content.CreateChild("ContentNode")
        state = "Off"
        if share[kind] = invalid or isTrue(share[kind]) then state = "On"
        item.title = m.labels[kind] + ":   " + state
    end for
    m.list.content = content
    if focus > 0 then m.list.jumpToItem = focus
end sub

sub onStatus()
    m.top.FindNode("status").text = m.top.status
end sub

sub onSelected()
    i = m.list.itemSelected
    if i >= 0 and i < m.kinds.Count() then m.top.toggled = m.kinds[i]
end sub
