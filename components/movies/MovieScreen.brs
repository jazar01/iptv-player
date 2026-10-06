sub init()
    m.backdrop = m.top.FindNode("backdrop")
    m.poster = m.top.FindNode("poster")
    m.title = m.top.FindNode("title")
    m.meta = m.top.FindNode("meta")
    m.plot = m.top.FindNode("plot")
    m.people = m.top.FindNode("people")
    m.buttons = m.top.FindNode("buttons")
    m.actions = []
    m.backdrop.ObserveField("loadStatus", "onBackdropStatus")
    m.buttons.ObserveField("itemSelected", "onButton")
    m.top.ObserveField("focusedChild", "onFocusedChild")
    drawButtons()
end sub

sub onFocusedChild()
    if m.top.HasFocus() then m.buttons.SetFocus(true)
end sub

sub onBackdropStatus()
    m.backdrop.visible = (m.backdrop.loadStatus = "ready")
end sub

' Details win over what was known from the list; anything missing is left out.
sub draw()
    movie = m.top.movie
    if type(movie) <> "roAssociativeArray" then movie = {}
    d = m.top.details
    if type(d) <> "roAssociativeArray" then d = {}

    name = asString(d.name)
    if name = "" then name = asString(movie.name)
    m.title.text = name

    poster = asString(d.poster)
    if poster = "" then poster = asString(movie.poster)
    if m.poster.uri <> poster then m.poster.uri = poster
    backdrop = asString(d.backdrop)
    if m.backdrop.uri <> backdrop then m.backdrop.uri = backdrop
    onBackdropStatus()

    meta = []
    year = toInt(d.year)
    if year = 0 then year = toInt(movie.year)
    if year > 0 then meta.Push(year.ToStr())
    if asString(d.runtime) <> "" then meta.Push(asString(d.runtime))
    if asString(d.rating) <> "" then meta.Push("Rated " + asString(d.rating) + " / 10")
    if asString(d.genre) <> "" then meta.Push(asString(d.genre))
    m.meta.text = joinLine(meta, "     ")

    plot = asString(d.plot)
    if plot = "" then plot = asString(m.top.status)
    m.plot.text = plot

    people = []
    if asString(d.director) <> "" then people.Push("Director:  " + asString(d.director))
    if asString(d.cast) <> "" then people.Push("Cast:  " + asString(d.cast))
    m.people.text = joinLine(people, Chr(10))
end sub

function joinLine(parts as Object, separator as String) as String
    out = ""
    for each p in parts
        if out <> "" then out += separator
        out += p
    end for
    return out
end function

' Play, or (started) Resume from 1:12:05 and Start over.
sub drawButtons()
    position = m.top.position
    content = CreateObject("roSGNode", "ContentNode")
    if position >= 30
        m.actions = [position, 0]
        item = content.CreateChild("ContentNode")
        item.title = "Resume from " + formatDuration(position)
        item = content.CreateChild("ContentNode")
        item.title = "Start over"
    else
        m.actions = [0]
        item = content.CreateChild("ContentNode")
        item.title = "Play"
    end if
    m.buttons.content = content
end sub

sub onButton()
    i = m.buttons.itemSelected
    if i >= 0 and i < m.actions.Count() then m.top.play = { position: m.actions[i] }
end sub
