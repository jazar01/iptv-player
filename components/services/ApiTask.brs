sub init()
    m.top.functionName = "runLoop"
end sub

' Runs for the life of the app. Up to m.maxActive transfers run at once; the
' rest wait in m.queue. Retries are re-queued with a delay rather than
' sleeping, so other requests keep moving.
sub runLoop()
    m.port = CreateObject("roMessagePort")
    m.clock = CreateObject("roTimespan")
    m.queue = []
    m.active = {}       ' transfer identity -> job
    m.maxActive = 4
    m.top.ObserveField("request", m.port)
    ' Requests set before this point are lost, so callers wait for `ready`.
    m.top.ready = true

    while true
        startQueued()
        msg = wait(waitMs(), m.port)
        t = type(msg)
        if t = "roSGNodeEvent"
            req = msg.GetData()
            if type(req) = "roAssociativeArray" then accept(req)
        else if t = "roUrlEvent"
            onUrlEvent(msg)
        end if
        expireTimeouts()
    end while
end sub

sub accept(req as Object)
    if asString(req.op) = "clearCache"
        clearCache()
        res = newResponse(req)
        res.ok = true
        m.top.response = res
        return
    end if

    if not safeCachePath(asString(req.cacheFile))
        res = newResponse(req)
        res.error = "Bad cache path"
        m.top.response = res
        return
    end if

    url = asString(req.url)
    if url = "" then url = xtreamUrl(m.top.credentials, asString(req.action), req.params)
    if url = ""
        res = newResponse(req)
        res.error = "No server configured"
        m.top.response = res
        return
    end if

    ' Fresh enough on disk: answer without the network.
    if asString(req.cacheFile) <> "" and toInt(req.maxAgeSeconds) > 0
        age = cacheAgeSeconds(req.cacheFile)
        if age >= 0 and age < toInt(req.maxAgeSeconds)
            hit = newResponse(req)
            hit.ok = true
            hit.fromCache = true
            if not isTrue(req.saveOnly) then hit.data = ParseJson(readCacheText(req.cacheFile))
            m.top.response = hit
            return
        end if
    end if

    ' Cache-first: answer from cachefs: now, then again when the fresh copy
    ' arrives (or with unchanged=true if it's identical).
    cachedText = ""
    if asString(req.cacheFile) <> "" and isTrue(req.cacheFirst)
        cachedText = readCacheText(req.cacheFile)
        data = invalid
        if cachedText <> "" then data = ParseJson(cachedText)
        if data <> invalid
            hit = newResponse(req)
            hit.ok = true
            hit.data = data
            hit.fromCache = true
            m.top.response = hit
        else
            cachedText = ""
        end if
    end if

    timeoutMs = toInt(req.timeoutMs)
    if timeoutMs <= 0 then timeoutMs = 15000
    m.queue.Push({
        req: req
        url: url
        attempt: 1
        notBefore: 0
        timeoutMs: timeoutMs
        deadline: 0
        started: m.clock.TotalMilliseconds()
        cachedText: cachedText
        xfer: invalid
    })
end sub

function newResponse(req as Object) as Object
    return {
        id: asString(req.id)
        action: asString(req.action)
        context: req.context
        ok: false
        code: 0
        error: ""
        data: invalid
        fromCache: false
        unchanged: false
        ms: 0
    }
end function

sub startQueued()
    now = m.clock.TotalMilliseconds()
    i = 0
    while i < m.queue.Count() and m.active.Count() < m.maxActive
        job = m.queue[i]
        if job.notBefore <= now
            m.queue.Delete(i)
            startJob(job)
        else
            i = i + 1
        end if
    end while
end sub

sub startJob(job as Object)
    xfer = CreateObject("roUrlTransfer")
    xfer.SetMessagePort(m.port)
    xfer.SetUrl(job.url)
    xfer.EnableEncodings(true)
    xfer.RetainBodyOnError(true)
    if LCase(Left(job.url, 6)) = "https:"
        xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
        xfer.InitClientCertificates()
    end if

    if not xfer.AsyncGetToString()
        finishJob(job, { ok: false, code: 0, body: "", error: "Could not start request", retryable: true })
        return
    end if
    job.xfer = xfer
    job.deadline = m.clock.TotalMilliseconds() + job.timeoutMs
    m.active[xfer.GetIdentity().ToStr()] = job
end sub

sub onUrlEvent(msg as Object)
    if msg.GetInt() <> 1 then return     ' 1 = transfer complete
    key = msg.GetSourceIdentity().ToStr()
    job = m.active[key]
    if job = invalid then return
    m.active.Delete(key)

    code = msg.GetResponseCode()
    if code = 200
        finishJob(job, { ok: true, code: code, body: msg.GetString(), error: "", retryable: false })
        return
    end if
    ' Negative codes are network/curl failures; the failure reason says which.
    err = redact(msg.GetFailureReason())     ' may quote the URL, which holds the password
    if code > 0 then err = "HTTP " + code.ToStr()
    finishJob(job, { ok: false, code: code, body: "", error: err, retryable: (code <= 0 or code >= 500) })
end sub

sub expireTimeouts()
    now = m.clock.TotalMilliseconds()
    for each key in m.active.Keys()
        job = m.active[key]
        if now >= job.deadline
            job.xfer.AsyncCancel()
            m.active.Delete(key)
            finishJob(job, { ok: false, code: 0, body: "", error: "Timed out", retryable: true })
        end if
    end for
end sub

' Block until the next request when idle; poll while transfers or delayed
' retries are pending so timeouts and retries are noticed.
function waitMs() as Integer
    if m.queue.Count() = 0 and m.active.Count() = 0 then return 0
    return 100
end function

sub finishJob(job as Object, http as Object)
    res = newResponse(job.req)
    res.code = http.code
    res.error = http.error

    if http.ok and isTrue(job.req.saveOnly)
        ' Large lists (the search catalog): write to disk, don't parse here or
        ' send the data across threads. A whole JSON array or object (both
        ' ends present, so a cut-off download is caught) is all we check;
        ' SearchTask parses it and drops the file if it doesn't parse.
        body = http.body.Trim()
        first = Left(body, 1)
        last = Right(body, 1)
        if not ((first = "[" and last = "]") or (first = "{" and last = "}"))
            res.error = "Server returned incomplete or non-JSON data"
        else if asString(job.req.cacheFile) = "" or not writeCacheText(job.req.cacheFile, http.body)
            res.error = "Couldn't save the download (storage full?)"
        else
            res.ok = true
            res.error = ""
        end if
    else if http.ok
        if job.cachedText <> "" and http.body = job.cachedText
            res.ok = true
            res.error = ""
            res.unchanged = true
        else
            data = invalid
            if http.body.Trim() <> "" then data = ParseJson(http.body)
            if data = invalid
                res.error = "Server returned something other than JSON"
            else
                res.ok = true
                res.error = ""
                res.data = data
                if asString(job.req.cacheFile) <> "" then writeCacheText(job.req.cacheFile, http.body)
            end if
        end if
    else if http.retryable and job.attempt < 3
        backoffMs = [500, 1500]
        print "[api] "; res.id; " retry "; job.attempt + 1; " after "; http.error
        job.notBefore = m.clock.TotalMilliseconds() + backoffMs[job.attempt - 1]
        job.attempt = job.attempt + 1
        job.xfer = invalid
        m.queue.Push(job)
        return
    end if

    res.ms = m.clock.TotalMilliseconds() - job.started
    if res.ok
        note = ""
        if res.unchanged then note = ", unchanged"
        print "[api] "; res.id; " ok ("; res.ms; " ms"; note; ")"
    else
        print "[api] "; res.id; " FAILED code="; res.code; " "; res.error; " ("; res.ms; " ms)"
    end if
    m.top.response = res
end sub

' {server}/player_api.php?username=..&password=..[&action=..][&k=v...]
' Never print the result: it contains the password.
function xtreamUrl(creds as Dynamic, action as String, params as Dynamic) as String
    if type(creds) <> "roAssociativeArray" or asString(creds.server) = "" then return ""
    x = CreateObject("roUrlTransfer")
    url = creds.server + "/player_api.php?username=" + x.Escape(asString(creds.username)) + "&password=" + x.Escape(asString(creds.password))
    if action <> "" then url += "&action=" + x.Escape(action)
    if type(params) = "roAssociativeArray"
        for each key in params
            url += "&" + x.Escape(key) + "=" + x.Escape(asString(params[key]))
        end for
    end if
    return url
end function

' ---------------------------------------------------------------------------
' cachefs: holds only re-downloadable data (the catalog). The OS may clear it
' at any time; callers always fetch fresh after a cache hit.

function readCacheText(path as String) as String
    if not CreateObject("roFileSystem").Exists(path) then return ""
    return ReadAsciiFile(path)
end function

' Written to a temporary file and then renamed, so a reader never sees half
' a file; the age stamp is written last, so a failed write never looks
' fresh. Returns false if it couldn't be saved.
function writeCacheText(path as String, text as String) as Boolean
    slash = 0
    p = Instr(1, path, "/")
    while p > 0
        slash = p
        p = Instr(p + 1, path, "/")
    end while
    if slash > 0 then CreateDirectory(Left(path, slash - 1))
    fs = CreateObject("roFileSystem")
    if fs.Exists(path + ".time") then fs.Delete(path + ".time")
    temp = path + ".part"
    ok = WriteAsciiFile(temp, text)
    if ok
        if fs.Exists(path) then fs.Delete(path)
        ok = fs.Rename(temp, path)
    end if
    if not ok
        if fs.Exists(temp) then fs.Delete(temp)
        print "[api] could not write cache "; path
        return false
    end if
    ' Sidecar with the write time, for maxAgeSeconds.
    WriteAsciiFile(path + ".time", nowSeconds().ToStr())
    return true
end function

' Cache files live under cachefs:/ only, with no ".." in the path.
function safeCachePath(path as String) as Boolean
    if path = "" then return true
    return Left(path, 9) = "cachefs:/" and Instr(1, path, "..") = 0
end function

' Seconds since the cache file was written, or -1 if unknown.
function cacheAgeSeconds(path as String) as Integer
    fs = CreateObject("roFileSystem")
    if not fs.Exists(path) or not fs.Exists(path + ".time") then return -1
    written = Val(ReadAsciiFile(path + ".time"), 10)
    if written <= 0 then return -1
    return nowSeconds() - written
end function

sub clearCache()
    fs = CreateObject("roFileSystem")
    dir = "cachefs:/catalog"
    if not fs.Exists(dir) then return
    for each name in fs.GetDirectoryListing(dir)
        fs.Delete(dir + "/" + name)
    end for
    print "[api] catalog cache cleared"
end sub
