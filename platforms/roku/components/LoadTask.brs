' Downloads the source to tmp:, enforces a size limit, then parses it as an Airwave library (JSON) or an M3U playlist.
' result: {items, name, error}; error is a sentence the interface shows as written.

sub init()
    m.top.functionName = "load"
end sub

sub load()
    url = AirwaveHttpUrl(m.top.url)
    if url = ""
        m.top.result = {"items": [], "name": "", "error": "Enter an HTTP or HTTPS address."}
        return
    end if
    fetched = AirwaveFetch(url, 8 * 1024 * 1024, 45000)
    if fetched.error <> ""
        m.top.result = {"items": [], "name": "", "error": fetched.error}
        return
    end if
    parsed = AirwaveParseSource(fetched.text, url)
    m.top.result = {"items": parsed.items, "name": parsed.name, "error": parsed.error}
end sub

function AirwaveFetch(url as string, limit as integer, timeout as integer) as object
    path = "tmp:/airwave-source"
    fs = CreateObject("roFileSystem")
    if fs.Exists(path) then fs.Delete(path)
    port = CreateObject("roMessagePort")
    transfer = CreateObject("roUrlTransfer")
    transfer.SetMessagePort(port)
    transfer.SetUrl(url)
    transfer.EnableEncodings(true)
    transfer.RetainBodyOnError(false)
    transfer.EnableFreshConnection(true)
    if LCase(Left(url, 6)) = "https:"
        transfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
        transfer.InitClientCertificates()
    end if
    if not transfer.AsyncGetToFile(path)
        return {"text": "", "error": "Could not start the download. Check the address and try again."}
    end if
    msg = Wait(timeout, port)
    if type(msg) <> "roUrlEvent"
        transfer.AsyncCancel()
        if fs.Exists(path) then fs.Delete(path)
        return {"text": "", "error": "The request timed out. Check the address and your connection, then try again."}
    end if
    code = msg.GetResponseCode()
    if code < 200 or code >= 300
        if fs.Exists(path) then fs.Delete(path)
        if code > 0 then return {"text": "", "error": "The source returned HTTP " + code.ToStr() + "."}
        return {"text": "", "error": "Could not reach the source. " + msg.GetFailureReason()}
    end if
    info = fs.Stat(path)
    size = 0
    if info <> invalid and info.DoesExist("size") then size = info.size
    if size > limit
        fs.Delete(path)
        return {"text": "", "error": "Source file exceeds the size limit."}
    end if
    text = ReadAsciiFile(path)
    fs.Delete(path)
    return {"text": text, "error": ""}
end function
