' Registry storage backend for StateStore.
'
' The document is kept in two alternating keys. Each save goes to the key NOT
' holding the newest copy, so a failed or partial write never touches the last
' good one. On load, the highest-numbered copy that parses wins.
'
'   value = "<seq>:<length>:<json>"     length catches truncated writes
'
' Interface (shared with any future backend):
'   read()      -> document AA, or invalid if nothing usable is saved
'   write(doc)  -> "ok" | "nospace" | "error"

function RegistryBackend(sectionName as String) as Object
    return {
        name: "registry"
        section: CreateObject("roRegistrySection", sectionName)
        registry: CreateObject("roRegistry")
        keys: ["docA", "docB"]
        seq: 0
        key: ""         ' key holding the newest good copy
        read: registryRead
        write: registryWrite
    }
end function

function registryRead() as Dynamic
    best = invalid
    for each key in m.keys
        copy = registryParseCopy(m.section, key)
        if copy = invalid
            if m.section.Exists(key) then print "[state] copy "; key; " is unreadable; ignoring it"
        else if best = invalid or copy.seq > best.seq
            best = copy
        end if
    end for
    if best = invalid then return invalid

    m.seq = best.seq
    m.key = best.key
    print "[state] loaded "; best.key; " (seq "; best.seq; ")"
    return best.doc
end function

function registryParseCopy(section as Object, key as String) as Dynamic
    if not section.Exists(key) then return invalid
    raw = section.Read(key)
    p1 = Instr(1, raw, ":")
    if p1 < 2 then return invalid
    p2 = Instr(p1 + 1, raw, ":")
    if p2 = 0 then return invalid

    seq = Val(Mid(raw, 1, p1 - 1), 10)
    length = Val(Mid(raw, p1 + 1, p2 - p1 - 1), 10)
    json = Mid(raw, p2 + 1)
    if json.Len() <> length then return invalid

    ' "i": case-insensitive objects, so dot writes update keys instead of
    ' adding lower-case duplicates. Where an older save holds both ("seenGames"
    ' and "seengames"), the lower-case one comes later and wins: it's the
    ' newer value. The next save writes one key.
    doc = ParseJson(json, "i")
    if type(doc) <> "roAssociativeArray" then return invalid
    return { seq: seq, key: key, doc: doc }
end function

function registryWrite(doc as Object) as String
    ' FormatJson escapes non-ASCII as \uXXXX, so Len() is the byte count.
    json = FormatJson(doc)
    if json = "" then return "error"

    seq = m.seq + 1
    value = seq.ToStr() + ":" + json.Len().ToStr() + ":" + json
    target = m.keys[0]
    if m.key = m.keys[0] then target = m.keys[1]

    ' Space check: the target key's old value is freed by the overwrite.
    ' Keep a margin for registry bookkeeping we can't see.
    freed = 0
    if m.section.Exists(target) then freed = target.Len() + m.section.Read(target).Len()
    needed = target.Len() + value.Len() - freed
    if needed > m.registry.GetSpaceAvailable() - 512 then return "nospace"

    if not m.section.Write(target, value) then return "error"
    if not m.section.Flush() then return "error"
    if m.section.Read(target) <> value then return "error"

    m.seq = seq
    m.key = target
    return "ok"
end function
