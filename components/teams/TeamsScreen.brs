sub init()
    m.list = m.top.FindNode("list")
    m.teams = []
    m.list.ObserveField("itemSelected", "onSelected")
    m.top.ObserveField("focusedChild", "onFocusedChild")
    onTeams()
end sub

sub onFocusedChild()
    if m.top.HasFocus() then m.list.SetFocus(true)
end sub

sub onTeams()
    m.teams = []
    if type(m.top.teams) = "roArray" then m.teams = m.top.teams
    labels = sportLabels()
    focus = m.list.itemFocused
    content = CreateObject("roSGNode", "ContentNode")
    for each t in m.teams
        sports = ""
        for each id in t.sports
            if sports <> "" then sports += ", "
            sports += asString(labels[id])
        end for
        if sports = "" then sports = "no sports picked"
        item = content.CreateChild("ContentNode")
        item.title = t.name + "   -   " + sports
    end for
    item = content.CreateChild("ContentNode")
    item.title = "+  Add a team"
    m.list.content = content
    if focus > 0 and focus < content.GetChildCount() then m.list.jumpToItem = focus
end sub

sub onSelected()
    i = m.list.itemSelected
    if i < m.teams.Count()
        m.top.chosen = { action: "edit", team: m.teams[i] }
    else
        m.top.chosen = { action: "add" }
    end if
end sub

' Sport ID -> label, from data/guide-rules.json "myTeams".
function sportLabels() as Object
    labels = {}
    json = ParseJson(ReadAsciiFile("pkg:/data/guide-rules.json"))
    if type(json) = "roAssociativeArray" and type(json.myTeams) = "roAssociativeArray" and type(json.myTeams.sports) = "roArray"
        for each s in json.myTeams.sports
            labels[asString(s.id)] = asString(s.label)
        end for
    end if
    return labels
end function
