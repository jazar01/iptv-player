' Audio-fix relay (see StreamRelay.xml). One request at a time: the Video
' node asks for the playlist, then segments one after another. Segment
' downloads run in the background between requests (pumpAll), and are
' fixed as the bytes arrive, so a request can be answered from a download
' that is still going.

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
    m.pidFor = {}           ' stream ID -> its audio PID (live and archive share it)
    m.downloads = []        ' segment downloads, oldest first (see newDownload)
    m.nextFile = 1
    m.PARTS = 12            ' virtual parts per one-minute archive segment
    m.port = CreateObject("roMessagePort")
    m.top.ObserveField("add", m.port)
    m.conns = {}
    listener = startListening()
    if listener = invalid
        print "[relay] couldn't open a local port; audio fix unavailable"
        return
    end if
    while true
        msg = wait(30, m.port)
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
        pumpAll()
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
    lines = entry.buf.Split(crlf)
    parts = lines[0].Split(" ")
    path = ""
    if parts.Count() >= 2 then path = parts[1]
    ' Range: bytes=<from>-<to> (the split archive minute).
    range = invalid
    re = CreateObject("roRegex", "^range:\s*bytes=([0-9]+)-([0-9]*)", "i")
    for each l in lines
        found = re.Match(l)
        if found.Count() > 2
            range = { from: Val(found[1], 10), upto: -1 }
            if found[2] <> "" then range.upto = Val(found[2], 10)
        end if
    end for
    serve(s, path, range)
    s.close()
    m.conns.Delete(key)
end sub

' /p/<key>.m3u8                       live playlist
' /t/<key>/<duration>/<start>.m3u8    archive playlist
' /s/<key>/<number>.ts                a segment, audio fixed
' /v/<key>/<number>/<part>.ts         part of an archive segment (see servePlaylist)
sub serve(s as Object, path as String, range as Dynamic)
    p = path.Split("?")[0]
    if Left(p, 3) = "/p/" and Right(p, 5) = ".m3u8"
        key = Mid(p, 4, Len(p) - 8)
        dropDownloads("t")      ' back to live: archive downloads aren't needed
        servePlaylist(s, asString(m.urls[key]), key)
    else if Left(p, 3) = "/t/" and Right(p, 5) = ".m3u8"
        bits = Mid(p, 4, Len(p) - 8).Split("/")
        template = ""
        if bits.Count() = 3 then template = asString(m.urls[bits[0]])
        url = ""
        if template <> "" then url = template.Replace("{duration}", bits[1]).Replace("{start}", bits[2])
        dropDownloads("")       ' a new archive point: earlier downloads are stale
        servePlaylist(s, url, bits[0])
    else if Left(p, 3) = "/v/"
        bits = Mid(p, 4).Split("/")
        if bits.Count() = 3
            servePart(s, bits[0], asString(m.segUrls[bits[1]]), Val(bits[2].Split(".")[0], 10))
        else
            sendStatus(s, 404)
        end if
    else if Left(p, 3) = "/s/"
        bits = Mid(p, 4).Split("/")
        if bits.Count() = 2
            serveSegment(s, bits[0], asString(m.segUrls[bits[1].Split(".")[0]]), range)
        else
            sendStatus(s, 404)
        end if
    else
        sendStatus(s, 404)
    end if
end sub

' ---------------------------------------------------------------------------
' Playlists

' Live: segments pointed at the relay. Archive: each one-minute segment
' (about 20 MB) is listed as PARTS virtual segments of a few seconds
' (/v/<key>/<number>/<part>.ts), and the target duration lowered to match,
' so the player starts after the first part instead of a whole minute. The
' relay still downloads each minute once and serves the parts from it.
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
    archive = (Left(key, 1) = "t")
    count = m.PARTS
    longest = 0
    out = []
    for each line in r.body.Split(Chr(10))
        l = line.Trim()
        if l = "" or Left(l, 1) = "#"
            out.Push(l)
        else
            number = segmentNumber(resolveUrl(r.finalUrl, l))
            last = out.Count() - 1
            if archive and last >= 0 and Left(out[last], 8) = "#EXTINF:"
                seconds = Val(out[last].Mid(8).Split(",")[0])
                out.Pop()
                partMs = Int(seconds * 1000 / count)
                if partMs > longest then longest = partMs
                duration = (partMs \ 1000).ToStr() + "." + Right("00" + (partMs mod 1000).ToStr(), 3)
                for p = 0 to count - 1
                    out.Push("#EXTINF:" + duration + ",")
                    out.Push("/v/" + key + "/" + number + "/" + p.ToStr() + ".ts")
                end for
            else
                out.Push("/s/" + key + "/" + number + ".ts")
            end if
        end if
    end for
    text = out.Join(Chr(10))
    if longest > 0
        target = (longest + 999) \ 1000
        text = CreateObject("roRegex", "#EXT-X-TARGETDURATION:[0-9]+", "").Replace(text, "#EXT-X-TARGETDURATION:" + target.ToStr())
        if not m.logged.DoesExist("split")
            m.logged["split"] = true
            print "[relay] "; key; " archive minutes split into "; count; " parts of about "; target; " s"
        end if
    end if
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

' ---------------------------------------------------------------------------
' Segments

' The whole segment, or the requested byte range, sent as the download
' (already running, or started now) gets that far.
sub serveSegment(s as Object, key as String, url as String, range as Dynamic)
    if url = ""
        sendStatus(s, 404)
        return
    end if
    d = findDownload(url)
    if d = invalid then d = newDownload(key, url)
    sentTo = 0
    last = -1               ' last byte to send (-1: to the end)
    if range <> invalid and d.length > 0
        sentTo = range.from
        last = d.length - 1
        if range.upto >= 0 and range.upto < last then last = range.upto
    end if
    started = false
    clock = CreateObject("roTimespan")
    while clock.TotalMilliseconds() < 120000
        pumpDownload(d)
        if d.failed and not started
            sendStatus(s, 502)
            return
        end if
        available = d.ready
        if last >= 0 and available > last + 1 then available = last + 1
        if available > sentTo
            if not started
                started = true
                if last >= 0 and range <> invalid and isTrue(range.whole)
                    sendHead(s, 200, "video/mp2t", last - sentTo + 1)     ' a virtual part: a whole file to the player
                else if last >= 0
                    sendRangeHead(s, sentTo, last, d.length)
                else
                    sendHead(s, 200, "video/mp2t", d.length)
                end if
            end if
            sendAll(s, readBytes(d.out, sentTo, available - sentTo))
            sentTo = available
        end if
        if last >= 0 and sentTo > last then exit while
        if d.done and sentTo >= d.ready then exit while
        if d.failed then exit while
        if available <= sentTo then sleep(10)
    end while
    if not m.logged.DoesExist("seg" + Left(key, 1)) and d.done
        m.logged["seg" + Left(key, 1)] = true
        print "[relay] "; key; " first segment: "; d.ready; " bytes, "; d.fixer.fixed; " audio headers fixed"
    end if
end sub

' One of the PARTS pieces of an archive segment: bytes cut at whole packets
' in proportion to the segment's size (known once its download has the
' response headers). Without a size (not plain http), part 0 is the whole
' segment and the others are empty.
sub servePart(s as Object, key as String, url as String, part as Integer)
    if url = ""
        sendStatus(s, 404)
        return
    end if
    d = findDownload(url)
    if d = invalid then d = newDownload(key, url)
    clock = CreateObject("roTimespan")
    while d.align = -1 and not d.done and clock.TotalMilliseconds() < 5000
        pumpDownload(d)
        sleep(5)
    end while
    if d.length <= 0
        if part = 0
            serveSegment(s, key, url, invalid)
        else
            sendBody(s, 200, "video/mp2t", CreateObject("roByteArray"))
        end if
        return
    end if
    first = d.align
    if first < 0 then first = 0
    startAt = partBoundary(d.length, first, part)
    endAt = partBoundary(d.length, first, part + 1)
    if endAt <= startAt
        sendBody(s, 200, "video/mp2t", CreateObject("roByteArray"))
        return
    end if
    serveSegment(s, key, url, { from: startAt, upto: endAt - 1, whole: true })
end sub

' Where part k begins: 0 for the first, the size after the last, and
' otherwise a whole packet in proportion.
function partBoundary(length as Integer, first as Integer, k as Integer) as Integer
    if k <= 0 then return 0
    if k >= m.PARTS then return length
    return first + ((Int((length - first) / m.PARTS * k)) \ 188) * 188
end function

' A segment download: plain http is read off a socket as it arrives (the
' archive's edge server); anything else through roUrlTransfer, which only
' has the file at the end. Either way the fixed bytes go to `out`, and
' `ready` says how much of it can be served.
function newDownload(key as String, url as String) as Object
    while m.downloads.Count() >= 2      ' archive segments are ~20 MB each in tmp:
        closeDownload(m.downloads.Shift())
    end while
    streamId = Mid(key, 2)
    fixer = { pid: -1, pmt: -1, synced: false, skip: 0, have: 0, b3: 0, b4: 0, fixed: 0 }
    known = m.pidFor[streamId]
    if known <> invalid then fixer.pid = known
    d = {
        key: key
        streamId: streamId
        url: url
        out: "tmp:/relay_" + m.nextFile.ToStr() + ".ts"
        raw: "tmp:/relay_" + m.nextFile.ToStr() + "_raw.ts"
        ready: 0            ' bytes of `out` that can be served
        length: -1          ' the segment's size, when the server says
        align: -1           ' where whole TS packets begin (-2: not TS)
        done: false
        failed: false
        fixer: fixer
        src: invalid        ' socket source (openPlainHttp)
        xfer: invalid       ' roUrlTransfer source
        port: invalid
        buf: invalid        ' socket: received bytes not yet written
        pend: 0
    }
    m.nextFile = m.nextFile + 1
    DeleteFile(d.out)
    if LCase(Left(url, 7)) = "http://" then d.src = openPlainHttp(url)
    if d.src <> invalid
        d.length = d.src.length
        d.buf = CreateObject("roByteArray")
        d.buf[65536 + 188] = 0
    else
        DeleteFile(d.raw)
        d.port = CreateObject("roMessagePort")
        d.xfer = newTransfer(url)
        d.xfer.SetMessagePort(d.port)
        d.xfer.AsyncGetToFile(d.raw)
    end if
    m.downloads.Push(d)
    return d
end function

function findDownload(url as String) as Dynamic
    for each d in m.downloads
        if d.url = url then return d
    end for
    return invalid
end function

sub pumpAll()
    for each d in m.downloads
        if not d.done then pumpDownload(d)
    end for
end sub

' prefix: drop downloads whose key starts with it ("" for all).
sub dropDownloads(prefix as String)
    kept = []
    for each d in m.downloads
        if prefix = "" or Left(d.key, Len(prefix)) = prefix then closeDownload(d) else kept.Push(d)
    end for
    m.downloads = kept
end sub

sub closeDownload(d as Object)
    if d.src <> invalid then d.src.sock.close()
    if d.xfer <> invalid and not d.done then d.xfer.AsyncCancel()
    DeleteFile(d.out)
    DeleteFile(d.raw)
end sub

sub pumpDownload(d as Object)
    if d.done then return
    if d.src <> invalid
        pumpSocketDownload(d)
    else
        ev = d.port.GetMessage()
        if ev <> invalid and type(ev) = "roUrlEvent"
            if ev.GetResponseCode() <> 200
                print "[relay] segment failed: HTTP "; ev.GetResponseCode()
                d.failed = true
                d.done = true
                return
            end if
            ' The whole file at once: fix it and make it the output.
            data = CreateObject("roByteArray")
            data.ReadFile(d.raw)
            DeleteFile(d.raw)
            d.align = packetStart(data, data.Count())
            if d.align >= 0 then fixPackets(d, data, d.align, data.Count())
            data.WriteFile(d.out)
            d.length = data.Count()
            d.ready = d.length
            d.done = true
        end if
    end if
end sub

' Reads what has arrived into d.buf after any partial packet left from last
' time, fixes the whole packets and appends them to the output; the partial
' packet at the end (under 188 bytes) moves to the front for next time.
sub pumpSocketDownload(d as Object)
    src = d.src
    n = src.sock.getCountRcvBuf()
    closed = false
    if n > 0
        room = 65536 + 188 - d.pend
        if n > room then n = room
        got = src.sock.receive(d.buf, d.pend, n)
        if got > 0
            d.pend = d.pend + got
            src.written = src.written + got
            src.idle.Mark()
        end if
    else if src.length < 0 and src.sock.isReadable()
        ' No length given: only a read that returns nothing means closed
        ' (Roku can say "readable" before more data arrives).
        got = src.sock.receive(d.buf, d.pend, 1)
        if got = 1
            d.pend = d.pend + 1
            src.written = src.written + 1
        else if got = 0
            closed = true
        end if
    end if
    finished = closed or (src.length >= 0 and src.written >= src.length)
    if not finished and src.idle.TotalMilliseconds() > 30000
        print "[relay] socket download stalled"
        finished = true
    end if

    if d.align = -1 and (d.pend >= 564 or finished)
        d.align = packetStart(d.buf, d.pend)
        if d.align < 0 then d.align = -2
        if d.align > 0
            ' Bytes before the first whole packet go out as they are.
            d.buf.AppendFile(d.out, 0, d.align)
            d.ready = d.ready + d.align
            shiftBuffer(d, d.align)
        end if
    end if
    if d.align <> -1 and d.pend > 0
        whole = d.pend
        if d.align >= 0 and not finished then whole = (d.pend \ 188) * 188
        if whole > 0
            if d.align >= 0 then fixPackets(d, d.buf, 0, whole)
            d.buf.AppendFile(d.out, 0, whole)
            d.ready = d.ready + whole
            shiftBuffer(d, whole)
        end if
    end if
    if finished
        d.done = true
        src.sock.close()
    end if
end sub

' Drops the first `count` pending bytes (the rest is under 188 bytes, or
' a buffer's worth only right after the alignment step).
sub shiftBuffer(d as Object, count as Integer)
    rest = d.pend - count
    for i = 0 to rest - 1
        d.buf[i] = d.buf[count + i]
    end for
    d.pend = rest
end sub

' GET over a plain socket, so the body can be read as it arrives. Returns
' { sock, written, length, idle } once a 200 response's headers are in, or
' invalid (redirect, error, chunked body, can't connect) to use
' roUrlTransfer instead.
function openPlainHttp(url as String) as Dynamic
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
    return { sock: sock, written: 0, length: length, idle: CreateObject("roTimespan") }
end function

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
' from Main (0) to LC (1). Works on consecutive runs of whole packets: the
' fixer carries the position in the current frame from one run to the
' next, and header bytes are judged as they go by (the profile is the third
' byte, fixed before the length bytes are even seen). The audio PID comes
' from the PAT and PMT as they pass, or from the stream's earlier segments.
' d.fixer: { pid, pmt, synced, skip, have, b3, b4, fixed }

sub fixPackets(d as Object, data as Object, from as Integer, upto as Integer)
    f = d.fixer
    p = from
    while p + 188 <= upto
        if data[p] = &h47
            pid = ((data[p + 1] and &h1F) << 8) or data[p + 2]
            afc = (data[p + 3] >> 4) and 3
            pusi = (data[p + 1] and &h40) <> 0
            if (afc = 1 or afc = 3) and pid = f.pid and f.pid >= 0
                off = p + 4
                if afc = 3 then off = off + 1 + data[off]
                if pusi
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
            else if pusi and (afc = 1 or afc = 3) and (pid = 0 or pid = f.pmt)
                readTables(d, data, p, pid, afc)
            end if
        end if
        p = p + 188
    end while
end sub

' PAT (PID 0) -> the PMT's PID; PMT -> the first ADTS AAC stream (type 0x0F).
sub readTables(d as Object, data as Object, p as Integer, pid as Integer, afc as Integer)
    f = d.fixer
    off = p + 4
    if afc = 3 then off = off + 1 + data[off]
    if off >= p + 180 then return
    o = off + 1 + data[off]
    if o + 12 > p + 188 then return
    sectionLen = ((data[o + 1] and &h0F) << 8) or data[o + 2]
    tableEnd = o + 3 + sectionLen - 4
    if tableEnd > p + 188 then tableEnd = p + 188
    if pid = 0
        q = o + 8
        while q + 4 <= tableEnd
            program = (data[q] << 8) or data[q + 1]
            if program <> 0
                f.pmt = ((data[q + 2] and &h1F) << 8) or data[q + 3]
                return
            end if
            q = q + 4
        end while
    else
        infoLen = ((data[o + 10] and &h0F) << 8) or data[o + 11]
        q = o + 12 + infoLen
        while q + 5 <= tableEnd
            if data[q] = &h0F
                audio = ((data[q + 1] and &h1F) << 8) or data[q + 2]
                if f.pid <> audio
                    f.pid = audio
                    f.synced = false
                    m.pidFor[d.streamId] = audio
                end if
                return
            end if
            q = q + 5 + (((data[q + 3] and &h0F) << 8) or data[q + 4])
        end while
    end if
end sub

' Where whole TS packets begin among the first `count` bytes: live segments
' start with one, but archive segments are cut from a recording at any byte
' (one began at byte 87). -1 if not found.
function packetStart(data as Object, count as Integer) as Integer
    for k = 0 to 187
        if k + 376 < count
            if data[k] = &h47 and data[k + 188] = &h47 and data[k + 376] = &h47 then return k
        end if
    end for
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

sub sendRangeHead(s as Object, first as Integer, last as Integer, total as Integer)
    crlf = Chr(13) + Chr(10)
    length = last - first + 1
    head = "HTTP/1.1 206 Partial Content" + crlf + "Content-Type: video/mp2t" + crlf + "Content-Range: bytes " + first.ToStr() + "-" + last.ToStr() + "/" + total.ToStr() + crlf + "Content-Length: " + length.ToStr() + crlf + "Connection: close" + crlf + crlf
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
