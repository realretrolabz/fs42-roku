' main.brs is the Roku app entry point.
' It creates a SceneGraph screen and shows our MainScene.

sub Main()
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)

    scene = screen.CreateScene("MainScene")
    screen.Show()

    ' Keep the app alive until the user exits or Roku closes the screen.
    while true
        msg = wait(0, port)

        if type(msg) = "roSGScreenEvent" then
            if msg.IsScreenClosed() then return
        end if
    end while
end sub
