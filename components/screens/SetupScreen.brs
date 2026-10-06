sub init()
    m.fields = ["server", "username", "password", "deviceName"]
    m.labels = { server: "Server URL", username: "Username", password: "Password", deviceName: "Device name" }
    m.hints = {
        server: "For example https://example.com:8080. Use https:// if your provider supports it: with http:// the password is sent unencrypted."
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
        if f = "server" and m.values.server <> "" and not isEncryptedServer(m.values.server) then shown = shown + "   (not encrypted)"
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
    ' Spoken names come in whole; server, username and password are spelled.
    if field = "password"
        setKeyboardVoice(dlg, "password")
        editBox = dlg.textEditBox
        if editBox <> invalid then editBox.secureMode = true
    else if field = "deviceName"
        setKeyboardVoice(dlg, "generic")
    else
        setKeyboardVoice(dlg, "alphanumeric")
    end if
    dlg.ObserveField("buttonSelected", "onKeyboardButton")
    dlg.ObserveField("wasClosed", "onKeyboardClosed")

    m.editing = field
    m.dialog = dlg
    m.top.GetScene().dialog = dlg
end sub

sub onKeyboardButton()
    if m.dialog.buttonSelected = 0
        typed = m.dialog.text.Trim()
        m.values[m.editing] = typed
        ' Voice entry comes in lower case: "living room" -> "Living room".
        if m.editing = "deviceName" then m.values.deviceName = UCase(Left(typed, 1)) + Mid(typed, 2)
        if m.editing = "server"
            m.values.server = normalizeServer(typed)
            if typed <> "" and m.values.server = ""
                m.top.status = "Use an address starting with https:// or http://."
            else if m.values.server <> "" and not isEncryptedServer(m.values.server)
                m.top.status = "This connection isn't encrypted (http://). It works, but use https:// if your provider supports it."
            else
                m.top.status = ""
            end if
        end if
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
