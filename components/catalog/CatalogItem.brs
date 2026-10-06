sub init()
    m.num = m.top.FindNode("num")
    m.name = m.top.FindNode("name")
    m.tag = m.top.FindNode("tag")
    m.logo = m.top.FindNode("logo")
    m.logo.ObserveField("loadStatus", "onLogoStatus")
    m.content = invalid
end sub

' The list recycles items; move the tag observer to the new content.
sub onItemContent()
    if m.content <> invalid then m.content.UnobserveFieldScoped("tag")
    m.content = m.top.itemContent
    if m.content = invalid then return
    m.content.ObserveFieldScoped("tag", "onTag")
    m.num.text = m.content.num
    name = localizeName(m.content.name)
    year = m.content.year
    if m.content.num <> ""
        ' Movies: the year is in the first column, not again in the name.
        name = nameWithoutYear(name, year)
    else if year > 0 and Instr(1, name, year.ToStr()) = 0
        ' Series: the year stays in the name; added if the provider left it out.
        name = name + " (" + year.ToStr() + ")"
    end if
    m.name.text = name
    ' Channels: a logo column, then the name. Others: the year column (or
    ' none), then the name.
    if m.content.showLogo
        m.name.translation = [112, 0]
        m.name.width = 778
    else if m.content.num = ""
        m.name.translation = [20, 0]
        m.name.width = 870
    else
        m.name.translation = [130, 0]
        m.name.width = 760
    end if
    logo = ""
    if m.content.showLogo then logo = m.content.logo
    if m.logo.uri <> logo then m.logo.uri = logo
    onLogoStatus()
    onTag()
    applyColors()
end sub

' Hidden until loaded, so a missing or broken logo leaves the column empty.
sub onLogoStatus()
    m.logo.visible = (m.logo.uri <> "" and m.logo.loadStatus = "ready")
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
