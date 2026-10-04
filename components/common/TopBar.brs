sub init()
    m.sections = ["home", "live", "movies", "series", "search", "settings"]
    names = ["Home", "Live TV", "Movies", "Series", "Search", "Settings"]
    m.TAB_WIDTH = 220

    tabs = m.top.FindNode("tabs")
    m.labels = []
    for i = 0 to m.sections.Count() - 1
        label = tabs.CreateChild("Label")
        label.translation = [i * m.TAB_WIDTH, 0]
        label.width = m.TAB_WIDTH - 20
        label.font = "font:MediumSystemFont"
        label.text = names[i]
        m.labels.Push(label)
    end for

    m.underline = m.top.FindNode("underline")
    m.clock = m.top.FindNode("clock")
    m.index = 0
    m.hadFocus = false

    m.top.ObserveField("focusedChild", "highlight")
    timer = m.top.FindNode("clockTimer")
    timer.ObserveField("fire", "updateClock")
    timer.control = "start"
    updateClock()
end sub

sub updateClock()
    m.clock.text = formatClock(nowSeconds())
end sub

function sectionIndex() as Integer
    for i = 0 to m.sections.Count() - 1
        if m.sections[i] = m.top.section then return i
    end for
    return 0
end function

' The current section is drawn white; the underline marks the focused tab
' and only shows while the bar has focus.
sub highlight()
    current = sectionIndex()
    focused = m.top.HasFocus()
    if focused and not m.hadFocus then m.index = current
    m.hadFocus = focused

    for i = 0 to m.labels.Count() - 1
        if i = current
            m.labels[i].color = "0xFFFFFFFF"
        else
            m.labels[i].color = "0x8C96A0FF"
        end if
    end for
    m.underline.visible = focused
    m.underline.translation = [96 + m.index * m.TAB_WIDTH, 104]
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "left" and m.index > 0
        m.index = m.index - 1
        highlight()
        return true
    else if key = "right" and m.index < m.sections.Count() - 1
        m.index = m.index + 1
        highlight()
        return true
    else if key = "OK"
        m.top.chosen = m.sections[m.index]
        return true
    end if
    return false
end function
