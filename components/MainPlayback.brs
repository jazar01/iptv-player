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
    m.connections = invalid     ' { active, max } from the provider, last checked

    ' Up/Down while watching: the channel shows at once, but its stream
    ' loads only once the presses stop, so skipping through channels
    ' doesn't open (and leave counting against the account) a stream each.
    m.stepTarget = invalid      ' favorite the presses have reached
    m.stepTimer = CreateObject("roSGNode", "Timer")
    m.stepTimer.duration = 0.6
    m.stepTimer.ObserveField("fire", "onStepTimer")
    m.top.AppendChild(m.stepTimer)
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
    m.usageCounted = false      ' one usage point per viewing session
    if m.player = invalid
        m.player = CreateObject("roSGNode", "PlayerScreen")
        m.player.ObserveField("progress", "onPlayerProgress")
        m.player.ObserveField("failed", "onPlayerFailed")
        m.player.ObserveField("channelStep", "onChannelStep")
        m.player.ObserveField("liveViewed", "onLiveViewed")
        m.player.ObserveField("liveWatched", "onLiveWatched")
        m.player.channelViewSeconds = m.store.callFunc("getChannelViewSeconds")
        m.player.ObserveField("toggleFavorite", "onPlayerToggleFavorite")
        m.player.ObserveField("infoRequested", "onPlayerInfoRequested")
        m.player.ObserveField("copyChosen", "onInfoCopyChosen")
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
    if m.infoFor <> invalid and m.infoFor.source = "player" then m.infoFor = invalid
    m.stepTimer.control = "stop"
    m.stepTarget = invalid
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
    m.failCode = toInt(event.GetData().code)
    checkConnections("failed")
    ' A live channel: offer its other copies on the error panel.
    if m.playing <> invalid and m.playing.kind = "live" then searchSend("infoRequest", { id: "failed", streamId: m.playing.id, market: m.store.callFunc("getMarket").key, similar: true })
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
    formatError = (m.failCode = -5 or m.failCode = -6)
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
    if m.stepTarget <> invalid then current = m.stepTarget.streamId
    index = favoriteIndex(favorites, current)
    if index < 0
        if direction > 0 then index = 0 else index = count - 1
    else
        index = (index + direction + count) mod count
    end if
    f = favorites[index]
    m.stepTarget = { streamId: f.streamId, name: f.name, epgChannelId: f.epgChannelId }
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
