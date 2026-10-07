# IPTV Player for Roku

A personal Roku app for watching one **Xtream Codes** IPTV account: live TV with
a guide, movies and series, with favorites and watch progress that stay put.
It's sideloaded onto Roku TVs in Developer Mode and isn't published in the Roku
Channel Store.

Written in BrightScript and SceneGraph, with PowerShell scripts for building,
installing and backing up.

## Features

**Home**
- Favorites with what's on now and next, plus channel logos.
- My Teams: upcoming and live games for teams you follow, found in event
  channels and the schedules of the national sports networks and your local
  ABC/CBS/NBC/FOX stations, with team logos.
- Continue Watching (movies and the next episode of a series), Watch List
  (movies to watch later), Favorite Series,
  and Recently Viewed channels.
- "See all" grid for every row; rows ordered by what you watch most.

**Live TV**
- Categories with your local stations and your country first, and your
  most-used categories at the top.
- Each channel row shows its logo and what's on now.
- Channel info panel: logo, schedule, details of the stream being played, and
  other copies of the channel to switch to.

**Guide**
- A channels-by-time grid (3-hour window, up to a day ahead) for Favorites,
  Local stations or any category.

**Movies and Series**
- Movie details page with backdrop, poster, plot, cast and rating; Resume or
  Start over.
- Series page with artwork, seasons and episodes (watched, in progress, new),
  air dates and descriptions.

**Search**
- Live channels, movies and series, with voice entry, word forms ("baking"
  finds "Bake"), synonyms, close spellings, and a fallback for misheard words.

**Playback**
- Pause, rewind and Start over on channels with a catch-up archive.
- Resume where you stopped, and watched tracking.
- Recovery from stalls and ended streams, readable error messages, and other
  copies or similar channels offered when a channel won't play.

**Settings**
- Per-TV options (My Teams, local market, row options) and account details:
  server, connections in use, account end date.
- Backup to your computer, with automatic restore if a TV loses its saved data.

## Requirements

- A Roku in Developer Mode. To turn it on, press Home 3 times, Up 2 times, then
  Right, Left, Right, Left, Right on the remote. Note the IP address it shows
  and the developer password you set.
- An Xtream Codes account (server URL, username, password).
- Windows with **PowerShell 7** (`pwsh`) and **Node.js** (for the code check,
  run through `npx`). `curl.exe` ships with Windows 10 and later.

## Getting started

1. Copy `scripts/deploy.local.example.ps1` to `scripts/deploy.local.ps1` and
   fill in your Roku's IP address and developer password. List every Roku you
   want to install to in `$LocalRokus`. This file is git-ignored; never commit
   it.
2. Build and install:

   ```powershell
   .\scripts\deploy.ps1            # the Roku in deploy.local.ps1
   .\scripts\deploy.ps1 -All       # every Roku in $LocalRokus
   .\scripts\deploy.ps1 -Console   # install, then stream the debug console
   ```

   Every deploy first runs a code check (BrighterScript, plus a check for code
   the Roku's compiler rejects) and uploads nothing if it fails. A failed
   install on the Roku removes the installed app **and its saved data**, so
   the check matters.
3. On the TV, open **IPTV Player** and enter the server URL, username, password
   and a name for the TV. Use `https://` if your provider supports it.

## Backup and restore

Each TV keeps its favorites, teams, progress and settings only on itself. To
keep a copy on your computer:

1. Run `.\scripts\backup-roku.ps1 -Roku "<name from $LocalRokus>"`.
2. On that TV, open **Settings** and press `*`, then **Play/Pause**.

The backup is saved in `backups\` (git-ignored; it contains your account
password). Every later deploy bundles the backups, and a TV that starts with no
saved data (reinstalled, or wiped by a failed install) restores its own backup
automatically. A `backups\household.json` copy, if present, sets up any TV
without one.

## Project layout

| Path | What's there |
| --- | --- |
| `manifest`, `source/` | App entry point. |
| `components/` | SceneGraph components: `MainScene` and its feature files (`Main*.brs`), screens (`home`, `catalog`, `guide`, `movies`, `series`, `search`, `player`, `teams`, `screens`) and services (`ApiTask`, `SearchTask`, `EpgService`, `StateStore`). |
| `data/guide-rules.json` | Provider conventions kept as data: guide title tags, time zones, event-time patterns, My Teams rules, search synonyms, category order. |
| `images/` | App icons, splash and UI images (drawn by `scripts/make-icons.ps1` and `scripts/make-ui-assets.ps1`). |
| `scripts/` | Deploy, backup, screenshot and asset scripts. |
| `docs/requirements.md` | The full design: features, data model, provider findings and decisions. |
| `CLAUDE.md` | Working notes for development: rules, conventions and Roku quirks. |

## Other scripts

```powershell
.\scripts\deploy.ps1 -PackageOnly   # code check and zip only, no upload
.\scripts\screenshot.ps1            # save a screenshot of the Roku screen
```

## Notes

- Personal project for one household's own account. It doesn't provide any
  content or streams, and it isn't affiliated with Roku or any IPTV provider.
- Saved state lives in each Roku's registry. Off-device backup and sync between
  TVs is planned for a version 2 (see `docs/requirements.md`).
