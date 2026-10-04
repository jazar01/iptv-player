' Playback: building play requests, the resume prompt, saving positions,
' watched tracking, channel up/down through favorites, and the
' connection-limit check after a failure.

sub initPlayback()
    m.player = invalid
    m.playing = invalid         ' current play request
    m.watchedKey = ""           ' "kind:id" already marked watched in this play
    m.resumeDialog = invalid
    m.tzRules = invalid
    m.guideRules = invalid
end sub

' item: { streamId, name, epgChannelId, archiveDays? }. Archive days come
' from the catalog or search item, else from the live search index.
sub playLive(item as Object)
    id = toInt(item.streamId)
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
    }
    if archiveDays > 0 then play.timeshift = timeshiftInfo(id)
    startPlayer(play, 0)
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

function formatDuration(seconds as Integer) as String
    h = seconds \ 3600
    mm = (seconds mod 3600) \ 60
    ss = seconds mod 60
    text = ""
    if h > 0 then text = h.ToStr() + ":"
    if h > 0 and mm < 10 then text = text + "0"
    text = text + mm.ToStr() + ":"
    if ss < 10 then text = text + "0"
    return text + ss.ToStr()
end function

' ---------------------------------------------------------------------------
' Player

sub startPlayer(play as Object, position as Integer)
    play.startPosition = position
    m.playing = play
    m.watchedKey = ""
    if m.player = invalid
        m.player = CreateObject("roSGNode", "PlayerScreen")
        m.player.ObserveField("progress", "onPlayerProgress")
        m.player.ObserveField("failed", "onPlayerFailed")
        m.player.ObserveField("channelStep", "onChannelStep")
        m.player.ObserveField("liveViewed", "onLiveViewed")
        m.player.ObserveField("closed", "onPlayerClosed")
        pushOverlay(m.player)
    end if
    if play.kind = "live" then m.player.channelLabel = favoriteLabel(play.id)
    m.player.content = play

    if play.kind = "live"
        cached = m.epg.callFunc("getPrograms", [play.id])
        entry = cached[play.id.ToStr()]
        if entry <> invalid then m.player.programs = entry
        m.epg.callFunc("want", [play.id])
    end if
end sub

sub onPlayerClosed()
    if m.player = invalid then return
    player = m.player
    m.player = invalid
    m.playing = invalid
    removeOverlay(player)
    refreshHome()
    updateCatalogTags()
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
    saved = true
    if isTrue(p.finished) or (p.duration > 0 and p.position >= p.duration * 0.9)
        m.watchedKey = key
        entry.fromPlayback = true
        if play.kind = "episode" then entry.nextEpisode = nextEpisodeAfter(play.seriesId, play.id)
        saved = m.store.callFunc("markWatched", entry)
        print "[main] watched "; key
    else if p.position >= 30
        saved = m.store.callFunc("savePosition", entry)
    end if
    if not saved then print "[main] WARNING: could not save progress for "; key
end sub

' The Video node failed. If the account is at its connection limit, say so
' instead of the generic message.
sub onPlayerFailed()
    sendRequest({ id: "connCheck", action: "" })
end sub

sub onConnectionCheck(res as Object)
    result = evaluateLogin(res)
    if not result.ok or m.player = invalid then return
    print "[main] connection check: "; result.activeConnections; " of "; result.maxConnections; " in use"
    if result.maxConnections > 0 and result.activeConnections >= result.maxConnections
        m.player.errorText = "All " + result.maxConnections.ToStr() + " connections on this account are in use. Stop watching on another TV, then try again."
    end if
end sub

' A minute on a live channel: add it to Recently Viewed. Home refreshes when
' the player closes.
sub onLiveViewed(event as Object)
    channel = event.GetData()
    if not m.store.callFunc("addRecent", channel) then print "[main] WARNING: could not save recently viewed "; channel.name
end sub

' Up / Down during live playback: next / previous favorite. From a channel
' that isn't a favorite, Up goes to the first favorite and Down to the last.
sub onChannelStep(event as Object)
    direction = event.GetData()     ' "step" is reserved in BrightScript
    if m.playing = invalid or m.playing.kind <> "live" then return
    favorites = m.store.callFunc("getFavorites")
    count = favorites.Count()
    if count = 0 then return
    index = favoriteIndex(favorites, m.playing.id)
    if index < 0
        if direction > 0 then index = 0 else index = count - 1
    else
        index = (index + direction + count) mod count
    end if
    f = favorites[index]
    playLive({ streamId: f.streamId, name: f.name, epgChannelId: f.epgChannelId })
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
