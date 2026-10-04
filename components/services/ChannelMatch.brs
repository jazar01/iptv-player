' Channel matching: finds a saved channel or series again after the provider
' renumbers its catalog. One shared component (requirements: Architecture);
' SearchTask uses it after each catalog refresh, and My Teams will use it to
' map networks to channels.
'
' Channels: guide ID (epg_channel_id) first, then name. Series: name plus
' year. Names are compared by matchKey(): lower-case, provider quality tags
' removed (data/guide-rules.json "channelMatching"), punctuation dropped.

function loadMatchRules() as Object
    rules = { ignore: [], punctuation: CreateObject("roRegex", "[^a-z0-9]+", "") }
    json = ParseJson(ReadAsciiFile("pkg:/data/guide-rules.json"))
    if type(json) = "roAssociativeArray" and type(json.channelMatching) = "roAssociativeArray" and type(json.channelMatching.ignorePatterns) = "roArray"
        for each pattern in json.channelMatching.ignorePatterns
            rules.ignore.Push(CreateObject("roRegex", asString(pattern), "i"))
        end for
    end if
    return rules
end function

function matchKey(name as String, rules as Object) as String
    key = LCase(name)
    for each re in rules.ignore
        key = re.ReplaceAll(key, " ")
    end for
    return rules.punctuation.ReplaceAll(key, " ").Trim()
end function

sub addToGroup(groups as Object, key as String, entry as Object)
    if key = "" then return
    if groups[key] = invalid then groups[key] = []
    groups[key].Push(entry)
end sub

' saved: { streamId, name, epgChannelId }
' lookup: { byEpg: { lcase guide ID -> [entries] }, byName: { matchKey -> [entries] } }
' Returns { entry, method } or invalid. Order:
'   1. the only channel with this guide ID
'   2. among channels sharing the guide ID, the one with the same name
'   3. the only channel with the same name
'   4. among channels sharing the guide ID, the first (same programming)
function matchChannel(saved as Object, lookup as Object, rules as Object) as Dynamic
    epg = LCase(asString(saved.epgChannelId))
    key = matchKey(asString(saved.name), rules)
    sameGuide = invalid
    if epg <> "" then sameGuide = lookup.byEpg[epg]

    if sameGuide <> invalid
        if sameGuide.Count() = 1 then return { entry: sameGuide[0], method: "guide ID" }
        for each e in sameGuide
            if matchKey(e.name, rules) = key then return { entry: e, method: "guide ID and name" }
        end for
    end if

    sameName = lookup.byName[key]
    if key <> "" and sameName <> invalid and sameName.Count() = 1 then return { entry: sameName[0], method: "name" }

    if sameGuide <> invalid then return { entry: sameGuide[0], method: "guide ID (first of " + sameGuide.Count().ToStr() + ")" }
    return invalid
end function

' saved: { seriesId, name, year }; lookup: { byName: { matchKey -> [entries] } }
' The only series with the same name and year (year ignored when either side
' doesn't know it), else invalid.
function matchSeries(saved as Object, lookup as Object, rules as Object) as Dynamic
    sameName = lookup.byName[matchKey(asString(saved.name), rules)]
    if sameName = invalid then return invalid
    year = toInt(saved.year)
    candidates = []
    for each e in sameName
        if year = 0 or e.year = 0 or e.year = year then candidates.Push(e)
    end for
    if candidates.Count() = 1 then return { entry: candidates[0], method: "name and year" }
    return invalid
end function
