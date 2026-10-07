' Audio-fix relay (see StreamRelay.xml). One request at a time: the Video
' node asks for the playlist, then segments one after another.

sub init()
    m.top.functionName = "relayLoop"
end sub

sub relayLoop()
    m.urls = {}             ' key -> provider URL (contains the password)
    m.segIds = {}           ' absolute segment URL -> number
    m.segUrls = {}          ' "<number>" -> absolute segment URL
    m.segOrder = []
    m.nextSeg = 1
    m.logged = {}           ' one-off log lines already printed
    m.port = CreateObject("roMessagePort")
    m.top.ObserveField("add", m.port)
    m.conns = {}
    listener = startListening()
    if listener = invalid
        print "[relay] couldn't open a local port; audio fix unavailable"
        return
    end if
    while true
        msg = wait(0, m.port)
        if type(msg) = "roSGNodeEvent"
            a = msg.GetData()
            if type(a) = "roAssociativeArray" then m.urls[asString(a.key)] = asString(a.url)
        else if type(msg) = "roSocketEvent"
            id = msg.getSocketID()
            if id = listener.getID()
                c = listener.accept()
                if c <> invalid
                    c.setMessagePort(m.port)
                    c.notifyReadable(true)
                    m.conns[c.getID().ToStr()] = { sock: c, buf: "" }
                end if
            else
                onReadable(id)
            end if
        end if
    end while
end sub

' 127.0.0.1 only: nothing else on the network can use the relay.
function startListening() as Dynamic
    for p = 18760 to 18769
        addr = CreateObject("roSocketAddress")
        addr.setAddress("127.0.0.1:" + p.ToStr())
        s = CreateObject("roStreamSocket")
        s.setAddress(addr)
        s.setMessagePort(m.port)
        s.notifyReadable(true)
        if s.listen(4)
            print "[relay] listening on 127.0.0.1:"; p
            m.top.port = p
            return s
        end if
        s.close()
    end for
    return invalid
end function

sub onReadable(id as Integer)
    key = id.ToStr()
    entry = m.conns[key]
    if entry = invalid then return
    s = entry.sock
    n = s.getCountRcvBuf()
    if n <= 0
        ' The player closed the connection.
        s.close()
        m.conns.Delete(key)
        return
    end if
    entry.buf = entry.buf + s.receiveStr(n)
    crlf = Chr(13) + Chr(10)
    if Instr(1, entry.buf, crlf + crlf) = 0 and Len(entry.buf) < 8192 then return
    s.notifyReadable(false)
    lineEnd = Instr(1, entry.buf, crlf)
    requestLine = entry.buf
    if lineEnd > 0 then requestLine = Left(entry.buf, lineEnd - 1)
    parts = requestLine.Split(" ")
    path = ""
    if parts.Count() >= 2 then path = parts[1]
    serve(s, path)
    s.close()
    m.conns.Delete(key)
end sub

' /p/<key>.m3u8                       live playlist
' /t/<key>/<duration>/<start>.m3u8    archive playlist
' /s/<number>.ts                      a segment, audio fixed
sub serve(s as Object, path as String)
    p = path.Split("?")[0]
    if Left(p, 3) = "/p/" and Right(p, 5) = ".m3u8"
        key = Mid(p, 4, Len(p) - 8)
        servePlaylist(s, asString(m.urls[key]), key)
    else if Left(p, 3) = "/t/" and Right(p, 5) = ".m3u8"
        bits = Mid(p, 4, Len(p) - 8).Split("/")
        template = ""
        if bits.Count() = 3 then template = asString(m.urls[bits[0]])
        url = ""
        if template <> "" then url = template.Replace("{duration}", bits[1]).Replace("{start}", bits[2])
        servePlaylist(s, url, bits[0])
    else if Left(p, 3) = "/s/"
        number = Mid(p, 4).Split(".")[0]
        serveSegment(s, asString(m.segUrls[number]))
    else
        sendStatus(s, 404)
    end if
end sub

sub servePlaylist(s as Object, url as String, key as String)
    if url = ""
        sendStatus(s, 404)
        return
    end if
    r = fetchText(url)
    if r.code <> 200
        print "[relay] "; key; " playlist failed: HTTP "; r.code
        sendStatus(s, 502)
        return
    end if
    if not m.logged.DoesExist("pl" + key)
        m.logged["pl" + key] = true
        print "[relay] "; key; " playlist ok ("; r.redirects; " redirect(s) followed)"
    end if
    out = []
    for each line in r.body.Split(Chr(10))
        l = line.Trim()
        if l = "" or Left(l, 1) = "#"
            out.Push(l)
        else
            out.Push("/s/" + segmentNumber(resolveUrl(r.finalUrl, l)) + ".ts")
        end if
    end for
    text = out.Join(Chr(10))
    sendBody(s, 200, "application/vnd.apple.mpegurl", textBytes(text))
end sub

' Stable numbers for segment URLs across playlist reloads; the oldest are
' forgotten once 120 are known.
function segmentNumber(url as String) as String
    known = m.segIds[url]
    if known <> invalid then return known
    number = m.nextSeg.ToStr()
    m.nextSeg = m.nextSeg + 1
    m.segIds[url] = number
    m.segUrls[number] = url
    m.segOrder.Push(url)
    while m.segOrder.Count() > 120
        old = m.segOrder.Shift()
        m.segUrls.Delete(asString(m.segIds[old]))
        m.segIds.Delete(old)
    end while
    return number
end function

sub serveSegment(s as Object, url as String)
    if url = ""
        sendStatus(s, 404)
        return
    end if
    file = "tmp:/relay_segment.ts"
    x = newTransfer(url)
    port = CreateObject("roMessagePort")
    x.SetMessagePort(port)
    x.AsyncGetToFile(file)
    ev = wait(90000, port)      ' archive segments are a minute long (about 20 MB)
    code = 0
    if ev <> invalid and type(ev) = "roUrlEvent" then code = ev.GetResponseCode()
    if ev = invalid then x.AsyncCancel()
    if code <> 200
        print "[relay] segment failed: HTTP "; code
        DeleteFile(file)
        sendStatus(s, 502)
        return
    end if
    data = CreateObject("roByteArray")
    data.ReadFile(file)
    DeleteFile(file)
    clock = CreateObject("roTimespan")
    fixed = fixAacProfile(data)
    if not m.logged.DoesExist("seg")
        m.logged["seg"] = true
        print "[relay] first segment: "; data.Count(); " bytes, "; fixed; " audio headers fixed in "; clock.TotalMilliseconds(); " ms"
    end if
    if fixed = 0 and not m.logged.DoesExist("nofix")
        m.logged["nofix"] = true
        print "[relay] a segment had no audio headers to fix ("; data.Count(); " bytes)"
    end if
    sendBody(s, 200, "video/mp2t", data)
end sub

' ---------------------------------------------------------------------------
' MPEG-TS: find the AAC (ADTS) stream and set each frame header's profile
' field from Main (0) to LC (1). Headers can span TS packets, so the byte
' positions of the current header are collected as packets go by.

function fixAacProfile(data as Object) as Integer
    total = data.Count()
    first = packetStart(data)
    if first < 0 then return 0
    pid = aacPid(data, first)
    if pid < 0 then return 0
    fixed = 0
    synced = false
    skip = 0                ' frame bytes left before the next header
    hdr = [0, 0, 0, 0, 0, 0]
    have = 0                ' header bytes collected
    p = first
    while p + 188 <= total
        if data[p] = &h47 and (((data[p + 1] and &h1F) << 8) or data[p + 2]) = pid
            afc = (data[p + 3] >> 4) and 3
            if afc = 1 or afc = 3
                off = p + 4
                if afc = 3 then off = off + 1 + data[off]
                if (data[p + 1] and &h40) <> 0
                    ' A PES packet starts here, and with it a new frame.
                    off = off + 9 + data[off + 8]
                    synced = true
                    skip = 0
                    have = 0
                end if
                i = off
                stopAt = p + 188
                while synced and i < stopAt
                    if skip > 0
                        advance = stopAt - i
                        if skip < advance then advance = skip
                        i = i + advance
                        skip = skip - advance
                    else
                        hdr[have] = i
                        have = have + 1
                        i = i + 1
                        if have = 6
                            have = 0
                            if data[hdr[0]] <> &hFF or (data[hdr[1]] and &hF6) <> &hF0
                                synced = false
                            else
                                frameLen = ((data[hdr[3]] and 3) << 11) or (data[hdr[4]] << 3) or ((data[hdr[5]] >> 5) and 7)
                                if frameLen < 7
                                    synced = false
                                else
                                    b = data[hdr[2]]
                                    if (b and &hC0) = 0
                                        data[hdr[2]] = (b and &h3F) or &h40
                                        fixed = fixed + 1
                                    end if
                                    skip = frameLen - 6
                                end if
                            end if
                        end if
                    end if
                end while
            end if
        end if
        p = p + 188
    end while
    return fixed
end function

' Where whole TS packets begin: live segments start with one, but archive
' segments are cut from a recording at any byte (one began at byte 87).
function packetStart(data as Object) as Integer
    total = data.Count()
    for k = 0 to 187
        if k + 376 < total
            if data[k] = &h47 and data[k + 188] = &h47 and data[k + 376] = &h47 then return k
        end if
    end for
    return -1
end function

' The PID of the first ADTS AAC stream (type 0x0F), from the PAT and PMT.
function aacPid(data as Object, first as Integer) as Integer
    total = data.Count()
    pmt = -1
    p = first
    while p + 188 <= total and p < first + 188 * 2000
        if data[p] = &h47 and (data[p + 1] and &h40) <> 0
            pid = ((data[p + 1] and &h1F) << 8) or data[p + 2]
            afc = (data[p + 3] >> 4) and 3
            off = p + 4
            if afc = 3 then off = off + 1 + data[off]
            if (afc = 1 or afc = 3) and off < p + 180
                o = off + 1 + data[off]
                sectionLen = ((data[o + 1] and &h0F) << 8) or data[o + 2]
                if pid = 0 and pmt < 0
                    q = o + 8
                    while q + 4 <= o + 3 + sectionLen - 4 and q + 4 <= p + 188
                        program = (data[q] << 8) or data[q + 1]
                        if program <> 0
                            pmt = ((data[q + 2] and &h1F) << 8) or data[q + 3]
                            exit while
                        end if
                        q = q + 4
                    end while
                else if pid = pmt and pmt >= 0
                    infoLen = ((data[o + 10] and &h0F) << 8) or data[o + 11]
                    q = o + 12 + infoLen
                    while q + 5 <= o + 3 + sectionLen - 4 and q + 5 <= p + 188
                        if data[q] = &h0F then return ((data[q + 1] and &h1F) << 8) or data[q + 2]
                        q = q + 5 + (((data[q + 3] and &h0F) << 8) or data[q + 4])
                    end while
                    return -1
                end if
            end if
        end if
        p = p + 188
    end while
    return -1
end function

' ---------------------------------------------------------------------------
' HTTP

function newTransfer(url as String) as Object
    x = CreateObject("roUrlTransfer")
    x.SetUrl(url)
    if LCase(Left(url, 6)) = "https:"
        x.SetCertificatesFile("common:/certs/ca-bundle.crt")
        x.InitClientCertificates()
    end if
    return x
end function

' { code, body, finalUrl, redirects }. finalUrl follows any Location headers
' (the provider redirects live playlists to an edge server, and its segment
' paths are relative to that server).
function fetchText(url as String) as Object
    result = { code: 0, body: "", finalUrl: url, redirects: 0 }
    x = newTransfer(url)
    port = CreateObject("roMessagePort")
    x.SetMessagePort(port)
    x.AsyncGetToString()
    ev = wait(20000, port)
    if ev = invalid or type(ev) <> "roUrlEvent"
        x.AsyncCancel()
        return result
    end if
    result.code = ev.GetResponseCode()
    result.body = ev.GetString()
    headers = ev.GetResponseHeadersArray()
    if type(headers) = "roArray"
        for each h in headers
            for each name in h
                if LCase(name) = "location"
                    result.finalUrl = resolveUrl(result.finalUrl, asString(h[name]))
                    result.redirects = result.redirects + 1
                end if
            end for
        end for
    end if
    return result
end function

' A playlist line against the playlist's URL: absolute, root-relative
' ("/hls/..."), or relative to its folder.
function resolveUrl(base as String, ref as String) as String
    lower = LCase(ref)
    if Left(lower, 7) = "http://" or Left(lower, 8) = "https://" then return ref
    schemeEnd = Instr(1, base, "://")
    if schemeEnd = 0 then return ref
    pathStart = Instr(schemeEnd + 3, base, "/")
    origin = base
    if pathStart > 0 then origin = Left(base, pathStart - 1)
    if Left(ref, 1) = "/" then return origin + ref
    noQuery = base.Split("?")[0]
    lastSlash = 0
    i = Instr(1, noQuery, "/")
    while i > 0
        lastSlash = i
        i = Instr(i + 1, noQuery, "/")
    end while
    if lastSlash <= schemeEnd + 2 then return origin + "/" + ref
    return Left(noQuery, lastSlash) + ref
end function

function textBytes(text as String) as Object
    b = CreateObject("roByteArray")
    b.FromAsciiString(text)
    return b
end function

sub sendStatus(s as Object, code as Integer)
    sendBody(s, code, "text/plain", textBytes(code.ToStr()))
end sub

sub sendBody(s as Object, code as Integer, contentType as String, body as Object)
    reason = "OK"
    if code = 404 then reason = "Not Found"
    if code = 502 then reason = "Bad Gateway"
    crlf = Chr(13) + Chr(10)
    head = "HTTP/1.1 " + code.ToStr() + " " + reason + crlf + "Content-Type: " + contentType + crlf + "Content-Length: " + body.Count().ToStr() + crlf + "Connection: close" + crlf + crlf
    sendAll(s, textBytes(head))
    sendAll(s, body)
end sub

' Writes all of it, waiting while the socket's buffer is full (up to 60 s).
sub sendAll(s as Object, data as Object)
    total = data.Count()
    sent = 0
    clock = CreateObject("roTimespan")
    while sent < total and clock.TotalMilliseconds() < 60000
        chunk = total - sent
        if chunk > 65536 then chunk = 65536
        n = s.send(data, sent, chunk)
        if n > 0
            sent = sent + n
        else if s.eAgain() or s.eWouldBlock() or s.eOK()
            sleep(5)
        else
            return
        end if
    end while
end sub
