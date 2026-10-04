sub init()
    m.video = m.top.FindNode("video")
    m.liveOverlay = m.top.FindNode("liveOverlay")
    m.modeLine = m.top.FindNode("modeLine")
    m.channelName = m.top.FindNode("channelName")
    m.channelPos = m.top.FindNode("channelPos")
    m.nowTitle = m.top.FindNode("nowTitle")
    m.nowTime = m.top.FindNode("nowTime")
    m.progressTrack = m.top.FindNode("progressTrack")
    m.progressFill = m.top.FindNode("progressFill")
    m.nextLine = m.top.FindNode("nextLine")
    m.hints = m.top.FindNode("hints")
    m.errorPanel = m.top.FindNode("errorPanel")
    m.errorMessage = m.top.FindNode("errorMessage")
    m.overlayTimer = m.top.FindNode("overlayTimer")
    m.saveTimer = m.top.FindNode("saveTimer")
    m.timeshiftTimeout = m.top.FindNode("timeshiftTimeout")
    m.timeshiftTimeout.ObserveField("fire", "onTimeshiftTimeout")
    m.viewedTimer = m.top.FindNode("viewedTimer")
    m.viewedTimer.ObserveField("fire", "onViewed")

    m.play = invalid
    m.programs = invalid
    m.finished = false
    m.mode = ""             ' "live" | "paused" | "timeshift" | "vod"
    m.note = ""             ' one-off message on the live overlay

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

    ' Never print play.url: it contains the password.
    print "[player] "; play.kind; " "; play.id; " '"; play.name; "' from "; toInt(play.startPosition); " s"
    m.viewedTimer.control = "stop"
    if play.kind = "live"
        m.saveTimer.control = "stop"
        m.viewedTimer.control = "start"     ' restarts on every channel change
        startLive()
    else
        m.mode = "vod"
        m.liveOverlay.visible = false
        ' The Video node's own controls: pause, rewind, fast-forward, seek.
        m.video.enableTrickPlay = true
        loadVideo(play.url, asString(play.streamFormat), false, toInt(play.startPosition))
        m.saveTimer.control = "start"
    end if
end sub

sub loadVideo(url as String, streamFormat as String, live as Boolean, playStart as Integer)
    m.video.control = "stop"
    c = CreateObject("roSGNode", "ContentNode")
    c.url = url
    c.title = asString(m.play.name)
    if streamFormat <> "" then c.streamFormat = streamFormat
    if live then c.live = true
    if playStart > 0 then c.playStart = playStart
    m.video.content = c
    m.video.control = "play"
end sub

sub onVideoState()
    state = m.video.state
    if m.play = invalid then return

    if m.mode = "timeshift"
        if state = "playing" and not m.tsConfirmed
            m.tsConfirmed = true
            m.timeshiftTimeout.control = "stop"
        else if state = "error"
            timeshiftFailed(m.video.errorCode.ToStr() + " " + asString(m.video.errorMsg) + " / " + asString(m.video.errorStr))
        else if state = "finished"
            ' End of this archive stretch. If more has been recorded since,
            ' load the next stretch from here; at the archive's edge, rejoin live.
            played = Int(m.video.position)
            reached = m.tsStart + played
            if not m.tsConfirmed
                timeshiftFailed("ended without playing")
            else if played > 5 and archiveEdge() - reached >= 60
                startTimeshift(reached, 0)
            else
                startLive()
            end if
        end if
        return
    end if

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

sub onViewed()
    if m.play = invalid or m.play.kind <> "live" then return
    m.top.liveViewed = { streamId: m.play.id, name: m.play.name, epgChannelId: asString(m.play.epgChannelId) }
end sub

sub close()
    m.saveTimer.control = "stop"
    m.overlayTimer.control = "stop"
    m.viewedTimer.control = "stop"
    reportProgress()
    m.video.control = "stop"
    m.play = invalid
    m.top.closed = true
end sub

' ---------------------------------------------------------------------------
' Live: pause, rewind and back to live through the provider's timeshift
' archive (channels with archiveDays > 0).

sub startLive()
    m.timeshiftTimeout.control = "stop"
    m.mode = "live"
    m.video.enableTrickPlay = false     ' our keys, not the Video node's
    loadVideo(m.play.url, asString(m.play.streamFormat), true, 0)
    showOverlay()
end sub

function canRewind() as Boolean
    t = m.play.timeshift
    return toInt(m.play.archiveDays) > 0 and type(t) = "roAssociativeArray" and asString(t.url) <> ""
end function

sub pauseLive()
    if not canRewind()
        showNote("This channel can't be paused or rewound (the provider keeps no archive for it).")
        return
    end if
    m.video.control = "pause"
    m.mode = "paused"
    m.pausedAt = nowSeconds()
    showOverlay()
    m.overlayTimer.control = "stop"     ' stay up while paused
end sub

' Newest moment the archive reliably has: it's written in one-minute
' segments and lags live (lagSeconds, from data/guide-rules.json).
function archiveEdge() as Integer
    lag = toInt(m.play.timeshift.lagSeconds)
    if lag <= 0 then lag = 300
    return nowSeconds() - lag
end function

' Jump into the archive as close to live (or the pause point) as it has
' recorded. The window is kept short (10 minutes before that point): the
' provider builds the archive playlist on request and long ones are slow.
' The Video node's own rewind then moves within that window.
sub rewindLive()
    if not canRewind()
        showNote("This channel can't be paused or rewound (the provider keeps no archive for it).")
        return
    end if
    target = archiveEdge()
    if m.mode = "paused" and m.pausedAt < target then target = m.pausedAt
    start = target - 10 * 60
    startTimeshift(start, target - start)
end sub

' Play after a pause. A short pause resumes from the player's own buffer.
' Longer ones continue from the archive: from the pause point if it's been
' recorded, else from the newest recorded moment (a little before the pause).
sub resumeFromPause()
    if nowSeconds() - m.pausedAt < 60
        m.video.control = "resume"
        m.mode = "live"
        showOverlay()
        return
    end if
    resumeAt = m.pausedAt
    if resumeAt > archiveEdge() then resumeAt = archiveEdge()
    startTimeshift(resumeAt, 0)
end sub

sub startTimeshift(startUtc as Integer, playStart as Integer)
    m.mode = "timeshift"
    m.tsStart = startUtc
    m.tsPlayStart = playStart
    if m.tsPlayStart < 0 then m.tsPlayStart = 0
    m.tsConfirmed = false

    t = m.play.timeshift
    ' Ask only for minutes already recorded, so the stream ends instead of
    ' waiting on segments that don't exist yet.
    minutes = Int((archiveEdge() - m.tsStart) / 60) + 1
    if minutes < 1 then minutes = 1
    url = t.url.Replace("{start}", serverTimeString(m.tsStart, t.tz)).Replace("{duration}", minutes.ToStr())
    print "[player] timeshift from "; serverTimeString(m.tsStart, t.tz); " server time, "; minutes; " min"
    m.video.enableTrickPlay = true
    loadVideo(url, "hls", false, m.tsPlayStart)
    m.timeshiftTimeout.control = "stop"
    m.timeshiftTimeout.control = "start"
    showOverlay()
end sub

sub onTimeshiftTimeout()
    if m.mode = "timeshift" and not m.tsConfirmed then timeshiftFailed("no video after 30 s")
end sub

' The archive didn't play: say why and rejoin live.
sub timeshiftFailed(reason as String)
    m.timeshiftTimeout.control = "stop"
    print "[player] timeshift failed: "; reason
    if Instr(1, reason, "larger than the entire buffer") > 0
        ' The provider's archive segments are a full minute each; for HD
        ' channels that's more than this Roku's video buffer holds.
        m.note = "This channel's archive is too high-quality for this Roku to rewind. Its SD version may work."
    else
        m.note = "This channel's archive wouldn't play, so you're back to live."
    end if
    startLive()
end sub

sub showNote(text as String)
    m.note = text
    showOverlay()
end sub

' ---------------------------------------------------------------------------
' Live overlay: mode, channel, current program with progress, next program.

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
    if m.mode = "paused" then return
    m.liveOverlay.visible = false
    m.note = ""
end sub

sub drawOverlay()
    if m.note <> ""
        m.modeLine.text = m.note
    else if m.mode = "paused"
        m.modeLine.text = "PAUSED  -  press Play to continue"
    else if m.mode = "timeshift"
        ' Until the archive starts playing the Video node reports position 0;
        ' measure from where playback is headed instead.
        position = Int(m.video.position)
        if not m.tsConfirmed then position = m.tsPlayStart
        behind = Int((nowSeconds() - (m.tsStart + position)) / 60)
        if behind < 0 then behind = 0
        m.modeLine.text = "BEHIND LIVE  " + behind.ToStr() + " MIN"
    else
        m.modeLine.text = ""
    end if

    if m.mode = "timeshift"
        m.hints.text = "Play/Pause, Rewind, Fast-forward: move through the archive     Back: return to live"
    else if canRewind()
        m.hints.text = "Up / Down: change favorite     Play/Pause: pause     Rewind: go back     *: show this again     Back: close"
    else
        m.hints.text = "Up / Down: change favorite channel     *: show this again     Back: close"
    end if

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
        if m.mode = "timeshift" or m.mode = "paused"
            startLive()
        else
            close()
        end if
        return true
    end if
    if m.play = invalid or m.play.kind <> "live" then return false

    if key = "up"
        m.top.channelStep = 1
        return true
    else if key = "down"
        m.top.channelStep = -1
        return true
    else if key = "play" and m.mode = "live"
        pauseLive()
        return true
    else if key = "play" and m.mode = "paused"
        resumeFromPause()
        return true
    else if key = "rewind" and (m.mode = "live" or m.mode = "paused")
        rewindLive()
        return true
    else if key = "fastforward" and m.mode = "live"
        showNote("You're watching live.")
        return true
    else if key = "options" or key = "OK" or key = "info"
        showOverlay()
        return true
    end if
    return false
end function
