' Navigation, library state, favorites and progress for the Roku channel.
' Storage lives in the "airwave" registry section: source (the playlist or library URL, unencrypted), favorites,
' progress, favoriteSeed and tidyNames. The library itself is fetched again at each launch.

sub init()
    AirwaveApplyFonts([
        ["brandName", "font", true, 32],
        ["libraryName", "font", false, 20],
        ["nav", "font", false, 28],
        ["nav", "focusedFont", true, 28],
        ["pageTitle", "font", true, 44],
        ["pageNote", "font", false, 24],
        ["clock", "font", false, 26],
        ["homeRows", "rowLabelFont", true, 28],
        ["emptyTitle", "font", true, 34],
        ["emptyText", "font", false, 26],
        ["emptyAction", "font", true, 26],
        ["emptyAction", "focusedFont", true, 26],
        ["groups", "font", false, 24],
        ["groups", "focusedFont", false, 24],
        ["browseEmpty", "font", false, 28],
        ["searchNote", "font", false, 24],
        ["playlistHeading", "font", true, 30],
        ["sourceText", "font", false, 26],
        ["storageNote", "font", false, 22],
        ["actions", "font", false, 26],
        ["actions", "focusedFont", true, 26],
        ["tidyText", "font", false, 22],
        ["toastText", "font", false, 24]
    ])
    m.top.backgroundURI = ""
    m.top.backgroundColor = "0x000000FF"
    m.registry = CreateObject("roRegistrySection", "airwave")
    m.pages = {"home": m.top.findNode("homePage"), "browse": m.top.findNode("browsePage"), "search": m.top.findNode("searchPage"), "settings": m.top.findNode("settingsPage")}
    m.nav = m.top.findNode("nav")
    m.homeRows = m.top.findNode("homeRows")
    m.emptyPanel = m.top.findNode("emptyPanel")
    m.emptyAction = m.top.findNode("emptyAction")
    m.groups = m.top.findNode("groups")
    m.grid = m.top.findNode("grid")
    m.browseEmpty = m.top.findNode("browseEmpty")
    m.keyboard = m.top.findNode("keyboard")
    m.results = m.top.findNode("results")
    m.searchNote = m.top.findNode("searchNote")
    m.actions = m.top.findNode("actions")
    m.player = m.top.findNode("player")
    m.toast = m.top.findNode("toast")
    m.pageTitle = m.top.findNode("pageTitle")
    m.pageNote = m.top.findNode("pageNote")
    m.clock = m.top.findNode("clock")

    m.navKeys = ["home", "search", "live", "movies", "favorites", "settings"]
    m.nav.content = listContent(["Home", "Search", "Live TV", "Movies", "Favorites", "Settings"])
    m.nav.observeField("itemSelected", "onNavSelected")
    m.homeRows.observeField("rowItemSelected", "onRowSelected")
    m.grid.observeField("itemSelected", "onGridSelected")
    m.results.observeField("itemSelected", "onResultSelected")
    m.groups.observeField("itemFocused", "onGroupFocused")
    m.emptyAction.observeField("itemSelected", "onEmptyAction")
    m.actions.observeField("itemSelected", "onAction")
    m.keyboard.observeField("text", "onSearchText")
    m.player.observeField("closed", "onPlayerClosed")
    m.player.observeField("progress", "onPlayerProgress")
    m.player.observeField("favoriteRequest", "onFavoriteRequest")
    m.top.findNode("toastTimer").observeField("fire", "onToastTimer")
    m.top.findNode("groupTimer").observeField("fire", "onGroupTimer")
    m.top.findNode("searchTimer").observeField("fire", "onSearchTimer")
    clockTimer = m.top.findNode("clockTimer")
    clockTimer.observeField("fire", "updateClock")
    clockTimer.control = "start"
    updateClock()
    applyPalette()

    m.items = []
    m.byId = caseSensitive()
    m.labels = caseSensitive()
    m.groupLabels = caseSensitive()
    m.libraryName = ""
    m.loadError = ""
    m.loading = false
    m.page = "home"
    m.browseKind = ""
    m.browseGroups = []
    m.returnFocus = invalid
    m.source = readKey("source", "")
    m.tidy = readKey("tidyNames", "true") <> "false"
    m.favorites = AirwaveBoundFavorites(readJson("favorites", []), 6000)
    m.progress = AirwaveBoundProgress(readJson("progress", {}), 5000)

    showPage("home")
    m.nav.setFocus(true)
    if m.source <> "" then loadLibrary()
end sub

' ---------------------------------------------------------------------------------------------------------------
' Registry

function readKey(key as string, fallback as string) as string
    if m.registry.Exists(key) then return m.registry.Read(key)
    return fallback
end function

function readJson(key as string, fallback as object) as object
    if not m.registry.Exists(key) then return fallback
    value = ParseJson(m.registry.Read(key))
    if value = invalid or type(value) <> type(fallback) then return fallback
    return value
end function

sub writeKey(key as string, value as string)
    m.registry.Write(key, value)
    m.registry.Flush()
end sub

function caseSensitive() as object
    aa = {}
    aa.SetModeCaseSensitive()
    return aa
end function

' ---------------------------------------------------------------------------------------------------------------
' Library

sub loadLibrary()
    m.loading = true
    m.loadError = ""
    m.task = CreateObject("roSGNode", "LoadTask")
    m.task.url = m.source
    m.task.observeField("result", "onLoaded")
    m.task.control = "RUN"
    render()
end sub

sub onLoaded()
    result = m.task.result
    m.task = invalid
    m.loading = false
    m.items = []
    m.byId = caseSensitive()
    m.labels = caseSensitive()
    if result = invalid or result.error <> ""
        m.loadError = "The playlist could not be loaded."
        if result <> invalid then m.loadError = result.error
        m.libraryName = ""
    else
        m.items = result.items
        m.libraryName = result.name
        for each x in m.items
            m.byId[x.id] = x
        end for
        seedFavorites()
    end if
    m.groupLabels = caseSensitive()
    if m.tidy then m.groupLabels = AirwaveTidyGroups(AirwaveGroups(m.items))
    render()
    ' A control that was focused while loading may now be hidden.
    if not m.nav.hasFocus() and not m.player.visible and m.top.dialog = invalid then focusPage()
end sub

' Library files can mark favorites; they are added once per library, as on the web.
sub seedFavorites()
    seed = m.libraryName + ":" + m.items.Count().ToStr()
    if readKey("favoriteSeed", "") = seed then return
    for each x in m.items
        if x.DoesExist("favorite")
            if x.favorite = true and not isFavorite(x.id) then m.favorites.Push(x.id)
        end if
    end for
    saveFavorites()
    writeKey("favoriteSeed", seed)
end sub

function itemsOfKind(kind as string) as object
    out = []
    for each x in m.items
        if x.kind = kind then out.Push(x)
    end for
    return out
end function

' Tidy names change display only; search, IDs and playback keep the playlist names.
function label(x as object) as object
    if not m.tidy then return {"name": x.name, "quality": ""}
    cached = m.labels.Lookup(x.id)
    if cached <> invalid then return cached
    t = AirwaveTidyName(x.name, x.group, x.kind)
    cached = {"name": t.name, "quality": t.quality}
    m.labels.AddReplace(x.id, cached)
    return cached
end function

function groupName(group as string) as string
    shown = m.groupLabels.Lookup(group)
    if shown = invalid then return group
    return shown
end function

' ---------------------------------------------------------------------------------------------------------------
' Content nodes

function listContent(labels as object) as object
    root = CreateObject("roSGNode", "ContentNode")
    for each text in labels
        child = root.createChild("ContentNode")
        child.title = text
    end for
    return root
end function

function tileNode(parent as object, x as object) as object
    node = parent.createChild("ContentNode")
    l = label(x)
    progress = 0.0
    entry = m.progress.Lookup(x.id)
    if x.kind = "movie" and AirwaveResumable(entry) then progress = entry.t / entry.d
    node.addFields({"itemId": x.id, "kind": x.kind, "tone": x.color, "quality": l.quality, "progress": progress})
    node.title = l.name
    node.HDPosterUrl = x.logo
    node.shortDescriptionLine1 = groupName(x.group)
    return node
end function

function gridContent(items as object, limit as integer) as object
    root = CreateObject("roSGNode", "ContentNode")
    count = 0
    for each x in items
        if count >= limit then exit for
        tileNode(root, x)
        count = count + 1
    end for
    return root
end function

' ---------------------------------------------------------------------------------------------------------------
' Pages

sub showPage(page as string)
    m.page = page
    for each key in m.pages
        m.pages[key].visible = false
    end for
    m.player.visible = false
    index = 0
    for i = 0 to m.navKeys.Count() - 1
        if m.navKeys[i] = page then index = i
    end for
    m.nav.jumpToItem = index
    if page = "live" or page = "movies" or page = "favorites"
        m.pages.browse.visible = true
    else
        m.pages[page].visible = true
    end if
    render()
end sub

sub render()
    name = m.libraryName
    if name = "" then name = "No library"
    if m.loading then name = "Loading…"
    m.top.findNode("libraryName").text = name
    if m.page = "home"
        renderHome()
    else if m.page = "live" or m.page = "movies" or m.page = "favorites"
        renderBrowse()
    else if m.page = "search"
        renderSearch()
    else if m.page = "settings"
        renderSettings()
    end if
end sub

sub setHeader(title as string, note as string)
    m.pageTitle.text = title
    m.pageNote.text = note
end sub

sub renderHome()
    setHeader("Home", "")
    m.homeRows.visible = false
    m.emptyPanel.visible = false
    if m.loading
        setHeader("Home", "Loading your library…")
        return
    end if
    if m.source = ""
        showEmpty("Add a playlist", "Enter the web address of an M3U playlist or an Airwave library file in Settings. Airwave loads it each time it starts.", "Add playlist")
        return
    end if
    if m.loadError <> ""
        showEmpty("The library could not be loaded", m.loadError, "Try again")
        return
    end if
    root = CreateObject("roSGNode", "ContentNode")
    sizes = []
    heights = []
    resume = resumeItems()
    favorites = []
    for each x in m.items
        if isFavorite(x.id) then favorites.Push(x)
    end for
    rows = [["Continue watching", resume, "movie"], ["Favorites", favorites, "live"], ["Live TV", itemsOfKind("live"), "live"], ["Movies", itemsOfKind("movie"), "movie"]]
    for each row in rows
        if row[1].Count() > 0
            node = gridContent(row[1], 50)
            node.title = row[0]
            root.appendChild(node)
            if row[2] = "movie"
                sizes.Push([240, 436])
                heights.Push(500)
            else
                sizes.Push([327, 259])
                heights.Push(320)
            end if
        end if
    end for
    m.homeRows.rowItemSize = sizes
    m.homeRows.rowHeights = heights
    m.homeRows.content = root
    m.homeRows.visible = true
    m.pageNote.text = "Arrows move · OK selects · * adds or removes a favorite · Back returns"
end sub

sub showEmpty(title as string, text as string, action as string)
    m.top.findNode("emptyTitle").text = title
    m.top.findNode("emptyText").text = text
    m.emptyAction.content = listContent([action])
    m.emptyPanel.visible = true
end sub

function resumeItems() as object
    entries = []
    for each id in m.progress
        x = m.byId.Lookup(id)
        if x <> invalid and AirwaveResumable(m.progress[id]) then entries.Push({"x": x, "u": m.progress[id].u})
    end for
    entries.SortBy("u", "r")
    out = []
    for each e in entries
        out.Push(e.x)
    end for
    return out
end function

sub renderBrowse()
    m.grid.visible = false
    m.browseEmpty.visible = false
    titles = {"live": "Live TV", "movies": "Movies", "favorites": "Favorites"}
    setHeader(titles[m.page], "")
    if m.page = "favorites"
        m.browseKind = ""
        m.groups.visible = false
        m.grid.translation = [378, 160]
        m.browseEmpty.translation = [378, 170]
        list = []
        for each x in m.items
            if isFavorite(x.id) then list.Push(x)
        end for
        m.pageNote.text = countText(list.Count(), "favorite", "favorites")
        if list.Count() = 0
            showBrowseEmpty("No favorites yet. Press * on a channel or movie, or while it plays, to add it here.")
            return
        end if
        fillGrid(list, false)
        return
    end if
    m.browseKind = "live"
    if m.page = "movies" then m.browseKind = "movie"
    all = itemsOfKind(m.browseKind)
    if m.browseKind = "live"
        m.pageNote.text = countText(all.Count(), "channel", "channels")
    else
        m.pageNote.text = countText(all.Count(), "movie", "movies")
    end if
    m.groups.visible = true
    m.grid.translation = [756, 160]
    m.browseEmpty.translation = [756, 170]
    if all.Count() = 0
        m.groups.visible = false
        if m.loading
            showBrowseEmpty("Loading your library…")
        else if m.browseKind = "live"
            showBrowseEmpty("No live channels. Add a playlist with live channels in Settings.")
        else
            showBrowseEmpty("No movies in this library. Add a playlist that includes movies.")
        end if
        return
    end if
    m.browseGroups = ["All"]
    m.browseGroups.Append(AirwaveGroups(all))
    shown = ["All"]
    for i = 1 to m.browseGroups.Count() - 1
        shown.Push(groupName(m.browseGroups[i]))
    end for
    m.groups.content = listContent(shown)
    m.groups.jumpToItem = 0
    fillGrid(all, m.browseKind = "movie")
end sub

sub showBrowseEmpty(text as string)
    m.browseEmpty.text = text
    m.browseEmpty.visible = true
end sub

function countText(n as integer, one as string, many as string) as string
    if n = 1 then return "1 " + one
    return n.ToStr() + " " + many
end function

' Grids hold at most 300 tiles; search reaches every entry.
sub fillGrid(items as object, movies as boolean)
    if movies
        m.grid.itemSize = [240, 436]
        m.grid.numColumns = 4
        m.grid.numRows = 2
    else
        m.grid.itemSize = [327, 259]
        m.grid.numColumns = 3
        m.grid.numRows = 3
    end if
    if m.page = "favorites" then m.grid.numColumns = 4
    m.grid.content = gridContent(items, 300)
    m.grid.visible = true
    if items.Count() > 300 then m.pageNote.text = m.pageNote.text + " · showing the first 300, search finds the rest"
end sub

sub onGroupFocused()
    timer = m.top.findNode("groupTimer")
    timer.control = "stop"
    timer.control = "start"
end sub

sub onGroupTimer()
    index = m.groups.itemFocused
    if index < 0 or index >= m.browseGroups.Count() or m.browseKind = "" then return
    fillGrid(AirwaveFilter(m.items, "", m.browseGroups[index], m.browseKind), m.browseKind = "movie")
end sub

sub renderSearch()
    setHeader("Search", "")
    runSearch()
end sub

sub onSearchText()
    timer = m.top.findNode("searchTimer")
    timer.control = "stop"
    timer.control = "start"
end sub

sub onSearchTimer()
    runSearch()
end sub

sub runSearch()
    query = m.keyboard.text
    if query = invalid then query = ""
    m.results.visible = false
    if m.items.Count() = 0
        m.searchNote.text = "Add a playlist in Settings to search it."
        return
    end if
    if query.Trim() = ""
        m.searchNote.text = "Search names and groups."
        return
    end if
    found = AirwaveFilter(m.items, query, "", "")
    if found.Count() = 0
        m.searchNote.text = "No matches for “" + query.Trim() + "”. Try another name, or clear the search to browse by group."
        return
    end if
    m.searchNote.text = countText(found.Count(), "result", "results")
    if found.Count() > 120 then m.searchNote.text = m.searchNote.text + " · showing the first 120"
    m.results.content = gridContent(found, 120)
    m.results.visible = true
end sub

sub renderSettings()
    setHeader("Settings", "")
    text = "No playlist added. Add the web address of an M3U playlist or an Airwave library file."
    if m.source <> ""
        host = AirwaveHost(m.source)
        if m.loading
            text = "Loading from " + host + "…"
        else if m.loadError <> ""
            text = "Could not load from " + host + ". " + m.loadError
        else
            text = m.libraryName + " from " + host + " · " + countText(m.items.Count(), "entry", "entries")
        end if
    end if
    m.top.findNode("sourceText").text = text
    labels = []
    m.actionKeys = []
    if m.source = ""
        labels.Push("Add playlist")
    else
        labels.Push("Replace playlist")
    end if
    m.actionKeys.Push("source")
    if m.source <> ""
        labels.Push("Reload playlist")
        m.actionKeys.Push("reload")
    end if
    if m.tidy
        labels.Push("Show original names")
    else
        labels.Push("Tidy names")
    end if
    m.actionKeys.Push("tidy")
    labels.Push("Reset Airwave")
    m.actionKeys.Push("reset")
    m.actions.content = listContent(labels)
end sub

' The host is shown instead of the full address, which may carry account details.
function AirwaveHost(url as string) as string
    rest = url
    p = Instr(1, rest, "://")
    if p > 0 then rest = Mid(rest, p + 3)
    for each mark in ["/", "?", "#"]
        p = Instr(1, rest, mark)
        if p > 0 then rest = Left(rest, p - 1)
    end for
    at = AirwaveLastIndex(rest, "@")
    if at > 0 then rest = Mid(rest, at + 1)
    return rest
end function

' ---------------------------------------------------------------------------------------------------------------
' Actions

sub onNavSelected()
    key = m.navKeys[m.nav.itemSelected]
    showPage(key)
    focusPage()
end sub

sub focusPage()
    if m.page = "home"
        if m.homeRows.visible
            m.homeRows.setFocus(true)
        else if m.emptyPanel.visible
            m.emptyAction.setFocus(true)
        else
            m.nav.setFocus(true)
        end if
    else if m.page = "search"
        m.keyboard.setFocus(true)
    else if m.page = "settings"
        m.actions.setFocus(true)
    else if m.groups.visible
        m.groups.setFocus(true)
    else if m.grid.visible
        m.grid.setFocus(true)
    else
        m.nav.setFocus(true)
    end if
end sub

sub onEmptyAction()
    if m.source <> "" and m.loadError <> ""
        loadLibrary()
        m.nav.setFocus(true)
    else
        askForSource()
    end if
end sub

sub onAction()
    key = m.actionKeys[m.actions.itemSelected]
    if key = "source"
        askForSource()
    else if key = "reload"
        loadLibrary()
    else if key = "tidy"
        m.tidy = not m.tidy
        if m.tidy
            writeKey("tidyNames", "true")
            m.groupLabels = AirwaveTidyGroups(AirwaveGroups(m.items))
        else
            writeKey("tidyNames", "false")
            m.groupLabels = caseSensitive()
        end if
        m.labels = caseSensitive()
        renderSettings()
        if m.tidy then toast("Names are tidied") else toast("Showing names as written in the playlist")
    else if key = "reset"
        confirmReset()
    end if
end sub

sub askForSource()
    dialog = CreateObject("roSGNode", "StandardKeyboardDialog")
    dialog.title = "Add a playlist"
    dialog.message = ["Enter the web address of an M3U playlist or an Airwave library file. It replaces the current library.", "The address is saved on this Roku without encryption."]
    dialog.buttons = ["Save", "Cancel"]
    dialog.text = m.source
    dialog.observeField("buttonSelected", "onSourceDialog")
    dialog.observeField("wasClosed", "onDialogClosed")
    m.top.dialog = dialog
end sub

sub onSourceDialog()
    dialog = m.top.dialog
    if dialog = invalid then return
    choice = dialog.buttonSelected
    text = dialog.text
    dialog.close = true
    if choice <> 0 then return
    url = AirwaveHttpUrl(text.Trim())
    if url = ""
        toast("Enter an HTTP or HTTPS address.")
        return
    end if
    m.source = url
    writeKey("source", url)
    loadLibrary()
    showPage("home")
    m.nav.setFocus(true)
end sub

sub onDialogClosed()
    focusPage()
end sub

sub confirmReset()
    dialog = CreateObject("roSGNode", "StandardMessageDialog")
    dialog.title = "Reset Airwave?"
    dialog.message = ["This clears the playlist address, favorites, viewing progress and preferences saved on this Roku."]
    dialog.buttons = ["Reset Airwave", "Cancel"]
    dialog.observeField("buttonSelected", "onResetDialog")
    dialog.observeField("wasClosed", "onDialogClosed")
    m.top.dialog = dialog
end sub

sub onResetDialog()
    dialog = m.top.dialog
    if dialog = invalid then return
    choice = dialog.buttonSelected
    dialog.close = true
    if choice <> 0 then return
    for each key in m.registry.GetKeyList()
        m.registry.Delete(key)
    end for
    m.registry.Flush()
    m.source = ""
    m.items = []
    m.byId = caseSensitive()
    m.labels = caseSensitive()
    m.groupLabels = caseSensitive()
    m.favorites = []
    m.progress = caseSensitive()
    m.tidy = true
    m.libraryName = ""
    m.loadError = ""
    toast("Airwave was reset")
    showPage("home")
    m.nav.setFocus(true)
end sub

' ---------------------------------------------------------------------------------------------------------------
' Playback

sub onRowSelected()
    pick = m.homeRows.rowItemSelected
    row = m.homeRows.content.getChild(pick[0])
    if row = invalid then return
    play(row.getChild(pick[1]), m.homeRows)
end sub

sub onGridSelected()
    play(m.grid.content.getChild(m.grid.itemSelected), m.grid)
end sub

sub onResultSelected()
    play(m.results.content.getChild(m.results.itemSelected), m.results)
end sub

sub play(node as dynamic, from as object)
    if node = invalid then return
    x = m.byId.Lookup(node.itemId)
    if x = invalid then return
    m.returnFocus = from
    resume = 0
    entry = m.progress.Lookup(x.id)
    if x.kind = "movie" and AirwaveResumable(entry) then resume = entry.t
    m.player.visible = true
    m.player.request = {"item": {"id": x.id, "url": x.url, "kind": x.kind, "title": label(x).name}, "resume": resume}
end sub

' Back from the player returns to the tile that started playback. Home is rebuilt for Continue watching and
' favorites; grids keep their group and only refresh the played tile's progress.
sub onPlayerClosed()
    m.player.visible = false
    if m.page = "home" and m.returnFocus <> invalid and m.returnFocus.isSameNode(m.homeRows)
        restoreHome()
        return
    end if
    if m.page = "favorites"
        refreshKeepingFocus()
        return
    end if
    if m.returnFocus <> invalid and m.returnFocus.visible
        refreshTileProgress(m.returnFocus)
        m.returnFocus.setFocus(true)
    else
        focusPage()
    end if
end sub

sub refreshTileProgress(list as object)
    if list.content = invalid then return
    node = list.content.getChild(list.itemFocused)
    if node = invalid then return
    entry = m.progress.Lookup(node.itemId)
    progress = 0.0
    if node.kind = "movie" and AirwaveResumable(entry) then progress = entry.t / entry.d
    node.progress = progress
end sub

' Rebuilds Home and puts focus back on the same title, or the nearest tile in the same row.
sub restoreHome()
    focus = m.homeRows.rowItemFocused
    rowTitle = ""
    itemId = ""
    if m.homeRows.content <> invalid and focus <> invalid and focus.Count() = 2
        row = m.homeRows.content.getChild(focus[0])
        if row <> invalid
            rowTitle = row.title
            tile = row.getChild(focus[1])
            if tile <> invalid then itemId = tile.itemId
        end if
    end if
    renderHome()
    if not m.homeRows.visible
        focusPage()
        return
    end if
    target = [0, 0]
    for r = 0 to m.homeRows.content.getChildCount() - 1
        row = m.homeRows.content.getChild(r)
        if row.title = rowTitle
            target = [r, 0]
            count = row.getChildCount()
            if focus[1] < count then target = [r, focus[1]] else target = [r, count - 1]
            for c = 0 to count - 1
                if row.getChild(c).itemId = itemId then target = [r, c]
            end for
        end if
    end for
    m.homeRows.jumpToRowItem = target
    m.homeRows.setFocus(true)
end sub

sub onPlayerProgress()
    p = m.player.progress
    if p = invalid or p.id = invalid then return
    if p.t < 0
        m.progress.Delete(p.id)
    else
        m.progress.AddReplace(p.id, {"t": Int(p.t), "d": Int(p.d), "u": CreateObject("roDateTime").AsSeconds()})
    end if
    m.progress = AirwaveBoundProgress(m.progress, 5000)
    writeKey("progress", FormatJson(m.progress))
end sub

sub onFavoriteRequest()
    toggleFavorite(m.player.favoriteRequest)
end sub

function isFavorite(id as string) as boolean
    for each f in m.favorites
        if f = id then return true
    end for
    return false
end function

sub toggleFavorite(id as string)
    if id = "" then return
    kept = []
    removed = false
    for each f in m.favorites
        if f = id
            removed = true
        else
            kept.Push(f)
        end if
    end for
    if not removed then kept.Push(id)
    m.favorites = kept
    saveFavorites()
    if removed then toast("Removed from favorites") else toast("Added to favorites")
end sub

sub saveFavorites()
    m.favorites = AirwaveBoundFavorites(m.favorites, 6000)
    writeKey("favorites", FormatJson(m.favorites))
end sub

' The focused tile, for the * key.
function focusedItemId() as string
    node = invalid
    if m.homeRows.hasFocus() and m.homeRows.content <> invalid
        focus = m.homeRows.rowItemFocused
        row = m.homeRows.content.getChild(focus[0])
        if row <> invalid then node = row.getChild(focus[1])
    else if m.grid.hasFocus() and m.grid.content <> invalid
        node = m.grid.content.getChild(m.grid.itemFocused)
    else if m.results.hasFocus() and m.results.content <> invalid
        node = m.results.content.getChild(m.results.itemFocused)
    end if
    if node = invalid then return ""
    return node.itemId
end function

' ---------------------------------------------------------------------------------------------------------------
' Keys: Left goes back towards the rail, Right into the page, Back to the rail and then Home before leaving.

function onKeyEvent(key as string, press as boolean) as boolean
    if not press or m.player.visible then return false
    if key = "options"
        id = focusedItemId()
        if id = "" then return false
        toggleFavorite(id)
        if m.page = "favorites" or m.page = "home" then refreshKeepingFocus()
        return true
    end if
    if key = "right"
        if m.nav.hasFocus()
            focusPage()
            return true
        end if
        if m.groups.hasFocus() and m.grid.visible
            m.grid.setFocus(true)
            return true
        end if
        if m.page = "search" and m.results.visible and not m.results.hasFocus()
            m.results.setFocus(true)
            return true
        end if
        return false
    end if
    if key = "left"
        if m.grid.hasFocus() and m.groups.visible
            m.groups.setFocus(true)
            return true
        end if
        if m.results.hasFocus()
            m.keyboard.setFocus(true)
            return true
        end if
        if not m.nav.hasFocus()
            m.nav.setFocus(true)
            return true
        end if
        return false
    end if
    if key = "back"
        if not m.nav.hasFocus()
            m.nav.setFocus(true)
            return true
        end if
        if m.page <> "home"
            showPage("home")
            return true
        end if
        return false
    end if
    return false
end function

sub refreshKeepingFocus()
    if m.page = "home"
        restoreHome()
        return
    end if
    index = m.grid.itemFocused
    renderBrowse()
    if m.grid.visible
        count = m.grid.content.getChildCount()
        if index >= count then index = count - 1
        if index < 0 then index = 0
        m.grid.jumpToItem = index
        m.grid.setFocus(true)
    else
        m.nav.setFocus(true)
    end if
end sub

' ---------------------------------------------------------------------------------------------------------------
' Chrome

sub toast(text as string)
    m.top.findNode("toastText").text = text
    m.toast.visible = true
    timer = m.top.findNode("toastTimer")
    timer.control = "stop"
    timer.control = "start"
end sub

sub onToastTimer()
    m.toast.visible = false
end sub

sub updateClock()
    now = CreateObject("roDateTime")
    now.ToLocalTime()
    m.clock.text = now.asTimeStringLoc("short")
end sub

' Dialogs and keyboards in the shared palette: raised surface, white focus with black text.
sub applyPalette()
    palette = CreateObject("roSGNode", "RSGPalette")
    palette.colors = {
        "DialogBackgroundColor": "0x1C1C1CFF",
        "DialogItemColor": "0xB4B4B4FF",
        "DialogTextColor": "0xFFFFFFFF",
        "DialogFocusColor": "0xFFFFFFFF",
        "DialogFocusItemColor": "0x000000FF",
        "DialogSecondaryTextColor": "0xB4B4B4FF",
        "DialogSecondaryItemColor": "0x444444FF",
        "DialogInputFieldColor": "0x2A2A2AFF",
        "DialogKeyboardColor": "0x111111FF",
        "DialogFootprintColor": "0x444444FF"
    }
    m.top.palette = palette
    m.keyboard.palette = palette
end sub
