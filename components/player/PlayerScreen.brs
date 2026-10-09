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
    m.progressLive = m.top.FindNode("progressLive")
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
    m.startTimer = m.top.FindNode("startTimer")
    m.startTimer.ObserveField("fire", "onStartTimeout")
    m.seekTimer = m.top.FindNode("seekTimer")
    m.seekTimer.ObserveField("fire", "onSeekTimer")
    m.holdTimer = m.top.FindNode("holdTimer")
    m.holdTimer.ObserveField("fire", "onHoldTimer")
    m.holdKey = invalid
    m.thumbGroup = m.top.FindNode("thumbGroup")
    m.thumb = m.top.FindNode("thumb")
    m.seekPending = invalid  ' live buffer: seconds of jumps pressed, not made yet
    m.infoPanel = m.top.FindNode("infoPanel")
    m.infoPanel.ObserveField("chosen", "onInfoCopyChosen")
    m.infoPanel.ObserveField("action", "onInfoAction")
    m.infoPanel.actions = true      ' Add to / Remove from Favorites (Roku takes * on some channels)
    m.statsTimer = m.top.FindNode("statsTimer")
    m.statsTimer.ObserveField("fire", "updatePlaybackInfo")
    m.bufferCount = 0       ' buffering spells on this channel after it played
    m.clock = CreateObject("roTimespan")
    m.bufferingSince = -1   ' clock ms when buffering began, -1 when not buffering
    m.livePlayed = false    ' this live stream has played (so buffering now is a stall)
    m.stallReloads = []     ' clock ms of recent watchdog reloads
    m.slowReloads = []      ' the same for movies, episodes and the archive
    m.lastFormat = ""       ' last logged stream format
    m.LIVE_GAP = 30         ' live buffer: at live, the player runs this far behind the newest piece (onBufferPiece)
    m.bufferStarted = false ' live buffer: checked that this load started at live (watchStall)

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

' Movies, episodes and the archive (timeshift) use the Video node's own
' pause/seek controls, so it has focus there. Live keeps focus on this
' screen: the Video node takes * for its own audio and captions menu when a
' stream has extra tracks (LBW: SEC Network, Oct 2026), and live * adds a
' favorite.
sub onFocusedChild()
    if m.top.HasFocus() and videoKeepsFocus() then m.video.SetFocus(true)
end sub

function videoKeepsFocus() as Boolean
    if m.errorPanel.visible then return false
    return m.mode = "vod" or m.mode = "timeshift"
end function

' Focus to whichever should have it now (see onFocusedChild); nothing changes
' while a panel or list over the video has it.
sub focusPlayer()
    if m.infoPanel.visible or m.errorCopyList.HasFocus() then return
    if not m.top.IsInFocusChain() then return
    if videoKeepsFocus()
        m.video.SetFocus(true)
    else
        m.video.SetFocus(false)
        m.top.SetFocus(true)
    end if
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
    m.startTimer.control = "stop"
    m.seekTimer.control = "stop"
    m.seekPending = invalid
    stopHold()
    m.LIVE_GAP = 30             ' until the Pi says how long its pieces are
    m.top.streamPicture = ""
    m.top.thumbBase = ""
    m.thumbGroup.visible = false
    m.bufferingSince = -1
    m.livePlayed = false
    m.vodPlayed = false         ' this movie or episode has played
    m.vodAt = toInt(play.startPosition)     ' where it last was, for a reload
    m.liveEndedAt = invalid     ' when this channel's stream last ended (liveStreamEnded)
    m.errored = false          ' the Video node reported an error since the last load (loadVideo)
    m.bufferCount = 0
    hideInfo()
    m.stallReloads = []
    m.slowReloads = []
    m.lastFormat = ""
    m.liveTick.control = "stop"
    m.liveSeconds = 0           ' playing time on this channel; restarts on every change
    m.viewedSent = false
    m.watchedSent = false
    if play.kind = "live"
        m.saveTimer.control = "stop"
        m.liveTick.control = "start"
        startLive()
        ' Set by MainScene (e.g. switched to another copy of the channel).
        if asString(play.note) <> "" then showNote(asString(play.note))
    else
        m.mode = "vod"
        m.liveOverlay.visible = false
        ' The Video node's own controls: pause, rewind, fast-forward, seek.
        m.video.enableTrickPlay = true
        loadVideo(play.url, asString(play.streamFormat), false, toInt(play.startPosition))
        focusPlayer()
        m.saveTimer.control = "start"
    end if
end sub

sub loadVideo(url as String, streamFormat as String, live as Boolean, playStart as Integer)
    m.video.control = "stop"
    m.errored = false
    m.playedSinceLoad = false   ' a late "finished" from the previous stream is ignored
    c = CreateObject("roSGNode", "ContentNode")
    c.url = url
    c.title = asString(m.play.name)
    if streamFormat <> "" then c.streamFormat = streamFormat
    if live then c.live = true
    if playStart > 0 then c.playStart = playStart
    m.video.content = c
    m.video.control = "play"
    ' The archive has its own limit (timeshiftTimeout).
    m.startTimer.control = "stop"
    if m.mode <> "timeshift" then m.startTimer.control = "start"
end sub

sub onVideoState()
    state = m.video.state
    if m.play = invalid then return
    watchStall(state)
    if state = "playing" or state = "error" or state = "finished" then m.startTimer.control = "stop"

    if state = "playing" then m.playedSinceLoad = true
    if state = "playing" and m.mode = "vod" then m.vodPlayed = true
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
            ' Stretches end on whole minutes: start the next on one (to the
            ' nearest), so it begins with its first piece.
            if isTrue(m.play.relayed) then reached = ((reached + 30) \ 60) * 60
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
        m.errored = true
        code = m.video.errorCode
        detail = asString(m.video.errorStr)
        print "[player] error "; code; " "; redact(m.video.errorMsg); " / "; redact(detail)
        logAudioTracks()
        ' The decoder rejected the audio ("Unsupported AAC stream"): this
        ' stream will never play on this Roku, however often it's retried.
        audioUnsupported = (code = -5 and Instr(1, LCase(detail), "unsupported aac") > 0)
        message = friendlyError(code, httpStatus(detail))
        ' Dolby audio that this TV connection doesn't take (a TV that accepts
        ' stereo only over HDMI): no fix here, but another copy may not be Dolby.
        dolbyUnsupported = (code = -5 and Instr(1, LCase(detail), "unsupported audio format: dolby") > 0)
        if audioUnsupported and m.play.kind = "live" then message = "This channel sends audio your Roku can't decode as it is. Trying to fix it ..."
        if dolbyUnsupported and m.play.kind = "live" then message = "This channel's audio is Dolby, which this TV doesn't accept. Looking for another copy ..."
        ' Where a movie or episode was, for OK (try again) on the panel.
        position = Int(m.video.position)
        if m.mode = "vod" and m.playedSinceLoad and position > 0 then m.vodAt = position
        m.saveTimer.control = "stop"
        showErrorPanel(message)
        m.top.failed = { play: m.play, code: code, message: message, audioUnsupported: audioUnsupported, dolbyUnsupported: dolbyUnsupported }
    else if state = "finished" and m.play.kind = "live" and not m.errored and m.playedSinceLoad
        ' (After an error the Video node also reports "finished", sometimes only
        ' once the next stream has loaded; reconnecting then would only repeat
        ' the error or restart a stream that just began.)
        liveStreamEnded()
    else if state = "finished" and m.play.kind <> "live"
        m.finished = true
        close()
    end if
end sub

' A live stream that ends (the provider stopped it: an event over, a server
' restart) would otherwise leave a frozen picture. Reconnect once; if it ends
' again within 2 minutes, stop and offer other copies (code -101).
sub liveStreamEnded()
    now = m.clock.TotalMilliseconds()
    if m.liveEndedAt <> invalid and now - m.liveEndedAt < 120000
        print "[player] live stream ended again; giving up"
        failPlayback(-101, "This channel stopped sending video. It may be off the air right now; try again later, or another copy of the channel.")
        return
    end if
    m.liveEndedAt = now
    print "[player] live stream ended; reconnecting"
    m.note = "The stream ended, so it was reconnected."
    startLive()
end sub

' ---------------------------------------------------------------------------
' Stalls. Some relayed live channels change format at commercial breaks
' without telling the player, and Roku's player can sit at "Loading" until
' the stream is reopened. Every buffering spell is logged. On a live stream
' that has already played, one lasting 6 s reloads the stream at the live
' point (at most 4 times in 3 minutes, then an error). A movie, episode or
' archive stretch that has played and then buffers for 25 s is reloaded
' where it was (at most 3 times in 5 minutes): movies and episodes then
' show an error, the archive goes back to live. A stream that never starts
' is onStartTimeout's.

sub watchStall(state as String)
    if state = "buffering"
        if m.bufferingSince < 0 then m.bufferingSince = m.clock.TotalMilliseconds()
        if m.mode = "live" and m.livePlayed
            m.stallTimer.duration = 6
            m.stallTimer.control = "start"
        else if (m.mode = "vod" or m.mode = "timeshift") and m.playedSinceLoad
            m.stallTimer.duration = 25
            m.stallTimer.control = "start"
        end if
        return
    end if
    m.stallTimer.control = "stop"
    if m.bufferingSince >= 0
        waited = (m.clock.TotalMilliseconds() - m.bufferingSince) / 1000
        if waited >= 1 and m.livePlayed then m.bufferCount = m.bufferCount + 1
        if waited >= 1 and (m.livePlayed or m.playedSinceLoad) then print "[player] buffered "; Int(waited); " s ("; m.mode; ", ended "; state; ")"
        m.bufferingSince = -1
    end if
    ' The live buffer's normal gap behind the newest segment (bufferBehind).
    if state = "playing" and m.mode = "live" and not m.bufferStarted and m.play <> invalid and isTrue(m.play.buffered) then bufferStartAtLive()
    if state = "playing" and m.mode = "live" and not m.livePlayed
        m.livePlayed = true
        m.top.livePlaying = { streamId: m.play.id }
    end if
end sub

sub onStall()
    if m.play = invalid or m.video.state <> "buffering" then return
    if m.mode = "live"
        liveStalled()
    else if m.mode = "vod"
        vodStalled("stalled")
    else if m.mode = "timeshift"
        archiveStalled()
    end if
end sub

' Nothing played within startTimer's 25 s of loading, and no error either:
' Roku's player can sit at "Loading" for good. A live channel's first start
' fails like an error, so its copies are offered (a reload after a stall
' that sits in "buffering" is the stall watchdog's).
sub onStartTimeout()
    if m.play = invalid or m.playedSinceLoad or m.errored or m.errorPanel.visible then return
    state = m.video.state
    if state = "playing" or state = "paused" then return
    if m.mode = "live" and not m.livePlayed
        print "[player] live stream didn't start in "; Int(m.startTimer.duration); " s (state "; state; ")"
        m.video.control = "stop"
        ' Code -102: the app's own "never started" (not the Video node's).
        failPlayback(-102, "This channel didn't start: no video arrived. It may be off the air right now; try again later, or another copy of the channel.")
    else if m.mode = "live" and state <> "buffering"
        liveStalled()
    else if m.mode = "vod"
        vodStalled("didn't start")
    end if
end sub

' The error panel, and the same path as a playback error (MainScene offers
' copies of a live channel). Codes below -99 are the app's own.
sub failPlayback(code as Integer, message as String)
    m.stallTimer.control = "stop"
    m.startTimer.control = "stop"
    m.saveTimer.control = "stop"
    showErrorPanel(message)
    m.top.failed = { play: m.play, code: code, message: message }
end sub

' The error panel takes the keys (OK tries again; with copies listed, OK
' plays the one chosen), even for movies, where the Video node has them.
sub showErrorPanel(message as String)
    m.errorMessage.text = message
    m.errorPanel.visible = true
    m.liveOverlay.visible = false
    m.top.FindNode("errorBack").text = "Press OK to try again, or Back to return."
    focusPlayer()
end sub

' OK on the error panel: the same item again, from where it was.
sub retryPlayback()
    print "[player] trying again: "; m.play.kind; " "; m.play.id
    m.errorPanel.visible = false
    hideErrorCopies()
    m.errored = false
    m.note = ""
    if m.play.kind = "live"
        m.stallReloads = []
        m.liveEndedAt = invalid
        startLive()
    else
        m.slowReloads = []
        m.mode = "vod"
        loadVideo(m.play.url, asString(m.play.streamFormat), false, m.vodAt)
        m.saveTimer.control = "start"
        focusPlayer()
    end if
end sub

' Movies and episodes: reload where it was. One that has never played gets
' one more try; one that has, 3 in 5 minutes. Its position is saved first,
' so after the error it resumes from there.
sub vodStalled(reason as String)
    position = Int(m.video.position)
    if m.playedSinceLoad and position > 0 then m.vodAt = position
    allowed = 3
    if not m.vodPlayed then allowed = 1
    if not reloadAllowed(allowed)
        print "[player] "; m.play.kind; " "; reason; " again; giving up"
        reportProgress()
        m.video.control = "stop"
        if m.vodPlayed
            failPlayback(-100, "This video keeps stalling. Try again in a few minutes; it will continue from here.")
        else
            failPlayback(-102, "This video didn't start: no video arrived from the provider. Try again in a few minutes.")
        end if
        return
    end if
    print "[player] "; m.play.kind; " "; reason; "; reloading at "; m.vodAt; " s"
    loadVideo(m.play.url, asString(m.play.streamFormat), false, m.vodAt)
end sub

' The archive: reload this stretch from where it was; back to live if it
' keeps stalling.
sub archiveStalled()
    if not reloadAllowed(3)
        timeshiftFailed("kept stalling")
        return
    end if
    at = m.tsStart + Int(m.video.position)
    if at > archiveEdge() then at = archiveEdge()
    print "[player] archive stalled; reloading from "; formatClock(at)
    m.note = "The recording stalled, so it was reloaded."
    startTimeshift(at, 0)
end sub

' Movie, episode and archive reloads: true (and counted) if fewer than
' allowed happened in the last 5 minutes.
function reloadAllowed(allowed as Integer) as Boolean
    now = m.clock.TotalMilliseconds()
    recent = []
    for each t in m.slowReloads
        if now - t < 300000 then recent.Push(t)
    end for
    m.slowReloads = recent
    if recent.Count() >= allowed then return false
    m.slowReloads.Push(now)
    return true
end function

sub liveStalled()
    now = m.clock.TotalMilliseconds()
    recent = []
    for each t in m.stallReloads
        if now - t < 180000 then recent.Push(t)
    end for
    m.stallReloads = recent
    if recent.Count() >= 4
        print "[player] still stalling after "; recent.Count(); " reloads in 3 minutes; giving up"
        m.video.control = "stop"
        ' Code -100: the app's own "kept stalling" (not the Video node's).
        failPlayback(-100, "This channel keeps stalling. Try it again in a minute, or another copy of the channel.")
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
    m.infoPanel.SetFocus(false)
    m.top.SetFocus(true)
    focusPlayer()
end sub

sub onChannelInfo()
    if m.infoPanel.visible then m.infoPanel.info = m.top.channelInfo
end sub

' Add to / Remove from Favorites in the channel info panel: the same as *
' (MainScene saves it and sends back channelLabel, which relabels it).
sub onInfoAction()
    if m.play = invalid or m.play.kind <> "live" or m.infoPanel.action <> "favorite" then return
    m.top.toggleFavorite = { streamId: m.play.id, name: m.play.name, epgChannelId: asString(m.play.epgChannelId) }
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
    if video = "" then video = m.top.streamPicture
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
    m.top.FindNode("errorBack").text = "OK plays the copy chosen. Back returns."
    m.errorCopyList.SetFocus(true)
end sub

sub hideErrorCopies()
    m.errorCopyItems = []
    m.errorCopyList.visible = false
    m.top.FindNode("copiesHead").visible = false
    m.top.FindNode("errorBg").height = 420
    m.top.FindNode("errorBack").translation = [420, 680]
    if m.errorCopyList.HasFocus()
        m.errorCopyList.SetFocus(false)
        m.top.SetFocus(true)
        focusPlayer()
    end if
end sub

sub onErrorCopySelected()
    i = m.errorCopyList.itemSelected
    if i < 0 or i >= m.errorCopyItems.Count() then return
    chosen = m.errorCopyItems[i]
    chosen.fromError = true     ' a stand-in for the channel that failed (MainScene may offer to swap the favorite)
    m.top.copyChosen = chosen
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
    ' Through the Pi with its audio converted, the stream starts at the
    ' resume point and grows as it's made: the position counts from there,
    ' and the length is the file's.
    if toInt(m.play.vodOffset) > 0 or isTrue(m.play.converted)
        position = position + toInt(m.play.vodOffset)
        if toInt(m.play.duration) > 0 then duration = toInt(m.play.duration)
    end if
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
    m.startTimer.control = "stop"
    m.overlayTimer.control = "stop"
    m.liveTick.control = "stop"
    stopHold()
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
    m.bufferStarted = false ' checked again once it plays (bufferStartAtLive)
    m.video.enableTrickPlay = false     ' our keys, not the Video node's
    loadVideo(m.play.url, asString(m.play.streamFormat), true, 0)
    showOverlay()
    focusPlayer()
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

' ---------------------------------------------------------------------------
' Live buffer (the Pi records the channel; m.play.buffered): the stream is
' one long live playlist, so pausing holds the picture and the player can go
' back within it. Play/Pause holds and carries on; Rewind jumps back 30 s,
' Left / Right 10 s; Fast-forward returns to live. Back always leaves the
' channel: as "go live" it got pressed once too often and left (Oct 2026).

function bufferKey(key as String) as Boolean
    if key = "fastforward"
        m.seekPending = invalid
        m.seekTimer.control = "stop"
        if m.mode = "held" or bufferBehind() > 5
            goLive()
        else
            showNote("You're watching live.")
        end if
        return true
    end if
    if key = "play"
        if m.mode = "held"
            m.video.control = "resume"
            m.mode = "live"
            print "[player] buffer: carried on at "; Int(m.video.position); " s (duration "; Int(m.video.duration); ")"
        else
            m.video.control = "pause"
            m.heldBehind = bufferBehind()       ' then counting up while held (watchingBehind)
            m.heldAt = nowSeconds()
            m.mode = "held"
            print "[player] buffer: held at "; Int(m.video.position); " s (duration "; Int(m.video.duration); ")"
        end if
        showOverlay()
        if m.mode = "held" then m.overlayTimer.control = "stop"
        return true
    end if
    jump = bufferJump(key)
    if jump = 0 then return false
    addJump(jump)
    ' Held down, the key keeps going (Roku sends one press and one release,
    ' no repeats): onHoldTimer adds a step each tick until the release.
    m.holdKey = key
    m.holdTicks = 0
    m.holdTimer.control = "stop"
    m.holdTimer.control = "start"
    return true
end function

function bufferJump(key as String) as Integer
    if key = "rewind" then return -30
    if key = "left" then return -10
    if key = "right" then return 10
    return 0
end function

' The held key: another step each tick, bigger after a couple of seconds.
sub onHoldTimer()
    if m.holdKey = invalid or m.play = invalid or not isTrue(m.play.buffered) or (m.mode <> "live" and m.mode <> "held")
        stopHold()
        return
    end if
    m.holdTicks = m.holdTicks + 1
    if m.holdTicks > 300                ' a release that never came
        stopHold()
        return
    end if
    jump = bufferJump(m.holdKey)
    if m.holdTicks > 6 then jump = jump * 3
    addJump(jump)
end sub

sub stopHold()
    m.holdKey = invalid
    m.holdTimer.control = "stop"
end sub

' Presses add up and the player jumps once, half a second after the last
' (or after a held key is let go): each jump makes it load again, so five
' presses felt like five stutters (Oct 2026).
sub addJump(jump as Integer)
    if m.seekPending = invalid
        m.seekPending = 0
        m.seekFrom = m.video.position
    end if
    ' Kept within the buffer: back no further than its start (when the TV
    ' tuned in), ahead no further than live. A channel with a catch-up
    ' archive goes on back into it, as far as the archive reaches.
    m.seekPending = m.seekPending + jump
    earliest = -Int(m.seekFrom)
    if canRewind() then earliest = Int(m.video.duration) - Int(m.seekFrom) - toInt(m.play.archiveDays) * 86400
    latest = liveSpot() - Int(m.seekFrom)
    if latest < 0 then latest = 0
    if m.seekPending <= earliest
        m.seekPending = earliest
        if canRewind() then m.note = "Start of the archive" else m.note = "Start of the buffer (when you tuned in to this channel)"
    else if m.seekPending < -Int(m.seekFrom)
        m.note = seekNote(m.seekPending) + "  (from the archive)"
    else if m.seekPending >= latest
        m.seekPending = latest
        m.note = "Live"
    else
        m.note = seekNote(m.seekPending)
    end if
    showOverlay()
    showThumb(m.seekFrom + m.seekPending, m.seekPending >= latest)
    m.seekTimer.control = "stop"
    m.seekTimer.control = "start"
end sub

' The Pi's picture of where the jump would land (target: a point in the
' player's timeline), over that moment on the progress bar. Not at live
' (the picture is on screen) or in the archive (the Pi has no pictures of it).
sub showThumb(target as Integer, atLive as Boolean)
    base = m.top.thumbBase
    if base = "" or atLive or target < 0
        m.thumbGroup.visible = false
        return
    end if
    behind = Int(m.video.duration) - target
    if behind < 0 then behind = 0
    ' The same address means another picture as the buffer grows, so a
    ' changing query keeps the Poster from reusing an old one.
    m.thumb.uri = base + behind.ToStr() + ".jpg?t=" + nowSeconds().ToStr()
    x = 96 + 864         ' the bar's middle when there's no guide
    p = m.programs
    if p <> invalid and type(p.now) = "roAssociativeArray" and p.now.ends > p.now.start
        moment = nowSeconds() - behind
        x = 96 + Int(1728 * clampFraction((moment - p.now.start) / (p.now.ends - p.now.start)))
    end if
    left = x - 196
    if left < 96 then left = 96
    if left > 96 + 1728 - 392 then left = 96 + 1728 - 392
    m.thumbGroup.translation = [left, 936 - 224 - 40]
    m.top.FindNode("thumbMark").translation = [x - left - 2, 224]
    m.thumbGroup.visible = true
end sub

function seekNote(offset as Integer) as String
    if offset < 0 then return "Back " + formatDuration(-offset)
    if offset > 0 then return "Ahead " + formatDuration(offset)
    return "Here"
end function

sub onSeekTimer()
    offset = m.seekPending
    m.seekPending = invalid
    m.thumbGroup.visible = false
    if offset = invalid or m.play = invalid then return
    if m.mode = "held"
        m.video.control = "resume"
        m.mode = "live"
    end if
    target = m.seekFrom + offset
    m.note = ""
    if target < 0 and canRewind()
        archiveFrom(target)
        return
    end if
    ' The buffer starts when the TV tuned in: say so, so a press that can't
    ' go further back isn't a mystery. Not past live either.
    if target < 1
        target = 0
        m.note = "Start of the buffer (when you tuned in to this channel)"
    end if
    if target >= liveSpot()
        goLive()
        return
    end if
    print "[player] buffer: jump "; offset; " s, from "; Int(m.seekFrom); " to "; Int(target); " s (duration "; Int(m.video.duration); ")"
    m.video.seek = target
    showOverlay()
end sub

' Before the start of the buffer, on a channel with an archive: the
' archive from that moment. The newest piece is about now, so a point in the
' player's timeline is that far before now. The archive runs a few minutes
' behind live (archiveEdge); a moment it hasn't recorded yet plays from its
' newest. Back returns to live, through the buffer again.
sub archiveFrom(target as Integer)
    moment = nowSeconds() - (Int(m.video.duration) - target)
    if moment > archiveEdge() then moment = archiveEdge()
    print "[player] buffer: before its start ("; target; " s); the archive from "; formatClock(moment)
    m.note = "From the archive:  " + formatClock(moment)
    startTimeshift(moment, 0)
end sub

' How far behind the Pi's newest piece live is (the Pi works it out from
' its piece and segment lengths).
sub onLiveGap()
    gap = m.top.liveGap
    if gap <= 0 or gap = m.LIVE_GAP then return
    m.LIVE_GAP = gap
    print "[player] buffer: live gap "; gap; " s; now "; Int(m.video.duration - m.video.position); " s from the newest"
end sub

' Where live is in the player's timeline: the newest segment, less the gap
' the player keeps at live.
function liveSpot() as Integer
    spot = Int(m.video.duration) - m.LIVE_GAP
    if spot < 0 then return 0
    return spot
end function

' Back to live within the buffer: a jump, no reload (a reload of a long
' buffered playlist starts at its beginning, not at live).
sub goLive()
    if m.mode = "held"
        m.video.control = "resume"
        m.mode = "live"
    end if
    m.thumbGroup.visible = false
    print "[player] buffer: back to live ("; liveSpot(); " s of "; Int(m.video.duration); ")"
    m.video.seek = liveSpot()
    showNote("Live")
end sub

' A buffered channel loaded (or reloaded) starts where the player chooses,
' which for a long buffer is its beginning: move it to live.
sub bufferStartAtLive()
    m.bufferStarted = true
    if m.video.duration - m.video.position > m.LIVE_GAP + 20
        print "[player] buffer: started "; Int(m.video.duration - m.video.position); " s back; moving to live"
        m.video.seek = liveSpot()
    end if
end sub

' Seconds behind live: the player's duration is how much is buffered, its
' position where it is in that, and at live it runs m.LIVE_GAP behind.
function bufferBehind() as Integer
    if m.play = invalid or not isTrue(m.play.buffered) then return 0
    behind = Int(m.video.duration - m.video.position) - m.LIVE_GAP
    if behind < 0 then return 0
    return behind
end function

' Seconds the picture is behind live: paused or rewound in the live buffer,
' or watching the archive; 0 at live.
function watchingBehind() as Integer
    if m.play = invalid then return 0
    if m.mode = "timeshift"
        position = Int(m.video.position)
        if not m.tsConfirmed then position = m.tsPlayStart
        behind = nowSeconds() - (m.tsStart + position)
        if behind < 0 then return 0
        return behind
    end if
    if m.mode = "paused" then return nowSeconds() - m.pausedAt
    if m.mode = "held" then return m.heldBehind + nowSeconds() - m.heldAt
    return bufferBehind()
end function

function clampFraction(f as Float) as Float
    if f < 0 then return 0
    if f > 1 then return 1
    return f
end function

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
    start = start - (start mod 60)      ' the minute it began in (see rewindLive)
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
    ' From the start of that minute: the archive comes in one-minute pieces,
    ' and playing from inside one means waiting for the piece up to there
    ' (through the audio fix, up to about 12 s instead of about 5).
    target = target - (target mod 60)
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
    t = m.play.timeshift
    ' Through the Pi (piBase), the archive is cut into pieces a minute at a
    ' time from its start, so begin where playback is wanted rather than
    ' minutes before it.
    piBase = asString(t.piBase)
    if piBase <> "" and playStart > 0
        startUtc = startUtc + playStart
        playStart = 0
    end if
    m.mode = "timeshift"
    ' The URL names a whole minute (serverTimeString), and the provider starts
    ' there: use that minute as the base and play the leftover seconds in, so
    ' "behind live", resume and continuation stay exact (review R11).
    extra = startUtc mod 60
    m.tsStart = startUtc - extra
    m.tsPlayStart = playStart + extra
    if m.tsPlayStart < 0 then m.tsPlayStart = 0
    m.tsConfirmed = false

    ' Ask only for minutes already recorded, so the stream ends instead of
    ' waiting on segments that don't exist yet.
    minutes = Int((archiveEdge() - m.tsStart) / 60) + 1
    if minutes < 1 then minutes = 1
    ' Through the audio fix, at most 15 minutes at a time: the provider takes
    ' longer to build a longer playlist (about 4 s for 11 minutes, 20 s for
    ' 90), and the next stretch loads when this one ends.
    if isTrue(m.play.relayed) and minutes > 15 then minutes = 15
    ' Through the Pi too: it holds what it has cut in memory (about 800 MB
    ' for 15 minutes of HD).
    if piBase <> "" and minutes > 15 then minutes = 15
    url = t.url.Replace("{start}", serverTimeString(m.tsStart, t.tz)).Replace("{duration}", minutes.ToStr())
    if piBase <> ""
        p = Instr(1, url, "://")
        if p > 0 then url = piBase + Left(url, p - 1) + "/" + Mid(url, p + 3)
    end if
    how = ""
    if piBase <> "" then how = " (in pieces through the Pi)"
    print "[player] timeshift from "; serverTimeString(m.tsStart, t.tz); " server time, "; minutes; " min"; how
    m.video.enableTrickPlay = true
    loadVideo(url, "hls", false, m.tsPlayStart)
    m.timeshiftTimeout.control = "stop"
    m.timeshiftTimeout.control = "start"
    showOverlay()
    focusPlayer()
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
    m.infoPanel.favorite = (m.top.channelLabel <> "")     ' "Favorite 3 of 8", or "" when not one
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
    else if m.mode = "paused" or m.mode = "held"
        m.modeLine.text = "PAUSED  -  press Play to continue"
    else if isTrue(m.play.buffered) and watchingBehind() > 15
        m.modeLine.text = "BEHIND LIVE  " + formatDuration(watchingBehind()) + "  -  Fast-forward: back to live"
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
    else if isTrue(m.play.buffered)
        m.hints.text = "Play/Pause: pause    Rewind: 30 s back    Left / Right: 10 s    Fast-forward: live    Up/Down: change favorite    OK again: channel info and favorites    Back: close"
    else if canRewind()
        m.hints.text = "Up/Down: change favorite    Play/Pause: pause    Rewind: go back    Replay: start this program over    OK again: channel info and favorites    Back: close"
    else
        m.hints.text = "Up / Down: change favorite     OK again: channel info and favorites     Back: close"
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
        ' Blue up to the moment being watched; behind live (paused, rewound
        ' or in the archive), lighter from there up to live.
        span = current.ends - current.start
        watching = now - watchingBehind()
        m.progressFill.width = 1728 * clampFraction((watching - current.start) / span)
        m.progressLive.width = 1728 * clampFraction((now - current.start) / span)
        m.progressTrack.visible = true
        m.progressFill.visible = true
        m.progressLive.visible = true
    else
        m.nowTitle.text = "No guide information"
        m.nowDesc.text = ""
        m.nowTime.text = ""
        m.progressTrack.visible = false
        m.progressFill.visible = false
        m.progressLive.visible = false
    end if

    if type(upcoming) = "roAssociativeArray"
        m.nextLine.text = "Next  " + formatClock(upcoming.start) + "   " + upcoming.title
    else
        m.nextLine.text = ""
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press
        ' A held jump key let go: the jump happens half a second later.
        if m.holdKey <> invalid and key = m.holdKey
            stopHold()
            return true
        end if
        return false
    end if
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
    ' Through the Pi's live buffer: pause and go back without the archive.
    if m.play <> invalid and isTrue(m.play.buffered) and (m.mode = "live" or m.mode = "held") and bufferKey(key) then return true
    ' Error panel with other copies: Up/Down stay in its list.
    if m.errorPanel.visible and m.errorCopyList.visible and (key = "up" or key = "down") then return true
    ' Error panel: OK tries again (a copy chosen in its list never gets here).
    if m.errorPanel.visible and m.play <> invalid and (key = "OK" or key = "play")
        retryPlayback()
        return true
    end if
    ' Everything below is live-only (channel step, favorite, pause, rewind,
    ' start over, channel info). Movies and episodes use the Video node's own
    ' controls, and * there must not save the movie ID as a favorite channel.
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
