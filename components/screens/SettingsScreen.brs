sub init()
    m.menu = m.top.FindNode("menu")
    m.details = m.top.FindNode("details")
    m.actions = ["teams", "teamsRow", "teamsPosition", "noGameTeams", "scores", "market", "recentFavorites", "converter", "account"]
    m.backupPanel = m.top.FindNode("backupPanel")
    m.top.FindNode("backupText").text = backupExplanation()
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
    converterLabel = "Off"
    if Left(asString(info.converter), 3) <> "off" and asString(info.converter) <> "" then converterLabel = asString(info.converter).Split(" ")[0].Replace(":8790", "")
    teamsPosition = "After Favorites"
    if isTrue(info.myTeamsFirst) then teamsPosition = "First"
    titles = [
        "My Teams"
        "Show My Teams on Home:   " + onOff(showMyTeams)
        "My Teams on Home:   " + teamsPosition
        "Show teams with no game:   " + onOff(showNoGameTeams)
        "Live scores on My Teams:   " + onOff(info.showScores = invalid or isTrue(info.showScores))
        "Local stations:   " + marketLabel
        "Favorites in Recently Viewed:   " + onOff(isTrue(info.showFavoritesInRecent))
        "Dolby converter:   " + converterLabel
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
    ' While the backup panel is open the screen itself holds focus.
    if m.top.HasFocus() and not m.backupPanel.visible then m.menu.SetFocus(true)
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
    expires = asString(info.expires)
    if expires = "" then expires = "no end date"
    m.details.text = "Device name:  " + asString(info.deviceName) + nl + "Server:  " + asString(info.server) + nl + "Account expires:  " + expires + nl + "Connections:  " + connections + "  (all devices on this account)" + nl + "Audio:  " + asString(info.audio) + nl + "Dolby converter:  " + asString(info.converter) + nl + "Device ID:  " + asString(info.deviceId) + nl + "App version:  " + asString(info.version)
end sub

' ---------------------------------------------------------------------------
' Backup panel: * opens it (it isn't in the menu, so it's not stumbled on);
' Play/Pause sends "backup", Back closes it. While it's open the screen keeps
' focus and takes every key, so Back doesn't leave Settings.

function backupExplanation() as String
    nl = Chr(10)
    text = "Saves this TV's setup to the computer you install the app from: the account, device name, favorites, My Teams, favorite series, watch progress and settings." + nl + nl
    text = text + "1.  On the computer, run  scripts\backup-roku.ps1 -Roku <this TV's name>.  It waits for this TV." + nl
    text = text + "2.  Press Play/Pause here. The computer saves the backup in its backups folder." + nl + nl
    text = text + "If this TV ever loses its saved data (a reinstall, or an update that failed to install), the next install from that computer brings it back automatically. A backup is a snapshot: changes made later aren't in it until you back up again." + nl + nl
    text = text + "The backup includes the account password. It goes only to the computer that's listening on your home network."
    return text
end function

sub showBackupPanel()
    m.backupPanel.visible = true
    m.top.SetFocus(true)
end sub

sub hideBackupPanel()
    m.backupPanel.visible = false
    m.menu.SetFocus(true)
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.backupPanel.visible
        if key = "play"
            hideBackupPanel()
            m.top.chosen = "backup"
        else if key = "back"
            hideBackupPanel()
        end if
        return true
    end if
    if key = "options"
        showBackupPanel()
        return true
    end if
    return false
end function
