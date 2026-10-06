# Roku IPTV Player — Requirements

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
- Grid program guide (EPG grid).
- My Teams, usage-based ordering and off-device backup (see Later features).

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

All devices share one account, so the connection limit can be exceeded. When the provider refuses a stream for that reason, the app shows a clear message instead of failing silently.

## Home screen and navigation

The home screen opens on fixed rows in a fixed order: Favorites, Continue Watching, then Recently Viewed. My Teams is added later, below Favorites, moving to the top only while a game is live or about to start.

The top bar holds Home, Live TV, Movies, Series, Search and Settings, plus a clock. A reference mockup exists for the TV layout at 1920×1080.

**Rows**

- **Favorites:** each channel shows the current program, a progress bar and the next program, from `get_short_epg` for visible channels only.
- **Continue Watching:** movies and series with time left; series point to the next unwatched episode. `*` on a card removes it: a movie's saved position is cleared; a series leaves the row and its saved positions are cleared, but its watched episodes are kept, and playing an episode again brings it back.
- **Recently Viewed:** live channels watched for about a minute or more, newest first, up to 15. Channels already in Favorites are left out. Cards look like Favorites cards (now, progress, next), and `*` adds a channel to Favorites. Saved per device with the other state, so it draws without the network.
- Each row is a self-contained module that supplies its own content, so new rows slot in without reworking the screen.

**Long rows**

- Rows scroll sideways (`RowList`). The last visible card is cut off at the screen edge to show there is more.
- The focused row's title shows a counter, such as "3 of 9".
- Each row shows about 15 items, then a "See all" tile that opens a full-screen grid. The Favorites grid is also where favorites are managed.

**Navigation behavior**

- Returning from playback puts focus back on the same card in the same row.
- The `*` options button adds or removes a favorite from any channel list, and for the channel being watched in the player.
- While a live channel plays, channel up/down moves through favorites.

**Speed**

- On launch, show the cached catalog from the last session immediately and refresh in the background.
- Favorites carry their own names and IDs, so the home screen draws without waiting on the network.
- Browse grids load in pages, so large catalogs never block the UI.

**Live TV local stations**

- When a market is set (Settings → Local stations), Live TV's first category is "Local stations - <market>", listing that market's ABC, CBS, NBC and FOX stations. It opens automatically like any first category. With no market set, the category isn't shown.
- In every Live TV list, those stations are tagged LOCAL. FAVORITE takes priority.
- The list comes from the search index, so it shows "Loading local stations ..." until the index has loaded. Changing the market updates the category and the tags right away.

## Search

Search finds live channels, movies and series by name. The Xtream API has no search, so the app searches its own copy of the full catalog.

- **Entry:** Search in the top bar opens the on-screen keyboard. Results update as letters are typed, after a short pause.
- **Results:** grouped as Channels, Movies and Series, each capped (about 50) with names starting with the search text first. Selecting a result does the same as selecting it in its browser: play a channel or movie, open a series. `*` on a channel adds or removes a favorite.
- **Matching:** case-insensitive; every word typed must appear in the name, in any order. Provider prefixes such as `US |` are searchable like any other text.
- **Local stations:** the device's market stations (Settings → Local stations) that match come first among channel results, tagged LOCAL, so a search like "abc" shows your affiliate before the ~200 others.
- **Index:** built from the full lists (`get_live_streams`, `get_vod_streams` and `get_series` without a category), cached in `cachefs:` and refreshed in the background at most once a day. Only names, IDs and the fields needed to play are kept.
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
- Some VOD files will not play on Roku because of codec or container. The player catches the `Video` node's error state and shows a readable message, never a black screen.
- A small overlay on live playback shows the channel and current program, and handles channel up/down through favorites.

**Pause, rewind and fast-forward**

- **Movies and episodes:** the `Video` node's own controls: Play/Pause, rewind, fast-forward and Left/Right to seek, with its progress bar.
- **Live channels with an archive** (`tv_archive` = 1 in `get_live_streams`, kept for `tv_archive_duration` days; marked REWIND in channel lists and search): Play/Pause pauses. A pause under a minute resumes from the player's own buffer; a longer one continues from the provider's timeshift archive. Rewind jumps into the archive, after which the `Video` node's own controls move through it. Back returns to live.
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
- A movie or episode counts as watched at about 90% viewed; its resume entry is then cleared.
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
| Saved data corrupted | Two alternating copies with version numbers; if the newest fails to parse, load the previous one. |

- Screens and player code never touch the registry directly; they call `StateStore` methods such as `getFavorites()`, `markWatched()` and `savePosition()`.
- An off-device backend can be added behind the same interface later (see Later features).
- Uninstalling the app deletes its registry. Only off-device backup protects against that.

**Channel matching (re-finding saved items after renumbering)**

- **When:** after every catalog (re)index, at launch and on each daily refresh. Only saved items whose IDs are missing from a fully loaded list are looked up, so a failed or partial download can't re-match anything.
- **Channels** (favorites and Recently Viewed), in order: the only channel with the same guide ID; among channels sharing the guide ID (HD/SD/backup copies of one feed are common), the one with the same name; the only channel with the same name; otherwise the first channel sharing the guide ID.
- **Series:** the only series with the same name and year (year ignored when either side doesn't know it). The series record and its episodes' resume entries move to the new ID; Continue Watching finds its episode again by season and episode number.
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

Schema 3 added `recent`, the Recently Viewed channels (newest `updatedAt` first, at most 15). Schema 4 added `teams` (My Teams) and `seenGames`, matchups already seen in the last 4 days (at most 20, per device), used to label replays. Schema 5 added `market`, the device's local TV market for My Teams. Schema 6 added `settings`, per-device on/off options (`showMyTeams`, `showNoGameTeams`, both on by default). New options join `settings` with a default when missing, without a schema change.

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
- **Network broadcasts:** short guide for about 15 national sports channels plus the preferred ABC affiliate.
- **Matching:** title and description, title matches ranked higher. Only the sports categories I select are scanned.
- **Sport mapping:** an editable rule table maps provider wording ("Volleyball:", "NCAAF", "College Football :") to one fixed sport list.
- **Duplicates:** one card per game; other channels showing it are listed as fallbacks.
- **Replays:** a matchup already seen in the last few days is labeled Replay.
- **No channel:** a game found with no playable channel still shows, with the network and a note.
- **Refresh:** on launch and about every 30 minutes while the home screen is showing.
- **Order:** live first, then by start time; team usage score breaks ties.
- No outside schedule service is needed for the 24-hour window.

**Built (step 1: teams and event channels, Oct 4, 2026)**

- **Showing the row** is a per-device setting: Settings → Show My Teams on Home (On by default). Off hides the row and skips the game searches and guide downloads behind it; teams stay saved.
- **Teams with no game:** Settings → Show teams with no game (On by default, `settings.showNoGameTeams`) adds a card at the end of the row for each team with nothing in the next 24 hours: team name, "No game in 24 hours", its sports. Selecting it opens the team's settings. These cards never move the row to the top. Games come first: live, then upcoming by start time.
- **Team names** should be written the way channel names write them ("Alabama", not "Alabama Crimson Tide"); nicknames go in aliases.
- **Teams** are managed in Settings → My Teams: name, sports (at least one), aliases ("Also called") and exclusions ("Not when it says"). Choosing sports is what keeps out other teams with the same name (minor-league hockey Eagles, for example).
- **Finding games** runs in SearchTask over the live index (`MyTeams.brs`): channels in event categories (`Sports | …`, `PPV …`; not `… Teams` or `… Replays`) whose name mentions a team as whole words, has an event time from 4 hours ago to 24 hours ahead, and whose sport is one of the team's. A listing whose sport can't be determined (e.g. "ESPNU: Auburn vs. Tennessee") makes a game only if it names the team in full; if only an alias matches (e.g. "Atlanta"), it can join a game found another way but never creates one. Network programs must name their sport. (Learned on the TV: an "Atlanta" alias otherwise pulled in a WNBA game and a local news show.) Team words are checked before anything else, so a full scan takes about 0.1–0.2 s.
- **Event times** use the `nameTimes` rules (also used to show channel names in local time), covering this provider's formats: ISO in UTC, `(10.04 01:00 PM ET)`, `@ 4 Oct 12:00 PM ET`, `@ Oct 04 01:00 PM ET`, `… London`, and no zone (read as US Eastern).
- **Sports, categories, separators, replay words, later languages and time windows** are rules in `data/guide-rules.json` (`myTeams`).
- **One card per game:** a team's listings starting within 90 minutes of each other are merged (one may include the pregame), keeping the earliest start. Main-language channels come first; selecting a game with several channels asks which.
- **Replays:** all channels named as replays, or a matchup already seen at least 6 hours earlier in the last 4 days.
- **Live** from the start time for 3½ hours. The row appears once a team is saved, below Favorites, or at the top while a game is live or starts within 30 minutes. It refreshes after each catalog refresh, after team changes and every 30 minutes on Home.
- **Before the start:** selecting a game more than 15 minutes early says event channels usually aren't on yet, with Play anyway. This provider answers HTTP 407 for an event channel that isn't carrying anything, before the game or, once seen, during one.

**Built (step 2: network broadcasts, Oct 4, 2026)**

- **Channels:** 16 national sports channels (ESPN, ESPN2, ESPNU, SEC, ACC, Big Ten, FS1, FS2, CBS Sports Network, NFL, MLB, NBA TV, NHL Network, TNT, TBS, truTV), listed by guide ID in `data/guide-rules.json` (`myTeams.networks`), plus the ABC, CBS, NBC and FOX stations of the device's market. Among copies of a feed, backup, low-bandwidth, West and overflow copies are skipped.
- **Local market:** Settings → Local stations picks the device's market from a list built from the provider's local-station channels (`GA | Atlanta | ABC 2 WSB` in `US | Local ABC`; patterns `localCategories` and `localName` in the rules). Saved per device (schema 5, `market`); empty until chosen, since a default would be wrong in other homes. Atlanta resolves to ABC WSB, CBS WANF and WUPA, FOX WAGA, NBC WXIA.
- **Guides:** each channel's next ~30 programs (`get_short_epg`) are saved to `cachefs:` through ApiTask, at most every 25 minutes, and searched in SearchTask: the title first; the description only when the title names a sport or a matchup (so talk shows that mention a team don't count), with the matchup taken from its first sentence.
- **Merging:** a network broadcast joins the event-channel card for the same game (same team, within 90 minutes). The network channel is listed first, since it's always on, and its guide title and end time are used.
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

### Off-device backup and sync

A small web service I host stores each device's saved document.

- GET and PUT of each device's JSON document.
- A remote backend inside `StateStore`; sync on launch and after changes.
- On a fresh install, offer "Restore from: Living room".
- Merge record by record using `updatedAt`, honoring deletions.
- The server can later compute results (full-guide search for My Teams) and push parsing-rule updates.

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
