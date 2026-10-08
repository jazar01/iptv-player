' Backups on the home Raspberry Pi (BackupTask; requirements: "Off-device
' backup and sync (V2)"). This TV's saved state goes to the Pi within a
' minute of a change, and once soon after launch, so an emptied Pi fills up
' again. A TV that starts with nothing saved offers to restore a backup.
' Nothing here waits on the Pi: if it's missing, only the Settings line says so.

sub initBackup()
    m.backup = CreateObject("roSGNode", "BackupTask")
    m.backup.ObserveField("status", "onBackupStatus")
    m.backup.ObserveField("listResult", "onBackupList")
    m.backup.ObserveField("fetchResult", "onBackupFetched")
    ' Requests set before the thread listens are lost: held until ready.
    m.backupQueue = []
    m.backup.ObserveField("ready", "onBackupReady")
    m.backupStatus = {}
    m.backupDue = false
    m.backupTimer = CreateObject("roSGNode", "Timer")
    m.backupTimer.ObserveField("fire", "sendBackup")
    m.top.AppendChild(m.backupTimer)
    m.store.ObserveField("savedCount", "onStateSaved")
    m.restoreDialog = invalid
    m.restoreDevices = []
    m.backup.control = "RUN"
    scheduleBackup(20)
    initSharing()
end sub

sub backupSend(field as String, value as Object)
    if m.backup.ready
        m.backup.SetField(field, value)
    else
        m.backupQueue.Push({ field: field, value: value })
    end if
end sub

sub onBackupReady()
    if not m.backup.ready then return
    for each q in m.backupQueue
        m.backup.SetField(q.field, q.value)
    end for
    m.backupQueue = []
end sub

' A save: back up within a minute. Not restarted by later saves, so steady
' ones (movie progress every 30 s) can't hold it off.
sub onStateSaved()
    scheduleBackup(60)
end sub

sub scheduleBackup(seconds as Integer)
    if m.backupDue then return
    m.backupDue = true
    m.backupTimer.duration = seconds
    m.backupTimer.control = "start"
end sub

sub sendBackup()
    m.backupDue = false
    if not m.store.callFunc("isConfigured") then return
    device = m.store.callFunc("getDevice")
    backupSend("upload", { json: m.store.callFunc("exportDocument"), deviceId: device.deviceId, name: device.deviceName })
    ' The change goes to the other TVs too.
    requestSync("change")
end sub

sub onBackupStatus(event as Object)
    m.backupStatus = event.GetData()
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
end sub

function backupText() as String
    s = m.backupStatus
    if type(s) <> "roAssociativeArray" or s.enabled = invalid then return "starting ..."
    if not isTrue(s.enabled) then return "off (no household key in this build)"
    if toInt(s.savedAt) > 0
        text = "saved to the Raspberry Pi at " + formatClock(toInt(s.savedAt))
        if asString(s.error) <> "" then text = text + "; the last try failed: " + asString(s.error)
        return text
    end if
    if asString(s.error) <> "" then return "NOT saved: " + asString(s.error)
    return "waiting for the first save"
end function

' ---------------------------------------------------------------------------
' Restore: a TV with nothing saved (Setup showing) asks the Pi for backups.
' Choosing one makes this TV that one again: same device ID, name, account,
' favorites, teams, progress and settings.

sub offerRestore()
    backupSend("listRequest", { id: "restore" })
end sub

sub onBackupList(event as Object)
    result = event.GetData()
    if asString(result.id) <> "restore" then return
    if m.store.callFunc("isConfigured") or m.setup = invalid then return     ' set up meanwhile
    devices = []
    if isTrue(result.ok)
        for each d in result.devices
            if devices.Count() < 6 then devices.Push(d)
        end for
    end if
    if devices.Count() = 0
        ' No Pi, or nothing on it: the household setup, else the bundle.
        trySetUpAsNew()
        return
    end if
    print "[main] "; devices.Count(); " backup(s) on the Pi; offering a restore"
    buttons = []
    for each d in devices
        ' No save time known: no date, rather than 1969 (time 0).
        label = d.name
        if d.savedAt > 0 then label = label + "   (saved " + formatDate(d.savedAt) + ", " + formatClock(d.savedAt) + ")"
        buttons.Push(label)
    end for
    buttons.Push("Set up as a new TV")
    dlg = CreateObject("roSGNode", "StandardMessageDialog")
    dlg.title = "Restore this TV?"
    dlg.message = ["Backups were found on the Raspberry Pi. If this TV is one of these (after a reinstall, say), choose it: its account, favorites, teams, progress and settings come back."]
    dlg.buttons = buttons
    dlg.ObserveField("buttonSelected", "onRestoreChoice")
    m.restoreDevices = devices
    m.restoreDialog = dlg
    m.top.dialog = dlg
end sub

sub onRestoreChoice()
    dlg = m.restoreDialog
    if dlg = invalid then return
    m.restoreDialog = invalid
    choice = dlg.buttonSelected
    dlg.close = true
    if choice < 0 or choice >= m.restoreDevices.Count()
        ' A new TV: the household setup, else the bundle, else Setup.
        trySetUpAsNew()
        return
    end if
    chosen = m.restoreDevices[choice]
    print "[main] restoring the backup of '"; chosen.name; "'"
    if m.setup <> invalid then m.setup.status = "Restoring " + chosen.name + " ..."
    backupSend("fetchRequest", { id: "restore", deviceId: chosen.id })
end sub

sub onBackupFetched(event as Object)
    result = event.GetData()
    if asString(result.id) <> "restore" then return
    if not isTrue(result.ok) or not m.store.callFunc("importDocument", result.json)
        print "[main] restore failed: "; asString(result.error)
        if m.setup <> invalid then m.setup.status = "The backup couldn't be restored (" + asString(result.error) + "). Set this TV up below."
        return
    end if
    finishRestore("Restored this TV from its backup on the Raspberry Pi")
end sub

' A new TV (stage 3): the household setup saved from the admin page, if the
' Pi has one; it asks only for this TV's name. Without one, the bundle from
' deploy.ps1, else Setup as usual.
sub trySetUpAsNew()
    backupSend("syncRequest", { id: "household", op: "household" })
end sub

sub onHouseholdFetched(r as Object)
    if m.store.callFunc("isConfigured") or m.setup = invalid then return
    if not isTrue(r.ok) or asString(r.json) = ""
        tryBundleRestore()
        return
    end if
    m.householdJson = r.json
    dlg = CreateObject("roSGNode", "StandardKeyboardDialog")
    dlg.title = "Name this TV"
    dlg.message = ["Your household setup is on the Raspberry Pi: this TV gets its account, favorites, My Teams, local stations and settings. Give the TV a name, such as Kitchen."]
    dlg.buttons = ["OK", "Set up by hand"]
    setKeyboardVoice(dlg, "generic")
    dlg.ObserveField("buttonSelected", "onHouseholdName")
    m.householdDialog = dlg
    m.top.dialog = dlg
end sub

sub onHouseholdName()
    dlg = m.householdDialog
    if dlg = invalid then return
    m.householdDialog = invalid
    choice = dlg.buttonSelected
    typed = dlg.text.Trim()
    dlg.close = true
    if choice <> 0 then return         ' by hand: Setup as usual
    if typed = ""
        showToast("Give this TV a name first.")
        onHouseholdFetched({ ok: true, json: m.householdJson })
        return
    end if
    name = UCase(Left(typed, 1)) + Mid(typed, 2)        ' voice entry comes in lower case
    if m.store.callFunc("applyHousehold", m.householdJson, name)
        finishRestore("Set up from your household setup as " + name)
    else if m.setup <> invalid
        m.setup.status = "The household setup couldn't be used. Set this TV up below."
    end if
end sub

sub tryBundleRestore()
    if m.store.callFunc("restoreFromBundle") then finishRestore("Restored this TV from the backup on the computer")
end sub

' As a launch with saved state: Home from what's saved, login behind it.
sub finishRestore(message as String)
    m.serverTimezone = m.store.callFunc("getSettings").serverTimezone
    m.api.credentials = m.store.callFunc("getCredentials")
    closeSetup()
    showSection("home")
    login()
    showToast(message)
    scheduleBackup(20)
end sub

' ---------------------------------------------------------------------------
' Sharing between TVs (V2 stage 2; merging is StateStore's mergeShared). A
' sync fetches the shared copy from the Pi, merges it with this TV's state
' (redrawing if anything came in), and saves the shared copy back when this
' TV had something newer. If another TV saved in between, the Pi refuses
' that (conflict) and the sync starts over, up to 3 times. Syncs run 10 s
' after launch, with each backup (a minute after a change), every 10
' minutes, and on coming back to Home after 2 minutes or more.

sub initSharing()
    m.backup.ObserveField("syncResult", "onSyncResult")
    m.syncing = false
    m.syncAgain = false
    m.syncTries = 0
    m.lastSyncAt = 0
    m.syncNote = ""             ' Settings / Sharing page line
    m.accountTry = invalid      ' an account sent from the admin page, being tried (onAccountTry)
    m.sharingScreen = invalid
    m.syncTimer = CreateObject("roSGNode", "Timer")
    m.syncTimer.duration = 600
    m.syncTimer.repeat = true
    m.syncTimer.ObserveField("fire", "onSyncTimer")
    m.top.AppendChild(m.syncTimer)
    m.syncTimer.control = "start"
    m.syncSoon = CreateObject("roSGNode", "Timer")
    m.syncSoon.duration = 10
    m.syncSoon.ObserveField("fire", "onSyncTimer")
    m.top.AppendChild(m.syncSoon)
    m.syncSoon.control = "start"
end sub

sub onSyncTimer()
    requestSync("timer")
end sub

' Back on Home: catch up with the other TVs if it's been a while.
sub syncIfStale()
    if nowSeconds() - m.lastSyncAt >= 120 then requestSync("home")
end sub

sub requestSync(reason as String)
    if not m.store.callFunc("isConfigured") then return
    share = m.store.callFunc("getShareSettings")
    if not (share.favorites or share.teams or share.series or share.progress or share.account) then return
    if m.syncing
        m.syncAgain = true
        return
    end if
    m.syncing = true
    m.syncTries = 0
    backupSend("syncRequest", { id: "sync", op: "fetch" })
end sub

sub onSyncResult(event as Object)
    r = event.GetData()
    if asString(r.id) = "householdCheck"
        checkHouseholdAccount(r)
        return
    end if
    if asString(r.id) = "household"
        onHouseholdFetched(r)
        return
    end if
    if asString(r.id) <> "sync" then return
    if r.op = "fetch"
        if not isTrue(r.ok)
            finishSync(false, "couldn't reach the Raspberry Pi")
            return
        end if
        merged = m.store.callFunc("mergeShared", r.json)
        if isTrue(merged.changed) then onSharedChanges()
        if isTrue(merged.upload)
            backupSend("syncRequest", { id: "sync", op: "put", json: merged.json, baseVersion: r.version, name: m.store.callFunc("getDevice").deviceName })
            return
        end if
        finishSync(true, "")
    else if r.op = "put"
        if isTrue(r.conflict) and m.syncTries < 3
            ' Another TV saved first: merge with theirs and try again.
            m.syncTries = m.syncTries + 1
            print "[main] shared copy changed meanwhile; merging again"
            backupSend("syncRequest", { id: "sync", op: "fetch" })
            return
        end if
        if isTrue(r.ok) then finishSync(true, "") else finishSync(false, "the Raspberry Pi didn't take the changes")
    end if
end sub

sub finishSync(ok as Boolean, problem as String)
    m.syncing = false
    if ok
        m.lastSyncAt = nowSeconds()
        m.syncNote = "last synced at " + formatClock(m.lastSyncAt)
        ' An account sent from the admin page?
        backupSend("syncRequest", { id: "householdCheck", op: "household" })
    else
        print "[main] sharing: "; problem
        m.syncNote = "NOT synced: " + problem
    end if
    if m.sharingScreen <> invalid then m.sharingScreen.status = sharingStatus()
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
    if m.syncAgain
        m.syncAgain = false
        requestSync("again")
    end if
end sub

' Records from other TVs arrived: redraw what shows them.
sub onSharedChanges()
    print "[main] shared changes from other TVs applied"
    refreshHome()
    requestGames()
    catalog = m.sections.live
    if catalog <> invalid and m.section = "live" then onCatalogShown(catalog)
end sub

function sharingText() as String
    share = m.store.callFunc("getShareSettings")
    names = []
    if share.favorites then names.Push("favorites")
    if share.teams then names.Push("teams")
    if share.series then names.Push("series and Watch List")
    if share.progress then names.Push("watch progress")
    if share.account then names.Push("account changes")
    if names.Count() = 0 then return "off"
    text = joinStrings(names, ", ")
    if m.syncNote <> "" then text = text + "; " + m.syncNote
    return text
end function

function sharingStatus() as String
    if m.syncNote = "" then return "Not synced yet since the app started."
    return "Sharing: " + m.syncNote + "."
end function

' Settings -> Sharing between TVs.
sub openSharing()
    m.sharingScreen = CreateObject("roSGNode", "SharingScreen")
    m.sharingScreen.share = m.store.callFunc("getShareSettings")
    m.sharingScreen.status = sharingStatus()
    m.sharingScreen.ObserveField("toggled", "onShareToggled")
    pushOverlay(m.sharingScreen)
end sub

sub onShareToggled(event as Object)
    kind = event.GetData()
    share = m.store.callFunc("getShareSettings")
    turnOn = not share[kind]
    if not m.store.callFunc("setShare", kind, turnOn)
        showToast("Couldn't save the change. Storage may be full.")
        return
    end if
    if m.sharingScreen <> invalid then m.sharingScreen.share = m.store.callFunc("getShareSettings")
    ' Turned on: what the other TVs have comes in now.
    if turnOn then requestSync("setting")
    settings = m.sections.settings
    if settings <> invalid then settings.info = settingsInfo()
end sub

' ---------------------------------------------------------------------------
' Account changes sent from the admin page ("Save and send to all TVs": the
' household setup's accountAt). Checked after each sync. The TV logs in with
' the new account first and switches only if that works; if the provider
' refuses it, the TV keeps its own and doesn't try that one again (a newer
' send is tried). Unreachable: tried again at the next sync. A TV with
' Settings -> Sharing between TVs -> Account changes off keeps its own.

sub checkHouseholdAccount(r as Object)
    if not isTrue(r.ok) or asString(r.json) = "" or m.accountTry <> invalid or m.setup <> invalid then return
    if not m.store.callFunc("getShareSettings").account then return
    h = ParseJson(r.json, "i")
    if type(h) <> "roAssociativeArray" or type(h.credentials) <> "roAssociativeArray" then return
    at = toInt(h.accountAt)
    if at <= 0 or at <= m.store.callFunc("getSettings").householdAccountAt then return
    creds = { server: normalizeServer(asString(h.credentials.server)), username: asString(h.credentials.username), password: asString(h.credentials.password) }
    if creds.server = "" then return
    current = m.store.callFunc("getCredentials")
    if current <> invalid and current.server = creds.server and current.username = creds.username and current.password = creds.password
        m.store.callFunc("setSetting", "householdAccountAt", at)       ' already this one
        return
    end if
    print "[main] the household setup has a new account; trying it"
    m.accountTry = { creds: creds, at: at }
    m.api.credentials = creds
    sendRequest({ id: "accountTry", action: "" })
end sub

sub onAccountTry(res as Object)
    t = m.accountTry
    m.accountTry = invalid
    if t = invalid then return
    result = evaluateLogin(res)
    if not result.ok
        restoreSavedCredentials()
        ' Any 4xx is a refusal too: this provider answers a wrong password with
        ' HTTP 404 (Oct 8, 2026), which a login takes for a wrong server URL.
        ' Only no answer, time-outs and server errors are tried again.
        if result.rejected or (res.code >= 400 and res.code < 500)
            ' Wrong password or account: not tried again until it's sent anew.
            m.store.callFunc("setSetting", "householdAccountAt", t.at)
            print "[main] the household account was refused ("; redact(result.message); "); kept this TV's"
            showToast("The account sent from the admin page didn't log in, so this TV kept its own.")
        else
            print "[main] couldn't try the household account now ("; redact(result.message); "); trying again later"
        end if
        return
    end if
    values = { server: t.creds.server, username: t.creds.username, password: t.creds.password, deviceName: m.store.callFunc("getDevice").deviceName }
    if not saveSetup(values)
        restoreSavedCredentials()
        print "[main] the household account couldn't be saved here"
        return
    end if
    m.store.callFunc("setSetting", "householdAccountAt", t.at)
    print "[main] account updated from the household setup"
    showToast("Account updated from the household setup")
    ' As after any login: account details, then the lists from the new account.
    onLogin(res)
    refreshHome()
end sub
