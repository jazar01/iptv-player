sub init()
    m.video = m.top.FindNode("video")
    m.liveOverlay = m.top.FindNode("liveOverlay")
    m.channelName = m.top.FindNode("channelName")
    m.channelPos = m.top.FindNode("channelPos")
    m.nowTitle = m.top.FindNode("nowTitle")
    m.nowTime = m.top.FindNode("nowTime")
    m.progressTrack = m.top.FindNode("progressTrack")
    m.progressFill = m.top.FindNode("progressFill")
    m.nextLine = m.top.FindNode("nextLine")
    m.errorPanel = m.top.FindNode("errorPanel")
    m.errorMessage = m.top.FindNode("errorMessage")
    m.overlayTimer = m.top.FindNode("overlayTimer")
    m.saveTimer = m.top.FindNode("saveTimer")

    m.play = invalid
    m.programs = invalid
    m.finished = false

    m.video.ObserveField("state", "onVideoState")
    m.overlayTimer.ObserveField("fire", "hideOverlay")
    m.saveTimer.ObserveField("fire", "reportProgress")
    m.top.ObserveField("focusedChild", "onFocusedChild")
end sub

' The Video node needs focus for its own pause/seek controls.
sub onFocusedChild()
    if m.top.HasFocus() then m.video.SetFocus(true)
end sub

sub onContent()
    play = m.top.content
    reportProgress()        ' leaving the previous item, if any

    m.play = play
    m.programs = invalid
    m.finished = false
    m.errorPanel.visible = false
    m.video.control = "stop"

    c = CreateObject("roSGNode", "ContentNode")
    c.url = play.url
    c.title = asString(play.name)
    if asString(play.streamFormat) <> "" then c.streamFormat = play.streamFormat
    if play.kind = "live" then c.live = true
    if toInt(play.startPosition) > 0 then c.playStart = toInt(play.startPosition)
    m.video.content = c
    m.video.control = "play"

    ' Never print play.url: it contains the password.
    print "[player] "; play.kind; " "; play.id; " '"; play.name; "' from "; toInt(play.startPosition); " s"
    if play.kind = "live"
        m.saveTimer.control = "stop"
        showOverlay()
    else
        m.liveOverlay.visible = false
        m.saveTimer.control = "start"
    end if
end sub

sub onVideoState()
    state = m.video.state
    if m.play = invalid then return
    if state = "error"
        code = m.video.errorCode
        print "[player] error "; code; " "; asString(m.video.errorMsg); " / "; asString(m.video.errorStr)
        message = friendlyError(code)
        m.errorMessage.text = message
        m.errorPanel.visible = true
        m.liveOverlay.visible = false
        m.saveTimer.control = "stop"
        m.top.failed = { play: m.play, code: code, message: message }
    else if state = "finished" and m.play.kind <> "live"
        m.finished = true
        close()
    end if
end sub

sub onErrorText()
    m.errorMessage.text = m.top.errorText
end sub

' Video node error codes -> words a person can act on.
function friendlyError(code as Integer) as String
    if code = -5 then return "This video uses a format or codec your Roku can't play."
    if code = -4 then return "The stream is empty or offline right now."
    if code = -2 then return "The server took too long to send the video."
    if code = -1 then return "The stream couldn't be loaded. The server may be down, or the account's connection limit may be reached."
    if code = -6 then return "This video is protected and can't be played here."
    ' -3 is usually a playlist Roku can't parse: typically an event channel
    ' outside its event, which serves a placeholder instead of video.
    if code = -3 then return "This stream couldn't be read. The channel may be off the air right now (event channels only carry video during their event), or the provider sent something Roku can't play."
    return "Playback failed (error " + code.ToStr() + ")."
end function

sub reportProgress()
    if m.play = invalid or m.play.kind = "live" then return
    position = Int(m.video.position)
    duration = Int(m.video.duration)
    if duration <= 0 then duration = toInt(m.play.duration)
    m.top.progress = { play: m.play, position: position, duration: duration, finished: m.finished }
end sub

sub close()
    m.saveTimer.control = "stop"
    m.overlayTimer.control = "stop"
    reportProgress()
    m.video.control = "stop"
    m.play = invalid
    m.top.closed = true
end sub

' ---------------------------------------------------------------------------
' Live overlay: channel, current program with progress, next program.

sub onPrograms()
    entry = m.top.programs
    if m.play = invalid or m.play.kind <> "live" or asString(entry.streamId) <> asString(m.play.id) then return
    m.programs = entry
    if m.liveOverlay.visible then drawOverlay()
end sub

sub showOverlay()
    if m.play = invalid or m.play.kind <> "live" then return
    drawOverlay()
    m.liveOverlay.visible = not m.errorPanel.visible
    m.overlayTimer.control = "stop"
    m.overlayTimer.control = "start"
end sub

sub hideOverlay()
    m.liveOverlay.visible = false
end sub

sub drawOverlay()
    m.channelName.text = asString(m.play.name)
    m.channelPos.text = m.top.channelLabel
    now = nowSeconds()
    p = m.programs
    current = invalid
    upcoming = invalid
    if p <> invalid
        current = p.now
        upcoming = p.upcoming
    end if

    if type(current) = "roAssociativeArray" and current.ends > now
        m.nowTitle.text = current.title
        m.nowTime.text = formatClock(current.start) + " - " + formatClock(current.ends)
        fraction = (now - current.start) / (current.ends - current.start)
        if fraction < 0 then fraction = 0
        if fraction > 1 then fraction = 1
        m.progressFill.width = 1728 * fraction
        m.progressTrack.visible = true
        m.progressFill.visible = true
    else
        m.nowTitle.text = "No guide information"
        m.nowTime.text = ""
        m.progressTrack.visible = false
        m.progressFill.visible = false
    end if

    if type(upcoming) = "roAssociativeArray"
        m.nextLine.text = "Next  " + formatClock(upcoming.start) + "   " + upcoming.title
    else
        m.nextLine.text = ""
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "back"
        close()
        return true
    end if
    if m.play <> invalid and m.play.kind = "live"
        if key = "up"
            m.top.channelStep = 1
            return true
        else if key = "down"
            m.top.channelStep = -1
            return true
        else if key = "options" or key = "OK" or key = "info"
            showOverlay()
            return true
        end if
    end if
    return false
end function
