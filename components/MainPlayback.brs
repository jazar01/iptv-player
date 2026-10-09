' Playback: building play requests, the resume prompt, saving positions,
' watched tracking, channel up/down through favorites, and the
' connection-limit check after a failure.

sub initPlayback()
    m.player = invalid
    m.playing = invalid         ' current play request
    m.watchedKey = ""           ' "kind:id" already marked watched in this play
    m.vodPending = invalid      ' a movie or episode waiting for its audio check (checkVodAudio)
    m.resumeDialog = invalid
    m.tzRules = invalid
    m.guideRules = invalid
    m.connections = invalid     ' { active, max } from the provider, last checked

    ' Live streams whose audio doesn't play here (undecodable AAC even
    ' through the audio fix, or Dolby this TV doesn't take): streamId ->
    ' retry after (UTC seconds). Playing one goes to a working copy instead.
    ' Kept on this Roku for 7 days (StateStore stream marks, with
    ' relayStreams), so each launch doesn't fail them once again; the
    ' provider changes sources, so after that they're tried again.
    marks = m.store.callFunc("getStreamMarks")
    m.badStreams = marks.bad
    m.MARK_SECONDS = 7 * 86400
    m.autoCopyFor = invalid     ' { streamId, name, item, afterFailure } waiting for its copies
    ' SearchTask answers about copies; when it's busy (indexing, a scoreboard)
    ' or not answering, don't leave the viewer with nothing (onAutoCopyTimeout).
    m.autoCopyTimer = CreateObject("roSGNode", "Timer")
    m.autoCopyTimer.duration = 4
    m.autoCopyTimer.ObserveField("fire", "onAutoCopyTimeout")
    m.top.AppendChild(m.autoCopyTimer)

    ' The audio fix (StreamRelay): streams that failed with "Unsupported AAC
    ' stream" play through it, streamId -> until (UTC seconds; 7 days, kept
    ' with badStreams). Only if the relayed stream fails too with an audio
    ' or format error is it marked bad (badStreams) and a copy tried.
    m.relayStreams = marks.relay
    ' The Dolby converter (a Raspberry Pi at home, Settings -> Dolby
    ' converter): streams whose Dolby audio this TV refused play through it,
    ' streamId -> until (7 days, kept with the other marks).
    m.convertStreams = marks.convert
    m.bufferKeepTimer = CreateObject("roSGNode", "Timer")       ' live buffer keep-alive
    m.bufferKeepTimer.duration = 10     ' its answer also brings the live gap and picture size
    m.bufferKeepTimer.repeat = true
    m.bufferKeepTimer.ObserveField("fire", "onBufferKeepTimer")
    m.top.AppendChild(m.bufferKeepTimer)
    m.converterDownUntil = 0    ' UTC seconds: converter not answering until then (converterDown)
    m.converterRetry = invalid  ' a converted channel that failed, while the converter is looked for
    m.converterSearchFor = ""   ' "settings" | "playback": who a converter search is for
    m.playingStarted = 0        ' live stream ID that has started playing (onLivePlaying)
    m.relay = CreateObject("roSGNode", "StreamRelay")
    ' It also searches the home network for a Dolby converter (MainLogin:
    ' Settings -> Dolby converter); the timer covers a relay that never answers.
    m.relay.ObserveField("discovered", "onConverterFound")
    m.converterSearchTimer = CreateObject("roSGNode", "Timer")
    m.converterSearchTimer.duration = 5
    m.converterSearchTimer.ObserveField("fire", "onConverterSearchTimeout")
    m.top.AppendChild(m.converterSearchTimer)
    m.relay.control = "RUN"

    ' Up/Down while watching: the channel shows at once, but its stream
    ' loads only once the presses stop, so skipping through channels
    ' doesn't open (and leave counting against the account) a stream each.
    m.stepTarget = invalid      ' favorite the presses have reached
    m.stepOrigin = invalid      ' the non-favorite channel Up/Down started from (onChannelStep)

    ' A favorite that failed and a stand-in that plays: offer to swap them.
    m.swapDeclined = {}         ' favorite IDs answered "Not now" this session
    m.swapDialog = invalid
    m.swapTimer = CreateObject("roSGNode", "Timer")
    m.swapTimer.duration = 6
    m.swapTimer.ObserveField("fire", "onSwapTimer")
    m.top.AppendChild(m.swapTimer)
    m.stepTimer = CreateObject("roSGNode", "Timer")
    m.stepTimer.duration = 0.6
    m.stepTimer.ObserveField("fire", "onStepTimer")
    m.top.AppendChild(m.stepTimer)
end sub

' item: { streamId, name, epgChannelId, archiveDays?, note?, direct? }. Archive
' days come from the catalog or search item, else from the live search index.
' A stream known to have audio this Roku can't play goes to a working copy
' instead (unless direct). note: shown on the live overlay once it starts.
sub playLive(item as Object)
    id = toInt(item.streamId)
    ' Chosen anywhere but Up/Down: a new starting point for Up/Down.
    if not isTrue(item.fromStep) then m.stepOrigin = invalid
    if isStreamBad(id) and not isTrue(item.direct) and not needsConverter(id)
        findPlayableCopy(item, false)
        return
    end if
    archiveDays = toInt(item.archiveDays)
    if archiveDays = 0 then archiveDays = toInt(m.archiveDays[id.ToStr()])
    play = {
        kind: "live"
        id: id
        name: asString(item.name)
        epgChannelId: asString(item.epgChannelId)
        url: streamUrl("live", id, "m3u8")
        streamFormat: "hls"
        archiveDays: archiveDays
        note: asString(item.note)
        stepFrom: toInt(item.stepFrom)     ' a copy played for this channel: Up/Down and the label go by it
        replaceFor: toInt(item.replaceFor)  ' a favorite that failed, this standing in for it (onSwapTimer)
    }
    if archiveDays > 0 then play.timeshift = timeshiftInfo(id)
    if liveBufferOn() and not isTrue(item.noBuffer)
        ' Through the Pi's live buffer: pause and rewind on every channel.
        ' Audio this TV can't take (Dolby, or the AAC the relay fixes) is
        ' converted there too.
        bufferPlay(play, needsConverter(id) or needsRelay(id))
        pingConverter(id)
    else if needsConverter(id)
        convertPlay(play)
        pingConverter(id)
    else if needsRelay(id)
        relayPlay(play)
    end if
    startPlayer(play, 0)
end sub

' ---------------------------------------------------------------------------
' Live buffer: the Pi's converter service (pi/dolby-converter/buffer.py)
' records the channel being watched in memory and serves it as one growing
' playlist, so the player can pause and go back. On by default when a Pi is
' set up (Settings -> Live buffer). The Pi is told when the TV leaves the
' channel, and kept going while it plays (it stops a channel nobody asks
' about for 45 s, freeing the account's connection).

function liveBufferOn() as Boolean
    return converterAddress() <> "" and not converterDown() and m.store.callFunc("getSettings").liveBuffer
end function

' Settings -> Live buffer: takes effect from the next channel tuned.
sub toggleLiveBuffer()
    on = not m.store.callFunc("getSettings").liveBuffer
    if not m.store.callFunc("setLiveBuffer", on)
        showToast("Couldn't save the change. Storage may be full.")
    else if not on
        showToast("Live buffer off: live channels pause and rewind through the provider's archive")
    else if converterAddress() = ""
        showToast("Live buffer on. It needs the Dolby converter on the Raspberry Pi: set that up above")
    else
        showToast("Live buffer on: pause and rewind any live channel from when you tuned in")
    end if
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
end sub

sub bufferPlay(play as Object, convert as Boolean)
    p = Instr(1, play.url, "://")
    if p = 0 then return
    route = "b"
    if convert then route = "bc"
    play.bufferPath = Left(play.url, p - 1) + "/" + Mid(play.url, p + 3)
    play.url = "http://" + converterAddress() + "/" + route + "/" + play.bufferPath
    play.buffered = true
    play.converted = convert
    ' The provider's archive (Start over, going back past the buffer) goes
    ' through the Pi too, cut into 2-second pieces (archive.py): its HD
    ' one-minute segments (53 MB) are more than this Roku's video buffer
    ' holds. Converted on the way when the audio needs it.
    if type(play.timeshift) = "roAssociativeArray"
        piBase = "http://" + converterAddress() + "/a/"
        if convert then piBase = "http://" + converterAddress() + "/ac/"
        play.timeshift.piBase = piBase
    end if
end sub

sub sendBufferNote(play as Dynamic, route as String)
    if type(play) <> "roAssociativeArray" or not isTrue(play.buffered) then return
    sendRequest({ id: "buffer", url: "http://" + converterAddress() + "/" + route + "/" + play.bufferPath, priority: "low", timeoutMs: 3000, context: { path: play.bufferPath } })
end sub

' The keep-alive's answer: how far behind the Pi's newest piece the player
' should sit at live (the Pi works it out from its piece and segment
' lengths: about 14 s).
sub onBufferNote(res as Object)
    if not res.ok or type(res.data) <> "roAssociativeArray" then return
    p = m.playing
    if m.player = invalid or p = invalid or asString(p.bufferPath) <> asString(res.context.path) then return
    if toInt(res.data.liveGap) > 0 then m.player.liveGap = toInt(res.data.liveGap)
    if asString(res.data.id) <> "" then m.player.thumbBase = "http://" + converterAddress() + "/bt/" + asString(res.data.id) + "/"
    v = res.data.video
    if type(v) = "roAssociativeArray" and toInt(v.height) > 0 then m.player.streamPicture = pictureText(toInt(v.width), toInt(v.height), toInt(v.fps))
end sub

' "Full HD 1920x1080, 60 fps", as measured by the Pi.
function pictureText(width as Integer, height as Integer, fps as Integer) as String
    name = "SD"
    if height >= 2000
        name = "4K"
    else if height >= 1000
        name = "Full HD"
    else if height >= 700
        name = "HD"
    end if
    text = name + " " + width.ToStr() + "x" + height.ToStr()
    if fps > 0 then text = text + ", " + fps.ToStr() + " fps"
    return text
end function

sub onBufferKeepTimer()
    if m.player <> invalid then sendBufferNote(m.playing, "bk")
end sub

' Archive (catch-up) URL: an HLS playlist of one-minute segments. {start} is
' server-local "YYYY-MM-DD:HH-MM", {duration} is minutes. The .ts and
' timeshift.php forms are served too, but Roku can't play them (it reads
' them as MP4). Contains the password: never print.
function timeshiftInfo(id as Integer) as Object
    creds = m.api.credentials
    user = urlEncode(asString(creds.username))
    pass = urlEncode(asString(creds.password))
    return {
        url: creds.server + "/timeshift/" + user + "/" + pass + "/{duration}/{start}/" + id.ToStr() + ".m3u8"
        tz: timezoneRule(m.serverTimezone)
        lagSeconds: archiveLagSeconds()
    }
end function

function guideRules() as Object
    if m.guideRules = invalid
        m.guideRules = ParseJson(ReadAsciiFile("pkg:/data/guide-rules.json"))
        if type(m.guideRules) <> "roAssociativeArray" then m.guideRules = {}
    end if
    return m.guideRules
end function

function archiveLagSeconds() as Integer
    t = guideRules().timeshift
    if type(t) = "roAssociativeArray" and toInt(t.archiveLagSeconds) > 0 then return toInt(t.archiveLagSeconds)
    return 300
end function

' Time-zone rule for the server's zone, from data/guide-rules.json.
function timezoneRule(name as String) as Dynamic
    if m.tzRules = invalid
        m.tzRules = {}
        zones = guideRules().timezones
        if type(zones) = "roAssociativeArray" then m.tzRules = zones
    end if
    rule = m.tzRules[name]
    if rule = invalid
        print "[main] WARNING: no time-zone rule for '"; name; "'; using UTC for timeshift"
        rule = { standard: 0, daylight: 0, dst: "" }
    end if
    return rule
end function

' item: { itemId, name, ext, duration? }. askResume: offer Resume / Start over.
sub playMovie(item as Object, askResume as Boolean)
    id = toInt(item.itemId)
    ext = asString(item.ext)
    if ext = "" then ext = "mp4"
    play = {
        kind: "movie"
        id: id
        name: asString(item.name)
        ext: ext
        duration: toInt(item.duration)
        url: streamUrl("movie", id, ext)
        streamFormat: streamFormatFor(ext)
    }
    position = m.store.callFunc("getPosition", "movie", id)
    if askResume
        askToResume(play, position)
    else
        startPlayer(play, position)
    end if
end sub

' ep: { id, season, episode, name, ext, duration, seriesId, seriesName, year }
sub playEpisode(ep as Object, askResume as Boolean)
    id = toInt(ep.id)
    ext = asString(ep.ext)
    if ext = "" then ext = "mp4"
    play = {
        kind: "episode"
        id: id
        name: asString(ep.name)
        ext: ext
        duration: toInt(ep.duration)
        seriesId: toInt(ep.seriesId)
        seriesName: asString(ep.seriesName)
        year: toInt(ep.year)
        season: toInt(ep.season)
        episode: toInt(ep.episode)
        url: streamUrl("series", id, ext)
        streamFormat: streamFormatFor(ext)
    }
    ' A position saved under the episode's old ID (provider renumbering)
    ' moves to this one first.
    m.store.callFunc("remapEpisodes", play.seriesId, [{ id: id, season: play.season, episode: play.episode }])
    position = m.store.callFunc("getPosition", "episode", id)
    if askResume
        askToResume(play, position)
    else
        startPlayer(play, position)
    end if
end sub

' {server}/{live|movie|series}/{user}/{pass}/{id}.{ext}. Contains the
' password: never print it. Uses urlEncode(), not roUrlTransfer.Escape():
' roUrlTransfer can't be created on the render thread.
function streamUrl(path as String, id as Dynamic, ext as String) as String
    creds = m.api.credentials
    return creds.server + "/" + path + "/" + urlEncode(asString(creds.username)) + "/" + urlEncode(asString(creds.password)) + "/" + toInt(id).ToStr() + "." + ext
end function

' Container extension -> Video streamFormat; "" lets Roku decide.
function streamFormatFor(ext as String) as String
    e = LCase(ext)
    if e = "m3u8" then return "hls"
    if e = "mp4" or e = "m4v" or e = "mov" then return "mp4"
    if e = "mkv" then return "mkv"
    return ""
end function

' ---------------------------------------------------------------------------
' Resume prompt

sub askToResume(play as Object, position as Integer)
    if position < 30
        startPlayer(play, 0)
        return
    end if
    dlg = CreateObject("roSGNode", "StandardMessageDialog")
    dlg.title = play.name
    dlg.message = ["You stopped at " + formatDuration(position) + "."]
    dlg.buttons = ["Resume from " + formatDuration(position), "Start from the beginning"]
    dlg.ObserveField("buttonSelected", "onResumeButton")
    dlg.ObserveField("wasClosed", "onResumeClosed")
    m.resumeDialog = { dialog: dlg, play: play, position: position }
    m.top.dialog = dlg
end sub

sub onResumeButton()
    d = m.resumeDialog
    if d = invalid then return
    m.resumeDialog = invalid
    choice = d.dialog.buttonSelected
    d.dialog.close = true
    if choice = 0
        startPlayer(d.play, d.position)
    else
        startPlayer(d.play, 0)
    end if
end sub

' Back on the prompt: play nothing.
sub onResumeClosed()
    m.resumeDialog = invalid
end sub

' ---------------------------------------------------------------------------
' Player

sub startPlayer(play as Object, position as Integer)
    ' A movie or episode on a TV that can't play Dolby: its audio is checked
    ' first, and a file with no track this TV can play goes through the Pi
    ' (checkVodAudio). Played straight, it was silent, with no error.
    if (play.kind = "movie" or play.kind = "episode") and not isTrue(play.audioChecked) and vodNeedsCheck()
        checkVodAudio(play, position)
        return
    end if
    play.startPosition = position
    ' Leaving a buffered channel: the Pi can stop recording it.
    previous = m.playing
    if previous <> invalid and isTrue(previous.buffered) and asString(previous.bufferPath) <> asString(play.bufferPath) then sendBufferNote(previous, "bq")
    m.playing = play
    if isTrue(play.buffered) then m.bufferKeepTimer.control = "start" else m.bufferKeepTimer.control = "stop"
    m.watchedKey = ""
    m.usageCounted = false      ' one usage point per viewing session
    if m.player = invalid
        m.player = CreateObject("roSGNode", "PlayerScreen")
        m.player.ObserveField("progress", "onPlayerProgress")
        m.player.ObserveField("failed", "onPlayerFailed")
        m.player.ObserveField("channelStep", "onChannelStep")
        m.player.ObserveField("liveViewed", "onLiveViewed")
        m.player.ObserveField("livePlaying", "onLivePlaying")
        m.player.ObserveField("liveWatched", "onLiveWatched")
        m.player.channelViewSeconds = m.store.callFunc("getChannelViewSeconds")
        m.player.ObserveField("toggleFavorite", "onPlayerToggleFavorite")
        m.player.ObserveField("infoRequested", "onPlayerInfoRequested")
        m.player.ObserveField("copyChosen", "onInfoCopyChosen")
        m.player.ObserveField("closed", "onPlayerClosed")
        pushOverlay(m.player)
    end if
    if play.kind = "live"
        labelId = play.id
        if toInt(play.stepFrom) > 0 then labelId = play.stepFrom
        m.player.channelLabel = favoriteLabel(labelId)
    end if
    m.player.content = play

    if play.kind = "live"
        cached = m.epg.callFunc("getPrograms", [play.id])
        entry = cached[play.id.ToStr()]
        if entry <> invalid then m.player.programs = entry
        m.epg.callFunc("want", [play.id])
    end if
end sub

' ---------------------------------------------------------------------------
' Movies and episodes whose only audio is Dolby, on a TV that takes stereo:
' the Pi reads the file's tracks (probe.py, /p/; often already asked by the
' details page and kept there), and if none can play here, the file plays
' through the Pi from the resume point with its audio converted (vod.py,
' /v/<start>/). The player's position then counts from that point
' (vodOffset, added back in its progress reports).

function vodNeedsCheck() as Boolean
    if converterAddress() = "" or converterDown() then return false
    info = CreateObject("roDeviceInfo")
    return not (canPlayAudio(info, "ac3") and canPlayAudio(info, "eac3"))
end function

sub checkVodAudio(play as Object, position as Integer)
    play.audioChecked = true
    m.vodPending = { play: play, position: position }
    showToast("Checking this file's sound ...")
    path = "movie"
    if play.kind = "episode" then path = "series"
    url = streamUrl(path, play.id, asString(play.ext))
    p = Instr(1, url, "://")
    sendRequest({ id: "vodAudio", url: "http://" + converterAddress() + "/p/" + Left(url, p - 1) + "/" + Mid(url, p + 3), timeoutMs: 12000, context: { kind: play.kind, id: play.id } })
end sub

sub onVodAudio(res as Object)
    pending = m.vodPending
    if pending = invalid or toInt(res.context.id) <> toInt(pending.play.id) then return
    m.vodPending = invalid
    play = pending.play
    position = pending.position
    tracks = []
    if res.ok and type(res.data) = "roAssociativeArray" and isTrue(res.data.ok) and type(res.data.audio) = "roArray" then tracks = res.data.audio
    if tracks.Count() > 0 and not anyTrackPlays(tracks)
        url = play.url
        p = Instr(1, url, "://")
        play.url = "http://" + converterAddress() + "/v/" + position.ToStr() + "/" + Left(url, p - 1) + "/" + Mid(url, p + 3)
        play.streamFormat = "hls"
        play.vodOffset = position
        play.converted = true
        print "[main] "; play.kind; " "; play.id; ": no audio track this TV plays ("; asString(tracks[0].codec); "); through the Pi from "; position; " s"
        startPlayer(play, 0)
        return
    end if
    if tracks.Count() = 0 then print "[main] "; play.kind; " "; play.id; ": audio not checked ("; friendlyRequestError(res); "); playing it directly"
    startPlayer(play, position)
end sub

' The Pi's track names (probe.py) this Roku can decode as connected.
function anyTrackPlays(tracks as Object) as Boolean
    info = CreateObject("roDeviceInfo")
    codecs = { "aac": "aac", "mp3": "mp3", "mp2": "mp3", "flac": "flac", "opus": "opus", "vorbis": "vorbis", "pcm": "lpcm", "dolby digital": "ac3", "dolby digital plus": "eac3", "dolby digital plus atmos": "eac3" }
    for each t in tracks
        name = LCase(asString(t.codec))
        codec = codecs[name]
        if codec <> invalid and canPlayAudio(info, codec) then return true
    end for
    return false
end function

sub onPlayerClosed()
    if m.player = invalid then return
    player = m.player
    m.player = invalid
    sendBufferNote(m.playing, "bq")
    m.bufferKeepTimer.control = "stop"
    m.playing = invalid
    if m.infoFor <> invalid and m.infoFor.source = "player" then m.infoFor = invalid
    m.stepTimer.control = "stop"
    m.stepTarget = invalid
    removeOverlay(player)
    ' Back on a movie page: its Resume button reflects where playback stopped.
    if m.movieScreen <> invalid and m.movieItem <> invalid then m.movieScreen.position = m.store.callFunc("getPosition", "movie", m.movieItem.itemId)
    ' Home, catalog tags and the Watch List (a movie watched to the end
    ' leaves it).
    onWatchListChanged()
    refreshSeriesProgress()
end sub

' Every 30 s and on stop. Around 90% counts as watched: the resume entry is
' cleared and, for an episode, the series moves on to the next one.
sub onPlayerProgress(event as Object)
    p = event.GetData()
    play = p.play
    if type(play) <> "roAssociativeArray" or play.kind = "live" then return
    key = play.kind + ":" + toInt(play.id).ToStr()
    if key = m.watchedKey then return

    entry = {
        kind: play.kind
        id: play.id
        name: play.name
        ext: play.ext
        position: p.position
        duration: p.duration
        seriesId: play.seriesId
        seriesName: play.seriesName
        year: play.year
        season: play.season
        episode: play.episode
    }
    ' Usage ordering: one point per viewing session of a movie or series,
    ' once it's really been watched (the first progress report).
    if not isTrue(m.usageCounted) and p.position >= 30
        m.usageCounted = true
        usageKey = "m" + toInt(play.id).ToStr()
        if play.kind = "episode" then usageKey = "s" + toInt(play.seriesId).ToStr()
        m.store.callFunc("recordUsage", usageKey)
    end if

    saved = true
    if isTrue(p.finished) or (p.duration > 0 and p.position >= p.duration * 0.9)
        entry.fromPlayback = true
        if play.kind = "episode" then entry.nextEpisode = nextEpisodeAfter(play.seriesId, play.id)
        saved = m.store.callFunc("markWatched", entry)
        ' Only once it's saved; otherwise the next progress report tries again.
        if saved
            m.watchedKey = key
            print "[main] watched "; key
        end if
    else if p.position >= 30
        saved = m.store.callFunc("savePosition", entry)
    end if
    if not saved then print "[main] WARNING: could not save progress for "; key
end sub

' The Video node failed. If the account is at its connection limit, say so
' instead of the generic message, but not for format errors (-5 codec,
' -6 protected): those streams did connect, and a full count then only
' reflects streams just left that the provider hasn't timed out yet.
sub onPlayerFailed(event as Object)
    failure = event.GetData()
    m.failCode = toInt(failure.code)
    live = m.playing <> invalid and m.playing.kind = "live"
    ' Dolby this TV doesn't take, and a Dolby converter is set up: play it
    ' again through the converter (full quality, stereo AAC). If the
    ' converter was just found not answering, a copy plays straight away,
    ' without marking the channel (it goes through the converter again once
    ' that answers).
    if live and isTrue(failure.dolbyUnsupported) and not isTrue(m.playing.converted) and converterAddress() <> "" and converterDown()
        print "[main] stream "; m.playing.id; " has Dolby audio; the Dolby converter isn't answering, so a copy plays"
        findPlayableCopy({ streamId: m.playing.id, name: m.playing.name, epgChannelId: m.playing.epgChannelId, archiveDays: m.playing.archiveDays, stepFrom: m.playing.stepFrom }, true)
        return
    end if
    if live and isTrue(failure.dolbyUnsupported) and not isTrue(m.playing.converted) and converterAddress() <> ""
        id = toInt(m.playing.id)
        m.convertStreams[id.ToStr()] = nowSeconds() + m.MARK_SECONDS
        saveStreamMarks()
        print "[main] stream "; id; " has Dolby audio this TV doesn't take; playing it through the Dolby converter"
        playLive({ streamId: id, name: m.playing.name, epgChannelId: m.playing.epgChannelId, archiveDays: m.playing.archiveDays, stepFrom: m.playing.stepFrom, replaceFor: m.playing.replaceFor, direct: true, note: "This channel's Dolby audio is converted to stereo by the Raspberry Pi." })
        return
    end if
    ' Failed through the converter: the Pi off or moved, or the channel
    ' itself. A quick search of the home network tells which (onConverter-
    ' SearchDone): the Pi at a new address plays it again from there; no
    ' answer pauses the converter for 10 minutes; the Pi where it was means
    ' the channel itself failed. Either way but the first, a copy plays.
    if live and (isTrue(m.playing.converted) or (isTrue(m.playing.buffered) and not isTrue(failure.audioUnsupported)))
        converterFailed("code " + m.failCode.ToStr())
        return
    end if
    ' Audio this Roku can't decode: remember the stream and go straight to a
    ' working copy (no connection check: the stream did connect).
    if m.playing <> invalid and m.playing.kind = "live" and isTrue(failure.audioUnsupported) and not isTrue(m.playing.relayed) and m.relay.port > 0
        ' First time: play it again through the audio fix.
        id = toInt(m.playing.id)
        m.relayStreams[id.ToStr()] = nowSeconds() + m.MARK_SECONDS
        saveStreamMarks()
        print "[main] stream "; id; " has audio Roku rejects; playing it through the audio fix"
        playLive({ streamId: id, name: m.playing.name, epgChannelId: m.playing.epgChannelId, archiveDays: m.playing.archiveDays, stepFrom: m.playing.stepFrom, replaceFor: m.playing.replaceFor, direct: true, note: "This channel's audio is being repaired for this Roku." })
        return
    end if
    ' Dolby audio this TV doesn't accept, too: the relay can't help, but a
    ' copy with other audio can (Family Room, Oct 2026). Only audio and
    ' format errors (-5) count: a repaired stream that fails otherwise (the
    ' provider, a timeout, a stall, the connection limit) takes the normal
    ' path below, like any other channel.
    relayedAudio = m.playing <> invalid and isTrue(m.playing.relayed) and m.failCode = -5
    if m.playing <> invalid and m.playing.kind = "live" and (isTrue(failure.audioUnsupported) or isTrue(failure.dolbyUnsupported) or relayedAudio)
        ' Failed even through the audio fix (or the fix isn't running): mark
        ' it bad and go to a working copy.
        m.relayStreams.Delete(toInt(m.playing.id).ToStr())
        markStreamBad(m.playing.id)
        findPlayableCopy({ streamId: m.playing.id, name: m.playing.name, epgChannelId: m.playing.epgChannelId, archiveDays: m.playing.archiveDays, stepFrom: m.playing.stepFrom }, true)
        return
    end if
    checkConnections("failed")
    ' A live channel: offer its other copies on the error panel.
    if m.playing <> invalid and m.playing.kind = "live" then searchSend("infoRequest", { id: "failed", streamId: m.playing.id, market: m.store.callFunc("getMarket").key, similar: true })
end sub

' ---------------------------------------------------------------------------
' Streams with audio this Roku can't decode

sub markStreamBad(streamId as Dynamic)
    key = toInt(streamId).ToStr()
    m.badStreams[key] = nowSeconds() + m.MARK_SECONDS
    saveStreamMarks()
    print "[main] stream "; key; " has audio that doesn't play here; skipping it for 7 days"
end sub

sub saveStreamMarks()
    m.store.callFunc("setStreamMarks", { relay: m.relayStreams, convert: m.convertStreams, bad: m.badStreams })
end sub

' ---------------------------------------------------------------------------
' Dolby converter: a service on a home Raspberry Pi (pi/dolby-converter)
' that passes a stream on with its video untouched and its Dolby audio
' converted to AAC stereo, for TVs that take stereo only. Its address goes
' in front of the provider URL: http://<pi>/x/http/<host>/<path>.

' "192.168.222.99:8790", or "" when none is set up.
function converterAddress() as String
    return m.store.callFunc("getSettings").dolbyConverter
end function

' Marked for the converter (or, with converter_test in the manifest, every
' live channel, to try it on a TV that plays Dolby itself).
function needsConverter(streamId as Dynamic) as Boolean
    if converterAddress() = "" or converterDown() then return false
    if CreateObject("roAppInfo").GetValue("converter_test") = "1" then return true
    until = m.convertStreams[toInt(streamId).ToStr()]
    return until <> invalid and nowSeconds() < until
end function

' The converter didn't answer a search lately: Dolby channels use copies
' until converterDownUntil (10 minutes), or until Settings finds it working.
function converterDown() as Boolean
    return nowSeconds() < m.converterDownUntil
end function

' The channel playing through the converter failed (or the converter didn't
' answer its check): look for the converter, then converterSearchDone.
sub converterFailed(reason as String)
    p = m.playing
    if p = invalid then return
    r = m.converterRetry
    if r <> invalid and toInt(r.streamId) = toInt(p.id) then return      ' already looking
    print "[main] stream "; p.id; " failed through the Dolby converter ("; reason; "); looking for the converter"
    m.converterRetry = { streamId: p.id, name: p.name, epgChannelId: p.epgChannelId, archiveDays: p.archiveDays, stepFrom: p.stepFrom, replaceFor: p.replaceFor, address: converterAddress(), bufferOnly: isTrue(p.buffered) and not isTrue(p.converted) }
    if m.player <> invalid and isTrue(m.converterRetry.bufferOnly) then m.player.errorText = "The live buffer didn't play this channel. Checking it ..."
    if m.player <> invalid and not isTrue(m.converterRetry.bufferOnly) then m.player.errorText = "The Dolby converter didn't play this channel. Checking it ..."
    m.converterSearchFor = "playback"
    m.converterSearchTimer.control = "stop"
    m.converterSearchTimer.control = "start"
    m.relay.discover = { id: "playback" }
end sub

' Each play through the converter also asks its /health page: a converter
' that's off makes Roku's player wait at "Loading" (25 s, the start limit)
' instead of failing, and this finds out in about 2 s.
sub pingConverter(streamId as Integer)
    m.playingStarted = 0
    address = converterAddress()
    sendRequest({ id: "converterPing", url: "http://" + address + "/health", context: { streamId: streamId, address: address }, timeoutMs: 2000 })
end sub

sub onConverterPing(res as Object)
    if res.ok then return
    id = toInt(res.context.streamId)
    p = m.playing
    ' Only for the channel still loading through that converter.
    if p = invalid or toInt(p.id) <> id or not isTrue(p.converted) or m.playingStarted = id then return
    if asString(res.context.address) <> converterAddress() then return
    converterFailed("no answer from it")
end sub

' The search after a converted channel failed (see onPlayerFailed).
sub converterSearchDone(result as Object)
    m.converterSearchFor = ""
    m.converterSearchTimer.control = "stop"
    r = m.converterRetry
    m.converterRetry = invalid
    if r = invalid then return
    id = toInt(r.streamId)
    stillOn = m.player <> invalid and m.playing <> invalid and toInt(m.playing.id) = id
    found = asString(result.address)
    if isTrue(result.found) and found <> r.address
        ' The Pi moved (a new address from the router): use it from now on.
        print "[main] Dolby converter found at a new address, "; found; " (was "; r.address; ")"
        m.store.callFunc("setSetting", "dolbyConverter", found)
        m.converterStatus = ""
        if stillOn
            r.direct = true
            r.note = "The Dolby converter moved to " + found + "; playing through it there."
            playLive(r)
        end if
        return
    end if
    if isTrue(result.found)
        ' The Pi answered where it was: this channel failed by itself.
        print "[main] the Dolby converter answers; stream "; id; " failed through it, so a copy plays"
        m.convertStreams.Delete(id.ToStr())
        saveStreamMarks()
    else
        print "[main] the Dolby converter isn't answering; Dolby channels use copies for 10 minutes"
        m.converterDownUntil = nowSeconds() + 600
        m.converterStatus = "NOT answering; Dolby channels use other copies"
    end if
    if not stillOn then return
    if isTrue(r.bufferOnly)
        ' Only the live buffer failed: the channel straight from the provider.
        r.noBuffer = true
        r.direct = true
        playLive(r)
    else
        findPlayableCopy(r, true)
    end if
end sub

' http://host:port/path -> http://<pi>/x/http/host:port/path. Placeholders
' in the path ({start}, {duration} in archive URLs) pass through.
function converterUrl(url as String) as String
    p = Instr(1, url, "://")
    if p = 0 then return url
    return "http://" + converterAddress() + "/x/" + Left(url, p - 1) + "/" + Mid(url, p + 3)
end function

sub convertPlay(play as Object)
    play.url = converterUrl(play.url)
    play.converted = true
    if type(play.timeshift) = "roAssociativeArray" then play.timeshift.url = converterUrl(play.timeshift.url)
end sub

function needsRelay(streamId as Dynamic) as Boolean
    until = m.relayStreams[toInt(streamId).ToStr()]
    return until <> invalid and nowSeconds() < until and m.relay.port > 0
end function

' Points a live play request (and its archive) at the audio fix. The relay
' keeps the provider URLs (with the password); the player only sees
' 127.0.0.1 addresses.
sub relayPlay(play as Object)
    base = "http://127.0.0.1:" + m.relay.port.ToStr()
    key = "c" + play.id.ToStr()
    m.relay.add = { key: key, url: play.url }
    play.url = base + "/p/" + key + ".m3u8"
    play.relayed = true
    if type(play.timeshift) = "roAssociativeArray"
        tkey = "t" + play.id.ToStr()
        m.relay.add = { key: tkey, url: play.timeshift.url }
        play.timeshift.url = base + "/t/" + tkey + "/{duration}/{start}.m3u8"
    end if
end sub

function isStreamBad(streamId as Dynamic) as Boolean
    until = m.badStreams[toInt(streamId).ToStr()]
    return until <> invalid and nowSeconds() < until
end function

' Asks SearchTask for the channel's copies; onAutoCopies plays the first one
' not known to be bad. afterFailure: the channel just failed in the player
' (else it's about to be played and is already known to be bad).
sub findPlayableCopy(item as Object, afterFailure as Boolean)
    m.autoCopyFor = { streamId: toInt(item.streamId), name: asString(item.name), item: item, afterFailure: afterFailure }
    searchSend("infoRequest", { id: "autocopy", streamId: toInt(item.streamId), market: m.store.callFunc("getMarket").key })
    m.autoCopyTimer.control = "stop"
    m.autoCopyTimer.control = "start"
end sub

sub onAutoCopies(result as Object)
    a = m.autoCopyFor
    if a = invalid or toInt(result.streamId) <> a.streamId then return
    m.autoCopyFor = invalid
    m.autoCopyTimer.control = "stop"
    if a.afterFailure and (m.player = invalid or m.playing = invalid or toInt(m.playing.id) <> a.streamId) then return
    copy = invalid
    if type(result.copies) = "roArray"
        for each c in result.copies
            if copy = invalid and not isStreamBad(c.streamId) then copy = c
        end for
    end if
    if copy <> invalid
        print "[main] playing copy "; copy.streamId; " instead of "; a.streamId
        stepFrom = toInt(a.item.stepFrom)
        if stepFrom = 0 then stepFrom = a.streamId
        playLive({ streamId: copy.streamId, name: copy.name, epgChannelId: copy.epgChannelId, archiveDays: copy.archiveDays, direct: true, stepFrom: stepFrom, replaceFor: stepFrom, note: "Playing " + localizeName(asString(copy.name)) + ": another copy's audio doesn't play on Roku." })
    else if not a.afterFailure
        ' Known bad, but no other copy: try it anyway (the provider may have
        ' changed it since).
        item = a.item
        item.direct = true
        playLive(item)
    else
        ' No working copy: the error panel, with similar channels if any.
        print "[main] no playable copy of "; a.streamId
        m.player.errorText = "This channel's audio doesn't play on this TV, and no other copy of it does. The provider sometimes changes this; try again later."
        ' Similar channels by the name of the channel chosen, not of a copy
        ' ("LBW: FOX News" would only find other LBW channels).
        original = toInt(a.item.stepFrom)
        if original = 0 then original = a.streamId
        searchSend("infoRequest", { id: "failed", streamId: original, market: m.store.callFunc("getMarket").key, similar: true })
    end if
end sub

' No answer about copies in time: play the channel itself (it may play
' now), or, after a failure, say so on the error panel.
sub onAutoCopyTimeout()
    a = m.autoCopyFor
    if a = invalid then return
    m.autoCopyFor = invalid
    print "[main] no answer about copies of "; a.streamId; " in time (search busy or not answering)"
    if not a.afterFailure
        item = a.item
        item.direct = true
        playLive(item)
    else if m.player <> invalid and m.playing <> invalid and toInt(m.playing.id) = a.streamId
        m.player.errorText = "This channel didn't play here, and the app couldn't look for another copy just now. Try again in a moment, or choose another channel."
    end if
end sub

' How many of the account's connections are in use (player_api.php with no
' action: user_info.active_cons / max_connections). Counts every device on
' the account, and streams just left until the provider times them out.
' reason: "failed" | "info" | "settings"
sub checkConnections(reason as String)
    sendRequest({ id: "connCheck", action: "", context: { reason: reason } })
end sub

sub onConnectionCheck(res as Object)
    result = evaluateLogin(res)
    if not result.ok then return
    m.connections = { active: result.activeConnections, max: result.maxConnections }
    print "[main] connection check: "; result.activeConnections; " of "; result.maxConnections; " in use"
    reason = ""
    if type(res.context) = "roAssociativeArray" then reason = asString(res.context.reason)
    ' -100 (kept stalling) and -101 (stream ended): their own reloads fill the
    ' count, so no blame either.
    formatError = (m.failCode = -5 or m.failCode = -6 or m.failCode = -100 or m.failCode = -101)
    if reason = "failed" and not formatError and m.player <> invalid and result.maxConnections > 0 and result.activeConnections >= result.maxConnections
        m.player.errorText = "All " + result.maxConnections.ToStr() + " connections on this account are in use. Stop watching on another TV, then try again."
    else if reason = "info"
        deliverChannelInfo()
    else if reason = "settings"
        settings = m.sections.settings
        if settings <> invalid then settings.info = settingsInfo()
    end if
end sub

' "2 of 3 in use", or "" before the first check.
function connectionsText() as String
    c = m.connections
    if c = invalid or c.max <= 0 then return ""
    return c.active.ToStr() + " of " + c.max.ToStr() + " in use"
end function

' A minute on a live channel: add it to Recently Viewed. Home refreshes when
' the player closes.
sub onLiveViewed(event as Object)
    channel = event.GetData()
    if not m.store.callFunc("addRecent", channel) then print "[main] WARNING: could not save recently viewed "; channel.name
end sub

' A few minutes on a live channel: one use for usage ordering.
sub onLiveWatched(event as Object)
    m.store.callFunc("recordUsage", "c" + toInt(event.GetData().streamId).ToStr())
end sub

' * during live playback: same as * in a channel list, then update the
' player's "Favorite N of M".
sub onPlayerToggleFavorite(event as Object)
    onToggleFavorite(event)
    if m.player <> invalid and m.playing <> invalid then m.player.channelLabel = favoriteLabel(m.playing.id)
end sub

' Up / Down during live playback: next / previous favorite. From a channel
' that isn't a favorite, Up goes to the first favorite and Down to the last.
sub onChannelStep(event as Object)
    direction = event.GetData()     ' "step" is reserved in BrightScript
    if m.playing = invalid or m.playing.kind <> "live" then return
    favorites = m.store.callFunc("getFavorites")
    count = favorites.Count()
    if count = 0 then return
    current = m.playing.id
    if toInt(m.playing.stepFrom) > 0 then current = m.playing.stepFrom
    if m.stepTarget <> invalid then current = m.stepTarget.streamId
    ' A channel that isn't a favorite joins the loop just before the first
    ' favorite, so Up then Down comes back to it.
    if m.stepOrigin = invalid and favoriteIndex(favorites, current) < 0
        m.stepOrigin = { streamId: toInt(current), name: m.playing.name, epgChannelId: asString(m.playing.epgChannelId), archiveDays: m.playing.archiveDays }
    end if
    ring = []
    if m.stepOrigin <> invalid then ring.Push(m.stepOrigin)
    ring.Append(favorites)
    count = ring.Count()
    index = favoriteIndex(ring, current)
    if index < 0 then index = 0
    index = (index + direction + count) mod count
    f = ring[index]
    m.stepTarget = { streamId: f.streamId, name: f.name, epgChannelId: f.epgChannelId, archiveDays: f.archiveDays, fromStep: true }
    m.player.preview = { name: f.name, label: favoriteLabel(f.streamId) }
    m.stepTimer.control = "stop"
    m.stepTimer.control = "start"
end sub

sub onStepTimer()
    target = m.stepTarget
    m.stepTarget = invalid
    if target = invalid or m.player = invalid or m.playing = invalid or m.playing.kind <> "live" then return
    if toInt(target.streamId) <> toInt(m.playing.id)
        playLive(target)
    else
        m.player.preview = { restore: true }     ' back where it started: redraw the overlay
    end if
end sub

function favoriteIndex(favorites as Object, streamId as Dynamic) as Integer
    id = toInt(streamId)
    for i = 0 to favorites.Count() - 1
        if toInt(favorites[i].streamId) = id then return i
    end for
    return -1
end function

function favoriteLabel(streamId as Dynamic) as String
    favorites = m.store.callFunc("getFavorites")
    index = favoriteIndex(favorites, streamId)
    if index < 0 then return ""
    position = index + 1
    return "Favorite " + position.ToStr() + " of " + favorites.Count().ToStr()
end function

' ---------------------------------------------------------------------------
' Swapping a favorite that failed for the copy (or similar channel) that
' plays: asked once the stand-in has played for a few seconds.

sub onLivePlaying(event as Object)
    m.playingStarted = toInt(event.GetData().streamId)     ' for onConverterPing
    m.swapTimer.control = "stop"
    if m.playing = invalid or m.playing.kind <> "live" or toInt(m.playing.replaceFor) = 0 then return
    if toInt(event.GetData().streamId) <> toInt(m.playing.id) then return
    m.swapTimer.control = "start"
end sub

sub onSwapTimer()
    if m.player = invalid or m.playing = invalid or m.playing.kind <> "live" then return
    oldId = toInt(m.playing.replaceFor)
    if oldId = 0 or m.swapDeclined.DoesExist(oldId.ToStr()) then return
    if not m.store.callFunc("isFavorite", oldId) or m.store.callFunc("isFavorite", m.playing.id) then return
    old = invalid
    for each f in m.store.callFunc("getFavorites")
        if toInt(f.streamId) = oldId then old = f
    end for
    if old = invalid then return
    oldName = localizeName(asString(old.name))
    newName = localizeName(asString(m.playing.name))
    dlg = CreateObject("roSGNode", "StandardMessageDialog")
    dlg.title = "Replace favorite?"
    dlg.message = [oldName + " didn't play here, but " + newName + " does. Put " + newName + " in its place in your Favorites?"]
    dlg.buttons = ["Replace", "Not now"]
    dlg.ObserveField("buttonSelected", "onSwapChosen")
    dlg.ObserveField("wasClosed", "onSwapClosed")
    m.swapDialog = { dialog: dlg, oldId: oldId, oldName: oldName, newName: newName, channel: { streamId: toInt(m.playing.id), name: m.playing.name, epgChannelId: asString(m.playing.epgChannelId) } }
    m.top.dialog = dlg
end sub

sub onSwapChosen()
    d = m.swapDialog
    if d = invalid then return
    m.swapDialog = invalid
    choice = d.dialog.buttonSelected
    d.dialog.close = true
    if choice <> 0
        m.swapDeclined[d.oldId.ToStr()] = true
        return
    end if
    ' The same remapping as a provider renumbering: same place, pin and
    ' Recently Viewed entry, new channel.
    map = {}
    map[d.oldId.ToStr()] = d.channel
    if m.store.callFunc("remapChannels", map)
        showToast("Replaced " + d.oldName + " with " + d.newName + " in Favorites")
        if m.playing <> invalid and toInt(m.playing.id) = d.channel.streamId
            m.playing.stepFrom = 0
            m.playing.replaceFor = 0
            if m.player <> invalid then m.player.channelLabel = favoriteLabel(d.channel.streamId)
        end if
        refreshHome()
        updateCatalogTags()
    else
        showToast("Couldn't save the change. Storage may be full.")
    end if
end sub

sub onSwapClosed()
    d = m.swapDialog
    if d <> invalid then m.swapDeclined[d.oldId.ToStr()] = true
    m.swapDialog = invalid
end sub
