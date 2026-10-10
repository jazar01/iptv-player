' Backups on the home Raspberry Pi (see BackupTask.xml). One request at a
' time, each with short timeouts, so a missing Pi costs a few seconds of this
' thread and nothing else.

sub init()
    m.top.functionName = "backupLoop"
end sub

sub backupLoop()
    m.port = CreateObject("roMessagePort")
    m.address = ""          ' "ip:port" of the service, once found
    m.savedAt = 0
    m.lastError = ""
    m.keys = loadKeys()
    for each f in ["upload", "listRequest", "fetchRequest", "syncRequest", "nowPlaying"]
        m.top.ObserveField(f, m.port)
    end for
    m.top.ready = true
    if m.keys = invalid
        ' Still answers (no backups), so a restore falls back to the bundle.
        print "[backup] no household key in the package; backups off"
        m.top.status = { enabled: false, address: "", savedAt: 0, error: "" }
    else
        publishStatus()
    end if
    ' As in the other services: a runtime error is caught and logged, and the
    ' loop carries on (uncaught, it would freeze the app on a sideloaded Roku).
    while true
        msg = wait(0, m.port)
        if type(msg) = "roSGNodeEvent"
            field = msg.GetField()
            req = msg.GetData()
            try
                if field = "upload"
                    ' Only the newest state matters: skip ones already replaced.
                    pending = m.port.PeekMessage()
                    while pending <> invalid and type(pending) = "roSGNodeEvent" and pending.GetField() = "upload"
                        req = m.port.GetMessage().GetData()
                        pending = m.port.PeekMessage()
                    end while
                    upload(req)
                else if field = "listRequest"
                    m.top.listResult = listBackups(req)
                else if field = "syncRequest"
                    m.top.syncResult = sync(req)
                else if field = "fetchRequest"
                    m.top.fetchResult = fetchBackup(req)
                else if field = "nowPlaying"
                    pending = m.port.PeekMessage()
                    while pending <> invalid and type(pending) = "roSGNodeEvent" and pending.GetField() = "nowPlaying"
                        req = m.port.GetMessage().GetData()
                        pending = m.port.PeekMessage()
                    end while
                    sendNowPlaying(req)
                end if
            catch e
                print "[backup] ERROR handling "; field; " (recovered): "; redact(e.message)
                if field = "listRequest" then m.top.listResult = { id: asString(req.id), ok: false, devices: [], error: "error" }
                if field = "fetchRequest" then m.top.fetchResult = { id: asString(req.id), ok: false, json: "", error: "error" }
                if field = "syncRequest" then m.top.syncResult = { id: asString(req.id), op: asString(req.op), ok: false, conflict: false, json: "", version: 0 }
            end try
        end if
    end while
end sub

sub publishStatus()
    m.top.status = { enabled: true, address: m.address, savedAt: m.savedAt, error: m.lastError }
end sub

' ---------------------------------------------------------------------------
' Keys: the household key (64 hex characters) gives an encryption key and a
' signing key, the same way the Pi (and later the admin page) derive them.

function loadKeys() as Dynamic
    cfg = ParseJson(ReadAsciiFile("pkg:/data/backup.json"))
    if type(cfg) <> "roAssociativeArray" then return invalid
    hex = asString(cfg.key)
    if not CreateObject("roRegex", "^[0-9a-fA-F]{64}$", "").IsMatch(hex) then return invalid
    key = CreateObject("roByteArray")
    key.FromHexString(hex)
    enc = hmacOf(key, "enc")
    mac = hmacOf(key, "mac")
    if enc = invalid or mac = invalid then return invalid
    return { encHex: LCase(enc.ToHexString()), mac: mac }
end function

function hmacOf(key as Object, text as String) as Dynamic
    data = CreateObject("roByteArray")
    data.FromAsciiString(text)
    h = CreateObject("roHMAC")
    if h.Setup("sha256", key) <> 0 then return invalid
    return h.Process(data)
end function

' { v, device, name, savedAt, iv, data, mac } as JSON text.
function seal(json as String, deviceId as String, name as String) as String
    iv = LCase(CreateObject("roDeviceInfo").GetRandomUUID().Replace("-", ""))     ' 16 random bytes
    cipher = CreateObject("roEVPCipher")
    if cipher.Setup(true, "aes-256-cbc", m.keys.encHex, iv, 1) <> 0 then return ""
    plain = CreateObject("roByteArray")
    plain.FromAsciiString(json)
    encrypted = cipher.Process(plain)
    if encrypted = invalid then return ""
    data = encrypted.ToBase64String()
    sig = hmacOf(m.keys.mac, iv + data)
    ' Quoted keys: unquoted ones come out lower-cased ("savedat").
    return FormatJson({ "v": 1, "device": deviceId, "name": name, "savedAt": nowSeconds(), "iv": iv, "data": data, "mac": LCase(sig.ToHexString()) })
end function

' The plain JSON inside a sealed backup, or "" if its signature doesn't
' match (another household key) or it won't open.
function unseal(sealed as Dynamic) as String
    if type(sealed) <> "roAssociativeArray" then return ""
    iv = asString(sealed.iv)
    data = asString(sealed.data)
    sig = hmacOf(m.keys.mac, iv + data)
    if sig = invalid or LCase(sig.ToHexString()) <> LCase(asString(sealed.mac)) then return ""
    cipher = CreateObject("roEVPCipher")
    if cipher.Setup(false, "aes-256-cbc", m.keys.encHex, iv, 1) <> 0 then return ""
    encrypted = CreateObject("roByteArray")
    encrypted.FromBase64String(data)
    plain = cipher.Process(encrypted)
    if plain = invalid then return ""
    return plain.ToAsciiString()
end function

' ---------------------------------------------------------------------------
' Requests

sub upload(req as Dynamic)
    if m.keys = invalid or type(req) <> "roAssociativeArray" or asString(req.json) = "" then return
    deviceId = asString(req.deviceId)
    body = seal(asString(req.json), deviceId, asString(req.name))
    if body = ""
        m.lastError = "couldn't seal the backup"
        print "[backup] "; m.lastError
        publishStatus()
        return
    end if
    r = request("PUT", "/devices/" + deviceId, body)
    if r.code = 200
        m.savedAt = nowSeconds()
        m.lastError = ""
        print "[backup] saved to the Pi ("; body.Len(); " bytes)"
    else
        m.lastError = r.error
        print "[backup] not saved: "; r.error
    end if
    publishStatus()
end sub

function listBackups(req as Dynamic) as Object
    id = ""
    if type(req) = "roAssociativeArray" then id = asString(req.id)
    if m.keys = invalid then return { id: id, ok: false, devices: [], error: "backups off" }
    r = request("GET", "/devices", "")
    if r.code <> 200 then return { id: id, ok: false, devices: [], error: r.error }
    devices = []
    list = ParseJson(r.body)
    if type(list) = "roArray"
        for each d in list
            if type(d) = "roAssociativeArray" then devices.Push({ id: asString(d.id), name: asString(d.name), savedAt: toInt(d.savedAt) })
        end for
    end if
    return { id: id, ok: true, devices: devices, error: "" }
end function

function fetchBackup(req as Dynamic) as Object
    if type(req) <> "roAssociativeArray" then req = {}
    id = asString(req.id)
    if m.keys = invalid then return { id: id, ok: false, json: "", error: "backups off" }
    r = request("GET", "/devices/" + asString(req.deviceId), "")
    if r.code <> 200 then return { id: id, ok: false, json: "", error: r.error }
    json = unseal(ParseJson(r.body))
    if json = "" then return { id: id, ok: false, json: "", error: "the backup couldn't be opened (another household key?)" }
    return { id: id, ok: true, json: json, error: "" }
end function

' The shared copy (see BackupTask.xml). Sealed like a backup, as device
' "shared"; the Pi refuses a save made from an older version (409: another
' TV saved first), and MainBackup merges again.
function sync(req as Dynamic) as Object
    if type(req) <> "roAssociativeArray" then req = {}
    out = { id: asString(req.id), op: asString(req.op), ok: false, conflict: false, json: "", version: 0 }
    if m.keys = invalid then return out
    if out.op = "household"
        ' The household setup a new TV starts from (stage 3; saved from the
        ' admin page). json "" when there is none.
        r = request("GET", "/household", "")
        if r.code = 404
            out.ok = true
            return out
        end if
        if r.code <> 200 then return out
        json = unseal(ParseJson(r.body))
        if json = "" then return out
        out.ok = true
        out.json = json
        return out
    end if
    if out.op = "fetch"
        r = request("GET", "/shared", "")
        if r.code = 404
            out.ok = true       ' none yet: this TV's records start it
            return out
        end if
        if r.code <> 200 then return out
        sealed = ParseJson(r.body)
        json = unseal(sealed)
        if json = ""
            print "[backup] the shared copy couldn't be opened (another household key?)"
            return out
        end if
        out.ok = true
        out.json = json
        out.version = toInt(sealed.version)
    else if out.op = "put"
        body = seal(asString(req.json), "shared", asString(req.name))
        if body = "" then return out
        r = request("PUT", "/shared", body, { "X-Base-Version": toInt(req.baseVersion).ToStr() })
        if r.code = 200
            reply = ParseJson(r.body)
            out.ok = true
            if type(reply) = "roAssociativeArray" then out.version = toInt(reply.version)
        else if r.code = 409
            out.conflict = true
        else
            print "[backup] shared copy not saved: "; r.error
        end if
    end if
    return out
end function

' One HTTP request to the service: { code, body, error }. Finds the service
' first if needed, and once more if it doesn't answer where it was (the Pi
' got a new address).
' The admin page's "what's being watched": a short note to the service, only
' if it has already been found (a backup or sync finds it), never retried.
sub sendNowPlaying(req as Dynamic)
    if m.address = "" or type(req) <> "roAssociativeArray" then return
    body = FormatJson({ "deviceId": asString(req.deviceId), "name": asString(req.name), "kind": asString(req.kind), "title": asString(req.title), "program": asString(req.program), "via": asString(req.via) })
    httpCall("PUT", "http://" + m.address + "/now-playing", body, invalid)
end sub

function request(method as String, path as String, body as String, headers = invalid as Dynamic) as Object
    for attempt = 1 to 2
        if m.address = "" then m.address = findService()
        if m.address = "" then return { code: 0, body: "", error: "no backup service found on the home network" }
        r = httpCall(method, "http://" + m.address + path, body, headers)
        if r.code > 0 then return r
        print "[backup] the service at "; m.address; " didn't answer ("; r.error; "); looking again"
        m.address = ""
    end for
    return r
end function

function httpCall(method as String, url as String, body as String, headers as Dynamic) as Object
    xfer = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    xfer.SetMessagePort(port)
    xfer.SetUrl(url)
    xfer.RetainBodyOnError(true)
    xfer.AddHeader("Content-Type", "application/json")
    if headers = invalid then headers = {}
    for each name in headers
        xfer.AddHeader(name, asString(headers[name]))
    end for
    if method = "PUT"
        xfer.SetRequest("PUT")
        started = xfer.AsyncPostFromString(body)
    else
        started = xfer.AsyncGetToString()
    end if
    if not started then return { code: 0, body: "", error: "couldn't start the request" }
    msg = wait(5000, port)
    if type(msg) <> "roUrlEvent"
        xfer.AsyncCancel()
        return { code: 0, body: "", error: "timed out" }
    end if
    code = msg.GetResponseCode()
    if code = 200 then return { code: code, body: msg.GetString(), error: "" }
    if code > 0
        detail = ParseJson(msg.GetString())
        reason = "HTTP " + code.ToStr()
        if type(detail) = "roAssociativeArray" and asString(detail.error) <> "" then reason = reason + ": " + asString(detail.error)
        return { code: code, body: "", error: reason }
    end if
    return { code: 0, body: "", error: msg.GetFailureReason() }
end function

' Broadcasts "IPTV-BACKUP?" on the home network (twice, in case one is
' lost); the service answers "IPTV-BACKUP <port> <version>". "ip:port", or "".
function findService() as String
    sock = CreateObject("roDatagramSocket")
    here = CreateObject("roSocketAddress")
    here.setAddress("0.0.0.0:0")
    sock.setAddress(here)
    sock.setBroadcast(true)
    there = CreateObject("roSocketAddress")
    there.setAddress("255.255.255.255:8793")
    sock.setSendToAddress(there)
    port = CreateObject("roMessagePort")
    sock.setMessagePort(port)
    sock.notifyReadable(true)
    found = ""
    for each waitMs in [700, 1300]
        sock.sendStr("IPTV-BACKUP?")
        msg = wait(waitMs, port)
        if type(msg) = "roSocketEvent"
            parts = sock.receiveStr(512).Trim().Split(" ")
            if parts.Count() >= 2 and parts[0] = "IPTV-BACKUP"
                found = sock.getReceivedFromAddress().getHostName() + ":" + parts[1]
                exit for
            end if
        end if
    end for
    sock.close()
    if found = "" then print "[backup] no backup service answered" else print "[backup] backup service found at "; found
    return found
end function
