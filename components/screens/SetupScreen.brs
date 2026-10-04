sub init()
    m.fields = ["server", "username", "password", "deviceName"]
    m.labels = { server: "Server URL", username: "Username", password: "Password", deviceName: "Device name" }
    m.hints = {
        server: "For example http://example.com:8080"
        username: ""
        password: ""
        deviceName: "A name for this Roku, such as Living room"
    }
    m.values = { server: "", username: "", password: "", deviceName: "" }

    m.menu = m.top.FindNode("menu")
    m.statusLabel = m.top.FindNode("status")
    m.menu.ObserveField("itemSelected", "onItemSelected")
    m.top.ObserveField("focusedChild", "onFocusedChild")
    refreshMenu()
end sub

sub onFocusedChild()
    if m.top.HasFocus() then m.menu.SetFocus(true)
end sub

sub onValues()
    v = m.top.values
    for each f in m.fields
        if v[f] <> invalid then m.values[f] = asString(v[f])
    end for
    refreshMenu()
end sub

sub onStatus()
    m.statusLabel.text = m.top.status
end sub

sub refreshMenu()
    content = CreateObject("roSGNode", "ContentNode")
    for each f in m.fields
        shown = m.values[f]
        if f = "password" and shown <> "" then shown = String(shown.Len(), "*")
        if shown = "" then shown = "(not set)"
        item = content.CreateChild("ContentNode")
        item.title = m.labels[f] + ":   " + shown
    end for
    item = content.CreateChild("ContentNode")
    item.title = "Connect"

    focused = m.menu.itemFocused
    m.menu.content = content
    if focused > 0 then m.menu.jumpToItem = focused
end sub

sub onItemSelected()
    index = m.menu.itemSelected
    if index < m.fields.Count()
        openKeyboard(m.fields[index])
    else
        submit()
    end if
end sub

sub openKeyboard(field as String)
    dlg = CreateObject("roSGNode", "StandardKeyboardDialog")
    dlg.title = m.labels[field]
    if m.hints[field] <> "" then dlg.message = [m.hints[field]]
    dlg.text = m.values[field]
    dlg.buttons = ["OK", "Cancel"]
    if field = "password"
        dlg.keyboardDomain = "password"
        editBox = dlg.textEditBox
        if editBox <> invalid then editBox.secureMode = true
    end if
    dlg.ObserveField("buttonSelected", "onKeyboardButton")
    dlg.ObserveField("wasClosed", "onKeyboardClosed")

    m.editing = field
    m.dialog = dlg
    m.top.GetScene().dialog = dlg
end sub

sub onKeyboardButton()
    if m.dialog.buttonSelected = 0
        m.values[m.editing] = m.dialog.text.Trim()
        if m.editing = "server" then m.values.server = normalizeServer(m.values.server)
        refreshMenu()
    end if
    m.dialog.close = true
end sub

sub onKeyboardClosed()
    m.dialog = invalid
    m.menu.SetFocus(true)
end sub

sub submit()
    if m.top.busy then return
    for each f in m.fields
        if m.values[f] = ""
            m.top.status = m.labels[f] + " is required."
            return
        end if
    end for
    m.top.submit = {
        server: m.values.server
        username: m.values.username
        password: m.values.password
        deviceName: m.values.deviceName
    }
end sub
