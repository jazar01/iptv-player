sub init()
    m.title = m.top.FindNode("title")
    m.menu = m.top.FindNode("menu")
    m.hint = m.top.FindNode("hint")
    m.status = m.top.FindNode("status")
    m.sportsPanel = m.top.FindNode("sportsPanel")
    m.sportsList = m.top.FindNode("sports")

    m.sports = loadSports()     ' [{ id, label }]
    m.values = { id: "", name: "", aliases: [], exclusions: [], sports: [] }
    m.actions = []

    content = CreateObject("roSGNode", "ContentNode")
    for each s in m.sports
        item = content.CreateChild("ContentNode")
        item.title = s.label
    end for
    m.sportsList.content = content

    m.menu.ObserveField("itemSelected", "onSelected")
    m.menu.ObserveField("itemFocused", "onFocused")
    m.top.ObserveField("focusedChild", "onFocusedChild")
    refresh()
end sub

sub onFocusedChild()
    if not m.top.HasFocus() then return
    if m.sportsPanel.visible then m.sportsList.SetFocus(true) else m.menu.SetFocus(true)
end sub

sub onTeam()
    t = m.top.team
    m.values = {
        id: asString(t.id)
        name: asString(t.name)
        aliases: copyList(t.aliases)
        exclusions: copyList(t.exclusions)
        sports: copyList(t.sports)
    }
    refresh()
end sub

function copyList(items as Dynamic) as Object
    out = []
    if type(items) = "roArray" then out.Append(items)
    return out
end function

function loadSports() as Object
    list = []
    json = ParseJson(ReadAsciiFile("pkg:/data/guide-rules.json"))
    if type(json) = "roAssociativeArray" and type(json.myTeams) = "roAssociativeArray" and type(json.myTeams.sports) = "roArray"
        for each s in json.myTeams.sports
            list.Push({ id: asString(s.id), label: asString(s.label) })
        end for
    end if
    return list
end function

sub refresh()
    if m.values.id = "" then m.title.text = "Add a team" else m.title.text = "Edit " + m.values.name

    m.actions = ["name", "sports", "aliases", "exclusions", "save"]
    if m.values.id <> "" then m.actions.Push("delete")
    content = CreateObject("roSGNode", "ContentNode")
    for each action in m.actions
        item = content.CreateChild("ContentNode")
        item.title = actionTitle(action)
    end for
    focus = m.menu.itemFocused
    m.menu.content = content
    if focus > 0 and focus < content.GetChildCount() then m.menu.jumpToItem = focus
    onFocused()
end sub

function actionTitle(action as String) as String
    if action = "name" then return "Team name:   " + orNotSet(m.values.name)
    if action = "sports" then return "Sports:   " + orNotSet(sportsText())
    if action = "aliases" then return "Also called:   " + orNotSet(listText(m.values.aliases))
    if action = "exclusions" then return "Not when it says:   " + orNotSet(listText(m.values.exclusions))
    if action = "save" then return "Save"
    return "Delete this team"
end function

function orNotSet(text as String) as String
    if text = "" then return "(not set)"
    return text
end function

function listText(items as Object) as String
    out = ""
    for each item in items
        if out <> "" then out += ", "
        out += item
    end for
    return out
end function

function sportsText() as String
    out = ""
    for each s in m.sports
        for each id in m.values.sports
            if id = s.id
                if out <> "" then out += ", "
                out += s.label
            end if
        end for
    end for
    return out
end function

sub onFocused()
    i = m.menu.itemFocused
    if i < 0 or i >= m.actions.Count() then return
    action = m.actions[i]
    if action = "name"
        m.hint.text = "As it appears in channel names, e.g. Alabama, Eagles, Dodgers."
    else if action = "sports"
        m.hint.text = "Only games in these sports are shown. This keeps out other teams with the same name (minor-league Eagles, for example)."
    else if action = "aliases"
        m.hint.text = "Other names to look for, separated by commas: a mascot or short form, e.g. Crimson Tide, Bama."
    else if action = "exclusions"
        m.hint.text = "Names that contain your team's name but aren't your team, separated by commas, e.g. North Alabama, Alabama State."
    else
        m.hint.text = ""
    end if
end sub

sub onSelected()
    action = m.actions[m.menu.itemSelected]
    m.status.text = ""
    if action = "name"
        openKeyboard("name", "Team name", m.values.name)
    else if action = "aliases"
        openKeyboard("aliases", "Also called (commas between names)", listText(m.values.aliases))
    else if action = "exclusions"
        openKeyboard("exclusions", "Not when it says (commas between names)", listText(m.values.exclusions))
    else if action = "sports"
        openSports()
    else if action = "save"
        if m.values.name.Trim() = ""
            m.status.text = "Enter the team's name first."
        else if m.values.sports.Count() = 0
            m.status.text = "Pick at least one sport."
        else
            m.top.save = m.values
        end if
    else if action = "delete"
        m.top.remove = m.values.id
    end if
end sub

' ---------------------------------------------------------------------------
' Keyboard (text fields)

sub openKeyboard(field as String, title as String, text as String)
    dlg = CreateObject("roSGNode", "StandardKeyboardDialog")
    dlg.title = title
    dlg.text = text
    dlg.buttons = ["OK", "Cancel"]
    dlg.ObserveField("buttonSelected", "onKeyboardButton")
    dlg.ObserveField("wasClosed", "onKeyboardClosed")
    m.editing = field
    m.dialog = dlg
    m.top.GetScene().dialog = dlg
end sub

sub onKeyboardButton()
    if m.dialog.buttonSelected = 0
        text = m.dialog.text.Trim()
        if m.editing = "name"
            m.values.name = capitalizeWords(text)
        else
            items = []
            for each part in text.Split(",")
                if part.Trim() <> "" then items.Push(capitalizeWords(part.Trim()))
            end for
            m.values[m.editing] = items
        end if
        refresh()
    end if
    m.dialog.close = true
end sub

sub onKeyboardClosed()
    m.dialog = invalid
    m.menu.SetFocus(true)
end sub

' ---------------------------------------------------------------------------
' Sports checklist

sub openSports()
    checked = []
    for each s in m.sports
        isChecked = false
        for each id in m.values.sports
            if id = s.id then isChecked = true
        end for
        checked.Push(isChecked)
    end for
    m.sportsList.checkedState = checked
    m.sportsPanel.visible = true
    m.sportsList.SetFocus(true)
end sub

sub closeSports()
    picked = []
    checked = m.sportsList.checkedState
    for i = 0 to m.sports.Count() - 1
        if i < checked.Count() and checked[i] then picked.Push(m.sports[i].id)
    end for
    m.values.sports = picked
    m.sportsPanel.visible = false
    refresh()
    m.menu.SetFocus(true)
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if press and key = "back" and m.sportsPanel.visible
        closeSports()
        return true
    end if
    return false
end function
