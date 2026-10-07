' Small helpers shared by components. Include with
'   <script type="text/brightscript" uri="pkg:/components/common/Utils.brs" />

' Any scalar (string, number, boolean) to a string; invalid and objects to "".
function asString(v as Dynamic) as String
    if v = invalid then return ""
    t = type(v)
    if t = "String" or t = "roString" then return v
    if GetInterface(v, "ifToStr") <> invalid then return v.ToStr()
    return ""
end function

' Xtream returns IDs and counts as either numbers or strings; normalize them.
function toInt(v as Dynamic) as Integer
    t = type(v)
    if t = "Integer" or t = "roInteger" then return v
    if t = "LongInteger" or t = "roLongInteger" or t = "Float" or t = "roFloat" or t = "Double" or t = "roDouble" then return Int(v)
    return Val(asString(v), 10)
end function

function isTrue(v as Dynamic) as Boolean
    t = type(v)
    return (t = "Boolean" or t = "roBoolean") and v
end function

' UTC seconds; used for every updatedAt.
function nowSeconds() as Integer
    return CreateObject("roDateTime").AsSeconds()
end function

' First letter of each word upper case; the rest left as typed, so "A&M" or
' "UAB" stay as they are. "alabama crimson tide" -> "Alabama Crimson Tide".
function capitalizeWords(text as String) as String
    out = ""
    startOfWord = true
    for i = 1 to text.Len()
        ch = Mid(text, i, 1)
        if startOfWord then out += UCase(ch) else out += ch
        startOfWord = (ch = " " or ch = "-" or ch = "/" or ch = "(" or ch = ".")
    end for
    return out
end function

' For display beside a year column: "Show (2019)", "Show - 2019" or
' "Show [2019]" -> "Show". Only that year is removed.
function nameWithoutYear(name as String, year as Integer) as String
    if year <= 0 then return name
    y = year.ToStr()
    re = CreateObject("roRegex", "\s*(\(" + y + "\)|\[" + y + "\]|-\s*" + y + "$)\s*", "")
    stripped = re.ReplaceAll(name, " ").Trim()
    if stripped = "" then return name
    return stripped
end function

' Xtream puts the year in different fields depending on panel and kind.
function itemYear(item as Object) as Integer
    for each field in ["year", "releaseDate", "release_date", "releasedate"]
        y = Val(Left(asString(item[field]), 4), 10)
        if y > 1900 and y < 2200 then return y
    end for
    return 0
end function

' Percent-encode for a URL path segment or query value (UTF-8, RFC 3986
' unreserved characters kept). Safe on the render thread, unlike
' roUrlTransfer.Escape().
function urlEncode(text as String) as String
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(text)
    out = ""
    for each b in bytes
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b = 45 or b = 46 or b = 95 or b = 126
            out += Chr(b)
        else
            hexDigits = UCase(StrI(b, 16))
            if b < 16 then hexDigits = "0" + hexDigits
            out += "%" + hexDigits
        end if
    end for
    return out
end function

' UTC seconds -> local wall-clock time, e.g. "8:05 PM".
function formatClock(seconds as Integer) as String
    dt = CreateObject("roDateTime")
    dt.FromSeconds(seconds)
    dt.ToLocalTime()
    hours = dt.GetHours()
    minutes = dt.GetMinutes()
    suffix = "AM"
    if hours >= 12 then suffix = "PM"
    hours = hours mod 12
    if hours = 0 then hours = 12
    mm = minutes.ToStr()
    if minutes < 10 then mm = "0" + mm
    return hours.ToStr() + ":" + mm + " " + suffix
end function

function pad2(n as Integer) as String
    if n < 10 then return "0" + n.ToStr()
    return n.ToStr()
end function

' Minutes to add to UTC at the given moment, for a rule from
' data/guide-rules.json "timezones": { standard, daylight, dst: "eu" | "us" | "" }.
function utcOffsetMinutes(utc as Integer, rule as Dynamic) as Integer
    if type(rule) <> "roAssociativeArray" then return 0
    standard = toInt(rule.standard)
    daylight = toInt(rule.daylight)
    dst = asString(rule.dst)
    dt = CreateObject("roDateTime")
    dt.FromSeconds(utc)
    year = dt.GetYear()
    if dst = "eu"
        ' Last Sunday of March to last Sunday of October, 01:00 UTC.
        starts = sundayUtc(year, 3, -1) + 3600
        ends = sundayUtc(year, 10, -1) + 3600
    else if dst = "us"
        ' Second Sunday of March to first Sunday of November, 02:00 local.
        starts = sundayUtc(year, 3, 2) + 7200 - standard * 60
        ends = sundayUtc(year, 11, 1) + 7200 - daylight * 60
    else
        return standard
    end if
    if utc >= starts and utc < ends then return daylight
    return standard
end function

' Midnight UTC (as UTC seconds) of the nth Sunday of a month; n = -1 is the last.
function sundayUtc(year as Integer, month as Integer, n as Integer) as Integer
    dt = CreateObject("roDateTime")
    dt.FromISO8601String(year.ToStr() + "-" + pad2(month) + "-01T00:00:00Z")
    first = dt.AsSeconds()
    firstSunday = first + ((7 - dt.GetDayOfWeek()) mod 7) * 86400
    if n > 0 then return firstSunday + (n - 1) * 7 * 86400
    monthEnd = first + dt.GetLastDayOfMonth() * 86400
    sunday = firstSunday
    while sunday + 7 * 86400 < monthEnd
        sunday = sunday + 7 * 86400
    end while
    return sunday
end function

' UTC seconds -> "YYYY-MM-DD:HH-MM" in a rule's local time (Xtream timeshift format).
function serverTimeString(utc as Integer, rule as Dynamic) as String
    dt = CreateObject("roDateTime")
    dt.FromSeconds(utc + utcOffsetMinutes(utc, rule) * 60)
    return dt.GetYear().ToStr() + "-" + pad2(dt.GetMonth()) + "-" + pad2(dt.GetDayOfMonth()) + ":" + pad2(dt.GetHours()) + "-" + pad2(dt.GetMinutes())
end function

' Event times written into channel names, rewritten in the Roku's local time:
' "Rams @ Eagles (2026-10-04 17:00:00)" -> "Rams @ Eagles (Sun 1:00 PM)".
' Patterns and their time zones are "nameTimes" in data/guide-rules.json.
' For display only; saved names keep the provider's text.
function localizeName(name as String) as String
    found = findNameTime(name, true)
    if found = invalid then return name
    return name.Replace(found.text, "(" + formatDayTime(found.utc) + ")")
end function

' The first event time in a name: { utc, text (the matched part) } or
' invalid. displayOnly skips rules marked display: false.
function findNameTime(name as String, displayOnly as Boolean) as Dynamic
    if m.nameTimeRules = invalid then m.nameTimeRules = loadNameTimeRules()
    for each rule in m.nameTimeRules
        if rule.display or not displayOnly
            match = rule.regex.Match(name)
            if match.Count() > 1
                utc = nameTimeUtc(match, rule)
                if utc > 0 then return { utc: utc, text: match[0] }
            end if
        end if
    end for
    return invalid
end function

function loadNameTimeRules() as Object
    rules = []
    json = ParseJson(ReadAsciiFile("pkg:/data/guide-rules.json"))
    if type(json) <> "roAssociativeArray" or type(json.nameTimes) <> "roArray" then return rules
    zones = json.timezones
    if type(zones) <> "roAssociativeArray" then zones = {}
    for each r in json.nameTimes
        if type(r) = "roAssociativeArray" and asString(r.pattern) <> "" and type(r.order) = "roArray"
            zone = zones[asString(r.zone)]
            if zone = invalid then zone = { standard: 0, daylight: 0, dst: "" }
            display = true
            if r.display <> invalid then display = isTrue(r.display)
            rules.Push({ regex: CreateObject("roRegex", r.pattern, "i"), order: r.order, zone: zone, display: display })
        end if
    end for
    return rules
end function

' Capture groups -> UTC seconds, reading them as local time in the rule's zone.
function nameTimeUtc(match as Object, rule as Object) as Integer
    year = CreateObject("roDateTime").GetYear()
    month = 0
    day = 0
    hour = 0
    minute = 0
    ampm = ""
    for i = 0 to rule.order.Count() - 1
        if i + 1 < match.Count()
            value = match[i + 1]
            part = rule.order[i]
            if part = "year" then year = Val(value, 10)
            if part = "month" then month = Val(value, 10)
            if part = "monthName" then month = monthNumber(value)
            if part = "day" then day = Val(value, 10)
            if part = "hour" then hour = Val(value, 10)
            if part = "minute" then minute = Val(value, 10)
            if part = "ampm" then ampm = UCase(value)
        end if
    end for
    if ampm = "PM" and hour < 12 then hour = hour + 12
    if ampm = "AM" and hour = 12 then hour = 0
    if month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 then return 0

    dt = CreateObject("roDateTime")
    dt.FromISO8601String(year.ToStr() + "-" + pad2(month) + "-" + pad2(day) + "T" + pad2(hour) + ":" + pad2(minute) + ":00Z")
    localAsUtc = dt.AsSeconds()
    ' The offset in effect then (approximate only within a DST changeover hour).
    offset = utcOffsetMinutes(localAsUtc - toInt(rule.zone.standard) * 60, rule.zone)
    return localAsUtc - offset * 60
end function

' "Oct" / "OCT" / "October" -> 10, or 0.
function monthNumber(name as String) as Integer
    months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    key = LCase(Left(name, 3))
    for i = 0 to 11
        if months[i] = key then return i + 1
    end for
    return 0
end function

' UTC seconds -> local "Sun 1:00 PM".
function formatDayTime(utc as Integer) as String
    dt = CreateObject("roDateTime")
    dt.FromSeconds(utc)
    dt.ToLocalTime()
    return Left(dt.GetWeekday(), 3) + " " + formatClock(utc)
end function

' "example.com:8080/" -> "http://example.com:8080". Also drops a pasted
' "/player_api.php..." suffix, a query or fragment, and any "user:pass@"
' (the account goes in its own fields). No scheme means http: many Xtream
' servers have no https, so guessing it would just fail; Setup says when the
' connection isn't encrypted. Returns "" for anything but http or https.
function normalizeServer(server as String) as String
    s = server.Trim()
    if s = "" then return ""
    p = Instr(1, LCase(s), "/player_api.php")
    if p > 0 then s = Left(s, p - 1)
    for each mark in ["?", "#"]
        p = Instr(1, s, mark)
        if p > 0 then s = Left(s, p - 1)
    end for
    if Instr(1, s, "://") = 0 then s = "http://" + s
    scheme = LCase(Left(s, Instr(1, s, "://") - 1))
    if scheme <> "http" and scheme <> "https" then return ""
    rest = Mid(s, scheme.Len() + 4)
    hostEnd = Instr(1, rest + "/", "/")
    at = Instr(1, Left(rest, hostEnd - 1), "@")
    if at > 0 then rest = Mid(rest, at + 1)
    s = scheme + "://" + rest
    while Right(s, 1) = "/"
        s = Left(s, s.Len() - 1)
    end while
    if s.Len() <= scheme.Len() + 3 then return ""
    return s
end function

function isEncryptedServer(server as String) as Boolean
    return LCase(Left(server, 8)) = "https://"
end function

' For log lines that may carry text from the platform or the provider:
' every URL is cut to its scheme and host, so stream and API URLs (which
' hold the username and password) never reach the console.
function redact(text as Dynamic) as String
    re = CreateObject("roRegex", "([a-z][a-z0-9+.-]*://)(?:[^/@\s]*@)?([^/\s?#]*)[^\s""'<>]*", "i")
    return re.ReplaceAll(asString(text), "\1\2/...")
end function

' A provider ID made safe for a cache file name (digits, letters, - and _).
function safeKey(id as Dynamic) as String
    return CreateObject("roRegex", "[^A-Za-z0-9_-]", "").ReplaceAll(asString(id), "_")
end function

' Keyboard voice entry (a keyboard dialog, or a Dynamic keyboard): "generic"
' takes whole spoken words (names, searches); "alphanumeric"
' and "password" take letters spoken one at a time (addresses, usernames,
' passwords). Set on both the dialog and its text box: Roku's defaults for the
' text box spell letter by letter.
sub setKeyboardVoice(dlg as Object, mode as String)
    ' Keyboard dialogs have keyboardDomain; DynamicMiniKeyboard (Search) doesn't.
    if dlg.HasField("keyboardDomain") then dlg.keyboardDomain = mode
    editBox = dlg.textEditBox
    if editBox <> invalid then editBox.voiceEntryType = mode
end sub

' Seconds -> "1:12:05" or "12:05" (resume positions).
function formatDuration(seconds as Integer) as String
    h = seconds \ 3600
    mm = (seconds mod 3600) \ 60
    ss = seconds mod 60
    text = ""
    if h > 0 then text = h.ToStr() + ":"
    if h > 0 and mm < 10 then text = text + "0"
    text = text + mm.ToStr() + ":"
    if ss < 10 then text = text + "0"
    return text + ss.ToStr()
end function

' ---------------------------------------------------------------------------
' Provider details (get_vod_info, get_series_info): field names vary by panel.

' The first non-empty text among keys ("plot", "description", ...), or "".
function firstText(aa as Object, keys as Object) as String
    for each k in keys
        text = asString(aa[k]).Trim()
        if text <> "" then return text
    end for
    return ""
end function

' backdrop_path as a list (first one) or a single URL, or "".
function firstBackdrop(info as Object) as String
    backdrops = info.backdrop_path
    if type(backdrops) = "roArray"
        if backdrops.Count() > 0 then return asString(backdrops[0])
        return ""
    end if
    return asString(backdrops)
end function

' "7.25" -> "7.3"; nothing for a missing or zero rating.
function ratingText(value as Dynamic) as String
    rating = Val(asString(value))
    if rating <= 0 then return ""
    return Str(Int(rating * 10 + 0.5) / 10).Trim()
end function

' ---------------------------------------------------------------------------
' Plain-language text for a failed ApiTask response (res.code, res.error), for
' the screen; the technical detail stays in the console ([api] lines).
function friendlyRequestError(res as Object) as String
    code = toInt(res.code)
    detail = LCase(asString(res.error))
    if code = 401 or code = 403 then return "The provider refused the request (the account, or its connection limit)."
    if code = 404 then return "The provider doesn't have this right now."
    if code = 429 then return "The provider is limiting requests. Try again in a minute."
    if code >= 500 then return "The provider's server had a problem. Try again in a minute."
    if code > 0 then return "The provider answered with an error (HTTP " + code.ToStr() + ")."
    if Instr(1, detail, "timed out") > 0 then return "The server didn't answer in time. Try again in a moment."
    if Instr(1, detail, "resolve") > 0 then return "Can't find the server. Check the TV's internet connection."
    if Instr(1, detail, "ssl") > 0 or Instr(1, detail, "certificate") > 0 then return "A secure connection to the server failed."
    if Instr(1, detail, "json") > 0 or Instr(1, detail, "incomplete") > 0 then return "The provider sent data the app couldn't read. Try again later."
    if Instr(1, detail, "storage") > 0 or Instr(1, detail, "save") > 0 then return "The TV couldn't save the download (its storage may be full)."
    if Instr(1, detail, "no server") > 0 then return "No server is set up. Open Settings > Account and device name."
    return "Can't reach the server. Check the TV's internet connection."
end function

' UTC seconds -> "Nov 2, 2026" in the Roku's local time.
function formatDate(utc as Integer) as String
    dt = CreateObject("roDateTime")
    dt.FromSeconds(utc)
    dt.ToLocalTime()
    names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return names[dt.GetMonth() - 1] + " " + dt.GetDayOfMonth().ToStr() + ", " + dt.GetYear().ToStr()
end function
