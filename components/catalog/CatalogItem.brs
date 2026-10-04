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
    m.name.text = m.content.name
    onTag()
end sub

sub onTag()
    m.tag.text = m.content.tag
end sub
