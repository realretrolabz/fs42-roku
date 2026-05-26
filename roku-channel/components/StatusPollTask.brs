sub init()
    m.top.functionName = "pollStatus"
end sub

sub pollStatus()
    lastGeneration = invalid
    lastChannel = invalid

    while true
        status = fetchBridgeStatus()

        if status <> invalid
            m.top.bridgeAvailable = true
            m.top.statusMessage = ""

            if status.channel_number <> invalid and status.channel_number <> lastChannel
                lastChannel = status.channel_number
                m.top.channelNumber = status.channel_number
            end if

            if status.stream_generation <> invalid and isPlayableBridgeMode(status.mode)
                generation = status.stream_generation

                if lastGeneration = invalid or generation <> lastGeneration
                    lastGeneration = generation
                    m.top.streamGeneration = generation
                end if
            end if
        else
            m.top.bridgeAvailable = false
            m.top.statusMessage = "FieldStation42 bridge unavailable."
        end if

        sleepSeconds = m.top.pollSeconds
        if sleepSeconds = invalid or sleepSeconds < 1
            sleepSeconds = 2
        end if

        Sleep(sleepSeconds * 1000)
    end while
end sub

function fetchBridgeStatus() as Dynamic
    transfer = CreateObject("roUrlTransfer")
    transfer.SetUrl(m.top.statusUrl)

    response = transfer.GetToString()
    if response = invalid or response = ""
        return invalid
    end if

    return ParseJson(response)
end function

function isPlayableBridgeMode(mode as Dynamic) as Boolean
    return mode = "screen" or mode = "media" or mode = "filler"
end function
