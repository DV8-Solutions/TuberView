import XCTest
@testable import TuberCore

final class M3UTests: XCTestCase {

    private func parse(_ text: String) -> [Channel] {
        M3U.parse(Data(text.utf8))
    }

    func testReadsNameGroupLogoAndGuideID() {
        let list = parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="espn.us" tvg-name="ESPN" tvg-logo="http://x/l.png" group-title="Sports",US: ESPN HD
        http://host/live/u/p/101.ts
        """)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].name, "US: ESPN HD")
        XCTAssertEqual(list[0].group, "Sports")
        XCTAssertEqual(list[0].logo, "http://x/l.png")
        XCTAssertEqual(list[0].guideID, "espn.us")
        XCTAssertEqual(list[0].url, "http://host/live/u/p/101.ts")
        XCTAssertEqual(list[0].kind, .live)
        XCTAssertEqual(list[0].index, 0)
    }

    /// TuberView's rule: keep every channel. Same name, same address, it does
    /// not matter - every line is its own entry.
    func testKeepsEveryLineIncludingExactDuplicates() {
        let list = parse("""
        #EXTM3U
        #EXTINF:-1 group-title="News",CNN
        http://host/1.ts
        #EXTINF:-1 group-title="News",CNN
        http://host/2.ts
        #EXTINF:-1 group-title="US",CNN
        http://host/1.ts
        #EXTINF:-1 group-title="News",CNN
        http://host/1.ts
        """)
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(list.map(\.group), ["News", "News", "US", "News"])
    }

    func testCommaInsideQuotesIsNotTheNameSeparator() {
        let list = parse("""
        #EXTINF:-1 tvg-name="Rock, Paper" group-title="Kids, Family",Rock, Paper, Scissors
        http://host/3.ts
        """)
        XCTAssertEqual(list[0].name, "Rock, Paper, Scissors")
        XCTAssertEqual(list[0].group, "Kids, Family")
    }

    func testWindowsLineEndingsBlankLinesAndByteOrderMark() {
        let text = "\u{FEFF}#EXTM3U\r\n\r\n#EXTINF:-1 group-title=\"A\",One\r\nhttp://h/1.ts\r\n\r\n#EXTINF:-1,Two\r\nhttp://h/2.ts"
        let list = parse(text)
        XCTAssertEqual(list.map(\.name), ["One", "Two"])
        XCTAssertEqual(list.map(\.url), ["http://h/1.ts", "http://h/2.ts"])
    }

    func testAddressWithoutHeaderIsStillKept() {
        let list = parse("""
        #EXTM3U
        http://host/live/user/pass/777.ts
        """)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].name, "777.ts")
    }

    func testHeaderDoesNotLeakOntoTheNextAddress() {
        let list = parse("""
        #EXTINF:-1 group-title="A",First
        http://h/1.ts
        http://h/2.ts
        """)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[1].name, "2.ts")
        XCTAssertEqual(list[1].group, "")
    }

    func testOtherDirectivesAreSkippedAndExtGrpIsUsed() {
        let list = parse("""
        #EXTINF:-1,Solo
        #EXTVLCOPT:http-user-agent=Thing
        #EXTGRP:Docs
        http://h/9.ts
        """)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].name, "Solo")
        XCTAssertEqual(list[0].group, "Docs")
    }

    func testKinds() {
        XCTAssertEqual(M3U.kind(for: "http://h/movie/u/p/5.mkv"), .movie)
        XCTAssertEqual(M3U.kind(for: "http://h/series/u/p/6.mp4"), .episode)
        XCTAssertEqual(M3U.kind(for: "http://h/u/p/7.MP4?token=1"), .movie)
        XCTAssertEqual(M3U.kind(for: "http://h/u/p/8"), .live)
        XCTAssertEqual(M3U.kind(for: "http://h/live/u/p/8.m3u8"), .live)
    }

    func testRecognisesAPlaylistAndRejectsAnErrorPage() {
        XCTAssertTrue(M3U.looksLikePlaylist(Data("#EXTM3U\n".utf8)))
        XCTAssertFalse(M3U.looksLikePlaylist(Data("<html>Forbidden</html>".utf8)))
        XCTAssertFalse(M3U.looksLikePlaylist(Data()))
    }

    func testLargePlaylistKeepsItsCount() {
        var text = "#EXTM3U\n"
        let n = 20_000
        for i in 0..<n {
            text += "#EXTINF:-1 group-title=\"G\(i % 7)\",Channel \(i % 50)\nhttp://h/\(i % 100).ts\n"
        }
        XCTAssertEqual(parse(text).count, n)
    }
}

final class SearchTests: XCTestCase {

    private let channels: [Channel] = [
        Channel(index: 0, name: "US: ESPN HD", group: "Sports", logo: "", guideID: "", url: "http://h/1", kind: .live),
        Channel(index: 1, name: "US: ESPN 2", group: "Sports", logo: "", guideID: "", url: "http://h/2", kind: .live),
        Channel(index: 2, name: "Télé Québec", group: "CA", logo: "", guideID: "", url: "http://h/3", kind: .live),
        Channel(index: 3, name: "ESPN: The Movie", group: "Films", logo: "", guideID: "", url: "http://h/movie/4.mp4", kind: .movie),
    ]

    func testEmptyQueryShowsEverything() {
        XCTAssertEqual(Search.matches(in: channels, query: "", kind: nil), [0, 1, 2, 3])
        XCTAssertEqual(Search.matches(in: channels, query: "   ", kind: nil), [0, 1, 2, 3])
    }

    func testEveryWordMustMatchInAnyOrder() {
        XCTAssertEqual(Search.matches(in: channels, query: "espn", kind: nil), [0, 1, 3])
        XCTAssertEqual(Search.matches(in: channels, query: "hd espn", kind: nil), [0])
        XCTAssertEqual(Search.matches(in: channels, query: "espn zzz", kind: nil), [])
    }

    func testCaseAndAccentsAreIgnored() {
        XCTAssertEqual(Search.matches(in: channels, query: "TELE quebec", kind: nil), [2])
    }

    func testKindFilter() {
        XCTAssertEqual(Search.matches(in: channels, query: "espn", kind: .live), [0, 1])
        XCTAssertEqual(Search.matches(in: channels, query: "", kind: .movie), [3])
    }

    func testCategoryFilterNarrowsWithoutMerging() {
        XCTAssertEqual(Search.matches(in: channels, query: "", kind: nil, group: "Sports"), [0, 1])
        XCTAssertEqual(Search.matches(in: channels, query: "2", kind: nil, group: "Sports"), [1])
        XCTAssertEqual(Search.matches(in: channels, query: "", kind: .movie, group: "Sports"), [])
    }

    func testFavoritesFilterGoesByAddress() {
        let favorites: Set<String> = ["http://h/3", "http://h/1"]
        XCTAssertEqual(Search.matches(in: channels, query: "", kind: nil, urls: favorites), [0, 2])
        XCTAssertEqual(Search.matches(in: channels, query: "espn", kind: nil, urls: favorites), [0])
        XCTAssertEqual(Search.matches(in: channels, query: "", kind: nil, urls: []), [])
    }

    func testCategoriesAreCountedInPlaylistOrder() {
        XCTAssertEqual(Groups.list(in: channels, kind: nil), [
            GroupCount(name: "Sports", count: 2),
            GroupCount(name: "CA", count: 1),
            GroupCount(name: "Films", count: 1),
        ])
        XCTAssertEqual(Groups.list(in: channels, kind: .live), [
            GroupCount(name: "Sports", count: 2),
            GroupCount(name: "CA", count: 1),
        ])
        // every entry is in exactly one category
        XCTAssertEqual(Groups.list(in: channels, kind: nil).map(\.count).reduce(0, +), channels.count)
    }

    func testResumeForgetsTheVeryStartAndTheVeryEnd() {
        XCTAssertNil(Resume.positionToSave(positionMs: 10_000, lengthMs: 3_600_000))
        XCTAssertEqual(Resume.positionToSave(positionMs: 600_000, lengthMs: 3_600_000), 600_000)
        XCTAssertNil(Resume.positionToSave(positionMs: 3_570_000, lengthMs: 3_600_000))
        // length unknown: keep it
        XCTAssertEqual(Resume.positionToSave(positionMs: 600_000, lengthMs: 0), 600_000)
    }

    func testACancelledSearchReturnsNothingAtAll() {
        XCTAssertNil(Search.matches(in: channels, query: "espn", kind: nil, cancelled: { true }))
    }
}

final class RecoveryTests: XCTestCase {

    func testBackoffGrowsThenHolds() {
        XCTAssertEqual((1...7).map { Backoff.delay(forAttempt: $0) }, [1, 2, 4, 8, 15, 30, 30])
    }

    func testAStreamThatKeepsMovingIsNeverStalled() {
        var d = StallDetector(now: 0)
        for t in 0..<100 {
            let idle = d.observe(signature: [t, t * 10, t], playing: true, now: Double(t))
            XCTAssertEqual(idle, 0)
        }
        XCTAssertTrue(d.hasPlayed)
    }

    func testAFrozenStreamIsNoticedAfterTheShortLimitOncePlaying() {
        var d = StallDetector(now: 0)
        _ = d.observe(signature: [1, 1, 1], playing: true, now: 0)
        _ = d.observe(signature: [2, 2, 2], playing: true, now: 1)
        XCTAssertEqual(d.limit(), 10)
        // the counters stop, exactly as they do after the lid was closed
        XCTAssertEqual(d.observe(signature: [2, 2, 2], playing: true, now: 12), 11)
        XCTAssertTrue(d.observe(signature: [2, 2, 2], playing: true, now: 12) > d.limit())
    }

    func testAStreamStillOpeningGetsLonger() {
        var d = StallDetector(now: 0)
        XCTAssertEqual(d.limit(), 25)
        _ = d.observe(signature: [0, 0, 0], playing: false, now: 0)
        XCTAssertTrue(d.observe(signature: [0, 0, 0], playing: false, now: 12) < d.limit())
        XCTAssertTrue(d.observe(signature: [0, 0, 0], playing: false, now: 26) > d.limit())
        XCTAssertFalse(d.hasPlayed)
    }
}

final class GuideTests: XCTestCase {

    func testNamesMatchAcrossSpellings() {
        XCTAssertEqual(XMLTV.keys(forName: "US: USA Network (D)"), ["usanetworkd", "usanetwork"])
        XCTAssertEqual(XMLTV.keys(forName: "US: ESPN*"), ["espn"])
        XCTAssertEqual(XMLTV.keys(forName: "ESPN HD"), ["espnhd", "espn"])
        XCTAssertEqual(XMLTV.keys(forName: "USA Network HD"), ["usanetworkhd", "usanetwork"])
        XCTAssertEqual(XMLTV.keys(forName: "[UK] - Sky Sports 1 FHD"), ["ukskysports1fhd", "skysports1fhd", "skysports1"])
    }

    func testFindsAChannelByNameWhenTheIDIsMissing() {
        let base: TimeInterval = 946_684_800
        let xml = """
        <tv>
          <channel id="ESPN.us"><display-name>ESPN</display-name></channel>
          <channel id="Quiet.us"><display-name>Quiet</display-name></channel>
          <channel id="1"><display-name>USA Network HD (Pacific)</display-name></channel>
          <channel id="2"><display-name>USA Network HD</display-name></channel>
          <programme start="20000101000000 +0000" stop="20000101010000 +0000" channel="1">
            <title>Late</title>
          </programme>
          <programme start="20000101000000 +0000" stop="20000101010000 +0000" channel="2">
            <title>Early</title>
          </programme>
          <programme start="20000101000000 +0000" stop="20000101010000 +0000" channel="ESPN.us">
            <title>SportsCenter</title>
          </programme>
        </tv>
        """
        let guide = XMLTV.read(stream: InputStream(data: Data(xml.utf8)), from: base, to: base + 3600)
        XCTAssertEqual(guide.channel(guideID: "", name: "US: ESPN HD"), "espn.us")
        XCTAssertEqual(guide.channel(guideID: "ESPN.us", name: "anything"), "espn.us")
        XCTAssertEqual(guide.channel(guideID: "wrong", name: "US: ESPN*"), "espn.us")
        XCTAssertEqual(guide.channel(guideID: "usanetwork.us", name: "US: USA Network (D)"), "2")
        // a channel the guide lists but has no shows for is not a match
        XCTAssertNil(guide.channel(guideID: "Quiet.us", name: "Quiet"))
        XCTAssertNil(guide.channel(guideID: "", name: "Nothing Like It"))
    }


    func testTimesWithAndWithoutAnOffset() {
        XCTAssertEqual(XMLTV.time("19700101000000"), 0)
        XCTAssertEqual(XMLTV.time("20000101000000 +0000"), 946_684_800)
        // one in the afternoon in Paris is noon in London
        XCTAssertEqual(XMLTV.time("20000101130000 +0100"), 946_684_800 + 12 * 3600)
        XCTAssertEqual(XMLTV.time("20000101063000 -0530"), 946_684_800 + 12 * 3600)
        XCTAssertEqual(XMLTV.time("20240229120000 +0000"), 1_709_208_000)
        XCTAssertNil(XMLTV.time("soon"))
        XCTAssertNil(XMLTV.time("20001301000000"))
    }

    func testKeepsOnlyTheShowsInsideTheWindowInOrder() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ESPN.us"><display-name>ESPN</display-name></channel>
          <programme start="20000101020000 +0000" stop="20000101030000 +0000" channel="ESPN.us">
            <title lang="en">Late Game</title><desc>Later.</desc>
          </programme>
          <programme start="20000101000000 +0000" stop="20000101020000 +0000" channel="ESPN.us">
            <title>Tom &amp; Jerry</title><title lang="fr">Autre</title>
          </programme>
          <programme start="20000105000000 +0000" stop="20000105010000 +0000" channel="ESPN.us">
            <title>Far Away</title>
          </programme>
          <programme start="20000101000000 +0000" stop="20000101010000 +0000" channel="">
            <title>No Channel</title>
          </programme>
        </tv>
        """
        let base: TimeInterval = 946_684_800
        let guide = XMLTV.parse(Data(xml.utf8), from: base, to: base + 6 * 3600)
        XCTAssertEqual(Array(guide.keys), ["espn.us"])
        XCTAssertEqual(guide["espn.us"]?.map(\.title), ["Tom & Jerry", "Late Game"])

        let shows = guide["espn.us"] ?? []
        let early = XMLTV.nowAndNext(in: shows, at: base + 60)
        XCTAssertEqual(early.now?.title, "Tom & Jerry")
        XCTAssertEqual(early.next?.title, "Late Game")
        let late = XMLTV.nowAndNext(in: shows, at: base + 2 * 3600 + 60)
        XCTAssertEqual(late.now?.title, "Late Game")
        XCTAssertNil(late.next)
        let after = XMLTV.nowAndNext(in: shows, at: base + 9 * 3600)
        XCTAssertNil(after.now)
    }
}

final class CatalogTests: XCTestCase {

    func testGenresAreSplitAndSaidOnce() {
        XCTAssertEqual(Titles.genres("Crime;Drama;TV Crime"), ["Crime", "Drama"])
        XCTAssertEqual(Titles.genres("Animation; Action ;;TV Latest Releases"),
                       ["Animation", "Action", "Latest Releases"])
        XCTAssertEqual(Titles.genres(""), [])
        XCTAssertEqual(Titles.genres("TV"), ["TV"])
    }

    func testMovieYear() {
        XCTAssertEqual(Titles.movie("Rambo III 1988").title, "Rambo III")
        XCTAssertEqual(Titles.movie("Rambo III 1988").year, 1988)
        XCTAssertEqual(Titles.movie("Heat (1995)").title, "Heat")
        XCTAssertEqual(Titles.movie("Heat (1995)").year, 1995)
        XCTAssertEqual(Titles.movie("1917").title, "1917")
        XCTAssertNil(Titles.movie("1917").year)
        XCTAssertEqual(Titles.movie("Blade Runner 2049").title, "Blade Runner 2049")
        XCTAssertEqual(Titles.movie("Up").title, "Up")
        XCTAssertNil(Titles.movie("Apollo 13").year)
    }

    func testEpisodeMark() {
        let a = Titles.episode("Law & Order: Special Victims Unit S26E04")
        XCTAssertEqual(a?.show, "Law & Order: Special Victims Unit")
        XCTAssertEqual(a?.season, 26)
        XCTAssertEqual(a?.episode, 4)
        let b = Titles.episode("FBI s1 e12")
        XCTAssertEqual(b?.show, "FBI")
        XCTAssertEqual(b?.season, 1)
        XCTAssertEqual(b?.episode, 12)
        XCTAssertNil(Titles.episode("Final Table"))
        XCTAssertNil(Titles.episode("S01E01"))
    }

    func testStreamIDNeverHoldsTheLogin() {
        XCTAssertEqual(Titles.streamID("http://h:80/movie/user/pass/12345.mkv"), "12345")
        XCTAssertEqual(Titles.streamID("http://h/series/user/pass/77.mp4?x=1"), "77")
    }

    private func entry(_ i: Int, _ name: String, _ group: String, _ url: String, _ kind: ChannelKind) -> Channel {
        Channel(index: i, name: name, group: group, logo: "", guideID: "", url: url, kind: kind)
    }

    func testShowsGatherEpisodesAndRepeatsBecomeOneTile() {
        let list = [
            entry(0, "FBI S01E02", "Crime;Drama", "http://h/series/u/p/2.mp4", .episode),
            entry(1, "FBI S01E01", "Crime;Drama", "http://h/series/u/p/1.mp4", .episode),
            entry(2, "FBI S01E01", "TV Latest Releases", "http://h/series/u/p/1.mp4", .episode),
            entry(3, "Heat 1995", "Crime;Thriller", "http://h/movie/u/p/9.mkv", .movie),
            entry(4, "Heat 1995", "Crime;Thriller", "http://h/movie/u/p/10.mkv", .movie),
            entry(5, "ESPN", "US Sports", "http://h/live/u/p/5.ts", .live),
        ]
        let catalog = Catalog.build(from: list)!
        XCTAssertEqual(catalog.shows.count, 1)
        XCTAssertEqual(catalog.shows[0].name, "FBI")
        XCTAssertEqual(catalog.shows[0].episodes.map(\.channel), [1, 0])
        XCTAssertEqual(catalog.shows[0].genres, ["Crime", "Drama", "Latest Releases"])
        XCTAssertEqual(catalog.showGenres.first?.name, "Latest Releases")
        // two addresses are two films, whatever they are called
        XCTAssertEqual(catalog.movies.count, 2)
        XCTAssertEqual(catalog.movies[0].title, "Heat")
        XCTAssertEqual(catalog.movieGenres.map(\.name), ["Crime", "Thriller"])
        XCTAssertEqual(catalog.movieGenres.map(\.count), [2, 2])
        XCTAssertEqual(catalog.showOfEpisode["http://h/series/u/p/2.mp4"], 0)
    }
}
