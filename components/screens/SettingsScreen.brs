sub init()
    m.menu = m.top.FindNode("menu")
    m.details = m.top.FindNode("details")
    m.actions = ["teams", "account"]
    titles = ["My Teams", "Account and device name"]

    content = CreateObject("roSGNode", "ContentNode")
    for each title in titles
        item = content.CreateChild("ContentNode")
        item.title = title
    end for
    m.menu.content = content

    m.menu.ObserveField("itemSelected", "onSelected")
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

sub onFocusedChild()
    if m.top.HasFocus() then m.menu.SetFocus(true)
end sub

sub onSelected()
    m.top.chosen = m.actions[m.menu.itemSelected]
end sub

sub onInfo()
    info = m.top.info
    nl = Chr(10)
    m.details.text = "Device name:  " + asString(info.deviceName) + nl + "Server:  " + asString(info.server) + nl + "Device ID:  " + asString(info.deviceId) + nl + "App version:  " + asString(info.version)
end sub
