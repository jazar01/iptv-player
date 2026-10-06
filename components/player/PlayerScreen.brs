sub init()
    m.video = m.top.FindNode("video")
    m.liveOverlay = m.top.FindNode("liveOverlay")
    m.modeLine = m.top.FindNode("modeLine")
    m.channelName = m.top.FindNode("channelName")
    m.channelPos = m.top.FindNode("channelPos")
    m.nowTitle = m.top.FindNode("nowTitle")
    m.nowDesc = m.top.FindNode("nowDesc")
    m.nowTime = m.top.FindNode("nowTime")
    m.progressTrack = m.top.FindNode("progressTrack")
    m.progressFill = m.top.FindNode("progressFill")
    m.nextLine = m.top.FindNode("nextLine")
    m.hints = m.top.FindNode("hints")
    m.errorPanel = m.top.FindNode("errorPanel")
    m.errorMessage = m.top.FindNode("errorMessage")
    m.errorCopyList = m.top.FindNode("errorCopies")
    m.errorCopyList.ObserveField("itemSelected", "onErrorCopySelected")
    m.errorCopyItems = []
    m.overlayTimer = m.top.FindNode("overlayTimer")
    m.saveTimer = m.top.FindNode("saveTimer")
    m.timeshiftTimeout = m.top.FindNode("timeshiftTimeout")
    m.timeshiftTimeout.ObserveField("fire", "onTimeshiftTimeout")
    m.liveTick = m.top.FindNode("liveTick")
    m.liveTick.ObserveField("fire", "onLiveTick")
    m.stallTimer = m.top.FindNode("stallTimer")
    m.stallTimer.ObserveField("fire", "onStall")
    m.infoPanel = m.top.FindNode("infoPanel")
    m.infoPanel.ObserveField("chosen", "onInfoCopyChosen")
    m.statsTimer = m.top.FindNode("statsTimer")
    m.statsTimer.ObserveField("fire", "updatePlaybackInfo")
    m.bufferCount = 0       ' buffering spells on this channel after it played
    m.clock = CreateObject("roTimespan")
    m.bufferingSince = -1   ' clock ms when buffering began, -1 when not buffering
    m.livePlayed = false    ' this live stream has played (so buffering now is a stall)
    m.stallReloads = []     ' clock ms of recent watchdog reloads
    m.lastFormat = ""       ' last logged stream format

    m.play = invalid
    m.programs = invalid
    m.finished = false
    m.mode = ""             ' "live" | "paused" | "timeshift" | "vod"
    m.note = ""             ' one-off message on the live overlay

    m.video.ObserveField("state", "onVideoState")
    m.video.ObserveField("streamingSegment", "onStreamingSegment")
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
    hideErrorCopies()

    ' Never print play.url: it contains the password.
    print "[player] "; play.kind; " "; play.id; " '"; play.name; "' from "; toInt(play.startPosition); " s"
    m.stallTimer.control = "stop"
    m.bufferingSince = -1
    m.livePlayed = false
    m.bufferCount = 0
    hideInfo()
    m.stallReloads = []
    m.lastFormat = ""
    m.liveTick.control = "stop"
    m.liveSeconds = 0           ' playing time on this channel; restarts on every change
    m.viewedSent = false
    m.watchedSent = false
    if play.kind = "live"
        m.saveTimer.control = "stop"
        m.liveTick.control = "start"
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
    watchStall(state)

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
        detail = asString(m.video.errorStr)
        print "[player] error "; code; " "; redact(m.video.errorMsg); " / "; redact(detail)
        logAudioTracks()
        message = friendlyError(code, httpStatus(detail))
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

' ---------------------------------------------------------------------------
' Stalls. Some relayed live channels change format at commercial breaks
' without telling the player, and Roku's player can sit at "Loading" until
' the stream is reopened. Every buffering spell is logged; on a live stream
' that has already played, one lasting stallTimer's duration reloads the
' stream at the live point (at most 4 times in 3 minutes, then an error).

sub watchStall(state as String)
    if state = "buffering"
        if m.bufferingSince < 0 then m.bufferingSince = m.clock.TotalMilliseconds()
        if m.mode = "live" and m.livePlayed then m.stallTimer.control = "start"
        return
    end if
    m.stallTimer.control = "stop"
    if m.bufferingSince >= 0
        waited = (m.clock.TotalMilliseconds() - m.bufferingSince) / 1000
        if waited >= 1 and m.livePlayed then m.bufferCount = m.bufferCount + 1
        if waited >= 1 and m.livePlayed then print "[player] buffered "; Int(waited); " s ("; m.mode; ", ended "; state; ")"
        m.bufferingSince = -1
    end if
    if state = "playing" and m.mode = "live" then m.livePlayed = true
end sub

sub onStall()
    if m.play = invalid or m.mode <> "live" or m.video.state <> "buffering" then return
    now = m.clock.TotalMilliseconds()
    recent = []
    for each t in m.stallReloads
        if now - t < 180000 then recent.Push(t)
    end for
    m.stallReloads = recent
    if recent.Count() >= 4
        print "[player] still stalling after "; recent.Count(); " reloads in 3 minutes; giving up"
        m.video.control = "stop"
        m.errorMessage.text = "This channel keeps stalling. Try it again in a minute, or another copy of the channel."
        m.errorPanel.visible = true
        m.liveOverlay.visible = false
        return
    end if
    m.stallReloads.Push(now)
    print "[player] stalled "; Int(m.stallTimer.duration); " s; reloading the live stream ("; m.stallReloads.Count(); " in 3 min)"
    m.bufferingSince = -1
    m.lastFormat = ""
    m.note = "The stream stalled, so it was reconnected."
    startLive()
end sub

' Logs the stream's resolution and bit rate whenever they change, to see
' what happens at the breaks. Never the segment URL: it holds the password.
sub onStreamingSegment()
    seg = m.video.streamingSegment
    if type(seg) <> "roAssociativeArray" then return
    ' segType 1 is audio and 3 captions: their bit rate isn't the picture's.
    if toInt(seg.segType) = 1 or toInt(seg.segType) = 3 then return
    ' Only segments that report a picture size count. This provider's streams
    ' report none (type 0, no width or height) and a flat 128 kbps that is the
    ' playlist's declared figure, not the picture's, so nothing is shown.
    if toInt(seg.width) <= 0 then return
    format = toInt(seg.width).ToStr() + "x" + toInt(seg.height).ToStr()
    if toInt(seg.segBitrateBps) > 0 then format = format + ", " + Int(toInt(seg.segBitrateBps) / 1000).ToStr() + " kbps"
    if format = m.lastFormat then return
    if m.lastFormat = "" then print "[player] stream format: "; format else print "[player] stream format: "; format; " (was "; m.lastFormat; ")"
    m.lastFormat = format
end sub

' ---------------------------------------------------------------------------
' Channel info panel (OK twice while watching live). MainScene fills in the
' channel's details and guide; this adds what only the player knows.

sub showInfo()
    if m.play = invalid or m.play.kind <> "live" then return
    m.liveOverlay.visible = false
    m.overlayTimer.control = "stop"
    m.infoPanel.info = { name: m.play.name, facts: [], programsNote: "Loading ..." }
    updatePlaybackInfo()
    m.infoPanel.visible = true
    m.infoPanel.SetFocus(true)
    m.statsTimer.control = "start"
    m.top.infoRequested = { streamId: m.play.id, name: m.play.name, epgChannelId: asString(m.play.epgChannelId) }
end sub

sub hideInfo()
    if m.infoPanel = invalid or not m.infoPanel.visible then return
    m.statsTimer.control = "stop"
    m.infoPanel.visible = false
    m.video.SetFocus(true)
end sub

sub onChannelInfo()
    if m.infoPanel.visible then m.infoPanel.info = m.top.channelInfo
end sub

sub onInfoCopyChosen()
    m.top.copyChosen = m.infoPanel.chosen
end sub

' Live stream details, refreshed every 2 s while the panel is open. Read
' from the Video node; its stream and segment URLs hold the password and are
' never shown or printed.
sub updatePlaybackInfo()
    ' Three lines: picture, connection and state, trouble so far.
    lines = []
    video = m.lastFormat
    codecs = codecName(m.video.videoFormat) + " / " + codecName(m.video.audioFormat)
    if codecs <> " / "
        if video <> "" then video = video + "   -   "
        video = video + codecs
    end if
    if video <> "" then lines.Push(video)
    state = "Live"
    if m.mode = "paused" then state = "Paused"
    if m.mode = "timeshift" then state = "Rewound (archive)"
    if m.video.state = "buffering" then state = state + ", loading"
    info = m.video.streamInfo
    if type(info) = "roAssociativeArray" and toInt(info.measuredBitrate) > 0 then state = state + "   -   connection " + formatMbps(toInt(info.measuredBitrate))
    lines.Push(state)
    stalls = m.bufferCount.ToStr() + " loading pauses on this channel"
    if m.stallReloads.Count() > 0 then stalls = stalls + ", " + m.stallReloads.Count().ToStr() + " reconnects"
    lines.Push(stalls)
    m.infoPanel.playback = { lines: lines }
end sub

' The Video node's format names, as people know them.
function codecName(value as Dynamic) as String
    v = UCase(asString(value))
    names = { "MPEG4_10B": "H.264", "AVC": "H.264", "HEVC": "H.265", "MPEG4_15": "H.265", "MPEG2": "MPEG-2", "AAC_ADTS": "AAC", "AAC_LC": "AAC", "AC3": "Dolby Digital", "EAC3": "Dolby Digital Plus", "MP3": "MP3" }
    if names.DoesExist(v) then return names[v]
    return v
end function

function formatMbps(bps as Integer) as String
    tenths = Int(bps / 100000 + 0.5)
    return Int(tenths / 10).ToStr() + "." + (tenths mod 10).ToStr() + " Mbps"
end function

' ---------------------------------------------------------------------------
' Other copies on the error panel (MainScene sends them for a failed live
' channel). OK on one plays it.

sub onErrorCopies()
    list = m.top.errorCopies
    if not m.errorPanel.visible or type(list) <> "roArray" or list.Count() = 0 then return
    m.errorCopyItems = list
    content = CreateObject("roSGNode", "ContentNode")
    for each c in list
        item = content.CreateChild("ContentNode")
        title = localizeName(asString(c.name))
        if toInt(c.archiveDays) > 0 then title = title + "   (rewind)"
        item.title = title
    end for
    m.errorCopyList.content = content
    if m.top.errorCopiesLabel <> "" then m.top.FindNode("copiesHead").text = m.top.errorCopiesLabel
    m.top.FindNode("errorBg").height = 680
    m.top.FindNode("copiesHead").visible = true
    m.errorCopyList.visible = true
    m.top.FindNode("errorBack").translation = [420, 960]
    m.errorCopyList.SetFocus(true)
end sub

sub hideErrorCopies()
    m.errorCopyItems = []
    m.errorCopyList.visible = false
    m.top.FindNode("copiesHead").visible = false
    m.top.FindNode("errorBg").height = 420
    m.top.FindNode("errorBack").translation = [420, 680]
    if m.errorCopyList.HasFocus() then m.video.SetFocus(true)
end sub

sub onErrorCopySelected()
    i = m.errorCopyList.itemSelected
    if i >= 0 and i < m.errorCopyItems.Count() then m.top.copyChosen = m.errorCopyItems[i]
end sub

' Diagnostics for audio errors ("Unsupported AAC stream"): the stream's audio
' tracks as the Video node sees them, and the formats it reports.
sub logAudioTracks()
    tracks = m.video.availableAudioTracks
    if type(tracks) = "roArray"
        print "[player] audio tracks: "; tracks.Count()
        for each t in tracks
            if type(t) = "roAssociativeArray" then print "[player]   track "; asString(t.Track); " lang="; asString(t.Language); " name="; asString(t.Name); " format="; asString(t.Format)
        end for
    end if
    print "[player] audioFormat="; asString(m.video.audioFormat); " videoFormat="; asString(m.video.videoFormat)
end sub

sub onErrorText()
    m.errorMessage.text = m.top.errorText
end sub

' The HTTP status the provider answered with, from the Video node's detailed
' error ("...response code said error response code:(407):407:..."), or 0.
function httpStatus(detail as String) as Integer
    match = CreateObject("roRegex", "response code:\((\d{3})\)", "i").Match(detail)
    if match.Count() < 2 then return 0
    return Val(match[1], 10)
end function

' Video node error codes -> words a person can act on. An HTTP status from
' the provider says more than the error code, so it comes first.
function friendlyError(code as Integer, status as Integer) as String
    if status >= 400
        if status = 404
            message = "The provider doesn't have this stream right now (HTTP 404)."
        else if status = 403 or status = 401
            message = "The provider refused this stream (HTTP " + status.ToStr() + "). The account's connection limit may be reached."
        else if status >= 500
            message = "The provider's server had a problem with this stream (HTTP " + status.ToStr() + "). Try again in a minute."
        else
            message = "The provider refused this stream (HTTP " + status.ToStr() + ")."
        end if
        ' Not for 407: this provider sends it for event channels whose event
        ' is on (e.g. an NFL game in progress), so the hint would mislead.
        if m.play <> invalid and m.play.kind = "live" and status <> 407 then message = message + " If this is an event channel, it only works while its event is on."
        return message
    end if
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

' Every 5 s on a live channel: count the time only while video is actually
' playing (live or rewound), so a stream that never starts, an error panel
' or a pause doesn't count as viewing. Each threshold reports once per
' channel.
sub onLiveTick()
    if m.play = invalid or m.play.kind <> "live" then return
    if m.video.state <> "playing" then return
    m.liveSeconds = m.liveSeconds + m.liveTick.duration
    channel = { streamId: m.play.id, name: m.play.name, epgChannelId: asString(m.play.epgChannelId) }
    if not m.viewedSent and m.liveSeconds >= 60
        m.viewedSent = true
        m.top.liveViewed = channel
    end if
    if not m.watchedSent and m.liveSeconds >= m.top.channelViewSeconds
        m.watchedSent = true
        m.top.liveWatched = channel
    end if
    if m.viewedSent and m.watchedSent then m.liveTick.control = "stop"
end sub

sub close()
    m.saveTimer.control = "stop"
    hideInfo()
    m.stallTimer.control = "stop"
    m.overlayTimer.control = "stop"
    m.liveTick.control = "stop"
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
' Replay (the curved-arrow button): the program on now, from its start, via the archive.
' Needs the guide's start time and an archive that reaches back that far.
sub startOver()
    if not canRewind()
        showNote("This channel can't start over (the provider keeps no archive for it).")
        return
    end if
    current = invalid
    if m.programs <> invalid then current = m.programs.now
    if type(current) <> "roAssociativeArray" or toInt(current.start) <= 0
        showNote("No guide information for this channel, so there's no start to go back to. Rewind goes back 10 minutes.")
        return
    end if
    start = toInt(current.start)
    if start < nowSeconds() - toInt(m.play.archiveDays) * 86400
        showNote("This program started before the archive begins.")
        return
    end if
    if start > archiveEdge() - 60
        ' Started within the last few minutes: not recorded yet.
        showNote("This program has only just started; the archive hasn't caught up yet.")
        return
    end if
    print "[player] start over: "; current.title; " from "; formatClock(start)
    m.note = "From the start:  " + asString(current.title)
    startTimeshift(start, 0)
end sub

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
    print "[player] timeshift failed: "; redact(reason)
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

' Up/Down: name the channel being reached right away; its stream comes
' when the presses stop (onContent).
sub onPreview()
    p = m.top.preview
    if m.play = invalid or m.play.kind <> "live" or type(p) <> "roAssociativeArray" then return
    if isTrue(p.restore)
        if m.liveOverlay.visible then drawOverlay()
        return
    end if
    showOverlay()
    m.channelName.text = localizeName(asString(p.name))
    m.channelPos.text = asString(p.label)
    m.modeLine.text = "CHANGING CHANNEL ..."
    m.nowTitle.text = ""
    m.nowDesc.text = ""
    m.nowTime.text = ""
    m.nextLine.text = ""
    m.progressFill.width = 0
end sub

' "Favorite 3 of 12" changes when * adds or removes this channel.
sub onChannelLabel()
    if m.liveOverlay.visible then m.channelPos.text = m.top.channelLabel
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
        m.hints.text = "Up/Down: change favorite    *: favorite    Play/Pause: pause    Rewind: go back    Replay: start this program over    OK again: channel info    Back: close"
    else
        m.hints.text = "Up / Down: change favorite     *: add/remove favorite     OK again: channel info     Back: close"
    end if

    m.channelName.text = localizeName(asString(m.play.name))
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
        m.nowDesc.text = asString(current.description)
        m.nowTime.text = formatClock(current.start) + " - " + formatClock(current.ends)
        fraction = (now - current.start) / (current.ends - current.start)
        if fraction < 0 then fraction = 0
        if fraction > 1 then fraction = 1
        m.progressFill.width = 1728 * fraction
        m.progressTrack.visible = true
        m.progressFill.visible = true
    else
        m.nowTitle.text = "No guide information"
        m.nowDesc.text = ""
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
    ' Channel info open: Back closes it; nothing else reaches the player
    ' (Up/Down at the end of its list mustn't change channel).
    if m.infoPanel.visible
        if key = "back" then hideInfo()
        return true
    end if
    if key = "back"
        if m.mode = "timeshift" or m.mode = "paused"
            startLive()
        else
            close()
        end if
        return true
    end if
    ' Error panel with other copies: Up/Down stay in its list.
    if m.errorPanel.visible and m.errorCopyList.visible and (key = "up" or key = "down") then return true

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
    else if key = "replay"
        startOver()
        return true
    else if key = "rewind" and (m.mode = "live" or m.mode = "paused")
        rewindLive()
        return true
    else if key = "fastforward" and m.mode = "live"
        showNote("You're watching live.")
        return true
    else if key = "options"
        ' * adds or removes the channel being watched as a favorite, like *
        ' in every channel list. MainScene saves it and updates channelLabel.
        m.top.toggleFavorite = { streamId: m.play.id, name: m.play.name, epgChannelId: asString(m.play.epgChannelId) }
        showOverlay()
        return true
    else if key = "OK" or key = "info"
        ' First press shows the strip; a second, while it's up, channel info.
        if m.liveOverlay.visible then showInfo() else showOverlay()
        return true
    end if
    return false
end function
