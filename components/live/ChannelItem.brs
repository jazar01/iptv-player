sub init()
    m.num = m.top.FindNode("num")
    m.name = m.top.FindNode("name")
    m.favorite = m.top.FindNode("favorite")
    m.content = invalid
end sub

' The list recycles items; move the isFavorite observer to the new content.
sub onItemContent()
    if m.content <> invalid then m.content.UnobserveFieldScoped("isFavorite")
    m.content = m.top.itemContent
    if m.content = invalid then return
    m.content.ObserveFieldScoped("isFavorite", "onFavorite")
    m.num.text = m.content.num
    m.name.text = m.content.name
    onFavorite()
end sub

sub onFavorite()
    m.favorite.visible = m.content.isFavorite
end sub
