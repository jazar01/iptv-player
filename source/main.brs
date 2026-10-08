' Entry point. Everything else lives in SceneGraph: MainScene owns the screens
' and the services (ApiTask, StateStore, EpgService).

sub Main()
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)

    scene = screen.CreateScene("MainScene")
    screen.Show()
    ' After Show: observed before it, the change never arrived and Exit did
    ' nothing (Oct 2026).
    scene.ObserveField("exitApp", port)

    while true
        msg = wait(0, port)
        if type(msg) = "roSGScreenEvent" and msg.IsScreenClosed() then return
        ' Back on Home, then Exit (MainScene asks first).
        if type(msg) = "roSGNodeEvent" and msg.GetField() = "exitApp" and msg.GetData() = true then return
    end while
end sub
