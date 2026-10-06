sub init()
    m.menu = m.top.FindNode("menu")
    m.details = m.top.FindNode("details")
    m.actions = ["teams", "teamsRow", "noGameTeams", "market", "recentFavorites", "account"]
    buildMenu({})

    m.menu.ObserveField("itemSelected", "onSelected")
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

' info: as the `info` field (missing values show as their defaults).
sub buildMenu(info as Object)
    marketLabel = asString(info.market)
    if marketLabel = "" then marketLabel = "not set"
    showMyTeams = (info.showMyTeams = invalid or isTrue(info.showMyTeams))
    showNoGameTeams = (info.showNoGameTeams = invalid or isTrue(info.showNoGameTeams))
    titles = [
        "My Teams"
        "Show My Teams on Home:   " + onOff(showMyTeams)
        "Show teams with no game:   " + onOff(showNoGameTeams)
        "Local stations:   " + marketLabel
        "Favorites in Recently Viewed:   " + onOff(isTrue(info.showFavoritesInRecent))
        "Account and device name"
    ]
    focus = m.menu.itemFocused
    content = CreateObject("roSGNode", "ContentNode")
    for each title in titles
        item = content.CreateChild("ContentNode")
        item.title = title
    end for
    m.menu.content = content
    if focus > 0 then m.menu.jumpToItem = focus
end sub

function onOff(value as Boolean) as String
    if value then return "On"
    return "Off"
end function

sub onFocusedChild()
    if m.top.HasFocus() then m.menu.SetFocus(true)
end sub

sub onSelected()
    m.top.chosen = m.actions[m.menu.itemSelected]
end sub

sub onInfo()
    info = m.top.info
    buildMenu(info)
    nl = Chr(10)
    connections = asString(info.connections)
    if connections = "" then connections = "checking ..."
    m.details.text = "Device name:  " + asString(info.deviceName) + nl + "Server:  " + asString(info.server) + nl + "Connections:  " + connections + "  (all devices on this account)" + nl + "Device ID:  " + asString(info.deviceId) + nl + "App version:  " + asString(info.version)
end sub
