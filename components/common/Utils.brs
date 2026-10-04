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
