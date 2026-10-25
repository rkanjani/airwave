' Tile tints follow .tone-0 .. .tone-5 in app/styles.css. The white ring marks focus, as on the web.

sub init()
    AirwaveApplyFonts([
        ["artName", "font", true, 28],
        ["badgeText", "font", true, 17],
        ["title", "font", false, 24],
        ["subtitle", "font", false, 20]
    ])
    m.tones = ["0x1B2230FF", "0x2A1F1AFF", "0x1D2620FF", "0x2A1C20FF", "0x262318FF", "0x1C2428FF"]
    m.ring = m.top.findNode("ring")
    m.art = m.top.findNode("art")
    m.artName = m.top.findNode("artName")
    m.logo = m.top.findNode("logo")
    m.badge = m.top.findNode("badge")
    m.badgeBack = m.top.findNode("badgeBack")
    m.badgeText = m.top.findNode("badgeText")
    m.title = m.top.findNode("title")
    m.subtitle = m.top.findNode("subtitle")
    m.track = m.top.findNode("track")
    m.bar = m.top.findNode("bar")
    m.logo.observeField("loadStatus", "onLogo")
end sub

' The art takes the space above the two caption lines.
sub onSize()
    w = m.top.width
    h = m.top.height - 76
    if w <= 0 or h <= 0 then return
    m.art.width = w
    m.art.height = h
    m.ring.width = w + 10
    m.ring.height = h + 10
    m.artName.width = w - 40
    m.artName.height = h - 20
    m.title.translation = [2, h + 14]
    m.title.width = w - 4
    m.subtitle.translation = [2, h + 46]
    m.subtitle.width = w - 4
    m.track.translation = [0, h - 4]
    m.track.width = w
    m.bar.translation = [0, h - 4]
    onContent()
end sub

sub onContent()
    c = m.top.itemContent
    if c = invalid then return
    tone = 0
    if c.hasField("tone") then tone = c.tone
    m.art.blendColor = m.tones[tone mod 6]
    m.artName.text = c.title
    m.title.text = c.title
    m.subtitle.text = c.shortDescriptionLine1
    quality = ""
    if c.hasField("quality") then quality = c.quality
    if quality <> ""
        m.badgeText.text = quality
        bw = 14 + Len(quality) * 13
        m.badgeBack.width = bw
        m.badgeText.width = bw
        m.badge.translation = [m.top.width - bw - 10, 10]
        m.badge.visible = true
    else
        m.badge.visible = false
    end if
    progress = 0
    if c.hasField("progress") then progress = c.progress
    m.track.visible = progress > 0
    m.bar.visible = progress > 0
    m.bar.width = m.top.width * progress
    ' Channel logos sit inside the tile; movie posters fill it.
    w = m.top.width
    h = m.top.height - 76
    if c.hasField("kind") and c.kind = "movie"
        m.logo.translation = [0, 0]
        m.logo.width = w
        m.logo.height = h
        m.logo.loadDisplayMode = "scaleToZoom"
    else
        m.logo.translation = [w * 0.15, h * 0.18]
        m.logo.width = w * 0.7
        m.logo.height = h * 0.64
        m.logo.loadDisplayMode = "scaleToFit"
    end if
    m.logo.visible = false
    m.artName.visible = true
    m.logo.uri = c.HDPosterUrl
end sub

' The name stays until artwork has loaded, so a failed logo still leaves a readable tile.
sub onLogo()
    ready = m.logo.loadStatus = "ready" and m.logo.uri <> ""
    m.logo.visible = ready
    m.artName.visible = not ready
end sub

sub onFocus()
    ' Only the list that holds focus shows a ring, so a page behind the rail stays quiet.
    listFocused = m.top.rowListHasFocus or m.top.gridHasFocus
    if listFocused
        m.ring.opacity = m.top.focusPercent
    else
        m.ring.opacity = 0
    end if
end sub
