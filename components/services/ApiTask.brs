sub init()
    m.top.functionName = "runLoop"
end sub

' Runs for the life of the app. Requests set while one is in flight queue up
' on the port and are handled in order.
sub runLoop()
    port = CreateObject("roMessagePort")
    m.top.ObserveField("request", port)
    while true
        msg = wait(0, port)
        if type(msg) = "roSGNodeEvent"
            req = msg.GetData()
            if type(req) = "roAssociativeArray" then m.top.response = handleRequest(req)
        end if
    end while
end sub

function handleRequest(req as Object) as Object
    res = { id: asString(req.id), action: asString(req.action), ok: false, code: 0, error: "", data: invalid, ms: 0 }

    url = asString(req.url)
    if url = "" then url = xtreamUrl(m.top.credentials, res.action, req.params)
    if url = ""
        res.error = "No server configured"
        return res
    end if

    timeoutMs = toInt(req.timeoutMs)
    if timeoutMs <= 0 then timeoutMs = 15000
    backoffMs = [0, 500, 1500]
    timer = CreateObject("roTimespan")

    for attempt = 1 to backoffMs.Count()
        if backoffMs[attempt - 1] > 0
            print "[api] "; res.id; " retry "; attempt; " after "; res.error
            sleep(backoffMs[attempt - 1])
        end if

        http = httpGet(url, timeoutMs)
        res.code = http.code
        res.error = http.error
        if http.ok
            data = invalid
            if http.body.Trim() <> "" then data = ParseJson(http.body)
            if data = invalid
                res.error = "Server returned something other than JSON"
            else
                res.ok = true
                res.error = ""
                res.data = data
            end if
            exit for
        end if
        if not http.retryable then exit for
    end for

    res.ms = timer.TotalMilliseconds()
    if res.ok
        print "[api] "; res.id; " ok ("; res.ms; " ms)"
    else
        print "[api] "; res.id; " FAILED code="; res.code; " "; res.error; " ("; res.ms; " ms)"
    end if
    return res
end function

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

function httpGet(url as String, timeoutMs as Integer) as Object
    port = CreateObject("roMessagePort")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetMessagePort(port)
    xfer.SetUrl(url)
    xfer.EnableEncodings(true)
    xfer.RetainBodyOnError(true)
    if LCase(Left(url, 6)) = "https:"
        xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
        xfer.InitClientCertificates()
    end if

    if not xfer.AsyncGetToString()
        return { ok: false, code: 0, body: "", error: "Could not start request", retryable: true }
    end if

    msg = wait(timeoutMs, port)
    if type(msg) <> "roUrlEvent"
        xfer.AsyncCancel()
        return { ok: false, code: 0, body: "", error: "Timed out", retryable: true }
    end if

    code = msg.GetResponseCode()
    if code = 200 then return { ok: true, code: code, body: msg.GetString(), error: "", retryable: false }

    ' Negative codes are network/curl failures; the failure reason says which.
    err = msg.GetFailureReason()
    if code > 0 then err = "HTTP " + code.ToStr()
    return { ok: false, code: code, body: "", error: err, retryable: (code <= 0 or code >= 500) }
end function
