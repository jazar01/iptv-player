' Shared by everything that shows HomeCards (MainScene's row modules,
' HomeScreen, RowGridScreen).

' EpgService entry { now, upcoming } -> HomeItem program fields.
function programFields(entry as Object) as Object
    fields = { nowTitle: "", nowFlags: "", nowStart: 0, nowEnd: 0, nextTitle: "", nextStart: 0 }
    current = entry.now
    if type(current) = "roAssociativeArray"
        fields.nowTitle = cardTitle(current.title)
        fields.nowFlags = joinFlags(current.flags)
        fields.nowStart = current.start
        fields.nowEnd = current.ends
    end if
    upcoming = entry.upcoming
    if type(upcoming) = "roAssociativeArray"
        fields.nextTitle = cardTitle(upcoming.title)
        fields.nextStart = upcoming.start
    end if
    return fields
end function

' A card's one line for a program: "College Football : South Carolina at
' Kentucky" left room for "College Football : Sout..."; when what follows
' the sport is a matchup, the card shows just the matchup (Oct 10, 2026).
' The patterns are epg.cardTitle in data/guide-rules.json.
function cardTitle(title as Dynamic) as String
    text = asString(title)
    if m.cardTitleRules = invalid
        m.cardTitleRules = {}
        json = ParseJson(ReadAsciiFile("pkg:/data/guide-rules.json"))
        if type(json) = "roAssociativeArray" and type(json.epg) = "roAssociativeArray" and type(json.epg.cardTitle) = "roAssociativeArray"
            m.cardTitleRules = { prefix: rulesRegex(json.epg.cardTitle.sportPrefix, "i"), matchup: rulesRegex(json.epg.cardTitle.matchup, "i") }
        end if
    end if
    r = m.cardTitleRules
    if r.prefix = invalid or r.matchup = invalid then return text
    match = r.prefix.Match(text)
    if match.Count() = 0 then return text
    rest = Mid(text, Len(match[0]) + 1).Trim()
    if rest <> "" and r.matchup.IsMatch(rest) then return rest
    return text
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
        resumeKind: node.resumeKind
        itemId: node.itemId
        ext: node.ext
        position: node.position
        duration: node.duration
        seriesId: node.seriesId
        seriesName: node.seriesName
        year: node.year
        season: node.season
        episode: node.episode
        channels: node.channels
        teamName: node.teamName
        start: node.nowStart
    }
end function
