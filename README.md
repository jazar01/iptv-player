# Dixie TV

A personal Roku app for watching one **Xtream Codes** IPTV account: live TV with
a guide, movies and series, with favorites and watch progress that follow you
from TV to TV. It's sideloaded onto Roku TVs in Developer Mode and isn't
published in the Roku Channel Store. It's named after Dixie, the family's German
Shepherd, whose face is the logo.

Written in BrightScript and SceneGraph, with PowerShell scripts for building and
installing. An optional home Raspberry Pi adds Python services for backups,
sharing between TVs, Dolby audio conversion and a live buffer.

## Features

**Home**
- Favorites with what's on now and next, plus channel logos.
- My Teams: upcoming and live games for teams you follow, found in event
  channels and the schedules of the national sports networks and your local
  ABC/CBS/NBC/FOX stations, with team logos and live scores.
- Continue Watching (movies and the next episode of a series), Watch List
  (movies to watch later), Favorite Series,
  and Recently Viewed channels.
- "See all" grid for every row; rows ordered by what you watch most.

**Live TV**
- Categories with your local stations and your country first, and your
  most-used categories at the top.
- Each channel row shows its logo and what's on now.
- Channel info panel (OK twice while watching): logo, schedule, details of the
  stream being played, other copies of the channel, and add or remove it as a
  favorite.

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
- With the Pi's live buffer: pause and rewind any live channel back to when
  you tuned in. Play/Pause pauses, Rewind goes back 30 s, Left/Right 10 s
  (hold to keep going), Fast-forward returns to live.
- Without it: pause, rewind and Start over on channels with a catch-up archive.
- Resume where you stopped, and watched tracking.
- Recovery from stalls and ended streams, readable error messages, and other
  copies or similar channels offered when a channel won't play.
- Dolby channels play on TVs that take stereo only, converted by the Pi.

**Settings**
- Per-TV options (My Teams, local market, row options, TV name, Dolby
  converter, live buffer, what this TV shares) and account details: server,
  connections in use, account end date.

**Backups and sharing (with the Pi)**
- Each TV backs up to the Pi, encrypted with a household key; a new or wiped
  TV offers to restore one.
- Favorites, My Teams, Favorite Series, the Watch List and watch progress are
  shared between TVs (each TV picks what it takes part in).
- An admin page on the Pi shows the backups and holds the household setup: a
  new TV starts from it, and a changed provider account can be sent to every
  TV at once.
- A nightly copy of the backups to OneDrive.

## Requirements

- A Roku in Developer Mode. To turn it on, press Home 3 times, Up 2 times, then
  Right, Left, Right, Left, Right on the remote. Note the IP address it shows
  and the developer password you set.
- An Xtream Codes account (server URL, username, password).
- Windows with **PowerShell 7** (`pwsh`; Windows PowerShell 5.1 also works) and
  **Node.js** (for the code check, run through `npx`). `curl.exe` ships with
  Windows 10 and later.
- Optional: a Raspberry Pi on the home network (a Pi 5 with 8 GB is used here,
  running Debian 13), reachable over SSH with a key.

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
   the check matters, and the deploy warns when a TV has no recent backup.
3. On the TV, open **Dixie TV** and enter the server URL, username, password
   and a name for the TV. Use `https://` if your provider supports it. With the
   Pi set up, a new TV takes the household setup from it instead.

## The Raspberry Pi

Two services, installed over SSH by one script:

```powershell
.\scripts\pi-deploy.ps1                      # both
.\scripts\pi-deploy.ps1 -Service converter   # Dolby converter and live buffer
.\scripts\pi-deploy.ps1 -Service backup      # backups, sharing, admin page
```

- **Dolby converter and live buffer** (`pi/dolby-converter/`, port 8790):
  converts Dolby audio to stereo for TVs that can't play it, and records the
  channel each TV is watching in memory (about 6 GB in all) so it can be
  paused and rewound. Nothing is written to the card. TVs find it from
  Settings → Dolby converter; Settings → Live buffer turns the buffer off on a
  TV.
- **Backup service** (`pi/backup-service/`, port 8792): keeps each TV's
  sealed backup and the shared copy, and serves the admin page at
  `http://<pi>:8792/admin`. Before installing it, set `$BackupKey` (64 hex
  characters) and `$AdminPassword` in `deploy.local.ps1`. Keep a copy of the
  key somewhere other than this PC: without it no backup can be opened.
- **Off-site copy:** `offsite.sh` copies the backups to OneDrive each night
  with rclone (one-time setup in `docs/requirements.md`, "Off-site copy").

## Backup without the Pi

To keep a copy of a TV's saved state on your computer:

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
| `components/` | SceneGraph components: `MainScene` and its feature files (`Main*.brs`), screens (`home`, `catalog`, `guide`, `movies`, `series`, `search`, `player`, `teams`, `screens`) and services (`ApiTask`, `SearchTask`, `EpgService`, `StateStore`, `StreamRelay`, `BackupTask`). |
| `data/guide-rules.json` | Provider conventions kept as data: guide title tags, time zones, event-time patterns, My Teams rules, search synonyms, category order. |
| `pi/` | The Raspberry Pi services: `dolby-converter` (with the live buffer) and `backup-service` (with the admin page and off-site copy). |
| `images/`, `art/` | App icons, splash and UI images, drawn by `scripts/make-icons.ps1` and `scripts/make-ui-assets.ps1`; the logo is `art/dixie.svg`. |
| `scripts/` | Deploy, Pi deploy, backup, screenshot and asset scripts. |
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
- Saved state lives in each Roku's registry; the Pi holds the backups and the
  shared copy.
