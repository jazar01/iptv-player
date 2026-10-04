sub init()
    m.num = m.top.FindNode("num")
    m.name = m.top.FindNode("name")
    m.state = m.top.FindNode("state")
    m.content = invalid
end sub

' The list recycles items; move the state observer to the new content.
sub onItemContent()
    if m.content <> invalid then m.content.UnobserveFieldScoped("stateText")
    m.content = m.top.itemContent
    if m.content = invalid then return
    m.content.ObserveFieldScoped("stateText", "onState")
    m.num.text = "E" + m.content.episode.ToStr()
    m.name.text = m.content.displayName
    if m.name.text = "" then m.name.text = m.content.name
    onState()
end sub

sub onState()
    if m.content = invalid then return
    m.state.text = m.content.stateText
    if m.top.listHasFocus and m.top.focusPercent > 0.5
        ' Brighter text on the focused row's highlight.
        m.num.color = "0xC8D0D8FF"
        m.name.color = "0xFFFFFFFF"
        m.state.color = "0x7CC0FFFF"
        if m.content.state = "progress" then m.state.color = "0xFFD36BFF"
        if m.content.state = "watched" then m.state.color = "0xA0AAB4FF"
        return
    end if
    m.num.color = "0x8C96A0FF"
    if m.content.state = "watched"
        m.state.color = "0x6E7882FF"
        m.name.color = "0x8C96A0FF"
    else if m.content.state = "progress"
        m.state.color = "0xFFC94DFF"
        m.name.color = "0xE6EAEEFF"
    else
        m.state.color = "0x4DA3FFFF"
        m.name.color = "0xE6EAEEFF"
    end if
end sub
