# Roku IPTV player

Personal Roku app (BrightScript + SceneGraph) for one Xtream Codes account.
Sideloaded on home devices; never published.

Full requirements: docs/requirements.md. Read it before making design decisions.

## Rules

- All saved state goes through StateStore; all HTTP goes through ApiTask.
  (Exceptions: the Video node fetches streams itself, and Poster nodes load
  My Teams logos from their URL.)
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
  `MainChannelInfo.brs`. All share one
  `m`, so `init*()` in each file sets up its own state.
- `components/services/SearchTask.*`: search index on its own thread. ApiTask
  downloads the full lists to `cachefs:/catalog/all_*.json` (`saveOnly`,
  `maxAgeSeconds` one day); SearchTask indexes them from disk, so big lists
  never cross the render thread. Also publishes which channels have a
  catch-up archive, and runs channel matching after each (re)index.
- `components/services/ChannelMatch.brs`: shared re-matching rules (guide
  ID, then name; series by name and year). `match_selftest=1` in the
  manifest runs its on-device self-test at launch; take it out again after.
- `components/services/ApiTask.*`: long-running Task, up to 4 requests at once,
  so responses arrive in any order: match by `id` (and `context`). Optional
  `cacheFile`/`cacheFirst` caches catalog responses in `cachefs:/catalog/`.
  Full request/response shape is in `ApiTask.xml`.
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
- `components/search/`: SearchScreen (MiniKeyboard plus results list).
- `components/teams/`: TeamsScreen and TeamEditScreen (Settings → My Teams),
  MarketScreen (Settings → Local stations).
- `components/services/MyTeams.brs`: finds saved teams' games in event-channel
  names; runs in SearchTask (`gamesRequest` / `gamesResult`). MainTeams.brs
  asks for games, labels replays and wires the screens.
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
  and the time-zone rules used for timeshift URLs.

## Conventions

- Script tags use full `pkg:/components/...` URIs.
- Xtream returns numbers as strings or numbers inconsistently: wrap with
  `toInt()` / `asString()` before comparing.
- Debug output uses a `[area]` prefix: `[main]`, `[api]`, `[state]`, `[epg]`.
- `end`, `next`, `stop` and `step` are reserved in BrightScript, even as AA
  keys with dot access: programs use `start`/`ends`, EPG entries
  `now`/`upcoming`.
- `(expr).Method()` isn't valid BrightScript, and neither is a statement that
  starts with a call result (`f(x).y.Delete(k)`); assign to a variable first.
  BrighterScript misses it but the Roku won't compile it, and **a failed
  sideload removes the installed dev app together with its registry**: all
  saved state on that Roku is lost (happened Oct 6, 2026). `deploy.ps1` now
  checks for the call-result pattern before uploading.
- A field's onChange doesn't fire when it's set to the value it already
  holds. Fields that hide initial XML text by being set to "" (status
  messages) need `alwaysNotify="true"`.
- `roUrlTransfer` can only be created on a Task thread; on the render thread
  it's `invalid` and the next call crashes. Use `urlEncode()` from Utils for
  escaping. The BrighterScript check can't catch this.
- Never set `ApiTask.request` before `ready`; MainScene uses `sendRequest()`,
  which queues until then.
- List item components are recycled: observe content fields with
  `ObserveFieldScoped` and unobserve the old content when `itemContent` changes.
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

Roku IP and developer password: `-RokuIp`/`-Password`, then
`$env:ROKU_IP`/`$env:ROKU_DEV_PASSWORD`, then `scripts/deploy.local.ps1`
(git-ignored; template in `deploy.local.example.ps1`). Never commit or print
the local file's contents.

Home-screen logo and splash: `.\scripts\make-icons.ps1` draws them into
`images/` (colors and text at the top of the script); the manifest points at
them.

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

- Windows 11, PowerShell 7. Windows PowerShell 5.1 blocks scripts on this
  machine; use `pwsh`.
- Node.js (`C:\Program Files\nodejs`) and Git (`C:\Program Files\Git\cmd`) are
  installed but may be missing from PATH in older shells; prepend them if a
  command isn't found.
- Line endings are LF everywhere (`.gitattributes`).

## Status

- Milestone 1 done: setup, login, live categories printed to the console.
  Verified on a real Roku.
- Milestone 2 built: top bar, Home (Favorites with now/next, Continue
  Watching), Favorites grid, Live TV browser with * favorites, Settings.
  Verified on a Roku: Home, top bar, Live TV browsing, startup login, adding
  a favorite and it surviving a restart, guide data fetched. Visual pass
  waits for the mockup in `docs/`.
- Milestone 3 built: live / movie / episode playback, Movies and Series
  browsers, series pages, resume prompt, watched at 90%, Continue Watching
  with next episode, connection-limit message. Saved state is schema 2.
  Verified on a Roku: live playback with Up/Down and Back, readable error on
  a broken stream, movie resume and Continue Watching, episode playback and
  Continue Watching. Not yet tried: * to mark episodes watched/unwatched,
  reaching 90% (watched, next episode), the connection-limit message.
- Milestone 4 built: Search (live channels, movies, series) in the top bar,
  REWIND tag on archived channels, live pause/rewind/back-to-live through the
  provider's timeshift archive. Verified on a Roku: search, short pause,
  rewind and back to live on an SD channel, readable highlighted rows.
  Known limit: HD archives fail on this Roku (one-minute segments of ~45 MB
  exceed its ~31.6 MB video buffer); the app says so and suggests SD.
- Recently Viewed row (after Continue Watching): live channels watched for a
  minute, favorites left out, up to 15. Saved state is schema 3. Row drawn on
  a Roku; a channel being added after a minute not yet tried.
- Channel matching built: favorites, Recently Viewed and series are re-found
  after a provider renumbering. Self-test passed on a Roku against the real
  catalog; a real renumbering hasn't happened yet.
- Visual pass (own design, no mockup): gradient background, rounded cards and
  panels, one focus style (blue outline on cards, dark highlight with blue bar
  on list rows), top-bar logo mark, player fade, tidier series page (year
  once, episode titles without the repeated series name and S01E01 code, via
  episodeTitlePrefix in data/guide-rules.json). Checked on a Roku: Home, Live
  TV list, series page, player strip (by eye).
- My Teams step 1 built (requirements: Later features, My Teams, "Built"):
  Settings → My Teams, games from event-channel names (`MyTeams.brs` in
  SearchTask, rules `myTeams` and `nameTimes` in data/guide-rules.json),
  home row, replays, channel chooser, starts-later prompt. Saved state is
  schema 4. Checked on a Roku: teams saved, a game found and listed.
- My Teams step 2 built: network broadcasts from the full schedules of 16
  national channels (`myTeams.networks` by guide ID) plus the device's local
  ABC/CBS/NBC/FOX stations (Settings → Local stations, schema 5 `market`,
  stations found from provider channel names; the row can be switched off
  per device in Settings, schema 6 `settings.showMyTeams`; "no game" cards
  for teams without one, `settings.showNoGameTeams`),
  fetched to cachefs:/teams/ by ApiTask and searched in SearchTask; merged
  into the same game card with the network channel first. Verified on a Roku.
- Usage-based ordering built: decaying scores in their own registry section
  (StateStore recordUsage / getUsageScores), snapshot at launch
  (`m.usageScores`), applied in HomeRows (favorites, Continue Watching, My
  Teams tie-break); pin / unpin in the Favorites grid. Scores only build up
  with real viewing, so the ordering effect isn't verified yet.
- Local stations also in Search (first, tagged LOCAL) and Live TV (a
  "Local stations" first category answered by SearchTask localsRequest,
  LOCAL tags). Not yet checked on a Roku.
- Not yet built: off-device backup and sync.
