' Test harness for platforms/roku/source/core.brs under brs-node. Reads pkg:/input.json written by
' tests/roku.test.cjs, runs each case and prints one JSON line prefixed with AIRWAVE_RESULT.
sub main()
    input = ParseJson(ReadAsciiFile("pkg:/input.json"))
    out = {"hash": [], "url": [], "stream": [], "tidy": [], "m3u": [], "catalog": [], "filter": [], "clock": [], "bounds": {}}
    for each s in input.hash
        out.hash.Push(AirwaveHash(s))
    end for
    for each c in input.url
        out.url.Push(AirwaveHttpUrl(c[0], c[1]))
    end for
    for each c in input.stream
        out.stream.Push(AirwaveStreamFor(c[0], c[1]))
    end for
    for each c in input.tidy
        out.tidy.Push(AirwaveTidyName(c[0], c[1], c[2]))
    end for
    for each c in input.m3u
        text = ReadAsciiFile("pkg:/" + c[0])
        out.m3u.Push(AirwaveParseM3U(text, c[1]))
    end for
    for each name in input.catalog
        out.catalog.Push(AirwaveParseCatalog(ReadAsciiFile("pkg:/" + name)))
    end for
    items = AirwaveParseM3U(ReadAsciiFile("pkg:/playlist.m3u"), "https://lists.example/iptv/list.m3u").items
    for each c in input.filter
        found = []
        for each x in AirwaveFilter(items, c[0], c[1], c[2])
            found.Push(x.id)
        end for
        out.filter.Push(found)
    end for
    for each n in input.clock
        out.clock.Push(AirwaveClock(n))
    end for
    ' Pairs, not a map: brs-node serialises case-sensitive associative arrays with lowercased lookups.
    labels = AirwaveTidyGroups(input.groups)
    out.groups = []
    for each g in input.groups
        out.groups.Push([g, labels.Lookup(g)])
    end for
    out.bounds.favorites = AirwaveBoundFavorites(input.favorites, 60)
    out.bounds.progress = AirwaveBoundProgress(input.progress, 70)
    out.bounds.resumable = [AirwaveResumable({"t": 31, "d": 100}), AirwaveResumable({"t": 30, "d": 100}), AirwaveResumable({"t": 69, "d": 100}), AirwaveResumable({"t": 70, "d": 100}), AirwaveResumable({"t": 50, "d": 0})]
    out.tone = [AirwaveTone("abc", invalid), AirwaveTone("abc", 7), AirwaveTone("abc", "-2.5"), AirwaveTone("abc", "x")]
    print "AIRWAVE_RESULT " + FormatJson(out)
end sub
