# Dixie TV (Roku IPTV player)

Personal Roku app (BrightScript + SceneGraph) for one Xtream Codes account.
Sideloaded on home devices; never published. Named Dixie TV (Oct 2026) after
the family's German Shepherd, Dixie, whose face is the logo (`art/dixie.svg`).

Full requirements: docs/requirements.md. Read it before making design decisions.

## Rules

- All saved state goes through StateStore; all HTTP goes through ApiTask.
  (Exceptions: the Video node fetches streams itself, Poster nodes load
  logos from their URL, and StreamRelay fetches live and archive playlists
  and segments for streams it repairs; the Dolby converter on the home
  Raspberry Pi fetches streams it converts; BackupTask talks to the backup
  service on the Pi.)
- Provider parsing rules are data, not code.
- Screens talk only to MainScene (interface fields in, output fields out). They
  never call ApiTask or StateStore directly.
- Only the registry holds permanent state. `cachefs:` is for re-downloadable
  data only; never use `tmp:` for state.
- Never print URLs from `xtreamUrl()`, `streamUrl()` or anything else
  containing the password. Text from the platform or provider (Video
  `errorMsg`/`errorStr`, transfer failure reasons) goes through `redact()`
  before printing; it may quote the URL.

## Layout

- `manifest`, `source/main.brs`: entry point; only creates MainScene.
- `components/MainScene.*`: owns section screens (`screenHost`), the top bar,
  overlays (Setup, "See all" grids, series pages, player) and services; relays
  between screens and services and routes ApiTask responses by `id`. Split by
  area: `MainScene.brs` (core, focus, keys), `MainLogin.brs`, `MainHome.brs`,
  `MainCatalog.brs`, `MainPlayback.brs`, `MainSearch.brs`, `MainTeams.brs`,
  `MainChannelInfo.brs`, `MainMovies.brs`, `MainGuide.brs`. All share one
  `m`, so `init*()` in each file sets up its own state.
- `components/services/SearchTask.*`: search index on its own thread. ApiTask
  downloads the full lists to `cachefs:/catalog/all_*.json` (`saveOnly`,
  `maxAgeSeconds` one day); SearchTask indexes them from disk, so big lists
  never cross the render thread. Also publishes which channels have a
  catch-up archive, runs channel matching after each (re)index, and
  serves Movies and Series categories from those lists (`categoryRequest`;
  the provider's list for Documentaries alone is 2.7 MB).
- `components/services/ChannelMatch.brs`: shared re-matching rules (guide
  ID, then name; series by name and year). `match_selftest=1` in the
  manifest runs its on-device self-test at launch; take it out again after.
- `components/services/ApiTask.*`: long-running Task, up to 4 requests at once
  (background ones marked `priority: "low"` use at most 2), so responses
  arrive in any order: match by `id` (and `context`). Screens show failures
  through `friendlyRequestError(res)` (Utils), never raw error text. Optional
  `cacheFile`/`cacheFirst` caches catalog responses in `cachefs:/catalog/`.
  Full request/response shape is in `ApiTask.xml`.
- `components/services/StreamRelay.*`: audio fix for live streams Roku
  rejects ("Unsupported AAC stream": HE-AAC whose ADTS headers say Main
  profile). A local HTTP server on 127.0.0.1 serves the playlist with its
  segments pointed back at itself and rewrites each audio header to LC.
  MainPlayback sends a stream through it after that error (`relayStreams`,
  7 days, kept per Roku by StateStore `setStreamMarks`); if it fails there
  too with an audio error, `badStreams` and other copies.
- `components/services/EpgService.*`: now/next via `get_short_epg`, only for
  channels on screen; cached until the current program ends. Title cleanup
  rules come from `data/guide-rules.json`.
- `components/home/`: HomeScreen, RowGridScreen ("See all" for any row), HomeCard and its HomeItem
  content. Row modules live in `HomeRows.brs` (included by MainScene); a new
  home row is a new module there.
- `components/catalog/`: CatalogScreen, one instance each for Live TV, Movies
  and Series (`kind`); categories plus a paged item list.
- `components/movies/`: MovieScreen (movie details page; filled by
  `MainMovies.brs` from `get_vod_info`).
- `components/series/`: SeriesScreen (seasons, episodes with watched / in
  progress / new; * toggles watched).
- `components/player/`: ChannelInfoPanel (channel info side panel; filled by
  `MainChannelInfo.brs`), PlayerScreen (Video node, live overlay, readable
  errors, progress reports every 30 s and on stop, live pause/rewind via the
  provider's timeshift `.m3u8` archive, kept `archiveLagSeconds` behind live).
- `components/guide/`: GuideScreen (channels-by-time grid; filled by
  `MainGuide.brs`: channels from SearchTask `guideRequest`, one or more sets
  ticked in its Channels chooser and saved per TV (`guideChoices`),
  schedules from `get_simple_data_table`).
- `components/search/`: SearchScreen (DynamicMiniKeyboard with voice entry,
  plus results list, which shows recent searches while the box is empty;
  matching with word forms, synonyms, close spellings and an all-but-one
  fallback is in SearchTask).
- `components/teams/`: TeamsScreen and TeamEditScreen (Settings → My Teams),
  MarketScreen (Settings → Local stations).
- `components/services/MyTeams.brs`: finds saved teams' games in event-channel
  names; runs in SearchTask (`gamesRequest` / `gamesResult`). MainTeams.brs
  asks for games, labels replays and wires the screens.
- `components/services/BackupTask.*` and `components/MainBackup.brs`: V2
  backups. Each TV's saved state goes to the backup service on the Pi
  (`pi/backup-service/`, found by a UDP broadcast, port 8793), sealed with
  the household key (`$BackupKey` in `deploy.local.ps1`, packaged as
  `data/backup.json`): AES-256-CBC plus HMAC. A TV with nothing saved offers
  to restore one. `restore_test=1` in the manifest starts empty and saves
  nothing, to try the restore; take it out after. Stage 2, sharing between
  TVs: a versioned shared copy on the Pi (`/shared`, 409 when another TV
  saved first), merged by StateStore `mergeShared` (newer record wins,
  tombstones, `resumeGone`); Settings -> Sharing between TVs
  (`components/screens/SharingScreen.*`) picks the kinds per TV. Stage 3:
  the admin page `http://<pi>:8792/admin` (`pi/backup-service/admin.*`,
  password `$AdminPassword` in `deploy.local.ps1`) shows the backups and edits
  the household setup; a new TV starts from it (`applyHousehold`). Nightly
  off-site copy to OneDrive (`offsite.sh`, rclone, `iptv-offsite.timer`;
  requirements "Off-site copy"). Keep `$BackupKey` somewhere off this PC.
  "Save and send to all TVs" on the admin page pushes the account: each TV
  tries a login first (`checkHouseholdAccount`, `onAccountTry`).
- `components/services/StateStore.*`: interface functions called via
  `callFunc`. Every mutation saves immediately and returns true only if it
  persisted.
- `components/services/RegistryBackend.brs`: `read()` / `write(doc)` returning
  `"ok" | "nospace" | "error"`. A future remote backend implements the same two.
- `components/screens/`: Setup and Settings.
- `components/common/`: TopBar, and `Utils.brs` shared helpers (`asString`,
  `toInt`, `isTrue`, `nowSeconds`, `formatClock`, `normalizeServer`). Each
  component must include Utils with its own `<script>` tag.
- `data/`: editable provider rules, packaged with the app: guide title tags
  and the time-zone rules used for timeshift URLs. `deploy.ps1` refuses a
  rules file that isn't valid JSON and warns about patterns that don't
  compile; the app skips those patterns (`rulesRegex()` in Utils).
- `pi/dolby-converter/`: the Dolby converter, a Python service (stdlib only)
  plus ffmpeg on the home Raspberry Pi (192.168.222.99:8790). TVs that take
  stereo only play Dolby channels through it (`MainPlayback.brs`: Settings ->
  Dolby converter, `convertStreams`); it serves its own live playlist so
  provider session changes don't stall the player (requirements: "Dolby audio
  converter on a home Raspberry Pi"). Settings finds it by a UDP broadcast
  (port 8791) that StreamRelay sends and the Pi answers; playback searches
  the same way when the converter fails (new address saved, or 10 minutes
  of copies when it's off). The same service runs the live buffer
  (`buffer.py`): with Settings -> Live buffer on, every live channel plays
  through the Pi, which keeps it in memory since tuning in; PlayerScreen's
  `bufferKey` handles pause, jumps (held keys repeat) and Fast-forward to
  live (requirements: "Live buffer on the home Pi"); it keeps a small
  picture per piece, shown while jumping (`/bt/`). `archive.py` (`/a/`) cuts
  the provider's archive into the same pieces, so HD archives fit the Roku. `probe.py` (`/p/`)
  reads the start of a movie or episode file for its details page
  (picture, audio tracks, subtitles; `requestMediaInfo` in MainMovies.brs).
  `vod.py` (`/v/<start>/`) plays a Dolby-only movie or episode with its audio
  converted, for TVs that take stereo (`checkVodAudio` in MainPlayback.brs).

## Conventions

- Script tags use full `pkg:/components/...` URIs.
- Xtream returns numbers as strings or numbers inconsistently: wrap with
  `toInt()` / `asString()` before comparing.
- Debug output uses a `[area]` prefix: `[main]`, `[api]`, `[state]`, `[epg]`.
- `end`, `next`, `stop` and `step` are reserved in BrightScript, even as AA
  keys with dot access: programs use `start`/`ends`, EPG entries
  `now`/`upcoming`.
- In an object literal, unquoted keys are lower-cased in `FormatJson` output
  (`{ savedAt: 1 }` gives `"savedat"`): quote keys that leave the app
  (`{ "savedAt": 1 }`), as the sealed backups do.
- Parse saved state with `ParseJson(text, "i")`. Without "i" the objects are
  case-sensitive, and a dot write (`doc.seenGames = x`) adds a second,
  lower-case key instead of replacing the parsed "seenGames" (Oct 2026).
- `roFileSystem` can't be created on the render thread (StateStore, screens);
  use `ReadAsciiFile()`, which returns "" for a missing file.
- `(expr).Method()` isn't valid BrightScript, and neither is a statement that
  starts with a call result (`f(x).y.Delete(k)`); assign to a variable first.
  BrighterScript misses it but the Roku won't compile it, and **a failed
  sideload removes the installed dev app together with its registry**: all
  saved state on that Roku is lost (happened Oct 6, 2026). `deploy.ps1` now
  checks for both before uploading (also after `then`/`else`), and warns
  when the Roku has no backup under its name on the Pi or in `backups`
  younger than 14 days. A method's result is
  fine: `m.top.FindNode("x").visible = true` compiles.
- A field's onChange doesn't fire when it's set to the value it already
  holds. Fields that hide initial XML text by being set to "" (status
  messages) need `alwaysNotify="true"`.
- `roUrlTransfer` can only be created on a Task thread; on the render thread
  it's `invalid` and the next call crashes. Use `urlEncode()` from Utils for
  escaping. The BrighterScript check can't catch this.
- Never set `ApiTask.request` before `ready`; MainScene uses `sendRequest()`,
  which queues until then.
- Moving focus from a child back to its parent screen: call
  `child.SetFocus(false)` before `parent.SetFocus(true)`. Otherwise the child
  (even hidden) can keep focus and swallow keys; the Guide's chooser list ate
  Up/Down this way. Don't change focus inside a list's `itemSelected`
  handler either; the list takes focus back when its key handling ends
  (defer it with a short Timer).
- While video plays, Roku itself takes `*` on channels with captions or
  extra audio tracks: the key never reaches the app, whatever has focus.
  Anything `*` does in the player needs another way in (favorites: OK
  twice, channel info). An overlay opened from a list's selection is
  checked 0.2 s later (`pushOverlay`): the list can take focus back.
- `main.brs` observes the scene's `exitApp` after `screen.Show()`;
  observed before it, the change never arrived and Exit did nothing.
- List item components are recycled: observe content fields with
  `ObserveFieldScoped` and unobserve the old content when `itemContent` changes.
- On a sideloaded Roku, an uncaught runtime error in any thread opens the
  debugger and suspends every thread: the whole app freezes (found Oct 7,
  2026). The service loops (ApiTask, SearchTask, StreamRelay) and
  `onApiResponse` catch errors per message with `try`/`catch` and carry on;
  put new message handling inside them. MainScene restarts a service thread
  that stops anyway (at most 3 times in 10 minutes). Anything waiting for a
  reply needs a time limit: a lost reply must not block it for the session.
- Saved document shape and record rules (updatedAt, tombstones, UTC) are in the
  requirements' Data model section. Bump `m.SCHEMA` and migrate in
  `normalizeDocument()` when the shape changes.
- Two copies are kept in the registry, so the document must stay under roughly
  7 KB.

## Commands

Deploy to the Roku (runs the code check, zips, sideloads, streams the console):

    .\scripts\deploy.ps1 -Console

Deploy to every Roku listed in `$LocalRokus` in `scripts/deploy.local.ps1`
(packages once, continues past failures, prints a summary):

    .\scripts\deploy.ps1 -All

An upload that can't connect ("curl: (7)", port 80 closed) while the Roku
answers on 8060: restart that Roku. Its developer installer stopped
answering after its address changed (the Family Room, Oct 9, 2026, once
DHCP reservations were set).

Roku IP and developer password: `-RokuIp`/`-Password`, then
`$env:ROKU_IP`/`$env:ROKU_DEV_PASSWORD`, then `scripts/deploy.local.ps1`
(git-ignored; template in `deploy.local.example.ps1`). Never commit or print
the local file's contents.

Back up a Roku's saved state to `backups\<name>.json` (git-ignored; holds the
provider password): run this, then on that TV open Settings and press * (a panel explains the backup;
it isn't in the menu) and then Play/Pause. `deploy.ps1` bundles the backups, so a Roku that starts with no saved
state (wiped, reinstalled) restores itself at launch:

    .\scripts\backup-roku.ps1 -Roku Basement

Install or update the services on the Pi: the Dolby converter, the backup
service and the nightly bootable self-copy to its USB stick (`-Service
converter|backup|selfclone` for one; SSH host `iptv-pi`, a key without a
passphrase; `$LocalPi` in `deploy.local.ps1` overrides):

    .\scripts\pi-deploy.ps1

If the Pi's microSD card dies, take it out and power on: it starts from the
USB stick's copy (`pi/selfclone/`, made every night at 4:30; last result in
`/var/lib/pi-selfclone/last.json` on the Pi).

Home-screen logo and splash: `.\scripts\make-icons.ps1` draws them into
`images/`: Dixie from `art/dixie.svg` (her face, drawn from her photo; edit
it to change the logo) and the name; the manifest points at them. The
top-bar mark (`make-ui-assets.ps1`) is Dixie alone. Both draw the SVG with
`scripts/SvgArt.ps1` (paths of M, L, C and Z, fills, strokes, circles).
`art/` isn't packaged.

UI images (focus highlights, rounded panels, background, player fade, top-bar
mark): `.\scripts\make-ui-assets.ps1` draws them into `images/ui/`. Rounded
shapes are Roku 9-patch `.9.png` files; `rounded.9.png` is white and tinted
per use with `blendColor`. Focused cards use `card-focus.9.png`, focused
list rows `row-focus.9.png` (light text on a dark highlight).

Screenshots come back all black while video plays, and for the rest of that
app session; restart the app (Home, then reopen) before screenshotting.

Screenshot of the Roku screen (app must be running):
`.\scripts\screenshot.ps1` saves to `out\screenshot-<time>.jpg`.

Code check only: `.\scripts\deploy.ps1 -PackageOnly` (check + zip, no upload).
The check is `npx brighterscript@0`; it validates syntax, function scope and
script paths, but not fields on built-in Roku nodes, so the first real install
is the final check.

## Environment

- Windows 11, PowerShell 7 (`pwsh`, preferred). The user's terminal may be
  Windows PowerShell 5.1, which also runs the scripts: keep them working
  in both (5.1 has no `ConvertFrom-Json -AsHashtable`, no `??` / `?:`, no
  `&&`; deploy.ps1's backup check uses .NET's JavaScriptSerializer there).
  In 5.1, any stderr line from a native program (ssh's notices) is fatal
  under `$ErrorActionPreference = 'Stop'`, and in a console switched to UTF-8
  (ssh does that) text piped to a program starts with a byte-order mark:
  set `$OutputEncoding` and `[Console]::InputEncoding` to UTF-8 without one
  before piping secrets (deploy.ps1 `Install-Roku`).
- Node.js (`C:\Program Files\nodejs`) and Git (`C:\Program Files\Git\cmd`) are
  installed but may be missing from PATH in older shells; prepend them if a
  command isn't found.
- Line endings are LF everywhere (`.gitattributes`).

## Status

Version 2.0 (manifest 2.0.0, Oct 8, 2026): all of version 1, plus V2 backups,
sharing between TVs, the household setup and admin page on the Pi, the
Dolby converter and the live buffer. The design and per-feature notes are in
docs/requirements.md. Saved state is schema 8 (later per-device options and
optional record marks joined without a schema change).

- Built and checked on the Basement Roku: setup, login (retried in the
  background when it fails at launch), Home (Favorites, My Teams, Continue
  Watching, Watch List, Favorite Series, Recently Viewed, "See all" grids,
  channel logos),
  Live TV (now playing, logos, Local stations, channel info, * menu), Movies
  (details page), Series (artwork, episode details, Favorite Series), Search
  (voice, word forms, synonyms, close spellings), playback (live, VOD,
  pause/rewind/Start over via the timeshift archive, stall and end-of-stream
  recovery, other copies / similar channels on errors), My Teams (event
  channels and network schedules, logos), Settings (per-device options,
  connections, account expiry, backup panel), manual backup and automatic
  restore.
- Dolby converter on the home Raspberry Pi (Oct 8, 2026): ESPN 1080p played
  through it on the Basement TV (with `converter_test`); works on all three
  TVs (Oct 9); not yet tried with the archive.
- Live buffer on the Pi (Oct 8, 2026): pause, jumps and back to live
  checked on the Basement TV; deployed to the Family Room and Deck (Oct 9),
  not yet tried there or with two TVs buffering at once. 2-second pieces,
  the Pi's live gap and the measured picture size checked on the Basement
  TV (Oct 9) and deployed to all three TVs.
- Known limits: HD timeshift archives exceed this Roku's video buffer; some
  channels sometimes send an AAC variant no Roku decodes (Tennis Channel 2;
  it played again on Oct 8, 2026, and the Pi converter, which re-encodes the
  audio, may fix it when it comes back: untried, since the app sends only
  Dolby failures there); this
  provider sends no episode descriptions for some series.
- Not yet tried on a Roku: a real provider renumbering, reaching 90% of an
  episode (a movie at 90% worked, Oct 9), the connection-limit message, the usage-ordering effect.
- Next: nothing planned. The Pi runs from its Max Endurance card (Oct 9,
  2026; the old card is a spare) with the Active Cooler fitted.
