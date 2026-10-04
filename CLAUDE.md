# Roku IPTV player

Personal Roku app (BrightScript + SceneGraph) for one Xtream Codes account.
Sideloaded on home devices; never published.

Full requirements: docs/requirements.md. Read it before making design decisions.

## Rules

- All saved state goes through StateStore; all HTTP goes through ApiTask.
  (Exception: the Video node fetches streams itself.)
- Provider parsing rules are data, not code.
- Screens talk only to MainScene (interface fields in, output fields out). They
  never call ApiTask or StateStore directly.
- Only the registry holds permanent state. `cachefs:` is for re-downloadable
  data only; never use `tmp:` for state.
- Never print URLs from `xtreamUrl()`, `streamUrl()` or anything else
  containing the password.

## Layout

- `manifest`, `source/main.brs`: entry point; only creates MainScene.
- `components/MainScene.*`: owns section screens (`screenHost`), the top bar,
  overlays (Setup, Favorites grid, series pages, player) and services; relays
  between screens and services and routes ApiTask responses by `id`. Split by
  area: `MainScene.brs` (core, focus, keys), `MainLogin.brs`, `MainHome.brs`,
  `MainCatalog.brs`, `MainPlayback.brs`. All share one `m`, so `init*()`
  in each file sets up its own state.
- `components/services/ApiTask.*`: long-running Task, up to 4 requests at once,
  so responses arrive in any order: match by `id` (and `context`). Optional
  `cacheFile`/`cacheFirst` caches catalog responses in `cachefs:/catalog/`.
  Full request/response shape is in `ApiTask.xml`.
- `components/services/EpgService.*`: now/next via `get_short_epg`, only for
  channels on screen; cached until the current program ends. Title cleanup
  rules come from `data/guide-rules.json`.
- `components/home/`: HomeScreen, FavoritesScreen, HomeCard and its HomeItem
  content. Row modules live in `HomeRows.brs` (included by MainScene); a new
  home row is a new module there.
- `components/catalog/`: CatalogScreen, one instance each for Live TV, Movies
  and Series (`kind`); categories plus a paged item list.
- `components/series/`: SeriesScreen (seasons, episodes with watched / in
  progress / new; * toggles watched).
- `components/player/`: PlayerScreen (Video node, live overlay, readable
  errors, progress reports every 30 s and on stop).
- `components/services/StateStore.*`: interface functions called via
  `callFunc`. Every mutation saves immediately and returns true only if it
  persisted.
- `components/services/RegistryBackend.brs`: `read()` / `write(doc)` returning
  `"ok" | "nospace" | "error"`. A future remote backend implements the same two.
- `components/screens/`: Setup and Settings.
- `components/common/`: TopBar, and `Utils.brs` shared helpers (`asString`,
  `toInt`, `isTrue`, `nowSeconds`, `formatClock`, `normalizeServer`). Each
  component must include Utils with its own `<script>` tag.
- `data/`: editable provider rules, packaged with the app.

## Conventions

- Script tags use full `pkg:/components/...` URIs.
- Xtream returns numbers as strings or numbers inconsistently: wrap with
  `toInt()` / `asString()` before comparing.
- Debug output uses a `[area]` prefix: `[main]`, `[api]`, `[state]`, `[epg]`.
- `end`, `next`, `stop` and `step` are reserved in BrightScript, even as AA
  keys with dot access: programs use `start`/`ends`, EPG entries
  `now`/`upcoming`.
- `(expr).Method()` isn't valid BrightScript; assign to a variable first.
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

Roku IP and developer password: `-RokuIp`/`-Password`, then
`$env:ROKU_IP`/`$env:ROKU_DEV_PASSWORD`, then `scripts/deploy.local.ps1`
(git-ignored; template in `deploy.local.example.ps1`). Never commit or print
the local file's contents.

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
- Not yet built: channel matching (re-matching favorites after renumbering),
  the visual pass, and the Later features in the requirements.
