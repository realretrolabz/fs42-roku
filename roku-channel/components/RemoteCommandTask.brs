sub init()
    m.top.functionName = "sendCommand"
end sub

sub sendCommand()
    if m.top.commandUrl = invalid or m.top.commandUrl = ""
        m.top.error = "Missing command URL."
        return
    end if

    transfer = CreateObject("roUrlTransfer")
    transfer.SetUrl(m.top.commandUrl)

    method = UCase(m.top.commandMethod)
    if method = "POST"
        response = transfer.PostFromString("")
    else
        response = transfer.GetToString()
    end if

    if response = invalid
        m.top.error = "Command request failed."
    else
        m.top.response = response
    end if
end sub
