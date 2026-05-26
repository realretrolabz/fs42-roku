sub init()
    m.video = m.top.FindNode("streamVideo")
    m.tvOverlay = m.top.FindNode("tvOverlay")
    m.statusTask = m.top.FindNode("statusPollTask")
    m.channelDisplay = m.top.FindNode("channelDisplay")
    m.channelChangeLockTimer = m.top.FindNode("channelChangeLockTimer")
    m.bridgeUnavailableGroup = m.top.FindNode("bridgeUnavailableGroup")
    m.settingsGroup = m.top.FindNode("settingsGroup")
    m.settingsOctetFocus = m.top.FindNode("settingsOctetFocus")
    m.settingsOctetLabels = [
        m.top.FindNode("settingsOctet0")
        m.top.FindNode("settingsOctet1")
        m.top.FindNode("settingsOctet2")
        m.top.FindNode("settingsOctet3")
    ]
    m.settingsOctetFocusPositions = [
        [471, 474]
        [611, 474]
        [751, 474]
        [891, 474]
    ]
    channelDisplayFont = CreateObject("roSGNode", "Font")
    channelDisplayFont.uri = "pkg:/fonts/DSEG7Classic-Bold.ttf"
    channelDisplayFont.size = 52
    m.channelDisplay.font = channelDisplayFont
    m.standardOverlayUri = "pkg:/images/tv.png"
    m.scanlineOverlayUri = "pkg:/images/tv_scanlines.png"
    m.scanlineOverlayEnabled = false
    m.channelChangePending = false
    m.currentGeneration = -1
    m.selectedButtonIndex = 1

    m.buttons = [
        {
            name: "power"
            focusNode: m.top.FindNode("powerFocus")
            action: "toggleScanlines"
        }
        {
            name: "channelUp"
            focusNode: m.top.FindNode("channelUpFocus")
            path: "/player/channels/up"
            method: "GET"
        }
        {
            name: "channelDown"
            focusNode: m.top.FindNode("channelDownFocus")
            path: "/player/channels/down"
            method: "GET"
        }
    ]

    initializeNetworkConfig()
    m.statusTask.observeField("streamGeneration", "onStreamGenerationChanged")
    m.statusTask.observeField("channelNumber", "onChannelNumberChanged")
    m.statusTask.observeField("bridgeAvailable", "onBridgeAvailableChanged")
    m.channelChangeLockTimer.observeField("fire", "onChannelChangeLockTimeout")

    updateButtonFocus()
    m.top.setFocus(true)
    if m.hostConfigured
        m.statusTask.control = "RUN"
    end if

    if not m.hostConfigured
        showSettings()
    end if
end sub

sub playStream(generation as Integer)
    cacheBust = CreateObject("roDateTime").AsSeconds().ToStr()
    stream = CreateObject("roSGNode", "ContentNode")
    stream.url = m.streamBaseUrl + "?generation=" + generation.ToStr() + "&t=" + cacheBust
    stream.streamformat = "hls"

    m.video.control = "stop"
    m.video.content = stream
    m.video.control = "play"
end sub

sub onStreamGenerationChanged()
    generation = m.statusTask.streamGeneration
    if generation <> invalid and generation <> m.currentGeneration
        m.currentGeneration = generation
        clearChannelChangeLock()
        playStream(generation)
    end if
end sub

sub onChannelNumberChanged()
    m.channelDisplay.text = formatChannelDisplay(m.statusTask.channelNumber)
end sub

sub onBridgeAvailableChanged()
    if m.settingsGroup.visible or m.hostKeyboardDialog <> invalid
        m.bridgeUnavailableGroup.visible = false
    else
        m.bridgeUnavailableGroup.visible = not m.statusTask.bridgeAvailable
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false

    if m.settingsGroup.visible
        return handleSettingsKey(key)
    end if

    if key = "up"
        moveButtonFocus(-1)
        return true
    else if key = "down"
        moveButtonFocus(1)
        return true
    else if key = "OK" or key = "select"
        activateSelectedButton()
        return true
    else if key = "channelup"
        sendChannelCommand("/player/channels/up", "GET")
        return true
    else if key = "channeldown"
        sendChannelCommand("/player/channels/down", "GET")
        return true
    else if key = "options"
        showSettings()
        return true
    end if

    return false
end function

sub moveButtonFocus(delta as Integer)
    nextIndex = m.selectedButtonIndex + delta

    if nextIndex < 0
        nextIndex = m.buttons.Count() - 1
    else if nextIndex >= m.buttons.Count()
        nextIndex = 0
    end if

    m.selectedButtonIndex = nextIndex
    updateButtonFocus()
end sub

sub updateButtonFocus()
    for i = 0 to m.buttons.Count() - 1
        m.buttons[i].focusNode.visible = (i = m.selectedButtonIndex)
    end for
end sub

sub activateSelectedButton()
    button = m.buttons[m.selectedButtonIndex]

    if button.DoesExist("action") and button.action = "toggleScanlines"
        toggleScanlineOverlay()
        return
    end if

    if button.name = "channelUp" or button.name = "channelDown"
        sendChannelCommand(button.path, button.method)
        return
    end if

    sendRemoteCommand(button.path, button.method)
end sub

sub sendChannelCommand(path as String, method as String)
    if m.channelChangePending
        return
    end if

    m.channelChangePending = true
    m.channelChangeLockTimer.control = "stop"
    m.channelChangeLockTimer.control = "start"
    sendRemoteCommand(path, method)
end sub

sub clearChannelChangeLock()
    m.channelChangePending = false
    m.channelChangeLockTimer.control = "stop"
end sub

sub onChannelChangeLockTimeout()
    clearChannelChangeLock()
end sub

sub toggleScanlineOverlay()
    m.scanlineOverlayEnabled = not m.scanlineOverlayEnabled

    if m.scanlineOverlayEnabled
        m.tvOverlay.uri = m.scanlineOverlayUri
    else
        m.tvOverlay.uri = m.standardOverlayUri
    end if
end sub

sub sendRemoteCommand(path as String, method as String)
    if not m.hostConfigured then return

    task = CreateObject("roSGNode", "RemoteCommandTask")
    task.commandUrl = m.fs42BaseUrl + path
    task.commandMethod = method
    task.control = "RUN"
    m.lastCommandTask = task
end sub

sub initializeNetworkConfig()
    registry = CreateObject("roRegistrySection", "FieldStation42")
    m.hostConfigured = registry.Exists("host") and registry.Read("host") <> ""

    if m.hostConfigured
        m.fs42Host = registry.Read("host")
    else
        m.fs42Host = ""
    end if

    setNetworkUrls()
    loadSettingsOctetsFromHost(m.fs42Host)
end sub

sub setNetworkUrls()
    if not m.hostConfigured
        m.statusTask.control = "stop"
        m.streamBaseUrl = ""
        m.fs42BaseUrl = ""
        m.statusTask.statusUrl = ""
        return
    end if

    m.streamBaseUrl = "http://" + m.fs42Host + ":8088/stream.m3u8"
    m.fs42BaseUrl = "http://" + m.fs42Host + ":4242"
    m.statusTask.statusUrl = "http://" + m.fs42Host + ":8088/status"
end sub

sub loadSettingsOctetsFromHost(host as String)
    parts = host.Tokenize(".")
    m.settingsOctets = [0, 0, 0, 0]
    m.settingsHostBlank = parts.Count() <> 4

    if parts.Count() = 4
        for i = 0 to 3
            octet = Val(parts[i])
            if octet < 0 then octet = 0
            if octet > 255 then octet = 255
            m.settingsOctets[i] = octet
        end for
    end if

    m.selectedSettingsOctet = 0
    updateSettingsDisplay()
end sub

sub showSettings()
    openHostKeyboardDialog()
end sub

sub openHostKeyboardDialog()
    dialog = CreateObject("roSGNode", "StandardKeyboardDialog")
    dialog.title = "FIELDSTATION42 HOST"
    dialog.message = ["Enter the FieldStation42 host IP address."]
    dialog.buttons = ["Save", "Cancel"]
    dialog.keyboardDomain = "generic"
    dialog.text = m.fs42Host
    dialog.observeField("buttonSelected", "onHostKeyboardButtonSelected")

    m.hostKeyboardDialog = dialog
    m.top.dialog = dialog
    m.bridgeUnavailableGroup.visible = false
end sub

sub hideSettings()
    m.settingsGroup.visible = false
    onBridgeAvailableChanged()
end sub

sub closeHostKeyboardDialog()
    m.top.dialog = invalid
    m.hostKeyboardDialog = invalid
    onBridgeAvailableChanged()
end sub

sub onHostKeyboardButtonSelected()
    if m.hostKeyboardDialog = invalid then return

    buttonIndex = m.hostKeyboardDialog.buttonSelected
    if buttonIndex = 0
        host = sanitizeHostInput(m.hostKeyboardDialog.text)
        if isValidIpv4Address(host)
            saveHost(host)
            closeHostKeyboardDialog()
        else
            m.hostKeyboardDialog.message = ["Enter a valid IPv4 address, for example 192.168.1.42."]
        end if
    else
        closeHostKeyboardDialog()
    end if
end sub

function handleSettingsKey(key as String) as Boolean
    if key = "left"
        m.selectedSettingsOctet = m.selectedSettingsOctet - 1
        if m.selectedSettingsOctet < 0 then m.selectedSettingsOctet = 3
        updateSettingsDisplay()
        return true
    else if key = "right"
        m.selectedSettingsOctet = m.selectedSettingsOctet + 1
        if m.selectedSettingsOctet > 3 then m.selectedSettingsOctet = 0
        updateSettingsDisplay()
        return true
    else if key = "up"
        adjustSelectedOctet(1)
        return true
    else if key = "down"
        adjustSelectedOctet(-1)
        return true
    else if key = "OK" or key = "select"
        saveSettingsHost()
        return true
    else if key = "back"
        hideSettings()
        return true
    end if

    return true
end function

sub adjustSelectedOctet(delta as Integer)
    if m.settingsHostBlank
        m.settingsHostBlank = false
    end if

    value = m.settingsOctets[m.selectedSettingsOctet] + delta
    if value < 0 then value = 255
    if value > 255 then value = 0
    m.settingsOctets[m.selectedSettingsOctet] = value
    updateSettingsDisplay()
end sub

sub updateSettingsDisplay()
    for i = 0 to 3
        if m.settingsHostBlank
            m.settingsOctetLabels[i].text = "---"
        else
            m.settingsOctetLabels[i].text = formatOctet(m.settingsOctets[i])
        end if
        m.settingsOctetLabels[i].color = "0xFFFFFFFF"
    end for

    m.settingsOctetLabels[m.selectedSettingsOctet].color = "0xFF8A22FF"
    m.settingsOctetFocus.translation = m.settingsOctetFocusPositions[m.selectedSettingsOctet]
end sub

sub saveSettingsHost()
    if m.settingsHostBlank
        return
    end if

    host = m.settingsOctets[0].ToStr() + "." + m.settingsOctets[1].ToStr() + "." + m.settingsOctets[2].ToStr() + "." + m.settingsOctets[3].ToStr()
    saveHost(host)
    hideSettings()
end sub

sub saveHost(host as String)
    registry = CreateObject("roRegistrySection", "FieldStation42")
    registry.Write("host", host)
    registry.Flush()

    m.fs42Host = host
    m.hostConfigured = true
    m.currentGeneration = -1
    m.video.control = "stop"
    setNetworkUrls()
    m.statusTask.control = "RUN"
end sub

function sanitizeHostInput(host as Dynamic) as String
    if host = invalid then return ""

    return host.Trim()
end function

function isValidIpv4Address(host as String) as Boolean
    parts = host.Tokenize(".")
    if parts.Count() <> 4 then return false

    for i = 0 to 3
        part = parts[i]
        if Len(part) < 1 or Len(part) > 3 then return false
        if not isDigitsOnly(part) then return false

        value = Val(part)
        if value < 0 or value > 255 then return false
    end for

    return true
end function

function isDigitsOnly(value as String) as Boolean
    for i = 1 to Len(value)
        char = Mid(value, i, 1)
        if Instr(1, "0123456789", char) = 0 then return false
    end for

    return true
end function

function formatOctet(value as Integer) as String
    if value < 10
        return "00" + value.ToStr()
    else if value < 100
        return "0" + value.ToStr()
    end if

    return value.ToStr()
end function

function formatChannelDisplay(channel as Dynamic) as String
    if channel = invalid or channel < 0
        return "--"
    end if

    if channel < 10
        return "0" + channel.ToStr()
    end if

    return channel.ToStr()
end function
