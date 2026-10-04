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

' "example.com:8080/" -> "http://example.com:8080". Also drops a pasted
' "/player_api.php..." suffix.
function normalizeServer(server as String) as String
    s = server.Trim()
    if s = "" then return ""
    p = Instr(1, LCase(s), "/player_api.php")
    if p > 0 then s = Left(s, p - 1)
    if Instr(1, s, "://") = 0 then s = "http://" + s
    while Right(s, 1) = "/"
        s = Left(s, s.Len() - 1)
    end while
    return s
end function
