' Playback for one title at a time. A new request stops the previous stream first; events after closing are ignored,
' and closing stops the Video node and releases its content.

sub init()
    AirwaveApplyFonts([
        ["statusTitle", "font", true, 48],
        ["statusText", "font", false, 30],
        ["statusHint", "font", false, 26]
    ])
    m.video = m.top.findNode("video")
    m.status = m.top.findNode("status")
    m.statusTitle = m.top.findNode("statusTitle")
    m.statusText = m.top.findNode("statusText")
    m.statusHint = m.top.findNode("statusHint")
    m.active = false
    m.item = invalid
    m.lastSaved = -1
    m.failed = false
    m.video.notificationInterval = 1
    m.video.observeField("state", "onState")
    m.video.observeField("position", "onPosition")
end sub

sub onRequest()
    request = m.top.request
    if request = invalid or request.item = invalid then return
    start(request.item, request.resume)
end sub

sub start(item as object, resume as dynamic)
    stopVideo()
    m.item = item
    m.active = true
    m.failed = false
    m.lastSaved = -1
    m.status.visible = false
    stream = AirwaveStreamFor(item.url, item.kind)
    if stream.error <> ""
        showError(stream.error, false)
        return
    end if
    content = CreateObject("roSGNode", "ContentNode")
    content.url = stream.url
    content.title = item.title
    if stream.format <> "" then content.streamFormat = stream.format
    content.live = item.kind = "live"
    if item.kind = "movie" and resume <> invalid and resume > 0 then content.PlayStart = resume
    if LCase(Left(stream.url, 6)) = "https:"
        m.video.setCertificatesFile("common:/certs/ca-bundle.crt")
        m.video.initClientCertificates()
    end if
    m.video.content = content
    m.video.control = "play"
    m.video.setFocus(true)
end sub

sub onState()
    if not m.active then return
    state = m.video.state
    if state = "error"
        detail = m.video.errorMsg
        showError("Unable to play this stream. Check the link, connection, and supported video format." + chr(10) + detail, true)
    else if state = "finished"
        if m.item <> invalid and m.item.kind = "movie" then m.top.progress = {"id": m.item.id, "t": -1, "d": 0}
        closePlayer(false)
    end if
end sub

' Movies report progress every 15 seconds of playback, like the web player.
sub onPosition()
    if not m.active or m.item = invalid or m.item.kind <> "movie" then return
    position = m.video.position
    if m.lastSaved < 0 or Abs(position - m.lastSaved) >= 15
        reportProgress()
    end if
end sub

sub reportProgress()
    if m.item = invalid or m.item.kind <> "movie" or m.failed then return
    position = m.video.position
    duration = m.video.duration
    if position <= 0 then return
    m.lastSaved = position
    m.top.progress = {"id": m.item.id, "t": position, "d": duration}
end sub

sub showError(message as string, retry as boolean)
    m.failed = true
    m.canRetry = retry
    stopVideo()
    m.statusTitle.text = "Playback failed"
    m.statusText.text = message
    m.statusHint.text = "Press Back to return."
    if retry then m.statusHint.text = "Press OK to try again. Press Back to return."
    m.status.visible = true
    m.top.setFocus(true)
end sub

sub stopVideo()
    m.video.control = "stop"
    m.video.content = invalid
end sub

sub closePlayer(save as boolean)
    if not m.active then return
    if save then reportProgress()
    m.active = false
    stopVideo()
    m.status.visible = false
    m.item = invalid
    m.top.closed = true
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press or not m.active then return false
    if key = "back"
        closePlayer(true)
        return true
    end if
    if key = "OK" and m.failed and m.canRetry and m.item <> invalid
        start(m.item, invalid)
        return true
    end if
    if key = "options" and m.item <> invalid
        m.top.favoriteRequest = m.item.id
        return true
    end if
    return false
end function
