' Entry point. Everything else lives in SceneGraph: MainScene owns the screens
' and the services (ApiTask, StateStore, EpgService).

sub Main()
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)

    scene = screen.CreateScene("MainScene")
    scene.ObserveField("exitApp", port)
    screen.Show()

    while true
        msg = wait(0, port)
        if type(msg) = "roSGScreenEvent" and msg.IsScreenClosed() then return
        ' Back on Home, then Exit (MainScene asks first).
        if type(msg) = "roSGNodeEvent" and msg.GetField() = "exitApp" and msg.GetData() = true then return
    end while
end sub
