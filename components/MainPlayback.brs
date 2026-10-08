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

    ' Live streams whose audio this Roku can't decode ("Unsupported AAC
    ' stream"): streamId -> retry after (UTC seconds). Playing one goes to a
    ' working copy instead; the provider changes sources, so after a few
    ' hours it's tried again.
    m.badStreams = {}
    m.autoCopyFor = invalid     ' { streamId, name, item, afterFailure } waiting for its copies

    ' The audio fix (StreamRelay): streams that failed with "Unsupported AAC
    ' stream" play through it, streamId -> until (UTC seconds). Only if the
    ' relayed stream fails too is it marked bad (badStreams) and a copy tried.
    m.relayStreams = {}
    m.relay = CreateObject("roSGNode", "StreamRelay")
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
    if isStreamBad(id) and not isTrue(item.direct)
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
    if needsRelay(id) then relayPlay(play)
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

sub onPlayerClosed()
    if m.player = invalid then return
    player = m.player
    m.player = invalid
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
    ' Audio this Roku can't decode: remember the stream and go straight to a
    ' working copy (no connection check: the stream did connect).
    if m.playing <> invalid and m.playing.kind = "live" and isTrue(failure.audioUnsupported) and not isTrue(m.playing.relayed) and m.relay.port > 0
        ' First time: play it again through the audio fix.
        id = toInt(m.playing.id)
        m.relayStreams[id.ToStr()] = nowSeconds() + 4 * 3600
        print "[main] stream "; id; " has audio Roku rejects; playing it through the audio fix"
        playLive({ streamId: id, name: m.playing.name, epgChannelId: m.playing.epgChannelId, archiveDays: m.playing.archiveDays, stepFrom: m.playing.stepFrom, replaceFor: m.playing.replaceFor, direct: true, note: "This channel's audio is being repaired for this Roku." })
        return
    end if
    ' Dolby audio this TV doesn't accept, too: the relay can't help, but a
    ' copy with other audio can (Family Room, Oct 2026).
    if m.playing <> invalid and m.playing.kind = "live" and (isTrue(failure.audioUnsupported) or isTrue(failure.dolbyUnsupported) or isTrue(m.playing.relayed))
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
    m.badStreams[key] = nowSeconds() + 4 * 3600
    print "[main] stream "; key; " has audio this Roku can't decode; skipping it for 4 hours"
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
end sub

sub onAutoCopies(result as Object)
    a = m.autoCopyFor
    if a = invalid or toInt(result.streamId) <> a.streamId then return
    m.autoCopyFor = invalid
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
