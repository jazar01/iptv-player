# Code review: stability, reliability and user experience

Reviewed: commit `87b02b0` (all 60 source files, about 13,400 lines, plus the PowerShell scripts). Nothing was changed: these are findings and suggested fixes, in priority order.

**Overall:** the code is in good shape: careful about provider data (type checks, `toInt`/`asString` everywhere), saved state is robust (two registry copies, length check, read-back verify, roll back on a failed save), passwords never reach the console, and most failures already lead somewhere useful (copies, the audio repair, retries). The main gaps are **background threads that stop or stay busy without the app noticing**, a few **unguarded loops that can freeze the app**, **playback that can sit on "loading" with no way out**, and two small **date/replay bugs** in My Teams.

**Status (Oct 8, 2026):** #1–#7 are fixed. Testing #2 showed that on a sideloaded Roku an uncaught error in any thread opens the debugger and suspends every thread, so the whole app freezes and a thread's `state` never changes. The main fix is therefore `try`/`catch` around each message in the ApiTask, SearchTask and StreamRelay loops and in MainScene's reply handling; watching `state` and restarting a stopped thread stays as a backstop. #8–#22 are open.

## Priority 1: can lose data, freeze the app, or leave it doing nothing

| # | Problem | Where | Fix |
|---|---|---|---|
| 1 | **The backup script fails in Windows PowerShell 5.1, and writes nothing.** It uses `ConvertFrom-Json -AsHashtable` (PowerShell 7 only), the same problem `deploy.ps1` had. Your terminal is 5.1, so the safety net for a wiped Roku would silently not be there. | [backup-roku.ps1:82](../scripts/backup-roku.ps1:82) | Same fix as deploy.ps1: use .NET's JavaScriptSerializer on 5.1. |
| 2 | **Background threads that stop aren't noticed.** ApiTask, SearchTask and StreamRelay run in their own threads. If one hits a runtime error, it stops for the rest of the session. On a sideloaded app it drops into the debugger. Nothing in MainScene watches for this, so requests just vanish: no catalog, search, My Teams, copies or audio repair, and no message. | [MainScene.brs:43](../components/MainScene.brs:43), [MainSearch.brs:41](../components/MainSearch.brs:41), [MainPlayback.brs:25](../components/MainPlayback.brs:25) | Watch each task's `state`. On "stop", log it, restart it, and reset the counters in #3. |
| 3 | **"Waiting" counters never time out.** If a reply never comes (see #2), these flags stay set and the feature stops for the session: network guides (`m.guidePending`), live scores (`m.scoresPending`), Guide schedules (`m.guideInflight`), channel logos (`m.iconsPending`), EPG (`m.inflight` in EpgService), team logos (`m.logoPending`). | MainTeams, MainGuide, MainHome, EpgService | Record when each was set, and treat it as cleared after about 2 minutes. |
| 4 | **Pressing OK on a channel can do nothing.** A channel already marked "doesn't play" (Dolby on the Family Room TV, or FOX News's broken copy) asks SearchTask for a copy first, with no time limit. If SearchTask is busy (indexing the movie list takes about 4 s; parsing the 1 MB college-football scoreboard happens every 45 s during a game) or stopped, nothing plays and nothing is shown. | [MainPlayback.brs:399](../components/MainPlayback.brs:399) | Give it about 3 seconds, then play the channel itself (or show the error panel). |
| 5 | **Team records missing a field freeze the app.** Several loops assume every saved team has `sports`, `aliases` and `name`. One without them (a hand-edited or older `household.json`, a future import) stops the screen thread when Home builds the My Teams row, when Settings → My Teams opens, or when logos are looked up. | [HomeRows.brs:181](../components/home/HomeRows.brs:181), [TeamsScreen.brs:21](../components/teams/TeamsScreen.brs:21), [MainTeams.brs:360](../components/MainTeams.brs:360), [MainTeams.brs:412](../components/MainTeams.brs:412) | In `normalizeDocument()`, make sure every team has a `name` string and `sports`/`aliases`/`exclusions` lists. |
| 6 | **One malformed category entry stops SearchTask.** `liveCategoryName()` reads `c.category_id` without checking that `c` is an object. That's the same class as review item N03, which was fixed elsewhere, but this spot was missed. | [SearchTask.brs:260](../components/services/SearchTask.brs:260) | Add the same `type(c) = "roAssociativeArray"` check. |
| 7 | **A typo in `guide-rules.json` can stop a thread.** Regexes from the rules file are never checked. An invalid pattern gives `invalid`, and the first `.IsMatch`/`.Match` call stops the thread (SearchTask for My Teams; the screen thread for event times). The deploy script doesn't check the rules file at all. | [MyTeams.brs:79](../components/services/MyTeams.brs:79), [Utils.brs:189](../components/common/Utils.brs:189), deploy.ps1 | Skip and log invalid regexes. Have deploy.ps1 parse `data/*.json` before packaging. |

## Priority 2: playback and My Teams reliability

| # | Problem | Where | Fix |
|---|---|---|---|
| 8 | **A live channel that never starts loads forever.** The stall watchdog only arms after a stream has played once. A stream that sits at "loading" from the start, with no error from the Roku player, never times out. | [PlayerScreen.brs:224](../components/player/PlayerScreen.brs:224) | A startup limit of about 20–25 s, leading to the normal failure path (error panel and copies). This is also an open item from the October 7 review. |
| 9 | **Movies, episodes and the archive have no stall recovery.** The watchdog is live-only. A movie or a rewound archive that stalls mid-way stays on "loading" until you press Back. | [PlayerScreen.brs:221](../components/player/PlayerScreen.brs:221) | Movies and episodes: after about 20 s of loading, reload at the current position (up to 2–3 times), then show an error. Archive: reload the current stretch at the current point. |
| 10 | **Replays of later games in a series aren't labelled.** `recordSeenGames` keeps the **earliest** start for each matchup, and the replay rule (6–15 h later) compares against it. With Dodgers at Braves games 3 and 4, a 3 AM replay of game 4 is measured against game 3 (about 33 h earlier), so it shows as a new game. | [StateStore.brs:308](../components/services/StateStore.brs:308) | Keep the **latest** start per matchup (not later than now). |
| 11 | **Games around New Year disappear from My Teams.** Most event-time patterns have no year, so the current year is assumed. On Dec 31, a "Jan 1 … ET" game (bowl games, the CFP, NFL) reads as last January, falls outside the window, and is skipped. On Jan 1, a "Dec 31" listing lands a year ahead. | [Utils.brs:197](../components/common/Utils.brs:197) | Choose the year (last, this or next) that puts the date closest to now. |
| 12 | **Non-audio failures through the audio repair are treated as audio problems.** Any failure of a repaired stream (provider error, timeout, connection limit) marks it "doesn't play" for 4 hours and switches copies. If no copy plays, the message says the audio doesn't play on this TV, which is misleading. | [MainPlayback.brs:348](../components/MainPlayback.brs:348) | Only audio errors (code -5) take the audio path; other failures go to the normal error panel. |
| 13 | **The Family Room re-fails Dolby channels every session.** "Doesn't play here" is remembered in memory for 4 hours, so after each app restart FS1, ESPN and the rest fail once before switching. | [MainPlayback.brs:364](../components/MainPlayback.brs:364) | Keep a small per-TV list (registry, like usage scores) of streams that failed with Dolby or AAC errors, for about 7 days. Optionally, on a TV whose Settings say "Dolby: NO", prefer LBW copies for My Teams game channels up front. |

## Priority 3: user experience

| # | Suggestion | Where |
|---|---|---|
| 14 | **A retry on the error panel:** OK on the error panel does nothing when no copies are listed, and nothing for movie and episode errors. Make OK mean "Try again" (reload; for movies, from the last position). | [PlayerScreen.brs:810](../components/player/PlayerScreen.brs:810) |
| 15 | **Confirm before exiting:** Back on Home exits the app at once. An "Exit IPTV Player?" confirmation (or Back twice) prevents accidental exits. | [MainScene.brs:247](../components/MainScene.brs:247) |
| 16 | **Update score cards in place:** Home rebuilds every row from scratch on each refresh, and refreshes now happen every 45 s during a live game (scores). That can make the focus jump or flicker while you browse. Update the game cards in place when only scores change. | [HomeScreen.brs:26](../components/home/HomeScreen.brs:26) |
| 17 | **Retry for categories:** a category list that fails to load (Live TV, Movies, Series) is only retried on your next visit. Item lists have "Press OK to try again"; categories should too. | [MainCatalog.brs:193](../components/MainCatalog.brs:193) |
| 18 | **Clearer expiry message:** an expired account shows "The account is Expired."; add "Renew it with your provider". | [MainLogin.brs:111](../components/MainLogin.brs:111) |
| 19 | **Consistent Back on a dialog:** the Favorites pin/remove dialog doesn't observe `wasClosed` (the other dialogs do), so Back leaves stale state behind. Harmless, but inconsistent. | [MainHome.brs:143](../components/MainHome.brs:143) |

## Priority 4: scripts and safety

| # | Suggestion | Where |
|---|---|---|
| 20 | **Broaden the deploy check:** the Roku-compile check only catches `name(args).x` at the start of a line. It misses `m.obj.method(x).y.Delete(k)` and `(expr).Method()`, both of which the Roku also rejects. A failed install wipes that TV's saved data. | [deploy.ps1:98](../scripts/deploy.ps1:98) |
| 21 | **Warn about backups when deploying:** `deploy.ps1` could warn when a Roku has no backup in `backups\`, or one older than, say, 14 days. A failed install wipes the registry, and the restore only helps if a backup exists. | deploy.ps1 |
| 22 | **Say when the console is busy:** if another console connection is open, the Roku answers "Console connection is already in use", and `backup-roku.ps1` then waits 5 minutes before saying no backup arrived. Detect that text and say so straight away. | [backup-roku.ps1:48](../scripts/backup-roku.ps1:48) |

## Priority 5: efficiency and minor items

- **EpgService copies:** EpgService observes every ApiTask response just to check its id. Each observer gets its own copy of each response, including large catalog lists. Routing EPG responses through MainScene's single handler (or giving EPG its own response field) saves those copies. [EpgService.brs:13](../components/services/EpgService.brs:13)
- **Large categories:** big category lists cross from the request thread to the screen thread, and then into the catalog screen, as full copies. It's fine at today's sizes; keep in mind if a provider has categories with tens of thousands of items.
- **Account setup:** while Setup is "Connecting…", background requests (EPG, scores, guides) already use the new, unconfirmed account. If it fails, its data may have been cached. This is rare (account changes only).
- **Saving progress:** movie and episode progress is saved every 30 s, which means a registry write each time. Every 60 s, plus on stop, would halve the writes with no visible difference.
- **Log noise:** the Settings audio check prints a console line every time Settings info is rebuilt (each toggle and connection check).
- **Comments:** the comment at [MainPlayback.brs:492](../components/MainPlayback.brs:492) still describes the old Up/Down rule (first/last favorite) rather than the loop; and the rewind comment in PlayerScreen sits above `startOver` instead of `rewindLive`.
- **Low-memory Rokus:** SearchTask parses the whole movie list (about 32,000 items) at once. That's fine on Ultras, but heavy on low-memory models such as a Roku Express. Roku can signal low memory (`roDeviceInfo` low-memory events), so caches could be dropped then.

## Suggested order

1. **#1:** the backup script, a few minutes' work and most important for safety.
2. **#2–#7:** threads, timeouts and guards. Together they remove the "nothing happens" and "app freezes" cases.
3. **#8–#13:** playback recovery and the My Teams fixes. #10 and #11 are small; #11 matters before bowl season.
4. **#14–#22:** UX and scripts, as you like.
