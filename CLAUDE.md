# Roku IPTV player

Personal Roku app (BrightScript + SceneGraph) for one Xtream Codes account.
Sideloaded on home devices; never published.

Full requirements: docs/requirements.md. Read it before making design decisions.

## Rules

- All saved state goes through StateStore; all HTTP goes through ApiTask.
- Provider parsing rules are data, not code.
- Screens talk only to MainScene (interface fields in, output fields out). They
  never call ApiTask or StateStore directly.
- Only the registry holds permanent state. `cachefs:` is for re-downloadable
  data only; never use `tmp:` for state.
- Never print URLs from `xtreamUrl()` or anything else containing the password.

## Layout

- `manifest`, `source/main.brs`: entry point; only creates MainScene.
- `components/MainScene.*`: owns screens (in `screenHost`) and services; routes
  ApiTask responses by `id`.
- `components/services/ApiTask.*`: long-running Task. Set `credentials`, then
  `request` `{ id, action, params? }` or `{ id, url }`; get one `response`
  `{ id, action, ok, code, error, data, ms }` per request, in order.
- `components/services/StateStore.*`: interface functions called via
  `callFunc`. Every mutation saves immediately and returns true only if it
  persisted.
- `components/services/RegistryBackend.brs`: `read()` / `write(doc)` returning
  `"ok" | "nospace" | "error"`. A future remote backend implements the same two.
- `components/screens/`: one component per screen.
- `components/common/Utils.brs`: shared helpers (`asString`, `toInt`, `isTrue`,
  `nowSeconds`, `normalizeServer`). Each component must include it with its own
  `<script>` tag.

## Conventions

- Script tags use full `pkg:/components/...` URIs.
- Xtream returns numbers as strings or numbers inconsistently: wrap with
  `toInt()` / `asString()` before comparing.
- Debug output uses a `[area]` prefix: `[main]`, `[api]`, `[state]`.
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
- Not yet built: home screen, browsing, playback, EpgService, series watched
  tracking (`markWatched`, `S1:1-10` ranges), channel matching.
