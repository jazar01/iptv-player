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
    m.pidFor = {}           ' relay key -> its audio PID (for a segment whose tables come late)
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
' /s/<key>/<number>.ts                a segment, audio fixed
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
        bits = Mid(p, 4).Split("/")
        if bits.Count() = 2
            serveSegment(s, bits[0], asString(m.segUrls[bits[1].Split(".")[0]]))
        else
            sendStatus(s, 404)
        end if
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
            out.Push("/s/" + key + "/" + segmentNumber(resolveUrl(r.finalUrl, l)) + ".ts")
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

' A segment, passed on while it downloads: the download goes to a temporary
' file, and whatever has arrived (in whole TS packets) is fixed and sent, so
' the player can start long before a one-minute archive segment is complete.
' Plain-http segments (the archive's edge server) are read straight off a
' socket as they arrive; roUrlTransfer (https, and any fallback) only
' writes its file at the end.
sub serveSegment(s as Object, key as String, url as String)
    if url = ""
        sendStatus(s, 404)
        return
    end if
    file = "tmp:/relay_segment.ts"
    DeleteFile(file)
    port = CreateObject("roMessagePort")
    src = invalid
    if LCase(Left(url, 7)) = "http://" then src = openPlainHttp(url, port)
    x = invalid
    if src = invalid
        x = newTransfer(url)
        x.SetMessagePort(port)
        x.AsyncGetToFile(file)
    end if
    fs = CreateObject("roFileSystem")
    fixer = { pid: -1, synced: false, skip: 0, have: 0, b3: 0, b4: 0, fixed: 0 }
    first = -1              ' where whole packets begin
    sent = 0                ' bytes of the file sent so far
    started = false         ' response headers sent
    done = false
    code = 0
    clock = CreateObject("roTimespan")
    firstSendMs = -1
    while true
        ev = wait(40, port)
        if src <> invalid
            pumpSocket(src, file)
            done = src.done
            code = 200
        else if ev <> invalid and type(ev) = "roUrlEvent"
            done = true
            code = ev.GetResponseCode()
        end if
        if done and code <> 200
            print "[relay] segment failed: HTTP "; code
            if not started then sendStatus(s, 502)
            exit while
        end if
        if not done and clock.TotalMilliseconds() > 120000
            print "[relay] segment timed out"
            if x <> invalid then x.AsyncCancel()
            exit while
        end if
        size = 0
        if src <> invalid
            size = src.written
        else
            info = fs.Stat(file)
            if type(info) = "roAssociativeArray" then size = toInt(info.size)
        end if
        if first < 0 and (size >= 2000 or (done and size > 0))
            first = packetStart(readBytes(file, 0, size))
            if first < 0 then first = -2    ' not MPEG-TS packets: passed on as is
        end if
        ' The audio stream's PID, from the start of the data (the tables
        ' come round several times a second).
        if first >= 0 and fixer.pid = -1
            fixer.pid = aacPid(readBytes(file, 0, size), first)
            if fixer.pid < 0
                fixer.pid = -1
                if done or size - first > 3000000
                    fixer.pid = -2      ' no AAC stream found: nothing to fix
                    known = m.pidFor[key]
                    if known <> invalid then fixer.pid = known
                end if
            else
                m.pidFor[key] = fixer.pid
            end if
        end if
        if first = -2 or (first >= 0 and fixer.pid <> -1)
            upto = size
            if not done and first >= 0 then upto = first + ((size - first) \ 188) * 188
            if upto > sent
                chunk = readBytes(file, sent, upto - sent)
                if fixer.pid >= 0
                    from = 0
                    if sent < first then from = first - sent
                    fixPackets(fixer, chunk, from)
                end if
                if not started
                    sendHead(s, 200, "video/mp2t", -1)
                    started = true
                    firstSendMs = clock.TotalMilliseconds()
                end if
                sendAll(s, chunk)
                sent = upto
            end if
        end if
        if done and sent >= size then exit while
    end while
    if src <> invalid then src.sock.close()
    DeleteFile(file)
    if started and not m.logged.DoesExist("seg" + Left(key, 1))
        m.logged["seg" + Left(key, 1)] = true
        how = "download"
        if src <> invalid then how = "socket"
        print "[relay] "; key; " first segment ("; how; "): "; sent; " bytes, sending began after "; firstSendMs; " ms, "; fixer.fixed; " audio headers fixed, done in "; clock.TotalMilliseconds(); " ms"
    end if
    if started and fixer.fixed = 0 and not m.logged.DoesExist("nofix")
        m.logged["nofix"] = true
        print "[relay] a segment had no audio headers to fix ("; sent; " bytes)"
    end if
end sub

' GET over a plain socket, so the body can be read as it arrives. Returns
' { sock, buf, written, length, done, idle } once a 200 response's headers
' are in, or invalid (redirect, error, chunked body, can't connect) to use
' roUrlTransfer instead.
function openPlainHttp(url as String, port as Object) as Dynamic
    rest = Mid(url, 8)
    slash = Instr(1, rest, "/")
    hostPort = rest
    path = "/"
    if slash > 0
        hostPort = Left(rest, slash - 1)
        path = Mid(rest, slash)
    end if
    host = hostPort
    portNumber = 80
    colon = Instr(1, hostPort, ":")
    if colon > 0
        host = Left(hostPort, colon - 1)
        portNumber = Val(Mid(hostPort, colon + 1), 10)
    end if
    addr = CreateObject("roSocketAddress")
    if not addr.setHostName(host) then return invalid
    addr.setPort(portNumber)
    sock = CreateObject("roStreamSocket")
    sock.setSendToAddress(addr)
    sock.connect()
    clock = CreateObject("roTimespan")
    while not sock.isConnected() and clock.TotalMilliseconds() < 5000
        sleep(10)
    end while
    if not sock.isConnected()
        print "[relay] socket fetch: couldn't connect; using a download"
        sock.close()
        return invalid
    end if
    crlf = Chr(13) + Chr(10)
    request = "GET " + path + " HTTP/1.1" + crlf + "Host: " + hostPort + crlf + "User-Agent: " + rokuUserAgent() + crlf + "Accept: */*" + crlf + "Connection: close" + crlf + crlf
    sendAll(sock, textBytes(request))

    ' Response headers, a byte at a time (a few hundred bytes).
    head = ""
    one = CreateObject("roByteArray")
    one[0] = 0
    clock.Mark()
    while Right(head, 4) <> crlf + crlf and Len(head) < 16384 and clock.TotalMilliseconds() < 10000
        if sock.getCountRcvBuf() > 0
            if sock.receive(one, 0, 1) = 1 then head = head + Chr(one[0])
        else if sock.isReadable()
            exit while      ' closed before the headers ended
        else
            sleep(5)
        end if
    end while
    status = 0
    firstLine = head.Split(crlf)[0]
    parts = firstLine.Split(" ")
    if parts.Count() >= 2 then status = Val(parts[1], 10)
    lower = LCase(head)
    if Right(head, 4) <> crlf + crlf or status <> 200 or Instr(1, lower, "transfer-encoding: chunked") > 0
        print "[relay] socket fetch: HTTP "; status; "; using a download"
        sock.close()
        return invalid
    end if
    length = -1
    found = CreateObject("roRegex", "content-length:\s*([0-9]+)", "").Match(lower)
    if found.Count() > 1 then length = Val(found[1], 10)
    buf = CreateObject("roByteArray")
    buf[65535] = 0
    sock.setMessagePort(port)
    sock.notifyReadable(true)
    return { sock: sock, buf: buf, written: 0, length: length, done: false, idle: CreateObject("roTimespan") }
end function

' Moves whatever has arrived on the socket to the end of the file.
sub pumpSocket(src as Object, file as String)
    if src.done then return
    n = src.sock.getCountRcvBuf()
    if n > 0
        while n > 0
            k = n
            if k > 65536 then k = 65536
            got = src.sock.receive(src.buf, 0, k)
            if got <= 0 then exit while
            src.buf.AppendFile(file, 0, got)
            src.written = src.written + got
            n = src.sock.getCountRcvBuf()
        end while
        src.idle.Mark()
    else if src.length < 0 and src.sock.isReadable()
        ' No length given: the body ends when the server closes. Roku can
        ' report "readable" with no data before more arrives, so only a
        ' read that returns nothing counts as closed.
        got = src.sock.receive(src.buf, 0, 1)
        if got = 1
            src.buf.AppendFile(file, 0, 1)
            src.written = src.written + 1
            src.idle.Mark()
        else if got = 0
            src.done = true
        end if
    end if
    if src.length >= 0 and src.written >= src.length then src.done = true
    if src.idle.TotalMilliseconds() > 30000
        print "[relay] socket fetch stalled"
        src.done = true
    end if
end sub

' Like roUrlTransfer's ("Roku/DVP-14.0 (...)"): the provider answers 404 to
' requests that don't look like they come from a Roku.
function rokuUserAgent() as String
    v = CreateObject("roDeviceInfo").GetOSVersion()
    return "Roku/DVP-" + asString(v.major) + "." + asString(v.minor) + " (" + asString(v.major) + "." + asString(v.minor) + "." + asString(v.revision) + "." + asString(v.build) + ")"
end function

function readBytes(file as String, start as Integer, length as Integer) as Object
    b = CreateObject("roByteArray")
    if length > 0 then b.ReadFile(file, start, length)
    return b
end function

' ---------------------------------------------------------------------------
' MPEG-TS: in the AAC (ADTS) stream, set each frame header's profile field
' from Main (0) to LC (1). Works on consecutive chunks of whole packets: the
' fixer carries the position in the current frame from one chunk to the
' next, and header bytes are judged as they go by (the profile is the third
' byte, fixed before the length bytes are even seen).
' fixer: { pid, synced, skip, have, b3, b4, fixed }

sub fixPackets(f as Object, data as Object, from as Integer)
    total = data.Count()
    pid = f.pid
    p = from
    while p + 188 <= total
        if data[p] = &h47 and (((data[p + 1] and &h1F) << 8) or data[p + 2]) = pid
            afc = (data[p + 3] >> 4) and 3
            if afc = 1 or afc = 3
                off = p + 4
                if afc = 3 then off = off + 1 + data[off]
                if (data[p + 1] and &h40) <> 0
                    ' A PES packet starts here, and with it a new frame.
                    off = off + 9 + data[off + 8]
                    f.synced = true
                    f.skip = 0
                    f.have = 0
                end if
                i = off
                stopAt = p + 188
                while f.synced and i < stopAt
                    if f.skip > 0
                        advance = stopAt - i
                        if f.skip < advance then advance = f.skip
                        i = i + advance
                        f.skip = f.skip - advance
                    else
                        b = data[i]
                        if f.have = 0
                            if b = &hFF then f.have = 1 else f.synced = false
                        else if f.have = 1
                            if (b and &hF6) = &hF0 then f.have = 2 else f.synced = false
                        else if f.have = 2
                            if (b and &hC0) = 0
                                data[i] = (b and &h3F) or &h40
                                f.fixed = f.fixed + 1
                            end if
                            f.have = 3
                        else if f.have = 3
                            f.b3 = b
                            f.have = 4
                        else if f.have = 4
                            f.b4 = b
                            f.have = 5
                        else
                            frameLen = ((f.b3 and 3) << 11) or (f.b4 << 3) or ((b >> 5) and 7)
                            f.have = 0
                            if frameLen < 7 then f.synced = false else f.skip = frameLen - 6
                        end if
                        i = i + 1
                    end if
                end while
            end if
        end if
        p = p + 188
    end while
end sub

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
    sendHead(s, code, contentType, body.Count())
    sendAll(s, body)
end sub

' length -1: no Content-Length (the body ends when the connection closes).
sub sendHead(s as Object, code as Integer, contentType as String, length as Integer)
    reason = "OK"
    if code = 404 then reason = "Not Found"
    if code = 502 then reason = "Bad Gateway"
    crlf = Chr(13) + Chr(10)
    head = "HTTP/1.1 " + code.ToStr() + " " + reason + crlf + "Content-Type: " + contentType + crlf
    if length >= 0 then head = head + "Content-Length: " + length.ToStr() + crlf
    head = head + "Connection: close" + crlf + crlf
    sendAll(s, textBytes(head))
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
