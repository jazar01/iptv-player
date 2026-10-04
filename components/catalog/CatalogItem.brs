sub init()
    m.num = m.top.FindNode("num")
    m.name = m.top.FindNode("name")
    m.tag = m.top.FindNode("tag")
    m.content = invalid
end sub

' The list recycles items; move the tag observer to the new content.
sub onItemContent()
    if m.content <> invalid then m.content.UnobserveFieldScoped("tag")
    m.content = m.top.itemContent
    if m.content = invalid then return
    m.content.ObserveFieldScoped("tag", "onTag")
    m.num.text = m.content.num
    m.name.text = localizeName(m.content.name)
    ' Channels have no first-column value: start the name at the left.
    if m.content.num = ""
        m.name.translation = [20, 0]
        m.name.width = 870
    else
        m.name.translation = [130, 0]
        m.name.width = 760
    end if
    onTag()
    applyColors()
end sub

sub onTag()
    m.tag.text = m.content.tag
end sub

' Brighter text on the focused row's highlight.
sub applyColors()
    if m.top.listHasFocus and m.top.focusPercent > 0.5
        m.num.color = "0xC8D0D8FF"
        m.name.color = "0xFFFFFFFF"
        m.tag.color = "0xFFD36BFF"
    else
        m.num.color = "0x8C96A0FF"
        m.name.color = "0xE6EAEEFF"
        m.tag.color = "0xFFC94DFF"
    end if
end sub
