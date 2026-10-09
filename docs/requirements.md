# Dixie TV (Roku IPTV player) — Requirements

Oct 4, 2026 · @Jim

## Overview

A private Roku app that plays one Xtream Codes IPTV account for me and my family, with no per-device fees and no publishing to the Roku store.

Existing Roku IPTV apps fall short in three ways this app must fix:

- **Speed.** Navigation is slow and clunky. Opening the app and getting to a channel must be fast.
- **Memory.** Favorites and series progress get lost. Saved state must survive provider changes, restarts and power loss.
- **Cost.** They charge per Roku device. This app is free to install on every family device.

One owner (me) builds and maintains it. The developer is experienced, so this document records decisions and design, not tutorials.

## Version 1 scope

Version 1 plays live TV, movies and series from a single Xtream account, with reliable favorites and watch progress stored on each Roku.

**In version 1**

- Live TV, movies (VOD) and series, browsed by category.
- One provider, one account.
- Favorites-first home screen with what's on now and next.
- Resume where you left off for movies and episodes.
- Watched tracking for series, with a next-episode pointer.
- Per-device favorites and progress; no per-person profiles.
- Storage built behind an interface so off-device backup can be added later without rework.
- Clean display of guide titles (superscript Live/New tags stripped) and correct time-zone handling.
- Search across live channels, movies and series.
- Pause, rewind and fast-forward for movies and episodes, and for live channels through the provider's catch-up archive where the channel has one.

**Not in version 1**

- Browsing and playing past programs from a guide (catch-up beyond pausing and rewinding the channel being watched).
- Multiple providers or accounts.
- Per-person profiles.
- Off-device backup and sync (planned for V2; see Later features).

The grid Guide, My Teams and usage-based ordering were first left out of
version 1 and later built (see their sections).

## Distribution and setup

The app is never published. Roku devices at home get it by sideloading; the few devices in other homes get it through a beta channel.

| Method | Used for | Notes |
| --- | --- | --- |
| Sideload (Developer Mode) | Devices in my home | Free and permanent. One sideloaded app per device. Updates require being on the same network. |
| Beta channel (developer dashboard) | Devices in other homes | Installed by invite link from anywhere. Limits believed to be about 20 devices and 120-day expiry; confirm before relying on it. |

The sideloaded build and the beta channel are different apps to Roku, so each keeps its own separate saved data.

**First-run setup**

1. Enter server URL, username and password with the on-screen keyboard (once per device).
2. The app calls `player_api.php` once to validate them.
3. It reads `max_connections` and `allowed_output_formats` from the response, confirming HLS is available.
4. It generates a device ID (UUID) and asks for a device name, such as "Living room". Roku's built-in client ID is not used, because it differs between sideload and beta builds.

Settings shows the account's end date (`user_info.exp_date`), and a notice appears once per session when it's within 7 days. All devices share one account, so the connection limit can be exceeded. When the provider refuses a stream for that reason, the app shows a clear message instead of failing silently. That message is never used for format errors (codec -5, protected -6): those streams did connect, and a full count then only reflects streams just left that the provider hasn't timed out. Settings and the channel info panel show how many connections are in use ("2 of 3", from `user_info.active_cons`), counting every device on the account. Live streams (HLS) have no hang-up: a stream just left keeps counting until the provider times it out (typically 30 s to a few minutes), so fast channel changes used to hold extra connections. Up/Down while watching therefore names the channel at once but loads its stream only once the presses stop for 0.6 s.

## Home screen and navigation

The home screen opens on fixed rows in a fixed order: Favorites, Continue Watching, then Recently Viewed. My Teams sits below Favorites, or first if Settings → My Teams on Home says First; it stays in that place. (It used to jump to the top while a game was live or about to start, which also happened for replays; dropped Oct 2026 in favor of a fixed place.)

The top bar holds Home, Live TV, Guide, Movies, Series, Search and Settings, plus a clock. A reference mockup exists for the TV layout at 1920×1080.

**Rows**

- **Favorites:** each channel shows the current program, a progress bar and the next program, from `get_short_epg` for visible channels only.
- **Channel logos:** channel cards (Favorites, Recently Viewed, their "See all" grids) show the provider's logo (`stream_icon`) at the top right when the name is short enough to share the line (about 15 characters). Logos are looked up in the search index when the rows are built, not saved with favorites, so they cost no registry space; a card with no logo, or one that fails to load, keeps the full-width name.
- **Continue Watching:** movies and series with time left; series point to the next unwatched episode, skipping any marked watched by hand (a series with none left leaves the row). `*` on a card removes it: a movie's saved position is cleared; a series leaves the row and its saved positions are cleared, but its watched episodes are kept, and playing an episode again brings it back.
- **Watch List:** after Continue Watching, only while there are any: movies saved to watch later with `*` (Movies list, Search, the Home row and its "See all" grid) or the movie page's "Add to Watch List" button ("Remove from Watch List" once added). Cards show the name and year (no poster) and the runtime once the movie page has been opened; selecting one opens the movie page. Newest added first. A movie started on this TV is in Continue Watching instead, not in both; watching it to 90% takes it off the list. Movies opens on a "Watch List" category while there are any, and listed movies are tagged LIST there and in Search (IN PROGRESS wins in Movies). After a renumbering, movies are found again by name and year like series; one the provider no longer has shows "Not available" until removed. Schema 7 `watchlist`: `{ id, name, year, ext, mins, addedAt, updatedAt, deleted }`, at most 20 movies (about 115 bytes each, to stay well inside the registry budget); a full list refuses new movies with a message and is never trimmed.
- **Favorite Series:** after Continue Watching, only while there are any: series marked with `*` (in the Series list, Search, the Home row, or on the seasons column of a series page). Each card shows the name and year and where you are ("Next up: S2 E4", "Watched", "Not started"); selecting it opens the series page; most watched first. The Series list opens on a "Favorite series" category while there are any, and favorites are tagged FAVORITE there and in Search. Stored as a `favorite` mark on the series record (optional, no schema change), so re-matching after a renumbering covers them, and favorite series are never trimmed when storage runs low.
- **Recently Viewed:** live channels watched for about a minute or more (time the video is actually playing; paused, buffering or failed time doesn't count, and the same goes for usage scores), newest first, up to 15. Channels already in Favorites are left out unless Settings → Favorites in Recently Viewed is on (off by default; per device). Favorites are still recorded, so turning it on shows them right away. Cards look like Favorites cards (now, progress, next), and `*` adds a channel to Favorites. Saved per device with the other state, so it draws without the network.
- Each row is a self-contained module that supplies its own content, so new rows slot in without reworking the screen.

**Long rows**

- Rows scroll sideways (`RowList`). The last visible card is cut off at the screen edge to show there is more.
- The focused row's title shows a counter, such as "3 of 9".
- Each row shows about 15 items, then a "See all" tile that opens a full-screen grid of the whole row, for every row. `*` works there as on Home; the Favorites grid is also where favorites are managed (pin, unpin, remove).

**Navigation behavior**

- Returning from playback puts focus back on the same card in the same row.
- Back on Home asks "Exit Dixie TV?" (Exit / Cancel; Back again stays), so a stray press doesn't close the app.
- The `*` options button adds or removes a favorite from any channel list, and for the channel being watched in the player where the Roku lets it through. While video plays, Roku itself takes `*` (its audio and captions menu) on channels with captions or extra audio tracks, such as local stations and Food Network; the key never reaches the app, whatever has focus (found Oct 8, 2026). So in the player, OK twice opens channel info with Add to / Remove from Favorites at the top (Down reaches Other copies), and the overlay hint points there. In Live TV it opens a short menu instead: Add to / Remove from Favorites, or Channel info.
- While a live channel plays, channel up/down moves through favorites. From a channel that isn't a favorite, that channel joins the loop just before the first favorite (Up goes to the first favorite, Down from there comes back); a copy chosen in the player (error panel, channel info's other copies) takes the place of the channel it stands in for. When a favorite fails and a stand-in from its error panel (a copy or similar channel, or the copy the app switches to by itself) plays for 6 seconds, the app asks "Replace favorite?": Replace swaps the favorite in place (same position and pin, Recently Viewed too, through remapChannels); Not now isn't asked again for that favorite this session. Not asked when the stand-in is already a favorite. During live playback the player screen, not the Video node, has focus, so `*` always reaches the app: a Video node with focus keeps `*` for Roku's own audio and captions menu when a stream has extra tracks (LBW: SEC Network, Oct 2026). Movies, episodes and the archive give the Video node focus for its seek controls, so `*` there opens Roku's menu.

**Speed**

- On launch, show the cached catalog from the last session immediately and refresh in the background.
- Favorites carry their own names and IDs, so the home screen draws without waiting on the network.
- Browse grids load in pages, so large catalogs never block the UI.
- Category order (Live TV, Movies, Series, the Guide's chooser): the 5 most-used categories first (a use is picking a channel, movie or series from it; usage table keys "kc"/"km"/"ks" + category ID, as at launch so lists don't reshuffle while browsing), then categories prefixed with this Roku's country ("US |"; `categoryOrder` in `data/guide-rules.json` maps country codes to the provider's prefixes, e.g. GB to UK), then all others, each group in the provider's order. Local stations / Favorite series / Favorites stay first.
- Background downloads (full catalogs, network schedules, team logos) are low priority in ApiTask: they wait behind on-screen requests and use at most 2 of the 4 slots.
- Guide (now/next) requests follow the screen: the rows on screen are reported once scrolling pauses (0.3 s), and EpgService keeps at most 6 requests in flight, always for channels still on screen.
- A login that fails at launch for network reasons is retried in the background (1 min, doubling to 15 min); the provider's time zone from the last good login is saved, so rewind and Start over work before it succeeds.
- Failures are shown in plain language ("The server didn't answer in time. Try again in a moment."); the technical detail stays in the console. Malformed provider entries (non-objects in guide, category and catalog lists) are skipped rather than stopping the app.
- Live TV rows show what's on now under the channel name ("NFL Live     until 3:00 PM"), from `get_short_epg` for the rows on screen only (the list reports them, as Home does); programs the guide service already has appear at once.
- Channel rows in Live TV and in Search show the provider's logo (`stream_icon`) in a column left of the name; a channel without one (or whose logo fails to load) leaves the column empty so names stay aligned. Only rows on screen load logos.
- A category that fails to load says so; choosing it again (OK) retries.

**Live TV local stations**

- When a market is set (Settings → Local stations), Live TV's first category is "Local stations - <market>", listing that market's ABC, CBS, NBC and FOX stations. It opens automatically like any first category. With no market set, the category isn't shown.
- In every Live TV list, those stations are tagged LOCAL. FAVORITE takes priority.
- The list comes from the search index, so it shows "Loading local stations ..." until the index has loaded. Changing the market updates the category and the tags right away.

## Guide

The Guide (top bar) is a grid of channels by time.

- **Channels:** Favorites by default. A **Channels** button above the grid ("Channels:  Favorites + Local stations", or "+ 2 more") is reached with Up from the top row, and OK on it (or `*` anywhere in the Guide) opens the chooser: a checklist of Favorites, Local stations and every Live TV category (from the search index, with logos), with "Show the ticked channels" at the top; OK ticks, Back leaves it unchanged. Several sets show one after another in the list's order, each channel once (in its first set), with a line above the first channel of each later set and the focused channel's set beside the button. The choice is saved per TV (`settings.guideChoices`). Added Oct 9, 2026: `*` alone, with a small hint, wasn't found by new users, and only one set could be shown. Up from the button goes on to the top bar, as Up from the grid did.
- **Grid:** a 3-hour window from the current half hour, 7 channels at a time, program blocks sized by length, the program on now shaded and a red line at the current time. Above it, the focused program's title, day and time, length ("On now" when it is) and description.
- **Moving:** Up/Down change channel; Left/Right move between programs, scrolling the window by half hours at its edges, back to now and up to about a day ahead. OK on a program that's on now plays the channel; on a later one it says when it starts.
- **Data:** each channel's full schedule (`get_simple_data_table`), fetched for the rows on screen and the next screenful once scrolling pauses, at most 4 at a time, kept for an hour (3 hours back to 30 ahead). A failed request shows "Couldn't load the guide; trying again shortly" (not "No guide information", which means the provider has none) and is tried again after 1 minute, then 5, then every 15, by a timer (it was 5, 15 and 60 minutes, and only when scrolling: on Oct 9, 2026 the Willy Nilly TV's guide stayed empty for most of an hour).

## Search

Search finds live channels, movies and series by name. The Xtream API has no search, so the app searches its own copy of the full catalog.

- **Entry:** Search in the top bar opens the on-screen keyboard. Results update as letters are typed, after a short pause.
- **Recent searches:** Search opens from the top bar with an empty box (coming back from a result keeps the results), and while the box is empty the results area lists the last 10 searches (tagged RECENT, newest first) under a heading "Recent searches   OK to search again   * to remove", so Right, OK repeats the last search without typing. OK runs one again; `*` forgets it. A search is remembered when one of its results is chosen (so typos and dead ends aren't), the same words in other capitals counting as one. Kept per device in their own registry section (`iptv_searches`), not in the saved document or the backup. The results list starts below y 200 so Roku's own "Skip the remote. Use your phone." keyboard banner (top right, shown while a keyboard is on screen; not the app's) doesn't cover the heading.
- **Results:** grouped as Channels, Movies and Series, each capped (about 50) with names starting with the search text first. Selecting a result does the same as selecting it in its browser: play a channel or movie, open a series. `*` on a channel adds or removes a favorite.
- **Matching:** case-insensitive; every word typed must appear in the name, in any order. Provider prefixes such as `US |` are searchable like any other text. Word forms match: common endings (-ing, -ed, -es, -s, a final e) are trimmed from search words of 4+ letters, so "british baking" finds "The Great British Bake Off" and "movies" finds "movie". Synonym groups in `data/guide-rules.json` ("search") make any word in a group find the others (football ↔ NFL, film ↔ movie); add groups there. When a search finds nothing as typed, it is tried again with close spellings: catalog words with the same first letter up to 1 letter off (4–6 letters) or 2 (7+), so "bitish bake off" finds "British Bake Off". The word list for this is built on first use (logged as `[search] fuzzy word list`). If that still finds nothing, names with all but one of the search words are shown, for a word voice got wrong ("british break off" still finds "British Bake Off").
- **Local stations:** the device's market stations (Settings → Local stations) that match come first among channel results, tagged LOCAL, so a search like "abc" shows your affiliate before the ~200 others.
- **Index:** built from the full lists (`get_live_streams`, `get_vod_streams` and `get_series` without a category), cached in `cachefs:` and refreshed in the background at most once a day (checked every 6 hours, so a session left running stays current; a failed download is retried after 5 minutes). Only names, IDs and the fields needed to play are kept.
- **Movie and series categories (Oct 9, 2026):** Movies and Series lists come from these full lists (SearchTask `categoryRequest`), not the provider's category list: Documentaries is 6,801 movies, a 2.7 MB answer that took the provider 2 s and the Roku several more to read and pass to the screen, on every visit. From the index it opens in about 0.25 s, with only the fields a row needs. The provider's category lists are the full list filtered by `category_ids`, in the same order (24 categories compared). A movie added today shows in its category with the next daily refresh, as in Search. Until a kind's list is indexed (first launch) the provider's list is used. Live TV categories are small and still come from the provider.
- **Speed:** the index and matching live in a Task, not the render thread, and only the matches cross to the UI. The live list (about 16,000 channels) is the largest; if it proves too heavy on older models, live search can be limited to favorite categories (see Open questions).
- Guide search (what's on, by program title) is not part of this; the full guide is too large for the Roku and waits for the off-device server (Later features).

## Playback

Playback uses Roku's `Video` node, with HLS for live channels and the file's own container for movies and episodes.

| Content | Stream URL |
| --- | --- |
| Live | `{server}/live/{user}/{pass}/{id}.m3u8` |
| Movie | `{server}/movie/{user}/{pass}/{id}.{container_extension}` |
| Episode | `{server}/series/{user}/{pass}/{episode_id}.{container_extension}` |

- Live channels request HLS (`.m3u8`), not raw `.ts`.
- **Series page:** the series backdrop (dimmed) behind, the cover, title, year, number of seasons, genre, rating, plot, director and cast at the top (from `get_series_info`, cached), seasons and episodes below (6 episode rows), and under the list the focused episode's air date and length ("Aired Feb 10, 2019     22 min"), and its description when the provider sends one (this provider often doesn't: How It's Made episodes carry only air_date, duration, rating and a still image, which isn't shown). Entries in the episode lists that aren't objects are skipped. An episode focused for 0.8 s gets the same line about its file, between its air date and its description (asked once per episode).
- **Movie details:** choosing a movie in Movies or Search opens a page before playing: the backdrop (dimmed) behind, the poster, title, year, runtime, rating, genre, plot, director and cast (`get_vod_info`, cached in `cachefs:`; providers' field names vary, so several are tried), and Play, or Resume from the saved position plus Start over. Back from the player returns to the page with Resume updated. Continue Watching cards still resume straight away. What's inside the file comes from the Pi (`pi/dolby-converter/probe.py`, `/p/`, converter 1.4, Oct 9, 2026): ffprobe reads only the file's start (about 3 s, then kept in the Pi's memory, so a second look is instant) and the page shows, under the cast, the picture (4K / Full HD / HD / SD by size, Dolby Vision, HDR10 or HLG, frame rate, codec), each audio track (format, Atmos, channels, language) and the subtitle languages, e.g. "Full HD 1920x1080, 23.976 fps, H.264   -   Audio: Dolby Digital Plus Atmos 5.1 (English)   -   Subtitles: English, Spanish". The provider's own figures aren't used: `get_vod_info` has none for movies (only bit rate and container), and for an episode it reported the cover picture stored in the file (a 3840x2160 JPEG) as the video. Roku's player reports codecs while playing, never the size. Only with the converter set and answering; each look holds an account connection for those seconds. Information only: movies and episodes play straight from the provider (their audio problems don't arise: files are made once, with the audio described correctly and often a stereo track beside the Dolby one).
- Some VOD files will not play on Roku because of codec or container. The player catches the `Video` node's error state and shows a readable message, never a black screen. OK on the error panel tries again (a movie or episode from where it was); with copies listed, OK plays the copy chosen. A Live TV, Movies or Series category list that fails to load offers "Press OK to try again", as item lists do.
- When a live channel fails, the error panel also lists its other copies (same guide ID, up to 15); OK plays one. Copies are often encoded differently, so one may play where the first didn't. A channel with no copies gets "Similar channels" instead: names sharing its main words (provider prefix, quality tags, numbers and short words left out), shortest first, up to 15 (seen Oct 2026: Tennis Channel 2 failed on the Family Room Roku with "Unsupported AAC stream", an audio format that Roku couldn't decode).
- **Dolby audio check:** Settings shows what this Roku, as connected to its TV, can play of Dolby Digital (AC-3) and Dolby Digital Plus (E-AC-3) (`roDeviceInfo.CanDecodeAudio`, checked each time Settings opens, also logged with `GetAudioDecodeInfo`). Roku players mostly pass Dolby on over HDMI; a TV that reports stereo only makes every Dolby channel fail with "Unsupported audio format: Dolby Digital" (ESPN, SEC Network and Tennis Channel on the Family Room and Deck Rokus, Oct 2026), which the app can't fix: the TV's HDMI or audio settings, or a soundbar, can. The Family Room's Samsung LN52A650 (2008) accepts only PCM over HDMI and has no setting for it. On that error, with a Dolby converter set up in Settings (a home Raspberry Pi; see "Dolby audio converter on a home Raspberry Pi"), the channel plays again through it at full quality. Without one, the player switches to a copy the way it does for undecodable AAC (the relay can't help here): the stream is marked bad for 7 days (remembered on that Roku, so a relaunch doesn't fail it again), the first copy not marked bad plays, and "Replace favorite?" can make that copy the favorite on that TV. The provider's LBW copies have played there.
- **Audio Roku can't decode:** some copies send AAC whose header says Main profile at 24 kHz (HE-AAC mislabeled by the provider's encoder: ffmpeg decodes it as HE-AAC 48 kHz stereo, and with only the 2-bit profile field changed to LC the Roku plays it with sound, tested Oct 7, 2026; seen Oct 7, 2026 on FOX News and Tennis Channel Plus, while ESPN, ESPN 2 and SEC Network send E-AC-3, and WSB AAC-LC at 48 kHz). Roku's decoder rejects it ("Unsupported AAC stream", error -5), and the provider's .ts output carries the same audio. It varies over time: Tennis Channel 2 failed this way before and played (AC-3) on Oct 7. On this error the player doesn't reconnect (it would only fail again and hold a connection). MainScene plays the stream again through the audio fix (StreamRelay, a local HTTP server on 127.0.0.1): it fetches the playlist (following the provider's redirects to its edge server), points the segments at itself, and rewrites the profile field of every audio frame to LC (about 40 ms per 10-second segment). The stream keeps using the fix for 7 days (remembered on that Roku across launches, in its own registry section, not the backup), archive (pause and rewind) included, (archive segments are read off a plain-http socket as they arrive, and each one-minute segment is listed to the player as 12 parts of about 5 s so it starts after the first part; Rewind and Start over begin on a whole minute, so they start with a first part, while Pause then Play resumes exactly; stretches are at most 15 minutes because the provider takes longer to build longer archive playlists, about 4 s for 11 minutes and 20 s for 90; rewind and start over take about 6 s), with a note "This channel's audio is being repaired for this Roku." Only if it fails through the fix too with an audio or format error (-5) is it marked bad for 7 days, and the first other copy not marked bad is played, with a note naming it. Playing a channel already marked bad (from a list, the Guide, or Up/Down) goes to a working copy the same way, keeping its place for Up/Down through favorites. With no working copy the error panel says so and offers similar channels. Bad copies aren't offered on the error panel. Any other failure of a repaired stream (the provider, a timeout, a stall, the connection limit) goes to the normal error panel, like any channel.
- A small overlay on live playback shows the channel and current program with its description (up to 2 lines, from the guide), and handles channel up/down through favorites.
- **Channel info:** OK with the overlay up (OK twice), or `*` -> Channel info in Live TV, opens a side panel: the provider's logo, category, guide ID, rewind days, a resolution guessed from the name (HD, 1080p), Favorite / Local station, Playing now, and Other copies (channels sharing the guide ID, up to 15; OK watches one, handy when a copy stalls). Playing now is the program on now with its times and description (`get_simple_data_table`; the next programs were dropped Oct 9, 2026, to leave room for the copies: the overlay shows what's next), then, while watching, the picture, codecs, measured connection speed, and loading pauses and reconnects on this channel, refreshed every 2 s. The picture comes from the stream when it reports a size (this provider's don't, and their flat 128 kbps is a declared figure, not the picture's), else from the Pi's live buffer, which measures it ("Full HD 1920x1080, 60 fps"; 4K, Full HD, HD or SD by height): "ESPN 1 FHD" measured 1280x720, so names can be wrong. When there's room for fewer than 2 copies, the description goes, then the program title keeps to 1 line. Back closes it.
- **Stream ends:** if a live stream stops (the provider ended it), the player reconnects once; if it ends again within 2 minutes it says the channel stopped sending video and offers other copies or similar channels.
- **Stalls:** a live stream that has played and then sits in "Loading" for 6 seconds (12 until Oct 7, 2026; normal buffering on this connection lasts 1 to 3 s, and FS1's freezes at commercial breaks only clear with a reload) is reloaded at the live point, with a short note on the overlay. After 4 reloads in 3 minutes the player stops and says the channel keeps stalling. (Seen Oct 2026 during an NLDS game: the feed froze at "loading 33%" at commercial breaks, likely a format change the relay doesn't mark.) A live channel with no video 25 s after loading, and no error either, fails the same way (error panel, other copies). Movies, episodes and the archive: one that has played and then sits in "Loading" for 25 s is reloaded where it was, at most 3 times in 5 minutes; then a movie or episode stops with "keeps stalling" (its position saved), and the archive goes back to live. A movie or episode that never starts gets one reload, then an error. Every buffering spell and every change in the stream's resolution or bit rate is logged to the console (`[player] buffered …`, `[player] stream format: …`).

**Pause, rewind and fast-forward**

- **Movies and episodes:** the `Video` node's own controls: Play/Pause, rewind, fast-forward and Left/Right to seek, with its progress bar.
- **Live channels with an archive** (`tv_archive` = 1 in `get_live_streams`, kept for `tv_archive_duration` days; marked REWIND in channel lists and search): Play/Pause pauses. A pause under a minute resumes from the player's own buffer; a longer one continues from the provider's timeshift archive. Rewind jumps into the archive, after which the `Video` node's own controls move through it. Back returns to live.
- **Start over:** on a channel with an archive, the remote's Replay button (the curved arrow) plays the program on now from its start (its guide start time), through the timeshift archive. Not possible when the guide has no start time, the program began before the archive, or it began within the last few minutes (not recorded yet); the strip says which.
- **Live channels without an archive:** pause, rewind and fast-forward are unavailable; pressing them shows a short note saying so instead of doing nothing.
- **Timeshift URLs and times:** start times are in the server's time zone (`server_info.timezone`, Europe/London for this provider) and durations in minutes. The app converts from UTC using time-zone rules in `data/guide-rules.json`.

| Content | Timeshift stream URL (confirmed for this provider) |
| --- | --- |
| Live, from a past moment | `{server}/timeshift/{user}/{pass}/{duration_minutes}/{YYYY-MM-DD:HH-MM}/{id}.m3u8` |

**Archive findings for this provider (Oct 4, 2026)**

| Finding | Rule for the app |
| --- | --- |
| 199 of 16,009 live channels have an archive, 3 days each, mostly UK channels. | Show REWIND on those channels; others get the "no archive" note. |
| The `.m3u8` form returns an HLS playlist of one-minute segments. The `.ts` and `timeshift.php` forms return MPEG-TS that Roku can't play (it reads them as MP4). | Use only the `.m3u8` form. |
| Each segment exists only after its minute ends and is written a little later. Asking for the newest minute makes Roku wait forever. | Stay `archiveLagSeconds` (300) behind live, an editable rule in `data/guide-rules.json`. Request only recorded minutes, and treat no video within 30 s as a failure. |
| The playlist is built on request; a two-hour window took over 10 s. | Rewind requests a 10-minute window. |
| HD channels' one-minute segments are about 45 MB, more than this Roku's video buffer (about 31.6 MB); SD segments fit. | HD archives fail on this Roku: the app says so and suggests the channel's SD version. Newer Roku models may have bigger buffers. |

**Resume and watched tracking**

- Playback position is saved every 30 seconds and when playback stops.
- A movie or episode counts as watched at about 90% viewed; its resume entry is then cleared. Confirmed on a movie Oct 9, 2026: it left Continue Watching when the credits started, as most streaming apps do; kept at 90% (95% would leave movies with long credits in the row).
- The episode list marks each episode watched, in progress or new. Episodes can be marked watched or unwatched by hand.
- Continue Watching shows the next unwatched episode for each series.

## Persistence and reliability

Favorites and watch progress must never be lost. All saved state goes through one `StateStore` interface backed by the Roku registry in version 1.

| Failure seen in other apps | Requirement |
| --- | --- |
| Provider renumbers streams, so favorites point at nothing | Favorites store stream ID, name and `epg_channel_id`. After each catalog refresh, missing IDs are re-matched by guide ID, then by name. Series re-match by name plus year. |
| State kept in cache files the system can clear | Only the registry (`roRegistrySection`) holds permanent state. `cachefs:` holds only re-downloadable data such as the catalog. `tmp:` is never used for state. |
| Registry full (about 16 KB per app), writes fail silently | Compact encoding, free-space check before each save, and trimming of old resume entries and stale series. Favorites are never trimmed automatically. |
| Changes lost to a crash or power loss | `Flush()` after every change; every write's return value is checked. |
| A failed save looks like it worked until restart | A failed save undoes the change in memory, trimming included, so the screen shows only what's saved and a later save can't carry a change reported as failed. Setup saves the account and device name together. A finished movie or episode counts as watched only once that's saved; until then, playback keeps retrying. |
| Saved data corrupted | Two alternating copies with version numbers; if the newest fails to parse, load the previous one. Records of the wrong shape (from an old version or a hand-edited backup) are dropped or repaired at load. |
| A cut-off or unwritable download treated as good | Cache files are written to a temporary file and renamed into place, and stamped fresh only after that succeeds. A catalog list missing its closing bracket is rejected; one that won't parse loses its stamp, so the next refresh downloads it again. |
| An unexpected error stops a background thread, and the catalog, search or audio repair silently stops with it | Each service loop (ApiTask, SearchTask, StreamRelay) and MainScene's reply handling catch an error in one message and carry on. A service thread that stops anyway is restarted, at most 3 times in 10 minutes (then a message says to reopen the app); requests made meanwhile wait for it. Anything waiting for a reply (Home rows, the Guide, a category, the copy search, My Teams guides and scores) gives up after a time limit, so a lost reply can't stall it for the session. |
| Switching accounts shows the old account's data | A new account is saved before the catalog refresh starts; the old catalog, guides and My Teams network guides are cleared from cache and memory, and search is emptied until the new lists load. Favorites and progress are kept (one household, one provider at a time). |

- Screens and player code never touch the registry directly; they call `StateStore` methods such as `getFavorites()`, `markWatched()` and `savePosition()`.
- An off-device backend can be added behind the same interface later (see Later features).
- Uninstalling the app deletes its registry, and so does a failed sideload (it removes the installed dev app). Until the V2 backup service, a manual backup covers it:
  - **Back up:** in Settings, `*` opens a backup panel (not in the menu, so it isn't found by accident) that explains backup and restore; Play/Pause there prints the saved document, Back closes it (base64, between `[backup] BEGIN` / `END` markers) on the debug console; `scripts/backup-roku.ps1 -Roku <name>` listens and saves `backups/<name>.json` plus a dated copy. `backups/` is git-ignored (it holds the provider password).
  - **Restore:** `deploy.ps1` bundles each Roku's latest backup, matched by the IPs in `$LocalRokus`, plus `backups/household.json` if present, as `data/restore.json` in the package. At launch, a Roku with no saved state restores its own backup (same device ID), or else the household copy under its deploy-list name with a new device ID and no per-device history. A Roku that has saved state never uses the bundle. Tested Oct 6, 2026 with a build pointed at an empty registry section: the Basement backup came back (account, 4 favorites, 3 teams) without Setup.

**Channel matching (re-finding saved items after renumbering)**

- **When:** after every catalog (re)index, at launch and on each daily refresh. Only saved items whose IDs are missing from a fully loaded list are looked up, so a failed or partial download can't re-match anything.
- **Channels** (favorites and Recently Viewed), in order: the only channel with the same guide ID; among channels sharing the guide ID (HD/SD/backup copies of one feed are common), the one with the same name; the only channel with the same name; otherwise the first channel sharing the guide ID.
- **Series:** the only series with the same name and year (year ignored when either side doesn't know it). The series record and its episodes' resume entries move to the new ID; Continue Watching finds its episode again by season and episode number.
- **Episodes:** episode IDs can change too. When fresh series info arrives, and just before an episode plays, saved positions and the current episode move to the ID now listed for the same season and episode number. If a position was saved under both IDs, the newer is kept.
- **Names** are compared lower-case with provider quality tags removed (HD, FHD, 1080p and similar; editable patterns in `data/guide-rules.json`) and punctuation dropped, so "ESPN (1080p)" matches "ESPN HD".
- **Results:** matched items take the new ID, name and guide ID, and the app shows a short note. A favorite whose new ID is already a favorite becomes a tombstone rather than a duplicate. Anything with no match is kept as it was and logged, never deleted.
- **Testing:** `match_selftest=1` in the manifest runs an on-device self-test against the real catalog at launch (made-up IDs must be found again); it passed on Oct 4, 2026.

## Data model

All saved state is one versioned JSON document per device, shaped so it can later be uploaded unchanged. Every record carries `updatedAt` so two copies can be merged record by record.

```json
{
  "schema": 6,
  "deviceId": "<uuid>",
  "deviceName": "Living room",
  "credentials": { "server": "…", "username": "…", "password": "…" },
  "favorites": [ { "streamId": 1234, "name": "ESPN", "epgChannelId": "ESPN.us", "pinned": false, "position": null, "updatedAt": 0, "deleted": false } ],
  "series": [ { "seriesId": 55, "name": "…", "year": 2024, "watched": "S1:1-10,S2:1-4", "current": { "episodeId": 901, "season": 2, "episode": 5, "name": "…", "ext": "mkv" }, "updatedAt": 0, "deleted": false } ],
  "resume": [
    { "kind": "movie", "id": 777, "name": "…", "ext": "mp4", "position": 2210, "duration": 7680, "updatedAt": 0 },
    { "kind": "episode", "id": 901, "name": "…", "ext": "mkv", "seriesId": 55, "season": 2, "episode": 5, "position": 1234, "duration": 2640, "updatedAt": 0 }
  ],
  "recent": [ { "streamId": 20271, "name": "ESPN 2", "epgChannelId": "ESPN2.us", "updatedAt": 0 } ],
  "teams": [ { "id": "a1b2c3d4", "name": "Alabama", "aliases": ["Crimson Tide"], "exclusions": ["North Alabama"], "sports": ["football"], "updatedAt": 0, "deleted": false } ],
  "seenGames": [ { "key": "a1b2c3d4|alabama vs texas", "start": 0 } ],
  "market": { "key": "GA|Atlanta", "label": "Atlanta, GA" },
  "settings": { "showMyTeams": true, "showNoGameTeams": true }
}
```

Schema 3 added `recent`, the Recently Viewed channels (newest `updatedAt` first, at most 15). Schema 4 added `teams` (My Teams) and `seenGames`, games already seen in the last 4 days, one entry per matchup and start (at most 20, newest kept, per device), used to label replays. Schema 5 added `market`, the device's local TV market for My Teams. Schema 6 added `settings`, per-device on/off options (`showMyTeams`, `showNoGameTeams`, both on by default; later `showFavoritesInRecent`, off). New options join `settings` with a default when missing, without a schema change. Teams can also carry `logo` and `logoFor` (team logos); both are optional and missing means "not looked up yet", so they needed no schema change. Schema 7 added `watchlist`, the Watch List movies (see Home, Watch List). Schema 8 (V2 sharing) added `resumeGone`, removed resume points `[{ kind, id, at }]` (at most 40, 28 days), so another TV's copy can't bring them back, and `favoriteAt` and `progressAt` on series, since a series' favorite and its progress are shared separately; per-TV `settings.share` (`favorites`, `teams`, `series`, `progress`, all on when missing) says what this TV shares.

Schema 2 (milestone 3) added `name` and `ext` to resume entries and the episode details to `series.current`, so Continue Watching draws and plays without the network. `series.current` is the episode to continue (in progress or next unwatched); its position lives in the matching `resume` entry. A series whose last episode is watched has `current: null` and leaves Continue Watching.

| Rule | Detail |
| --- | --- |
| Timestamps | `updatedAt` from `roDateTime().AsSeconds()` on every record. |
| Deletions | Marked `deleted` with a timestamp, not removed, so a later sync cannot resurrect them. Cleared after a few weeks while storage is local-only. |
| Watch history | Episode ranges per season (`S1:1-10,S2:1-4`), about 60 bytes per series. Merges as a union. |
| Resume | Newest copy wins. Capped at about 50 entries, oldest dropped. Names capped at 60 characters to save registry space. |
| Recently viewed | Per device, like usage scores; not merged across devices. Capped at 15. The first thing trimmed when the registry is nearly full. |
| Times | Stored in UTC. |

Later features add fields to this document: favorite teams, and a separate per-device usage-score table. The schema number increases with each change.

## Architecture

The app is BrightScript with SceneGraph. Screens talk only to MainScene, and three services own all network and storage access.

&#91;embedded content: app architecture · screens, MainScene, three services\]

- **ApiTask** is a `Task` node wrapping every HTTP call, because `roUrlTransfer` must run off the render thread. Retries and error handling live in one place.
- **EpgService** fetches now/next for visible favorites in version 1. Its interface (`getPrograms`, later `findPrograms`) lets a server answer it later.
- **StateStore** is the only path to saved state: registry in version 1, a backup server added behind it later.
- **Channel matching** is one shared component (`ChannelMatch.brs`, run by SearchTask): it re-matches saved channels and series after renumbering and, later, maps networks to channels for My Teams.

## Provider guide findings

The provider's full XMLTV guide is about 63 MB with 11,330 channels and 186,000 programs, too large to load on a Roku. It covers roughly 24 hours back and 24 hours ahead. Findings below come from the sample downloaded on Oct 4, 2026.

| Finding | Example | Rule for the app |
| --- | --- | --- |
| Titles carry superscript tags | `Alabama vs. #8 Texas ᴸᶦᵛᵉ`, `Today ᴺᵉʷ` | Strip for display; keep as flags. |
| Live tag is unreliable on event channels | A Sunday re-air of Saturday's game was tagged ᴸᶦᵛᵉ | Trust the tag on network channels only. |
| Guide times use a +0100 offset, even for US channels | `20261004180000 +0100` | Parse the offset; store UTC. |
| Event channels are numbered families | `BossSports.ESPN Unlimited.092` (about 2,800 channels) | Recognize families by pattern. |
| Event channel names carry sport, matchup and start time | `ESPN UNLTD 092: Volleyball: Alabama vs. #8 Texas (10.04 01:00 PM ET)` | Parse from `get_live_streams` names; no guide needed. |
| Event blocks are 4-hour placeholders | `Next Event: … at 01:00PM EDT on Oct 4`, then `Signing Off` | Take start time from the text, not the block. |
| Event channels fill in only about the evening before | No next-day events listed | Same-day lookups only. |
| One network game appears on many channels | ABC game on 192 affiliates | Group by matchup and start time; use a preferred affiliate per network. |
| Team names collide with other content | North Alabama, *Sweet Home Alabama*, the band Alabama, local news | Search sports channels only; aliases with exclusions. |

These patterns are this provider's conventions and may change. All parsing rules, including the sport-name mapping, are stored as editable data, not hard-coded.

## Later features

Three features follow version 1. Version 1's abstractions (`StateStore`, modular rows, channel matching, `EpgService`) are what make each one an addition rather than a rewrite.

### My Teams

A home-screen row of my favorite teams' games in the next 24 hours, for only the sports I choose per team.

- **Favorite team record:** name, aliases (including mascot), exclusions, chosen sports, `updatedAt`, deleted flag.
- **Event channels:** parse sport, matchup and start time from stream names in the selected sports categories.
- **Network broadcasts:** the guide for about 15 national sports channels plus the preferred ABC affiliate.
- **Matching:** title and description, title matches ranked higher. Only the sports categories I select are scanned.
- **Sport mapping:** an editable rule table maps provider wording ("Volleyball:", "NCAAF", "College Football :") to one fixed sport list.
- **Duplicates:** one card per game; other channels showing it are listed as fallbacks.
- **Live scores:** a live game card (not a replay) shows the score and game state in place of the sport line ("LAD 3 - ATL 1   Mid 8th"), from ESPN's public scoreboard JSON (no key; unofficial, so it may change or stop, and then cards just show the sport line). Fetched through ApiTask to cachefs:/teams/ (saveOnly) only while Home shows a live game, every 45 s, and at once on coming back to Home when the last fetch is over 30 s old (new scores are set on the game cards in place, without rebuilding Home, so focus stays put), one scoreboard per league of the sports being played (`myTeams.scores` in data/guide-rules.json: our sport ID -> ESPN league paths; college football with every FBS game is about 1 MB); SearchTask matches games by team name or alias and a start within 12 hours (`findScores`). Settings -> Live scores on My Teams turns it off (per device, `settings.showScores`, on by default), for watching on a delay.
- **Replays:** a matchup with a game seen 6 to 15 hours earlier is labeled Replay (each game is kept, so a replay of game 4 of a series is measured against game 4, not game 3) (rebroadcasts air that night or the next morning; the next game of a series is about 17 hours or more later).
- **No channel:** a game found with no playable channel still shows, with the network and a note.
- **Refresh:** on launch and about every 30 minutes while the home screen is showing.
- **Order:** live first, then by start time; team usage score breaks ties.
- No outside schedule service is needed for the 24-hour window.

**Built (step 1: teams and event channels, Oct 4, 2026)**

- **Showing the row** is a per-device setting: Settings → Show My Teams on Home (On by default). Off hides the row and skips the game searches and guide downloads behind it; teams stay saved.
- **Teams with no game:** Settings → Show teams with no game (On by default, `settings.showNoGameTeams`) adds a card at the end of the row for each team with nothing in the next 24 hours: team name, "No game in 24 hours", its sports. Selecting it opens the team's settings. These cards never move the row to the top. Games come first: live, then upcoming by start time.
- **Team names** should be written the way channel names write them ("Alabama", not "Alabama Crimson Tide"); nicknames go in aliases.
- **Teams** are managed in Settings → My Teams: name, sports (at least one), aliases ("Also called") and exclusions ("Not when it says"). Choosing sports is what keeps out other teams with the same name (minor-league hockey Eagles, for example).
- **Logos:** looked up once per team name on TheSportsDB (free public API, `myTeams.logos` in `data/guide-rules.json`): the team name first, then each alias, taking the first result in one of the team's sports. The 250 px image URL is saved with the team (`logo`, plus `logoFor`, the name it was found for, so a rename looks it up again; `logo` "" means none found). Game cards show the logo at the bottom right, "no game" cards at the top right beside the name; initials stand in when there's no logo or it hasn't loaded. Settings → My Teams → a team → Logo shows the result, and OK looks it up again. Only the team's name and aliases are sent.
- **Finding games** runs in SearchTask over the live index (`MyTeams.brs`): channels in event categories (`Sports | …`, `PPV …`; not `… Teams` or `… Replays`) whose name mentions a team as whole words, has an event time from 4 hours ago to 24 hours ahead, and whose sport is one of the team's. A listing whose sport can't be determined (e.g. "ESPNU: Auburn vs. Tennessee") makes a game only if it names the team in full; if only an alias matches (e.g. "Atlanta"), it can join a game found another way but never creates one. Network programs must name their sport. (Learned on the TV: an "Atlanta" alias otherwise pulled in a WNBA game and a local news show.) Team words are checked before anything else, so a full scan takes about 0.1–0.2 s.
- **Event times** use the `nameTimes` rules (also used to show channel names in local time), covering this provider's formats: ISO in UTC, `(10.04 01:00 PM ET)`, `@ 4 Oct 12:00 PM ET`, `@ Oct 04 01:00 PM ET`, `… London`, and no zone (read as US Eastern). Formats without a year take the year that puts the date nearest to now, so a "Jan 1" bowl game listed on Dec 31 is next year's.
- **Sports, categories, separators, replay words, later languages and time windows** are rules in `data/guide-rules.json` (`myTeams`).
- **One card per game:** a team's listings of the same sport starting within 90 minutes of each other are merged (one may include the pregame), keeping the earliest start. A listing whose sport is unknown joins the nearest; an alias-only listing that could belong to two games joins neither. So a football and a volleyball game an hour apart stay two cards. Main-language channels come first; selecting a game with several channels asks which.
- **Replays:** all channels named as replays, or a matchup already seen 6 to 15 hours earlier. Until Oct 2026 any matchup seen 6 hours to 4 days earlier counted, which labeled the next games of a playoff series (Dodgers at Braves, NLDS) as replays.
- **Live** from the start time for 3½ hours. The row appears once a team is saved, below Favorites, or at the top while a game is live or starts within 30 minutes. It refreshes after each catalog refresh, after team changes and every 30 minutes on Home.
- **Before the start:** selecting a game more than 15 minutes early says event channels usually aren't on yet, with Play anyway. This provider answers HTTP 407 for an event channel that isn't carrying anything, before the game or, once seen, during one.

**Built (step 2: network broadcasts, Oct 4, 2026)**

- **Channels:** 16 national sports channels (ESPN, ESPN2, ESPNU, SEC, ACC, Big Ten, FS1, FS2, CBS Sports Network, NFL, MLB, NBA TV, NHL Network, TNT, TBS, truTV), listed by guide ID in `data/guide-rules.json` (`myTeams.networks`), plus the ABC, CBS, NBC and FOX stations of the device's market. Among copies of a feed, backup, low-bandwidth, West and overflow copies are skipped.
- **Local market:** Settings → Local stations picks the device's market from a list built from the provider's local-station channels (`GA | Atlanta | ABC 2 WSB` in `US | Local ABC`; patterns `localCategories` and `localName` in the rules). Saved per device (schema 5, `market`); empty until chosen, since a default would be wrong in other homes. Atlanta resolves to ABC WSB, CBS WANF and WUPA, FOX WAGA, NBC WXIA.
- **Guides:** each channel's whole schedule (`get_simple_data_table`, about 2–3 days, 70–170 listings) is saved to `cachefs:` through ApiTask, at most every hour, and searched in SearchTask: the title first; the description only when the title names a sport or a matchup (so talk shows that mention a team don't count), with the matchup taken from its first sentence. (Learned Oct 6, 2026: this provider ignores `get_short_epg`'s limit and sends only 4 listings, a few hours, so an evening NLDS game on FS1 was missed until the guides switched; the call is `guideAction` in `data/guide-rules.json`.) Listings that name a team but don't make a game are logged with the reason (`[teams]   skipped:`).
- **Merging:** a network broadcast joins the event-channel card for the same game (same team and sport, within 90 minutes). The network channel is listed first, since it's always on, and its guide title and end time are used.
- **"No channel" cards** aren't built: every source the app has comes with a channel, so they would need an outside schedule, which this feature avoids.
- Verified on a Roku: the Braves–Dodgers game was found on FS1 and merged with its event channel.

### Usage-based item ordering

Items within each row are ordered by a decaying score that combines recency and frequency. Row positions never change.

- **Favorites:** a view counts after about 3 minutes on a channel, so channel surfing does not count. Pinned favorites stay first in manual order; the rest sort by score.
- **Continue Watching:** score per movie or series, one point per viewing session.
- **My Teams:** time order; team score breaks ties only.
- **When:** re-sort at app launch only. Order holds when returning from playback.
- **Storage:** a separate per-device table keyed by favorite, series/movie and team ID. Not synced; each TV keeps its own habits.

**Built (Oct 4, 2026)**

- **Score:** each use adds 1 point; points halve every 14 days. Uses: 3 minutes on a live channel, a movie or series watched past 30 seconds (once per viewing session), choosing a team's game. Half-life, the 3-minute threshold and the 60-entry cap are rules in `data/guide-rules.json` (`usage`).
- **Storage:** its own registry section (`iptv_usage`), one compact string, single copy, apart from the synced document. Lowest scores are dropped past 60 entries; a failed write is skipped, since losing it only resets the ordering.
- **Launch snapshot:** scores are read once at launch and used all session, so rows never reshuffle. Favorites added during a session go at the end; anything started during a session goes at the front of Continue Watching.
- **Pinning:** `*` in the Favorites grid offers Pin to front / Unpin / Remove. Pinned favorites come first in the order they were pinned; pinning applies immediately.
- **Recently Viewed** stays newest first (not part of usage ordering).

### Off-device backup and sync (V2)

Version 2: stages 1 (automatic backups to the home Pi, restore), 2 (sharing between TVs) and 3 (household setup and admin page) built Oct 8, 2026; see "Built" below. Prompted by Oct 6, 2026, when a failed sideload removed the Basement Roku's dev app and with it all its saved state. Decisions so far:

**Service: interchangeable storage, nothing more.**

- A tiny protocol, documented in the repo: `GET /devices`, `GET /devices/<id>`, `PUT /devices/<id>`. No provider-specific features.
- The server stores sealed files only; encryption, merging and restore all happen on the Roku, so any host works.
- Two implementations kept in the repo: a Cloudflare Worker (free tier, Workers KV) and a portable script that stores files in a folder (any PC, Pi, NAS or Docker). `scripts/test-backup-server.ps1` checks any host against the protocol before switching.
- `scripts/backup-export.ps1` / `backup-import.ps1` keep a local copy of all backups and move them between hosts.

**Hosting on the home Raspberry Pi (option, recorded Oct 8, 2026).** If the Pi Dolby converter is built (below), the same Pi can be the main host: the folder-storage server and the admin web app run beside the converter, as another systemd service. Nothing on the TVs changes; the protocol, encryption and signing are the same as for Cloudflare.

- **For:** one always-on box for both jobs; fast and private, since backups and the household configuration never leave the house; no cloud account needed.
- **Off-site copy:** a failed card, a power surge or anything that takes the Pi takes the backups with it. Store them on an SSD (USB) rather than the microSD card, and copy them off the Pi every night (a PC, a USB drive, or a cloud folder, or the Cloudflare host as a second copy). The TVs refill an empty server within one launch each, but only while they still have their own state.
- **Address:** a fixed IP reserved on the router, and the backup hostname pointed at it by the router's local DNS if it has one, otherwise the IP itself. Rokus can't resolve `.local` names. Moving later to Cloudflare stays a hostname change, with the same key.
- **When the Pi is off or unreachable:** the app carries on with what each TV has saved and catches up when it's back (the "never slows or blocks" rules below).
- **Admin page from outside the house:** home only, unless something like Tailscale is added; editing the household configuration away from home isn't needed today.
- **Provider password:** the household configuration holding it is sealed with the household key, as on any host, so the Pi stores only encrypted data and other devices on the home network can't read it.

**Switching hosts without touching the TVs.**

- The app is built with a hostname you control (e.g. `backup.<your domain>`) and a household key, set once in `scripts/deploy.local.ps1` (git-ignored) and baked in at deploy. Moving providers is a DNS change (short TTL), with the same key on the new server.
- Each backup is encrypted (AES) and every request signed (HMAC) on the Roku, so the key never travels and a plain-HTTP host is still safe. HTTPS is an extra layer, not a requirement, which keeps the choice of host open.
- The TVs are the source of truth: each keeps its full state locally and re-sends its backup when the server's copy is out of date, so a new, empty server refills itself within one launch of each TV.

**Never slows or blocks the Roku.**

- Its own background Task: not the render thread, not ApiTask's provider request slots.
- Local-first: StateStore saves to the registry as now; the backup is notified afterwards and nothing waits on it.
- Batched uploads (latest version only, at most every few minutes), never while a stream is starting; ~5 s timeouts; backing off up to hours when unreachable; failures logged, never shown.
- Launch never waits. Only a fresh install (no local state) asks the service, and only offers "Restore from: Basement / Family Room" if it answers within a couple of seconds; otherwise Settings → Restore from backup stays available.
- Off entirely when no backup hostname is configured. Verified against a server that never answers before relying on it.

**Sharing between TVs: some, not all (to decide).** The saved document already supports record-by-record merging (`updatedAt`, tombstones), so chosen kinds of records (for example favorites, teams, series favorites, watch progress) can merge across TVs while others stay per TV (device name, local market, Recently Viewed, usage ordering). Which ones is still open.

**Household configuration: pre-configures new installs.**

- One household document on the service, alongside the device backups. It holds the provider account (server URL, username, password) and what a new TV starts with: the household favorites (live channels), My Teams (the saved teams), the local stations market, and every option on the Settings page (Show My Teams on Home, My Teams position, Show teams with no game, Favorites in Recently Viewed). The device name is still asked on each TV. Watch List, Favorite Series and viewing history start empty and are per TV. It replaces today's `backups\household.json`, which only changes with a redeploy.
- Sealed like the backups: encrypted with the household key, so the host only stores encrypted data. Protocol additions: `GET /household`, `PUT /household`.
- A TV that starts with no saved state asks for its own backup first, then falls back to the household configuration and asks only for a device name. The same "never blocks" rules apply: a short timeout, then the normal Setup screen.
- Changing the household configuration doesn't overwrite TVs that are already set up. Any later "push to all TVs" (for example a new provider password) is a separate, explicit choice.

**Admin web app (phone or computer).**

- A small web app served by the same host as the backup Worker: Cloudflare Pages or the Worker's static assets, both free (e.g. `backup.<your domain>/admin`). Not a native iOS app, which would need a Mac with Xcode and a paid Apple developer account (free installs expire after 7 days). On an iPhone it's added to the home screen from Safari and runs full screen like an app.
- Edits the household configuration. Optionally it also lists the household's TVs with their last backup time, and lets you view or restore a TV's backup.
- Encryption happens in the browser (Web Crypto) with the household key, entered once on each phone or computer and kept in that browser's storage, so the service still never sees plain data.
- Access: Cloudflare Access (Zero Trust free plan, up to 50 users) asks for an email code or Google sign-in before the page loads. Its sign-up may ask for a card even on the free plan; confirm when setting up. Fallback: a password checked by the Worker. The Roku endpoints stay key-signed, with no sign-in.
- Built and deployed from this repo with the rest of V2 (Worker, admin page, protocol test script).

**Decided (Oct 8, 2026):** the home Raspberry Pi is the host, found by a network search (as the Dolby converter is), not a hostname; shared between TVs: favorites, My Teams, Favorite Series and the Watch List, and watch progress (resume points and watched episodes). Device name, local stations market, Recently Viewed, settings and usage ordering stay per TV.

**Built, stage 1: automatic backups and restore (Oct 8, 2026).** Stages: 1 backups and restore; 2 sharing the chosen records between TVs; 3 the household configuration and admin page.

- **Pi:** `pi/backup-service/backup.py` (Python standard library only) runs as the `iptv-backup` systemd service on port 8792 under its own no-login account, storing in `/var/lib/iptv-backup`: `devices/<id>.json`, the latest sealed backup per TV, and `history/<id>/<YYYY-MM-DD>.json`, the last copy of each day, 30 days kept. Protocol: `GET /devices` (id, name, savedAt), `GET`/`PUT /devices/<id>`, `GET /devices/<id>/history` and `/devices/<id>/<day>`, `GET /health`. It answers `IPTV-BACKUP?` on UDP 8793 with `IPTV-BACKUP <port> <version>`, home network only. `scripts\pi-deploy.ps1 -Service backup` installs it (no `-Service`: the converter too).
- **Household key:** 32 random bytes, `$BackupKey` in `scripts\deploy.local.ps1` (git-ignored; a new key makes existing backups unreadable). `deploy.ps1` puts it into the package as `data/backup.json`; `pi-deploy.ps1` writes it to `/etc/iptv-backup/key` (root and the service only) over SSH's input. Keys derived from it: encryption = HMAC-SHA256(key, "enc"), signing = HMAC-SHA256(key, "mac").
- **Sealed backup:** `{"v":1, "device", "name", "savedAt", "iv", "data", "mac"}`: the saved document encrypted with AES-256-CBC (random IV), base64; mac = HMAC-SHA256 over iv + data. The Pi checks the mac and refuses a mismatch, so other devices on the network can't overwrite a backup; it can't read one. Names and save times are in the clear, for the restore list. Basement's is about 7 KB.
- **App:** BackupTask, its own thread (`components/services/BackupTask.*`), finds the service by the broadcast, seals and sends; MainBackup.brs sends this TV's state 20 s after launch and within a minute of any save (not pushed back by later saves, so movie progress every 30 s can't hold it off). Settings shows "Backup: saved to the Raspberry Pi at 2:09 PM", or why not. Nothing waits on the Pi.
- **Restore:** a TV that starts with nothing saved asks the Pi for its backups and offers "Restore this TV?" with each TV's name and save time, plus "Set up as a new TV". Choosing one makes this TV that one again (same device ID and name), then Home and the login carry on as at a normal launch. No Pi, nothing on it, or "Set up as a new TV": the copy `deploy.ps1` bundled from `backups\` (this TV's by IP, else the household copy), as before; otherwise Setup. The bundle is no longer applied automatically at startup, since the Pi's copy is newer.
- **Tested Oct 8, 2026 on the Basement TV:** backups found the Pi and were saved; one decrypted on the PC with the key (8 favorites, 3 teams, 2 series, 2 Watch List movies, the account); a forged upload was refused. With `restore_test=1` in the manifest (start empty, write nothing), the TV offered Basement's backup, restored it, and Home came back with favorites, My Teams and Continue Watching.
- **Not yet:** a nightly copy off the Pi; an SSD.

**Built, stage 2: sharing between TVs (Oct 8, 2026).**

- **What's shared:** favorites (with pinning), My Teams, Favorite Series and the Watch List, and watch progress (resume points and watched episodes). Each TV chooses in Settings → Sharing between TVs, all on by default; a kind turned off stops going both ways, and what the TV has stays. Device name, local stations market, Recently Viewed, settings and usage ordering stay per TV.
- **Shared copy:** one sealed document on the Pi, `/shared` (`{ favorites, teams, watchlist, series, resume, resumeGone }`), with a version number. A save names the version it was merged from; if another TV saved in between, the Pi refuses it (HTTP 409) and the TV fetches, merges and saves again (up to 3 times), so no TV's changes are lost. Daily copies are kept as for backups.
- **Merging (StateStore `mergeShared`):** record by record, the newer `updatedAt` wins, deletions included (tombstones; ones older than 28 days are dropped on both sides). Series: the favorite and the progress each go by their own time (`favoriteAt`, `progressAt`), and watched episodes are joined, so marking one unwatched on one TV doesn't carry to the others. Resume points: the newest of each unless removed since (`resumeGone`); the shared copy holds the newest 25, each TV up to 50. The TV redraws Home and My Teams when anything came in.
- **When:** 10 s after launch, with each backup (within a minute of a change), every 10 minutes, and on coming back to Home 2 minutes or more after the last sync. Nothing waits on it; Settings shows the last sync, or why not.
- **Tested Oct 8, 2026** on the Basement TV, with the PC as a second TV (`fake-tv.ps1` in the session scratchpad): a favorite the PC added appeared on the TV on going back to Home; one removed on the TV was a tombstone in the shared copy within a minute. Then with real TVs: Basement, Family Room and an unnamed TV (likely the Deck) merged their favorites and teams.
- **Teams are one team by name (found Oct 8, 2026):** each TV had added Alabama, the Falcons and the Braves itself, with its own IDs, so sharing showed each team twice on every TV. When merging, a team with the same name as another (any case) is the same team: the copy with the lowest ID is kept, and the TV deletes its other copies, which then reaches the other TVs.

**Built, stage 3: household setup and admin page (Oct 8, 2026).**

- **Admin page:** `http://192.168.222.99:8792/admin`, served by the backup service (`pi/backup-service/admin.py` and `admin.html`; plain HTML and JavaScript, works on a phone). Signed in with an admin password, `$AdminPassword` in `scripts\deploy.local.ps1`; `pi-deploy.ps1` sends it over SSH's input and the Pi stores only its hash (PBKDF2, `/etc/iptv-backup/admin`). Sessions last 12 hours (HttpOnly, SameSite=Strict cookie); a wrong password waits a second. Home network only, as the rest of the service.
- **Pages:** TVs (each TV's backup opened: account without the password, favorites, My Teams, local stations, Favorite Series, Watch List, Continue Watching, settings, sharing; its daily copies, each viewable, and "Make current" to make one the backup a reinstalled TV restores); Household setup; Sharing (the shared copy's version, who saved it, what it holds).
- **Opened on the Pi, not in the browser:** browsers allow their encryption (Web Crypto) only on HTTPS pages, and the Pi serves plain HTTP at home, so the service opens and seals data for the page (Python `cryptography`, installed by `install.sh`). It already holds the household key to check uploads, so this changes who can read backups only for whoever has the admin password.
- **Household setup:** account, favorites, My Teams, local stations and the Settings page options. Filled by "Copy everything" from a TV's backup, then single favorites and teams removed and the account edited; saved sealed (`/var/lib/iptv-backup/household.json`), which the TVs read from `GET /household`. It replaces `backups\household.json` for new TVs; that bundle stays as the fallback.
- **New TV:** after "Set up as a new TV" (or when the Pi has no backups), the TV asks the Pi for the household setup and, if there is one, asks only "Name this TV". Its records are dated when the setup was saved, so changes the TVs shared since win. Without one: the bundle from deploy.ps1, else Setup. TVs already set up aren't changed.
- **Tested Oct 8, 2026:** the admin API from the PC (refused without sign-in, with a wrong password and after sign-out; a TV's backup opened; a household setup copied from Basement saved and read back as a TV reads it, 12 favorites, 6 teams, Atlanta). On the Basement TV with `restore_test=1`: "Set up as a new TV", named Test, came up with the household account, favorites, My Teams and local stations; sharing then brought Continue Watching and removed the duplicate teams.
- **Sending the account to TVs already set up (Oct 8, 2026):** the admin page's "Save and send to all TVs" (Account section) sets `accountAt` in the household setup; a plain Save keeps the last one. After each sync, a TV fetches the household setup and, when `accountAt` is newer than the one it last took or refused (`settings.householdAccountAt`), logs in with the new account first (MainBackup `checkHouseholdAccount`). It switches only if that works (saved like a new account in Setup: an account change clears the cached lists), with "Account updated from the household setup". Refused: it keeps its own, says so once, and doesn't try that account again until it's sent anew; any 4xx counts as refused, since this provider answers a wrong password with HTTP 404, which a normal login reads as a wrong server URL. No answer or a server error: tried again at the next sync. A TV with Settings → Sharing between TVs → "Account changes from the admin page" off keeps its own. The same account as the TV's: just noted. Tested Oct 8, 2026 on the Basement TV: a deliberately wrong password was tried, refused and not retried, the TV kept working; then the correct account, already in use, was only noted.

**Off-site copy (Oct 8, 2026).** Every night at 3:30 AM (`iptv-offsite.timer`, run soon after start-up if the Pi was off then), `offsite.sh` copies `/var/lib/iptv-backup` to OneDrive with rclone: `DixieTV-backups/<YYYY-MM-DD>/`, 30 nights kept (folders removed by their date name, not file times). Every file there is sealed with the household key, so OneDrive holds nothing readable. The result goes to `offsite.json`, shown on the admin page's TVs tab ("Last copied …", or the error). The OneDrive connection is the rclone remote `dixie-onedrive` in `/etc/iptv-backup/rclone.conf` (root only), made once: `rclone authorize "onedrive"` on a PC with a browser, then `ssh -t iptv-pi "sudo rclone config --config /etc/iptv-backup/rclone.conf"` (new remote, onedrive, global region, no auto config, paste the token, OneDrive Personal). Debian's rclone 1.60 could list OneDrive but every upload failed ("unauthenticated"), so `install.sh` installs the current release from rclone.org (checksum checked) when the one there is older than 1.65; 1.75.1 copied the first night's 9 files (75 KB).

- **The household key must live off this PC too:** `$BackupKey` in `scripts\deploy.local.ps1` is the only way to open any backup, on the Pi or in OneDrive. Keep a copy in a password manager (done Oct 8, 2026). The Pi and every Roku have DHCP reservations on the router, so their addresses stay fixed.
- **Rebuilding a dead Pi:** Raspberry Pi OS, an SSH key (`iptv-pi`), `.\scripts\pi-deploy.ps1`, the OneDrive connection again, then `rclone copy dixie-onedrive:DixieTV-backups/<last night> /var/lib/iptv-backup` (as root, then `chown -R iptvbackup /var/lib/iptv-backup`). The TVs send anything newer at their next start.

Later, the service could also compute results the Roku can't (full-guide search, e.g. for My Teams) and push parsing-rule updates.

### Dolby audio converter on a home Raspberry Pi

Recorded Oct 7, 2026 as an option; built Oct 8, 2026 (see "Built" below). The problem: a TV that accepts only stereo over HDMI (the Family Room's 2008 Samsung LN52A650) can't play any Dolby channel (ESPN, SEC Network, FS1, Tennis Channel), and the Roku won't decode Dolby for apps. Today the app falls back to the provider's LBW copies (AAC, lower bitrate). The app itself can't convert the audio: Roku gives apps no audio decoder, and decoding Dolby in BrightScript is far too slow. Cloudflare can't do it either (Workers can't run ffmpeg, and relaying video isn't allowed on the free plan).

**Design:**

- **Hardware:** a Raspberry Pi 4 (2 GB) or Pi 5 at home, on wired Ethernet, with a fixed address from the router (about $70-90 with power supply, case and microSD). Only audio is converted; video is copied untouched, so a stream takes a few percent of the CPU.
- **Pi side:** a small converter service (about 100 lines) plus **ffmpeg**: for each request it fetches one segment from the provider and returns it with the video copied and the Dolby audio converted to AAC stereo (`-c:v copy -c:a aac -ac 2`, timestamps kept), well under a second per 10-second segment. An install script sets up ffmpeg and a systemd service that starts at boot; setup notes cover Raspberry Pi OS Lite (Raspberry Pi Imager), SSH and the fixed address. It's stateless and keeps no provider account: each request carries the segment's provider URL (inside the home network only).
- **App side:** a "Dolby converter" address in Settings (per device, or later in the household configuration). On a TV whose Settings audio check says no Dolby, a Dolby channel plays through StreamRelay as now, but its segments point at the Pi instead of the provider, so the TV gets the full-quality copy in stereo instead of LBW. Rewind (the archive) works the same way. If the Pi is off or unreachable, the app falls back to switching to another copy, as today.
- **Connections:** none while idle. While a TV watches through it, the Pi fetches the stream instead of the Roku (same household internet address), so it's still one provider connection per stream being watched, as without the Pi. Other channels, and TVs that play Dolby, don't use it.
- **Several TVs:** one Pi serves every affected TV (more than one is likely: the Deck Roku failed on SEC Network too). Each TV decides for itself from its Settings audio check; the Pi's address can go in the household configuration so new TVs pick it up. A Pi 4 handles several audio conversions at once, and the account allows 3 streams anyway. A TV is affected when the app's Settings show "Dolby audio: NO".
- **Network:** per stream, about 6-10 Mbit/s from the Pi to a Roku (video unchanged; FS1 measured 5-6 Mbit/s, busy 1080p sports up to about 8-10; audio gets slightly smaller, Dolby 384-640 kbit/s to AAC 128-192). The Pi carries each stream twice (in from the provider, out to the Roku): about 12-20 Mbit/s per stream, 35-60 Mbit/s at 3 streams, a few percent of its gigabit port. Internet use doesn't change (the Pi downloads instead of the Roku); the Pi-to-Roku leg stays inside the house. Segments arrive and are passed on in bursts, which keeps the Roku's buffer full.
- **Home network (as of Oct 2026):** the Pi on wired gigabit Ethernet; some Rokus are wireless, on Ubiquiti UniFi AP SHDs (802.11ac Wave 2, 4x4, up to about 1.7 Gbit/s on 5 GHz), far more than a few streams need. A wireless Roku gets the same amount of data from the Pi as it does from the internet today, so one that streams well now will through the Pi; delivery may even be steadier, since provider hiccups no longer reach it directly. If one struggles, check in the UniFi controller (Clients): that it's on 5 GHz (the Ultras support it), its signal (about -65 dBm or better) and link rate (well above 50 Mbit/s), and whether it flips between APs (lock it to the nearest only if so).
- **Also the backup host:** the same Pi can host V2 backup and sharing and the admin web app (see "Hosting on the home Raspberry Pi" under Off-device backup and sync), with an SSD for storage and a nightly copy off the Pi.
- **Alternative without code:** a soundbar or AV receiver with HDMI input between that Roku and its TV decodes Dolby itself (about $100 or more per TV). A Pi can't sit between Roku and TV instead: its two HDMI ports are outputs, and HDMI capture add-ons top out at 1080p30, are blocked by the Roku's HDCP, and add lag.

**Built (Oct 8, 2026).** Differences from the design above are noted.

- **Pi:** the home Raspberry Pi 5 (8 GB, Debian 13, Python 3.13, ffmpeg 7.1, wired gigabit; its file sharing and Wi-Fi hotspot were turned off Oct 8, 2026). `pi/dolby-converter/converter.py` (Python standard library only) runs as the `dolby-converter` systemd service on port 8790 under its own no-login account, starts at boot and writes nothing to disk. `scripts\pi-deploy.ps1` copies the folder over SSH and runs its `install.sh` (installs ffmpeg if missing, then installs and restarts the service). SSH uses a key without a passphrase made for this (host `iptv-pi` in `~\.ssh\config`); the Pi accepts keys only.
- **Addresses:** the app puts `http://<pi>:8790/x/` in front of the provider URL, written as `<scheme>/<host:port>/<path>`, so the archive's `{start}` / `{duration}` placeholders pass through unchanged. Playlists are rewritten so every segment points back at the Pi; segments come back with the video copied and the first audio track as AAC-LC stereo 192 kbit/s (`-c:v copy -c:a aac -ac 2 -copyts`), whole, with a Content-Length. Not through StreamRelay, as first designed: the Roku plays the Pi's address directly. Also `/health` (JSON status) and `/r/` (passed on unchanged). Only clients on 192.168.222.0/24 are served. Provider URLs hold the password, so the log shows only the host and file name.
- **Measured:** ESPN 1080p arrives as about 12 MB per 10-second segment (about 10 Mbit/s); fetching and converting one takes 0.7-1.0 s, with the Pi nearly idle. The audio came out as AAC-LC stereo, 48 kHz, with timestamps continuing from segment to segment, and it looked and sounded fine on the Basement TV.
- **Provider sessions (learned Oct 8, 2026):** each request for a channel's address redirects to an edge server (iad02/iad03) with a new session token. Asking the original address on every playlist reload opened session after session, and the provider refused (HTTP 403) after about 40 s. Reloading the redirected address keeps one session: playlist reloads alone ran 7 minutes without trouble. A session that also downloads video was twice ended after about 5 1/2 minutes (HTTP 407 on the playlist, 403 on its segments), and a new session numbers its segments differently, which stalled the player until the app reloaded it (6 s). So the Pi gives the player its own playlist: segment numbers continue across provider sessions, and after a session ends, the new session's newest segment follows a discontinuity marker, so the player carries on. Unused channels are forgotten after 2 minutes.
- **App:** Settings → Dolby converter (Raspberry Pi), per device (`settings.dolbyConverter`, "address:port", "" = off; port 8790 is added when left out). Choosing it first searches the home network (about 2 s): StreamRelay broadcasts `IPTV-DOLBY-CONVERTER?` on UDP 8791, twice, and the Pi answers `IPTV-DOLBY-CONVERTER <port> <version>` (home network only, not its Wi-Fi hotspot). Found: "Use this converter" (always offered, also when it's the one in use), Enter an address, Turn off, Cancel; not found: Try again, Enter an address. A new Pi address is picked up by choosing the setting again. The details panel shows whether the Pi answers its health check, made whenever Settings opens or the address changes; the details now sit beside the menu (9 items no longer leave room below it). On "Unsupported audio format: Dolby" with a converter set, the channel plays again through it, with a note on the overlay; the stream is remembered on that TV for 7 days (StateStore stream marks, kind "convert"), so later plays go through the Pi at once. Each play through the converter also asks its `/health` page: a converter that's off leaves Roku's player at "Loading" instead of failing (25 s, the start limit), and the check finds out in about 2 s. When a converted channel fails, or the check gets no answer, the app searches the home network as Settings does: the Pi at a new address is saved and the channel plays again through it there ("The Dolby converter moved to …"); no answer pauses the converter for 10 minutes (Dolby channels go to a copy after their one Dolby failure, without being marked bad), until Settings finds it working; the Pi answering where it was means the channel itself failed, so its convert mark goes and a copy plays. Choosing a converter in Settings clears the "doesn't play here" marks, so channels marked before it existed try it. Tested Oct 8, 2026 on the Basement TV with `converter_test`: a wrong saved address was replaced by the Pi's and ESPN played through it; with the service stopped, ESPN went to "LBW: ESPN" in about 4-5 s. The rewind archive goes through the Pi too. `converter_test=1` in the manifest sends every live channel through the converter, to try it on a TV that plays Dolby itself; take it out afterwards.
- **Family Room (Oct 8, 2026):** found the Pi from Settings and played ESPN and other Dolby channels through it ("working well"). A provider session ended there (HTTP 509) and the Pi carried on with a new one.
- **All TVs (Oct 9, 2026):** works on the Basement, Family Room and Deck TVs.
- **Not yet tried:** the archive (rewind) through the Pi.

### Live buffer on the home Pi

Built Oct 8, 2026 (converter service 1.2; 2-second pieces, the archive beyond the buffer and the picture size Oct 9, 1.3). Instant pause and rewind on every live channel, like a cable box, instead of a traditional DVR: while a TV watches a channel through the Pi, the Pi keeps everything since the TV tuned in.

- **Why:** the provider's catch-up archive covers only 199 channels, runs 5 minutes behind live, takes about 6 s to start, and is too big for this Roku's buffer on HD channels. The buffer covers every channel, reaches right up to live and holds normal 10-second segments.
- **Pi (`pi/dolby-converter/buffer.py`, in the converter service):** a recorder per channel checks the provider's playlist every 2 s (5 s left the picture 2-3 s further behind) and fetches new segments as they appear (the first fetch takes the newest 3), splits each into 2-second pieces at keyframes (ffmpeg's HLS writer with `-copyts`, in `/tmp`, which is memory on this Pi; its segment writer counted from zero and cut at every keyframe of the provider's timestamps), converting the audio on the way when the TV needs it, and keeps them in memory: nothing is written to the card. It reloads the redirected address and starts a new provider session when one ends, with a discontinuity marker, as the converter does. The TV gets one growing playlist of everything kept (`/b/<scheme>/<host>/<path>`, `/bc/` with the audio converted; segments `/bs/<id>/<seq>.ts`). No extra provider connections: the Pi fetches what the TV watches anyway. Memory: `--buffer-mb` (6000 MB) shared equally by the channels being recorded, oldest segments dropped past a channel's share (HD sports about 4.5 GB an hour: about 80 minutes for one TV, half that each for two). A recorder stops when its TV leaves the channel (`/bq/`) or after 45 s with no request (playlist, segment or keep-alive `/bk/`, sent every 10 s while the TV plays or holds it; its answer carries the live gap and the picture size), freeing the account's connection. `/health` lists the channels being recorded. Streams split where their keyframes allow: SEC Network (keyframes about 2.5 s apart) gave 4 pieces per 10-second segment, ESPN 5 per 11 s. A segment that can't be split is kept whole. The picture's size and frame rate are measured (ffprobe) at the start and with each new provider session.
- **App:** Settings → Live buffer, per device (`settings.liveBuffer`, on by default), used only when the Dolby converter is set and answering. Every live channel then plays through the Pi (converted where the converter would have converted it), and the player's own keys work in it: Play/Pause holds the picture and carries on; Rewind goes back 30 s and Left / Right 10 s (the pieces let jumps land within about 2 s and start sooner, which felt smoother), held down they keep going (30 s steps after about 3 s), and presses add up into one jump half a second after the last, since each jump rebuffers; Fast-forward returns to live; Back always leaves the channel (as "back to live" it got pressed once too often and left the channel). The jump count stops at live, and at the start of the buffer ("Start of the buffer (when you tuned in to this channel)") unless the channel has a catch-up archive: then it goes on ("Back 12:30  (from the archive)", as far as the archive's days reach) and plays the archive from that moment, or from the newest the archive has (it runs about 5 minutes behind live); Back returns to live through the buffer. On SEC Network the archive was found but its HD one-minute segments (53 MB) don't fit this Roku's video buffer (31 MB), the known limit: the note says so and live resumes. The overlay shows "BEHIND LIVE m:ss - Fast-forward: back to live", and the progress bar shows the point being watched in blue with the lighter part up to live.
- **Roku's player with a long playlist (learned Oct 8, 2026):** its duration is the length buffered and its position counts from the playlist's start; at live it plays about three pieces behind the newest (30 s with the provider's 10-second segments). With 2-second pieces the gap is set by the Pi instead (`liveGap` in its keep-alive answer): new pieces arrive a whole provider segment at a time, so the player needs that much plus a little in hand, max(3 pieces + 2, segment + 4), about 15 s (`LIVE_GAP`). Live through the buffer is then about 17 s behind the provider's newest picture, against about 30 s playing straight from it; the provider itself runs well behind broadcast TV, which no app can change (phone alerts arrive first). Loading or reloading a long buffered playlist starts at its beginning, not at live, so the app seeks to live once it plays, and returns to live by seeking rather than reloading. Seeks land on segment boundaries.
- **Fallbacks:** with the Pi off or not answering, live channels play straight from the provider, with the archive rewind where there is one. A channel the buffer can't play (the provider refuses it, as event channels did with HTTP 407) is checked as converter failures are; if the Pi answers, the channel plays directly ("The live buffer didn't play this channel").
- **Pictures while jumping (Oct 9, 2026, converter 1.5):** the Pi keeps a 320-pixel JPEG of each piece's first picture (ffmpeg, after the piece is in, so live isn't held up; 4-8 KB each, about 25 MB an hour, counted in the buffer's memory). `/bt/<id>/<behind>.jpg` gives the picture from that many seconds before the newest piece (the keep-alive answer carries the recorder's `id`). While Rewind or Left/Right are pressed or held, the TV shows it above the progress bar at that moment's place, with a mark on the bar; not at live or in the archive.
- **HD archive in pieces (Oct 9, 2026, `archive.py`, `/a/` and `/ac/`):** with the live buffer on, the provider's archive (going back past the buffer, Start over) comes through the Pi, each one-minute segment cut into 2-second pieces as live is. SEC Network's HD archive (54 MB a minute, more than this Roku's 31 MB video buffer, which refused it) became pieces of about 2.4 MB; the first playlist came in 6.6 s (the first minute fetched and cut) and 4 minutes were ready in 19 s, served as a growing (EVENT) playlist, closed with ENDLIST when complete. The TV asks for at most 15 minutes at a time (the next stretch loads when it ends) and starts exactly where wanted, not minutes before; the Pi keeps at most 2 such jobs (about 800 MB each for HD) and drops one unused for 90 s.
- **Storage hardware (Oct 8, 2026):** a 32 GB SanDisk Max Endurance microSD card for the Pi (made for continuous video recording), moved over with `rpi-clone` on the Pi and a USB card reader (a file copy: the old card is a full 32 GB, so a byte-for-byte image may not fit); an NVMe SSD and HAT (about $100, 256 GB at least) would be far more than the Pi needs. A traditional DVR (recordings kept for days) was considered and not chosen: the household mostly watches VOD, and nearly every game is available on demand afterwards, so what sports need is pause and rewind while watching live, which the buffer gives. A DVR would also need a USB drive (HD about 4-5 GB an hour).

### Multiple provider accounts (options, undecided)

Recorded Oct 7, 2026; not decided or planned. The current account is hit-or-miss on quality and reliability, and other IPTV providers may be good, so more than one account may be wanted later. For now the aim is to make the current account work as well as possible: nearly every fix so far is general (audio repair, Dolby fallback, stall watchdog, end-of-stream recovery, faster archive start, copy switching, "Replace favorite?", the Dolby check, live scores) and would carry over, while provider-specific behavior stays in `data/guide-rules.json` (title tags, server time zone, event-channel naming, LBW and network names), which would need a set per provider.

- **A. Switch between accounts:** Settings keeps a list of accounts and one is active at a time, like profiles. Each has its own catalog, guide and search; favorites and progress are per account. Moderate effort: records gain an account tag (schema change with migration); only the active account's catalog loads. A failing channel means switching accounts by hand.
- **B. One merged app with automatic backup (recommended for reliability):** all accounts load together; the same channel from different providers (matched by guide ID, as copies are now) is one channel with several sources. A favorite plays from the preferred provider and switches to another provider when it fails, stalls or its audio can't play (today's copy switching, across providers); channel info's Other copies lists sources from all accounts, labelled by provider; each provider's connection limit is tracked on its own. Larger effort: schema change, a search index over several catalogs (two providers is about 30,000 live channels, to be checked against Roku memory), and guide rules per provider.
- **Smaller first step toward B, a backup account:** browse the main account as now; a second account is used only as a fallback source, so when a channel fails on the main provider the same guide ID is looked up on the backup and played from there. Most of B's reliability gain with little change to the screens, and it grows into B.
- **Notes:** the app detects failures and stalls but not soft or blocky picture, so lower quality stays a choice per channel (provider ranking learned from those choices could come later). Each account is a separate subscription with its own connection limit. Trial accounts plus the app's logs (stalls, reloads, errors per channel) can compare providers on real use.

### Computers and phones in this household (nice-to-have, not planned)

Recorded Oct 7, 2026; no plans to build it. The Roku app is the main need, and its issues come first. The household also has Windows PCs, Macs and iPhones; a version for them may be considered later. If it is:

- **Shape:** keep the Roku app as it is; a second app in Flutter covers Windows, Mac and iPhone/iPad from one codebase, in its own folder in this repository. Two codebases are practical with the changes made by the assistant; this document stays the single description of both.
- **Shared, not copied:** `data/guide-rules.json` (guide tags, My Teams rules, search synonyms, scoreboard leagues), the saved-document format, and the V2 sync protocol, so favorites, teams and progress follow between TVs, computers and phones.
- **Order:** Windows first (built, run and tested on the development PC), then Mac and iPhone (built on a Mac; iPhones need an Apple developer account at $99/year, or installs that expire every 7 days). Features: live TV with the guide and favorites, movies and series with resume, search, then My Teams and the rest.
- **Costs that remain:** testing on each platform, Apple's signing, and each platform's own quirks.
- **Accounts and connections:** the same household account, sharing its 3 connections with the TVs. Other households use their own provider accounts.
- **Until then:** VLC on a PC or Mac can open the account's M3U playlist link, and IPTV apps in the App Store take an Xtream login.

## Open questions

- [ ] Which Roku models are in use? Older models have much less memory, which limits catalog caching.
- [x] Does the provider's `allowed_output_formats` include HLS (`m3u8`)? **Yes:** `m3u8` and `ts` (login response, Oct 4, 2026).
- [x] What is the account's `max_connections`? **3** (login response, Oct 4, 2026). One was already in use at the time.
- [ ] Are 3 simultaneous streams enough for the households sharing the account? Depends on how often several TVs watch at once; the connection-limit message matters more as a result.
- [ ] Confirm current beta channel limits (device count, expiry) before relying on it.
- [x] Which live channels have a catch-up archive (`tv_archive`), and for how many days? **199 of 16,009, 3 days each, mostly UK** (Oct 4, 2026). See Archive findings under Playback.
- [x] Which timeshift URL form does this provider accept, and does it expect start times in `server_info.timezone`? **The `/timeshift/...m3u8` form, with London (server) time.** The `.ts` and `timeshift.php` forms are served but don't play on Roku.
- [ ] Is searching all ~16,000 live channels fast enough on the oldest Roku in use? On the basement Roku (Oct 4, 2026) indexing took under a second for channels and about 2 s for 31,920 movies, and searching feels instant. Still to check on the oldest model.
- [ ] Do newer Roku models have a video buffer large enough for this provider's HD archive segments (about 45 MB)?
