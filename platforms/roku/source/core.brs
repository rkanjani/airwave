' Airwave core for Roku: playlist and catalog parsing, IDs, display names and stream selection.
' Pure functions with no SceneGraph calls, so the render thread and Task nodes can both include this file.
' The rules mirror app/core.js; tests/roku.test.cjs runs both on the same fixtures and compares the results.

function AirwaveIsString(value as dynamic) as boolean
    t = type(value)
    return t = "String" or t = "roString"
end function

function AirwaveIsNumber(value as dynamic) as boolean
    t = type(value)
    return t = "Integer" or t = "roInt" or t = "roInteger" or t = "LongInteger" or t = "roLongInteger" or t = "Float" or t = "roFloat" or t = "Double" or t = "roDouble" or t = "Intrinsic Double"
end function

' ---------------------------------------------------------------------------------------------------------------
' IDs: FNV-1a over UTF-16 code units, printed in base 36, the same value as hash() in app/core.js.
' Playlist IDs, favorites and progress therefore match the web interface for the same stream URL.

function AirwaveHashValue(s as string) as longinteger
    h = 2166136261&
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(s)
    if bytes.Count() = Len(s)
        ' ASCII only: each byte is one UTF-16 code unit, and indexing bytes is faster than Mid().
        ' Inlined step: a byte below 128 only changes the low 8 bits under XOR.
        for each b in bytes
            low = CInt(h mod 256&)
            h = ((h - low + ((low or b) and not (low and b))) * 16777619&) mod 4294967296&
        end for
        return h
    end if
    n = Len(s)
    for i = 1 to n
        c = Asc(Mid(s, i, 1))
        if c > 65535
            ' A firmware that reports whole code points: hash the surrogate pair JavaScript would see.
            c = c - 65536
            h = AirwaveFnvStep(h, 55296 + (c \ 1024))
            h = AirwaveFnvStep(h, 56320 + (c mod 1024))
        else
            h = AirwaveFnvStep(h, c)
        end if
    end for
    return h
end function

function AirwaveFnvStep(h as longinteger, c as integer) as longinteger
    low = CInt(h mod 65536&)
    mixed = (low or c) and not (low and c)
    h = h - low + mixed
    return (h * 16777619&) mod 4294967296&
end function

function AirwaveHash(s as string) as string
    v = AirwaveHashValue(s)
    if v = 0 then return "0"
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = ""
    while v > 0
        out = Mid(digits, CInt(v mod 36&) + 1, 1) + out
        v = v \ 36&
    end while
    return out
end function

' Tile tint 0-5: the catalog color when it is a number, otherwise derived from the ID (tone() in app/app.js).
function AirwaveTone(id as string, color as dynamic) as integer
    if AirwaveIsNumber(color)
        return CInt(Abs(Int(color)) mod 6)
    end if
    if AirwaveIsString(color) and color.Trim() <> ""
        if AirwaveRegex("^\s*-?(\d+\.?\d*|\.\d+)\s*$", "").IsMatch(color)
            return CInt(Abs(Int(Val(color))) mod 6)
        end if
    end if
    return CInt(AirwaveHashValue(id) mod 6&)
end function

' ---------------------------------------------------------------------------------------------------------------
' URLs: http(s) only, normalised the way the WHATWG URL parser does for the cases playlists use: scheme and host
' case, default ports, dot segments, relative references and percent-encoding. Returns "" when not http(s).

function AirwaveHttpUrl(value as dynamic, base = invalid as dynamic) as string
    if not AirwaveIsString(value) then return ""
    v = AirwaveUrlClean(value)
    if v = "" then return ""
    b = invalid
    if AirwaveIsString(base)
        if base <> ""
            ' A playlist resolves every entry against one base, so the parsed base is kept.
            if m.airwaveBaseKey = invalid or m.airwaveBaseKey <> base
                m.airwaveBaseKey = base
                m.airwaveBase = AirwaveUrlParse(AirwaveUrlClean(base), invalid)
            end if
            b = m.airwaveBase
            if b = invalid then return ""
        end if
    end if
    if AirwaveCanonicalUrl(v) then return v
    u = AirwaveUrlParse(v, b)
    if u = invalid then return ""
    return AirwaveUrlString(u)
end function

' Fast path for the common case: an absolute URL already in serialized form (lowercase scheme and host, path present,
' no userinfo, dot segments, default or zero-padded port, or characters the serializer would encode).
function AirwaveCanonicalUrl(v as string) as boolean
    parts = AirwaveRegex("^(https?)://([a-z0-9.-]+)(:[1-9][0-9]{0,4})?/[\x21-\x7E]*$", "").Match(v)
    if parts.Count() = 0 then return false
    if AirwaveRegex("[" + Chr(34) + "#<>`{}\\']|/\.|%2[eE]", "").IsMatch(v) then return false
    if parts[3] <> ""
        port = Val(Mid(parts[3], 2))
        if port > 65535 or (parts[1] = "http" and port = 80) or (parts[1] = "https" and port = 443) then return false
    end if
    return true
end function

function AirwaveUrlClean(value as string) as string
    v = value.Trim()
    if Instr(1, v, Chr(9)) > 0 or Instr(1, v, Chr(10)) > 0 or Instr(1, v, Chr(13)) > 0
        v = AirwaveRegex("[\t\r\n]", "").ReplaceAll(v, "")
    end if
    return v
end function

' Special schemes treat backslashes as slashes before the query or fragment.
function AirwaveUrlSlashes(v as string) as string
    if Instr(1, v, "\") = 0 then return v
    stop_at = Len(v) + 1
    q = Instr(1, v, "?")
    f = Instr(1, v, "#")
    if q > 0 and q < stop_at then stop_at = q
    if f > 0 and f < stop_at then stop_at = f
    head = Left(v, stop_at - 1)
    return head.Replace("\", "/") + Mid(v, stop_at)
end function

function AirwaveUrlParse(v as string, b as dynamic) as dynamic
    parts = AirwaveRegex("^([a-zA-Z][a-zA-Z0-9+.\-]*):(.*)$", "s").Match(v)
    if parts.Count() > 0
        scheme = LCase(parts[1])
        if scheme <> "http" and scheme <> "https" then return invalid
        rest = AirwaveUrlSlashes(parts[2])
        if b <> invalid
            if b.scheme = scheme and Left(rest, 1) <> "/" then return AirwaveUrlResolve(rest, b)
        end if
        while Left(rest, 1) = "/"
            rest = Mid(rest, 2)
        end while
        return AirwaveUrlAuthority(scheme, rest)
    end if
    if b = invalid then return invalid
    return AirwaveUrlResolve(AirwaveUrlSlashes(v), b)
end function

function AirwaveUrlResolve(rest as string, b as object) as dynamic
    if Left(rest, 2) = "//"
        while Left(rest, 1) = "/"
            rest = Mid(rest, 2)
        end while
        return AirwaveUrlAuthority(b.scheme, rest)
    end if
    u = {"scheme": b.scheme, "user": b.user, "host": b.host, "port": b.port}
    tail = AirwaveUrlTail(rest)
    first = Left(rest, 1)
    if first = "/"
        u.path = tail.path
        u.query = tail.query
    else if first = "?"
        u.path = b.path
        u.query = tail.query
    else if first = "#"
        u.path = b.path
        u.query = b.query
    else if rest = ""
        u.path = b.path
        u.query = b.query
    else
        slash = AirwaveLastIndex(b.path, "/")
        u.path = Left(b.path, slash) + tail.path
        u.query = tail.query
    end if
    u.fragment = tail.fragment
    return AirwaveUrlFinish(u)
end function

' Splits "path?query#fragment"; absent query and fragment are invalid so "?" alone survives as in JavaScript.
function AirwaveUrlTail(rest as string) as object
    out = {"path": rest, "query": invalid, "fragment": invalid}
    f = Instr(1, rest, "#")
    if f > 0
        out.fragment = Mid(rest, f + 1)
        rest = Left(rest, f - 1)
    end if
    q = Instr(1, rest, "?")
    if q > 0
        out.query = Mid(rest, q + 1)
        rest = Left(rest, q - 1)
    end if
    out.path = rest
    return out
end function

function AirwaveUrlAuthority(scheme as string, rest as string) as dynamic
    cut = Len(rest) + 1
    for each mark in ["/", "?", "#"]
        p = Instr(1, rest, mark)
        if p > 0 and p < cut then cut = p
    end for
    authority = Left(rest, cut - 1)
    tail = AirwaveUrlTail(Mid(rest, cut))
    user = ""
    at = AirwaveLastIndex(authority, "@")
    if at > 0
        user = AirwaveUrlUser(Left(authority, at - 1))
        authority = Mid(authority, at + 1)
    end if
    host = authority
    port = ""
    if Left(authority, 1) = "["
        close = Instr(1, authority, "]")
        if close = 0 then return invalid
        host = Left(authority, close)
        after = Mid(authority, close + 1)
        if after <> ""
            if Left(after, 1) <> ":" then return invalid
            port = Mid(after, 2)
        end if
    else
        colon = Instr(1, authority, ":")
        if colon > 0
            host = Left(authority, colon - 1)
            port = Mid(authority, colon + 1)
        end if
        if host = "" then return invalid
        if AirwaveRegex("[\x00-\x20#%/:<>?@\[\\\]^|\x7F]", "").IsMatch(host) then return invalid
    end if
    if port <> ""
        if not AirwaveRegex("^\d+$", "").IsMatch(port) then return invalid
        number = Val(port)
        if number > 65535 then return invalid
        port = Str(number).Trim()
        if (scheme = "http" and port = "80") or (scheme = "https" and port = "443") then port = ""
    end if
    u = {"scheme": scheme, "user": user, "host": LCase(host), "port": port, "path": tail.path, "query": tail.query, "fragment": tail.fragment}
    return AirwaveUrlFinish(u)
end function

' "user:pass" keeps an empty user before a password and drops an empty password, as the URL serializer does.
function AirwaveUrlUser(raw as string) as string
    colon = Instr(1, raw, ":")
    name = raw
    password = ""
    if colon > 0
        name = Left(raw, colon - 1)
        password = Mid(raw, colon + 1)
    end if
    set = Chr(34) + "#<>?`{}/:;=@[\]^|"
    out = AirwavePercentEncode(name, set)
    if password <> "" then out = out + ":" + AirwavePercentEncode(password, set)
    return out
end function

function AirwaveUrlFinish(u as object) as object
    path = u.path
    if Left(path, 1) <> "/" then path = "/" + path
    u.path = AirwavePercentEncode(AirwaveDotSegments(path), Chr(34) + "<>`{}")
    if u.query <> invalid then u.query = AirwavePercentEncode(u.query, Chr(34) + "<>'")
    if u.fragment <> invalid then u.fragment = AirwavePercentEncode(u.fragment, Chr(34) + "<>`")
    return u
end function

function AirwaveDotSegments(path as string) as string
    segments = path.Split("/")
    out = []
    last = segments.Count() - 1
    for i = 1 to last
        s = segments[i]
        ls = LCase(s)
        if s = "." or ls = "%2e"
            if i = last then out.Push("")
        else if s = ".." or ls = ".%2e" or ls = "%2e." or ls = "%2e%2e"
            if out.Count() > 0 then out.Pop()
            if i = last then out.Push("")
        else
            out.Push(s)
        end if
    end for
    return "/" + out.Join("/")
end function

function AirwaveUrlString(u as object) as string
    s = u.scheme + "://"
    if u.user <> "" then s = s + u.user + "@"
    s = s + u.host
    if u.port <> "" then s = s + ":" + u.port
    s = s + u.path
    if u.query <> invalid then s = s + "?" + u.query
    if u.fragment <> invalid then s = s + "#" + u.fragment
    return s
end function

' Encodes controls, spaces, non-ASCII (as UTF-8) and the given characters; existing escapes are left alone.
function AirwavePercentEncode(s as string, set as string) as string
    if s = "" then return s
    probe = "[^\x21-\x7E]"
    for i = 1 to Len(set)
        probe = probe + "|\x" + StrI(Asc(Mid(set, i, 1)), 16).Trim()
    end for
    if not AirwaveRegex(probe, "").IsMatch(s) then return s
    out = ""
    bytes = CreateObject("roByteArray")
    n = Len(s)
    i = 1
    while i <= n
        ch = Mid(s, i, 1)
        c = Asc(ch)
        if c >= 55296 and c <= 56319 and i < n
            ' Surrogate pair (firmware that indexes UTF-16): encode both halves as one character.
            ch = Mid(s, i, 2)
            i = i + 1
            c = 65536
        end if
        if c < 33 or c > 126 or Instr(1, set, ch) > 0
            bytes.FromAsciiString(ch)
            hex = bytes.ToHexString()
            for j = 1 to Len(hex) step 2
                out = out + "%" + Mid(hex, j, 2)
            end for
        else
            out = out + ch
        end if
        i = i + 1
    end while
    return out
end function

function AirwaveLastIndex(s as string, mark as string) as integer
    found = 0
    p = Instr(1, s, mark)
    while p > 0
        found = p
        p = Instr(p + 1, s, mark)
    end while
    return found
end function

' ---------------------------------------------------------------------------------------------------------------
' Playlists. Returns {items, error}; error is "" on success and uses the same wording as parseM3U in app/core.js.

function AirwaveParseM3U(text as string, base = invalid as dynamic) as object
    if Len(text) > 5 * 1024 * 1024 then return AirwaveFailure("Playlist is too large. Use a playlist smaller than 5 MB.")
    if not AirwaveRegex("^\s*#EXTM3U", "m").IsMatch(text) then return AirwaveFailure("This is not an M3U playlist. It should start with #EXTM3U.")
    if Left(text, 1) = Chr(65279) then text = Mid(text, 2)
    attrPattern = AirwaveRegex("([\w-]+)=" + Chr(34) + "([^" + Chr(34) + "]*)" + Chr(34), "")
    numberPattern = AirwaveRegex("^\s*([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)", "")
    moviePath = AirwaveRegex("\.(mp4|mkv|mov|webm)(\?|$)", "i")
    movieGroup = AirwaveRegex("movie|film|vod", "i")
    entries = []
    seen = {}
    seen.SetModeCaseSensitive()
    pending = invalid
    for each raw in text.Split(Chr(10))
        line = raw.Trim()
        if line = ""
            ' Blank lines carry nothing.
        else if Left(line, 8) = "#EXTINF:"
            pending = AirwaveExtinf(line, base, attrPattern, numberPattern)
        else if Left(line, 1) = "#"
            ' Other directives keep the pending #EXTINF.
        else
            url = AirwaveHttpUrl(line, base)
            if url = "" or seen.DoesExist(url)
                pending = invalid
            else
                seen[url] = true
                p = pending
                if p = invalid then p = {"name": "Channel " + (entries.Count() + 1).ToStr(), "group": "Unsorted", "epgId": "", "logo": "", "duration": -1}
                name = p.name
                if name = "" then name = "Untitled channel"
                kind = "live"
                if p.duration > 0 or moviePath.IsMatch(url) or movieGroup.IsMatch(p.group) then kind = "movie"
                entries.Push({"id": AirwaveHash(url), "url": url, "name": name, "group": p.group, "epgId": p.epgId, "logo": p.logo, "kind": kind, "color": entries.Count() mod 6})
                pending = invalid
                if entries.Count() > 10000 then return AirwaveFailure("This library has over 10,000 entries. Import a smaller playlist.")
            end if
        end if
    end for
    if entries.Count() = 0 then return AirwaveFailure("No HTTP or HTTPS streams found in this playlist.")
    return {"items": entries, "error": ""}
end function

function AirwaveExtinf(line as string, base as dynamic, attrPattern as object, numberPattern as object) as object
    ' The first comma outside double quotes ends the attributes; an unclosed quote hides every later comma.
    comma = 0
    if Instr(1, line, Chr(34)) = 0
        comma = Instr(9, line, ",")
    else
        q = Chr(34)
        found = AirwaveRegex("^((?:[^" + q + ",]|" + q + "[^" + q + "]*" + q + ")*),", "s").Match(Mid(line, 9))
        if found.Count() > 1 then comma = 9 + Len(found[1])
    end if
    head = line
    name = "Untitled channel"
    if comma > 0
        head = Left(line, comma - 1)
        name = Mid(line, comma + 1).Trim()
    end if
    attrs = {}
    for each match in attrPattern.MatchAll(head)
        attrs[LCase(match[1])] = match[2]
    end for
    group = "Unsorted"
    if attrs.DoesExist("group-title") and attrs["group-title"] <> "" then group = attrs["group-title"]
    epg = ""
    if attrs.DoesExist("tvg-id") then epg = attrs["tvg-id"]
    logo = ""
    if attrs.DoesExist("tvg-logo") then logo = AirwaveHttpUrl(attrs["tvg-logo"], base)
    duration = -1
    number = numberPattern.Match(Mid(line, 9))
    if number.Count() > 1 then duration = Val(number[1])
    return {"name": name, "group": group, "epgId": epg, "logo": logo, "duration": duration}
end function

function AirwaveFailure(message as string) as object
    return {"items": [], "error": message}
end function

' ---------------------------------------------------------------------------------------------------------------
' Private catalog JSON, version 2: {version: 2, name, items}. Invalid items are skipped; IDs stay as given.

function AirwaveParseCatalog(text as string) as object
    if Len(text) > 8 * 1024 * 1024 then return AirwaveCatalogFailure("Library file is too large. Use a file smaller than 8 MB.")
    json = ParseJson(text)
    if type(json) <> "roAssociativeArray" then return AirwaveCatalogFailure("This is not an Airwave library file.")
    if not json.DoesExist("items") or type(json.items) <> "roArray" then return AirwaveCatalogFailure("This is not an Airwave library file.")
    if json.DoesExist("version")
        if not AirwaveIsNumber(json.version) then return AirwaveCatalogFailure("This library file uses an unsupported version.")
        if json.version <> 2 then return AirwaveCatalogFailure("This library file uses an unsupported version.")
    end if
    name = "My library"
    if AirwaveIsString(json.name)
        if json.name.Trim() <> "" then name = json.name.Trim()
    end if
    items = []
    seen = {}
    seen.SetModeCaseSensitive()
    for each raw in json.items
        item = AirwaveCatalogItem(raw)
        if item <> invalid
            if not seen.DoesExist(item.id)
                seen[item.id] = true
                items.Push(item)
                if items.Count() > 10000 then return AirwaveCatalogFailure("This library has over 10,000 entries. Import a smaller playlist.")
            end if
        end if
    end for
    if items.Count() = 0 then return AirwaveCatalogFailure("This library has no HTTP or HTTPS entries.")
    return {"name": name, "items": items, "error": ""}
end function

function AirwaveCatalogItem(raw as dynamic) as dynamic
    if type(raw) <> "roAssociativeArray" then return invalid
    if not AirwaveIsString(raw.id) or not AirwaveIsString(raw.name) or not AirwaveIsString(raw.url) or not AirwaveIsString(raw.kind) then return invalid
    if raw.id = "" then return invalid
    if raw.kind <> "live" and raw.kind <> "movie" then return invalid
    url = raw.url.Trim()
    if AirwaveHttpUrl(url) = "" then return invalid
    group = "Unsorted"
    if AirwaveIsString(raw.group)
        if raw.group <> "" then group = raw.group
    end if
    epg = ""
    if AirwaveIsString(raw.epgId) then epg = raw.epgId
    logo = ""
    if AirwaveIsString(raw.logo) then logo = AirwaveHttpUrl(raw.logo)
    favorite = false
    if type(raw.favorite) = "Boolean" or type(raw.favorite) = "roBoolean" then favorite = raw.favorite
    name = raw.name
    if name.Trim() = "" then name = "Untitled channel"
    return {"id": raw.id, "url": url, "name": name, "group": group, "epgId": epg, "logo": logo, "kind": raw.kind, "favorite": favorite, "color": AirwaveTone(raw.id, raw.color)}
end function

function AirwaveCatalogFailure(message as string) as object
    return {"name": "", "items": [], "error": message}
end function

' A fetched source is a catalog when it is a JSON object, otherwise it is read as an M3U playlist.
function AirwaveParseSource(text as string, base = invalid as dynamic) as object
    if Left(text, 1) = Chr(65279) then text = Mid(text, 2)
    if Left(text.Trim(), 1) = "{"
        return AirwaveParseCatalog(text)
    end if
    result = AirwaveParseM3U(text, base)
    result.name = "My library"
    return result
end function

' ---------------------------------------------------------------------------------------------------------------
' Search and grouping, as filter() in app/core.js: case-insensitive match on "name group".

function AirwaveFilter(items as object, query as string, group as string, kind as string) as object
    q = LCase(query.Trim())
    out = []
    for each x in items
        if (kind = "" or x.kind = kind) and (group = "" or group = "All" or x.group = group)
            if q = ""
                out.Push(x)
            else if Instr(1, LCase(x.name + " " + x.group), q) > 0
                out.Push(x)
            end if
        end if
    end for
    return out
end function

' Group names in first-seen order.
function AirwaveGroups(items as object) as object
    seen = {}
    seen.SetModeCaseSensitive()
    out = []
    for each x in items
        if not seen.DoesExist(x.group)
            seen[x.group] = true
            out.Push(x.group)
        end if
    end for
    return out
end function

function AirwaveClock(seconds as dynamic) as string
    total = 0
    if AirwaveIsNumber(seconds)
        if seconds > 0 then total = Int(seconds)
    end if
    h = total \ 3600
    m = (total mod 3600) \ 60
    s = total mod 60
    ss = s.ToStr()
    if s < 10 then ss = "0" + ss
    if h > 0
        mm = m.ToStr()
        if m < 10 then mm = "0" + mm
        return h.ToStr() + ":" + mm + ":" + ss
    end if
    return m.ToStr() + ":" + ss
end function

' ---------------------------------------------------------------------------------------------------------------
' Playback format for the Roku Video node. Returns {url, format, error}.
' HLS -> hls, MP4/MOV/M4V -> mp4, MKV -> mkv, DASH -> dash. Live raw MPEG-TS is requested as HLS at the same path
' with .m3u8 (the rewrite the relay and the Apple AVPlayer path use); other live channels are tried as HLS.
' Other movie containers are left to the firmware to detect; AVI is refused with a readable message.

function AirwaveStreamFor(url as string, kind as string) as object
    ext = AirwaveExtension(url)
    if ext = "m3u8" then return {"url": url, "format": "hls", "error": ""}
    if ext = "mp4" or ext = "m4v" or ext = "mov" then return {"url": url, "format": "mp4", "error": ""}
    if ext = "mkv" then return {"url": url, "format": "mkv", "error": ""}
    if ext = "mpd" then return {"url": url, "format": "dash", "error": ""}
    if ext = "avi" then return {"url": url, "format": "", "error": "AVI files cannot play on Roku. Use an MP4, MKV or HLS version of this title."}
    if kind = "live"
        if ext = "ts" then return {"url": AirwaveLiveHls(url), "format": "hls", "error": ""}
        return {"url": url, "format": "hls", "error": ""}
    end if
    return {"url": url, "format": "", "error": ""}
end function

' The first ".ts" that ends the path (before a query or at the end), any case, becomes ".m3u8".
function AirwaveLiveHls(url as string) as string
    return AirwaveRegex("\.ts(?=\?|$)", "i").Replace(url, ".m3u8")
end function

function AirwaveExtension(url as string) as string
    path = url
    f = Instr(1, path, "#")
    if f > 0 then path = Left(path, f - 1)
    q = Instr(1, path, "?")
    if q > 0 then path = Left(path, q - 1)
    scheme = Instr(1, path, "://")
    if scheme > 0
        path = Mid(path, scheme + 3)
        slash = Instr(1, path, "/")
        if slash = 0 then return ""
        path = Mid(path, slash)
    end if
    file = Mid(path, AirwaveLastIndex(path, "/") + 1)
    dot = AirwaveLastIndex(file, ".")
    if dot = 0 then return ""
    return LCase(Mid(file, dot + 1))
end function

' ---------------------------------------------------------------------------------------------------------------
' Registry bounds. Roku gives a channel 16 KB of registry; favorites and progress get fixed byte budgets and drop
' their oldest entries first.

function AirwaveBoundFavorites(ids as object, maxBytes as integer) as object
    out = []
    for each id in ids
        if AirwaveIsString(id) then out.Push(id)
    end for
    while out.Count() > 0 and Len(FormatJson(out)) > maxBytes
        out.Shift()
    end while
    return out
end function

' progress: id -> {"t": seconds, "d": duration, "u": updated (epoch seconds)}.
function AirwaveBoundProgress(progress as object, maxBytes as integer) as object
    out = {}
    out.SetModeCaseSensitive()
    for each id in progress
        entry = progress[id]
        if type(entry) = "roAssociativeArray"
            if AirwaveIsNumber(entry.t) and AirwaveIsNumber(entry.d) and AirwaveIsNumber(entry.u)
                out[id] = {"t": entry.t, "d": entry.d, "u": entry.u}
            end if
        end if
    end for
    while out.Count() > 0 and Len(FormatJson(out)) > maxBytes
        oldest = invalid
        for each id in out
            if oldest = invalid
                oldest = id
            else if out[id].u < out[oldest].u
                oldest = id
            end if
        end for
        out.Delete(oldest)
    end while
    return out
end function

' The web rule: a movie resumes when it has a known duration and more than 30 seconds watched and left.
function AirwaveResumable(entry as dynamic) as boolean
    if type(entry) <> "roAssociativeArray" then return false
    if not AirwaveIsNumber(entry.t) or not AirwaveIsNumber(entry.d) then return false
    return entry.d > 0 and entry.t > 30 and entry.t < entry.d - 30
end function

' ---------------------------------------------------------------------------------------------------------------
' Display names: tidyName() from app/core.js for ASCII names. Region prefixes and quality, HDR, HEVC, RAW and
' frame-rate tags come off the name; quality becomes a badge. Styled Unicode letters are not normalised here.

function AirwaveTidyName(raw as dynamic, group = "" as dynamic, kind = "" as dynamic) as object
    original = ""
    if AirwaveIsString(raw) then original = raw.Trim()
    t = {"name": original, "region": "", "quality": "", "tags": [], "notes": []}
    s = AirwaveStripEdges(original, " #=*~_.•·-", " #=*~_•·-")
    dropped = ""
    prefix = AirwaveRegex("^[\[(]?\s*([^|:\[\]()]{1,12}?)\s*(?:[\])]\s*[|:-]?|\|)\s*", "").Match(s)
    if prefix.Count() > 1
        if Len(prefix[0]) < Len(s) and (Instr(1, prefix[0], "|") > 0 or Left(prefix[0], 1) = "[" or Left(prefix[0], 1) = "(")
            if AirwaveRegex("^[A-Z]{2,3}$", "").IsMatch(prefix[1])
                t.region = prefix[1]
            else
                AirwaveAddQuality(t, prefix[1])
            end if
            s = Mid(s, Len(prefix[0]) + 1)
        end if
    end if
    lead = AirwaveRegex("^([^:]{2,24}):\s+", "").Match(s)
    groupWords = AirwaveWords(group)
    if lead.Count() > 1
        if kind = "live" and AirwaveRegex("^[A-Z]{2,3}$", "").IsMatch(lead[1])
            if t.region = "" then t.region = lead[1]
            dropped = lead[1]
            s = Mid(s, Len(lead[0]) + 1)
        else
            leadWords = AirwaveWords(lead[1])
            every = leadWords.Count() > 0
            for each w in leadWords
                if not AirwaveContains(groupWords, w) then every = false
            end for
            if every
                dropped = lead[1]
                s = Mid(s, Len(lead[0]) + 1)
            end if
        end if
    end if
    resolution = AirwaveRegex("^(8k|4k|uhd|2160p|4320p|1080[pi]|720p|576[pi]|480[pi])$", "i")
    fpsWord = AirwaveRegex("^(\d{2,3})fps$", "i")
    digits = AirwaveRegex("^\d{2,3}$", "")
    parts = AirwaveRegex("\s+", "").Split(s)
    kept = []
    i = 0
    while i < parts.Count()
        part = parts[i]
        token = AirwaveRegex("^[\[(]+|[\])]+$", "").ReplaceAll(part, "")
        first = kept.Count() = 0
        fps = ""
        nextPart = ""
        if i + 1 < parts.Count() then nextPart = parts[i + 1]
        if digits.IsMatch(token) and LCase(nextPart) = "fps"
            fps = token
        else
            m = fpsWord.Match(token)
            if m.Count() > 1 then fps = m[1]
        end if
        if fps <> "" and not first
            AirwavePushUnique(t.notes, fps + " FPS")
            if digits.IsMatch(token) then i = i + 1
        else if resolution.IsMatch(token) and AirwaveAddQuality(t, token)
            ' Resolution tags count anywhere.
        else if not first and AirwaveAddQuality(t, token)
            ' Looser quality words only after the first word.
        else if not first and AirwaveRegex("^(hdr|hdr10\+?)$", "i").IsMatch(token)
            AirwavePushUnique(t.tags, "HDR")
        else if not first and AirwaveRegex("^(hevc|h\.?265|x265)$", "i").IsMatch(token)
            AirwavePushUnique(t.tags, "HEVC")
        else if not first and LCase(token) = "raw"
            AirwavePushUnique(t.notes, "RAW")
        else
            kept.Push(part)
        end if
        i = i + 1
    end while
    s = kept.Join(" ")
    s = AirwaveRegex("[\[(]\s*[\])]", "").ReplaceAll(s, "")
    s = AirwaveRegex("\s{2,}", "").ReplaceAll(s, " ")
    s = AirwaveStripEdges(s, " |:#=*~_.,•·–—-", " |:#=*~_,•·–—-")
    if not AirwaveRegex("[A-Za-z0-9]|[^\x00-\x7F]", "").IsMatch(s)
        t.name = original
        return t
    end if
    if AirwaveShouting(dropped + " " + s) then s = AirwaveSmartCase(s)
    t.name = s
    return t
end function

' Removes leading characters in lead and trailing characters in trail (whitespace always counts).
function AirwaveStripEdges(s as string, lead as string, trail as string) as string
    n = Len(s)
    a = 1
    while a <= n and AirwaveEdgeChar(Mid(s, a, 1), lead)
        a = a + 1
    end while
    b = n
    while b >= a and AirwaveEdgeChar(Mid(s, b, 1), trail)
        b = b - 1
    end while
    return Mid(s, a, b - a + 1)
end function

function AirwaveEdgeChar(ch as string, set as string) as boolean
    c = Asc(ch)
    if c = 9 or c = 10 or c = 11 or c = 12 or c = 13 or c = 32 or c = 160 then return true
    return Instr(1, set, ch) > 0
end function

function AirwaveQualityList() as object
    return [["8K", "^(8k|4320p)$"], ["4K", "^(4k|uhd|2160p)$"], ["FHD", "^(fhd|1080[pi])$"], ["HD", "^(hd|720p)$"], ["SD", "^(sd|480[pi]|576[pi])$"]]
end function

function AirwaveAddQuality(t as object, token as string) as boolean
    list = AirwaveQualityList()
    current = -1
    for i = 0 to list.Count() - 1
        if list[i][0] = t.quality then current = i
    end for
    for i = 0 to list.Count() - 1
        if AirwaveRegex(list[i][1], "i").IsMatch(token)
            if t.quality = "" or i < current then t.quality = list[i][0]
            return true
        end if
    end for
    return false
end function

function AirwaveWords(s as dynamic) as object
    if not AirwaveIsString(s) then return []
    out = []
    for each w in AirwaveRegex("[^a-z0-9]+", "").Split(LCase(s))
        if w <> "" then out.Push(w)
    end for
    return out
end function

function AirwaveContains(list as object, value as string) as boolean
    for each x in list
        if x = value then return true
    end for
    return false
end function

sub AirwavePushUnique(list as object, value as string)
    if not AirwaveContains(list, value) then list.Push(value)
end sub

function AirwaveShouting(s as string) as boolean
    letters = AirwaveRegex("[^A-Za-z]", "").ReplaceAll(s, "")
    return Len(letters) >= 4 and letters = UCase(letters)
end function

function AirwaveSmartCase(s as string) as string
    acronyms = AirwaveRegex("^(A&E|ABC|ACC|AMC|AXN|BBC|BEIN|BET|CBC|CNN|CTV|C-SPAN|DAZN|ESPN|ESPNU|EU|HBO|IFC|ION|ITV|MASN|NASA|NBA|NESN|NFL|OAN|OWN|RAI|RTE|SEC|TUDN|TV|UFC|UK|US|USA|WWE|YES)$", "")
    small = AirwaveRegex("^(an|and|at|de|del|el|et|for|in|la|le|of|on|the|to|y)$", "i")
    roman = AirwaveRegex("^(I{2,3}|IV|VI{1,3}|IX)$", "")
    hasDigit = AirwaveRegex("\d", "")
    vowel = AirwaveRegex("[AEIOUY]", "")
    notLetter = AirwaveRegex("[^A-Za-z]", "")
    tokens = s.Split(" ")
    last = tokens.Count() - 1
    out = []
    for i = 0 to last
        token = tokens[i]
        inner = i > 0 and i < last
        if acronyms.IsMatch(AirwaveRegex("[^A-Za-z&-]", "").ReplaceAll(token, "")) or hasDigit.IsMatch(token) or roman.IsMatch(token)
            out.Push(token)
        else
            pieces = []
            for each part in token.Split("-")
                bare = notLetter.ReplaceAll(part, "")
                if Len(bare) < 2 and not (inner and small.IsMatch(bare))
                    pieces.Push(part)
                else if acronyms.IsMatch(bare) or not vowel.IsMatch(bare)
                    pieces.Push(part)
                else if inner and small.IsMatch(bare)
                    pieces.Push(LCase(part))
                else
                    pieces.Push(Left(part, 1) + LCase(Mid(part, 2)))
                end if
            end for
            out.Push(pieces.Join("-"))
        end if
    end for
    return out.Join(" ")
end function

' Group labels keep their region ("US · Sports"); labels that would collide keep their tags, then the raw name.
function AirwaveTidyGroups(groups as object) as object
    tidy = []
    for each g in groups
        t = AirwaveTidyName(g)
        shown = t.name
        if t.region <> "" then shown = t.region + " · " + t.name
        tidy.Push({"raw": g, "t": t, "label": shown})
    end for
    counts = AirwaveLabelCounts(tidy)
    for each x in tidy
        if counts[x.label] > 1
            extra = []
            if x.t.quality <> "" then extra.Push(x.t.quality)
            extra.Append(x.t.tags)
            extra.Append(x.t.notes)
            if extra.Count() > 0 then x.label = x.label + " · " + extra.Join(" ")
        end if
    end for
    counts = AirwaveLabelCounts(tidy)
    out = {}
    out.SetModeCaseSensitive()
    for each x in tidy
        if counts[x.label] > 1
            out[x.raw] = x.raw
        else
            out[x.raw] = x.label
        end if
    end for
    return out
end function

function AirwaveLabelCounts(tidy as object) as object
    counts = {}
    counts.SetModeCaseSensitive()
    for each x in tidy
        if counts.DoesExist(x.label)
            counts[x.label] = counts[x.label] + 1
        else
            counts[x.label] = 1
        end if
    end for
    return counts
end function

' Compiled patterns are reused: compiling one per call made a 10,000-entry playlist several times slower.
function AirwaveRegex(pattern as string, flags as string) as object
    if m.airwaveRegex = invalid
        m.airwaveRegex = {}
        m.airwaveRegex.SetModeCaseSensitive()
    end if
    key = flags + "/" + pattern
    rx = m.airwaveRegex.Lookup(key)
    if rx = invalid
        rx = CreateObject("roRegex", pattern, flags)
        m.airwaveRegex.AddReplace(key, rx)
    end if
    return rx
end function
