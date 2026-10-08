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
        ' No Pi, or nothing on it: the copy packaged at deploy, if any.
        tryBundleRestore()
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
        ' A new TV: the household copy packaged at deploy, if any, else Setup.
        tryBundleRestore()
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
