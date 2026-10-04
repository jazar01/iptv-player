' Shared by everything that shows HomeCards (MainScene's row modules,
' HomeScreen, FavoritesScreen).

' EpgService entry { now, upcoming } -> HomeItem program fields.
function programFields(entry as Object) as Object
    fields = { nowTitle: "", nowFlags: "", nowStart: 0, nowEnd: 0, nextTitle: "", nextStart: 0 }
    current = entry.now
    if type(current) = "roAssociativeArray"
        fields.nowTitle = current.title
        fields.nowFlags = joinFlags(current.flags)
        fields.nowStart = current.start
        fields.nowEnd = current.ends
    end if
    upcoming = entry.upcoming
    if type(upcoming) = "roAssociativeArray"
        fields.nextTitle = upcoming.title
        fields.nextStart = upcoming.start
    end if
    return fields
end function

function joinFlags(flags as Dynamic) as String
    out = ""
    if type(flags) <> "roArray" then return out
    for each flag in flags
        if out <> "" then out += ","
        out += asString(flag)
    end for
    return out
end function

function createHomeItem(parent as Object, item as Object) as Object
    node = parent.CreateChild("HomeItem")
    node.SetFields(item)
    return node
end function

sub applyPrograms(node as Object, entry as Object)
    node.SetFields(programFields(entry))
    node.epgVersion = node.epgVersion + 1
end sub

' What a screen reports to MainScene when a card is selected or * is pressed.
function itemSummary(node as Object) as Object
    return {
        rowId: node.rowId
        kind: node.kind
        itemKey: node.itemKey
        streamId: node.streamId
        name: node.name
        epgChannelId: node.epgChannelId
    }
end function
